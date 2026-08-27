# Doris POC — Plan

## Goal

Prove that two Apache Doris clusters, scheduled by HashiCorp Nomad with Consul service
discovery, can be kept in sync by [`selectdb/ccr-syncer`](https://github.com/selectdb/ccr-syncer),
and that data ingested into the active cluster appears on the standby.

## Original brief

1. Nomad + Consul cluster on Docker (assumed Docker Compose)
2. Two Apache Doris clusters on that Nomad cluster
3. Active-standby, synced with CCR via `ccr-syncer`
4. An ingestion pipeline feeding fake data into the active cluster; observe standby sync

## What changed after research

Two findings from primary sources reshaped the approach. Full detail in
[`research.md`](./research.md); reasoning in [`decisions.md`](./decisions.md).

1. **Nomad clients cannot run in Docker** (officially unsupported — clients need root,
   `CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, cgroups). The control plane goes in Compose; the
   Nomad client runs natively on the host. → ADR-001
2. **Each Nomad node needs its own local Consul agent** — sharing one Consul endpoint is
   explicitly forbidden. → ADR-002

Also worth knowing early:

3. **This host cannot run Doris.** 2 vCPU / 3.9 GB RAM / 4.9 GB free disk. The Doris
   FE+BE images alone are ~4.4 GB compressed (~8–10 GB unpacked), and Doris's own
   *dev/test minimum* is 8 cores + 8 GB for FE and 8 cores + 16 GB for BE — per cluster.
   Phase 1 fits comfortably; Phases 2–4 need a bigger machine.
4. **Official Doris CCR docs stop at 2.1.** No CCR documentation exists for 3.x or 4.x.
   CCR still works there, but expect to read 2.1 docs while running 3.0. → ADR-004

---

## Target architecture (Phase 1)

```
                       host: this VM
  ┌──────────────────────── docker compose ────────────────────────┐
  │                                                                │
  │  consul-server-1 ─┐                                            │
  │  consul-server-2 ─┼── Raft quorum (bootstrap_expect = 3)       │
  │  consul-server-3 ─┘                                            │
  │                                                                │
  │  nomad-server-1 + consul-agent-1  (shared netns)  ─┐           │
  │  nomad-server-2 + consul-agent-2  (shared netns)  ─┼─ Raft     │
  │  nomad-server-3 + consul-agent-3  (shared netns)  ─┘           │
  │                                                                │
  └────────────────────────────────────────────────────────────────┘
                              ▲
                              │ 4647 RPC
   ┌──────────────────────────┴──────────── native, systemd, root ─┐
   │  nomad client agent  ──local 127.0.0.1:8500──▶  consul agent  │
   │        │                                                      │
   │        └── docker driver ──▶ host Docker daemon               │
   └───────────────────────────────────────────────────────────────┘
```

Each Nomad server container has a Consul client agent sharing its network namespace, so
Nomad's default `consul { address = "127.0.0.1:8500" }` is correct without override.

**Versions:** Nomad 2.0.5, Consul 2.0.3 (both current OSS; Nomad 2.0.0 introduced no
config-breaking changes for the blocks we use).

---

## Phase 1 — Nomad + Consul cluster *(current scope, runs on this VM)*

**Deliverables**

| Path | Purpose |
|---|---|
| `compose.yaml` | 3 Consul servers, 3 Nomad servers, 3 Consul agent sidecars |
| `config/consul/server.hcl` | Consul server config |
| `config/consul/agent.hcl` | Consul client agent config |
| `config/nomad/server.hcl` | Nomad server config |
| `config/nomad/client.hcl` | Nomad client config (used natively) |
| `scripts/install-client.sh` | Installs Nomad + Consul from the official apt repo, writes systemd units, starts the native client |
| `scripts/verify.sh` | Asserts cluster health |
| `Makefile` | `make up`, `make down`, `make verify`, `make status` |

**Steps**
1. Write Consul server config and bring up the 3-server Consul cluster; confirm a leader.
2. Add the Nomad servers plus their Consul agent sidecars; confirm Nomad Raft quorum.
3. Install Nomad + Consul natively via the HashiCorp apt repo; configure the client to
   join the servers; enable the docker driver with the `allowed_modes` / `volumes`
   settings that Doris will later need (CVE-2026-14891 makes these mandatory for host
   namespace modes).
4. Run a throwaway job (a small container with a `service` block) to prove scheduling and
   Consul registration end-to-end.

**Exit criteria**
- `consul members` → 3 servers alive + 1 agent per Nomad node
- `consul operator raft list-peers` → leader elected
- `nomad server members` → 3 alive, leader elected
- `nomad node status` → 1 ready client, docker driver healthy
- Test job runs, and its service appears in the Consul catalog with a passing health check
- Consul UI on :8500 and Nomad UI on :4646 reachable

**Open question for you:** do you want ACLs and gossip encryption enabled in Phase 1?
Recommendation: **no** — it roughly doubles the bring-up complexity and adds token
plumbing that gets in the way of the Doris work. Better added in a later hardening pass.

---

## Phase 2 — Two Doris clusters on Nomad *(blocked on a larger VM)*

Not designed in detail yet — deliberately, since ADR-004 (version) and ADR-005 (identity
under a scheduler) are still open and the answers change the job specs.

**Prerequisites**
- A host of roughly **8 vCPU / 32 GB RAM / 200 GB disk**. Rationale: Doris's documented
  dev/test minimum is 8 cores + 8 GB (FE) and 8 cores + 16 GB (BE) *per cluster*; CCR
  additionally wants **≥ 4 GB FE heap per CCR job on both clusters**. 16 GB would be tight
  to the point of being misleading; 32 GB leaves room for the control plane and ingestion.
- Host tuning Doris requires: `vm.max_map_count = 2000000` (this VM is at 1048576), swap
  off (already true), THP `madvise`, raised file-handle limits, NTP.

**Work**
1. Resolve ADR-004 (Doris version) and ADR-005 (identity/pinning/ports/volumes).
2. Job specs for cluster A and cluster B, each 1 FE + 1 BE, with `enable_feature_binlog=true`
   baked into `fe.conf` and `be.conf` from the start — CCR needs it on both clusters and
   turning it on later means a restart.
3. FE tuning for CCR: `max_backup_restore_job_num_per_db = 2`,
   `ignore_backup_tmp_partitions = true`, `enable_restore_snapshot_rpc_compression = true`.
   BE tuning: `thrift_max_message_size = 2000000000`.
4. Register BEs with their FE; confirm both clusters healthy via the MySQL protocol on 9030.
5. Ensure BE↔BE reachability **between** clusters — CCR's full sync has the downstream BEs
   pull snapshot data directly from upstream BEs.

**Exit criteria:** both clusters independently healthy; `show backends` reports alive BEs
with addresses the other cluster can actually reach.

---

## Phase 3 — CCR replication

1. Build a `ccr-syncer` image (no official image exists) — either from source via
   `build.sh` or from the prebuilt `ccr-syncer-3.0.6-rc05-x64.tar.xz` the official
   quickstart links. → ADR-006
2. Run the syncer as a Nomad job; API on **:9190**.
3. Create a sync user on both clusters with `Select_priv`, `Load_priv`, `Alter_priv`,
   `Create_priv`, `Drop_priv` + Admin.
4. Create the test database and table on the source; enable binlog
   (`enable_db_binlog.sh` for a whole DB, or `ALTER TABLE ... SET ("binlog.enable"="true")`).
5. `POST /create_ccr` with src/dest (`port` = FE 9030, `thrift_port` = FE `rpc_port` 9020).
6. Verify: full sync completes, then incremental sync engages.

**Exit criteria:** `get_lag` returns a healthy job; a row written upstream appears
downstream.

---

## Phase 4 — Ingestion + observation

1. A generator producing fake rows into cluster A. Default choice: **Stream Load** over
   the FE HTTP port (8030) — simplest, no external dependency. If you'd rather exercise a
   more realistic path, Routine Load from Kafka is the alternative, at the cost of running
   Kafka.
2. A watcher that polls both clusters and reports row counts, divergence, and replication
   lag.
3. Scenarios worth running: steady-state lag; burst load; syncer restart mid-stream;
   schema change (DDL) propagation; pause/resume via the syncer API.

**Exit criteria:** continuous ingestion into A, with B converging, and lag reported over
time.

---

## Sequencing and current status

| Phase | Status | Blocker |
|---|---|---|
| 0 — Research | **Done** | — |
| 1 — Nomad + Consul | Ready to build | ACL/TLS question above |
| 2 — Two Doris clusters | Designed at outline only | Larger VM; ADR-004, ADR-005 |
| 3 — CCR | Outlined | Phase 2 |
| 4 — Ingestion | Outlined | Phase 3 |

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Doris identity churn under rescheduling corrupts cluster membership | High | ADR-005 — pin allocations, persistent volumes, FQDN mode, static ports |
| No official CCR docs for Doris 3.x/4.x | Medium | Target 3.0 but work from 2.1 docs; or drop to 2.1 |
| CCR FE memory (≥4 GB heap per job, per cluster) | Medium | Size the Phase 2 host accordingly; cap `binlog.max_bytes` / `binlog.ttl_seconds` |
| Syncer is a SPOF without a MySQL backend | Low for a POC | Accept; note it |
| Nomad servers in containers are outside the image's stated purpose | Low | ADR-001a — go fully native if it misbehaves |
| Doris `vm.max_map_count` requirement (2000000) | Low | Set it in Phase 2 host prep |
