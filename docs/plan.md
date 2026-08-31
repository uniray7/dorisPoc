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
4. **The target is not one VM.** This host will scale in and out, likely to **3 VMs in
   one Nomad cluster**, with both Doris clusters and the syncer scheduled across them.
   Phase 1 must therefore be built with host-routable advertise addresses and exposed
   ports from the start, or scaling out is a rewrite. → ADR-008
5. **Official Doris CCR docs stop at 2.1.** No CCR documentation exists for 3.x or 4.x.
   CCR still works there, but expect to read 2.1 docs while running 3.0. → ADR-004

---

## Target architecture (ADR-008 option A)

One **node stack**, replicated per VM. Today there is one VM; the same files run on three.

```
  ┌───────────────────────────── VM (× 1 today, × 3 later) ─────────────────────────────┐
  │                                                                                     │
  │  ┌──────────── docker compose ────────────┐                                         │
  │  │  consul-server   network_mode: host    │  advertise = VM's routable IP           │
  │  │  nomad-server    network_mode: host    │  8300/8301/8302/8500/8600, 4646/47/48   │
  │  └────────────────────────────────────────┘                                         │
  │             ▲                    ▲                                                  │
  │             │ 127.0.0.1:8500     │ 4647 RPC                                         │
  │  ┌──────────┴────────────────────┴──────── native, systemd, root ────────────────┐  │
  │  │  nomad client  ── docker driver ──▶  host Docker daemon                       │  │
  │  └───────────────────────────────────────────────────────────────────────────────┘  │
  └─────────────────────────────────────────────────────────────────────────────────────┘

  1 VM:   bootstrap_expect = 1,  retry_join = []
  3 VMs:  bootstrap_expect = 3,  retry_join = [vm1, vm2, vm3]        ← the only diff
```

**One Consul agent per VM, and it is the server.** With the Consul server on the host
network namespace there is no room for a second agent on 8500/8301/8600, so the Nomad
server and the native Nomad client both use it via the default
`consul { address = "127.0.0.1:8500" }`. ADR-002 is satisfied — the agent is local — with
the caveat noted in ADR-008 that it is a server rather than a client agent.

**Everything advertises the VM's routable IP**, driven by one environment variable per
VM. Never a `172.x` bridge address: that is the single thing which, if got wrong now,
turns scale-out into a rewrite.

**Versions:** Nomad 2.0.5, Consul 2.0.3 (both current OSS; Nomad 2.0.0 introduced no
config-breaking changes for the blocks we use).

**Security:** none in Phase 1 — no ACLs, no gossip encryption, no mTLS (ADR-009). Keep the
cluster on a private network.

---

## Phase 1 — Nomad + Consul cluster *(current scope, runs on this VM)*

**Deliverables**

| Path | Purpose |
|---|---|
| `compose.yaml` | One Consul server + one Nomad server, both `network_mode: host` — identical on every VM |
| `.env.example` | Per-VM values: `ADVERTISE_IP`, `BOOTSTRAP_EXPECT`, `RETRY_JOIN`, `NODE_NAME` |
| `config/consul/server.hcl` | Consul server config (also this node's local agent) |
| `config/nomad/server.hcl` | Nomad server config |
| `config/nomad/client.hcl` | Nomad client config (used natively) |
| `scripts/install-client.sh` | Installs Nomad from the official apt repo, writes the systemd unit, starts the native client — takes the server addresses as arguments so it is unchanged on VM 2 and VM 3 |
| `scripts/verify.sh` | Asserts cluster health, including that no agent advertises a bridge address |
| `Makefile` | `make up`, `make down`, `make verify`, `make status` |

No `config/consul/agent.hcl`: every VM in this topology runs a Consul *server*, so there
is no client-only agent to configure (ADR-008).

**Steps**
1. Write the Consul server config and bring it up with `bootstrap_expect = 1`, on the
   host network namespace, advertising the VM's routable IP; confirm a leader.
2. Add the Nomad server, same networking, pointing at `127.0.0.1:8500`; confirm it is
   leader and registered in Consul.
3. Install Nomad natively via the HashiCorp apt repo; configure the client to join the
   server and to use the local Consul agent; enable the docker driver with the
   `allowed_modes` / `volumes` settings that Doris will later need (CVE-2026-14891 makes
   these mandatory for host namespace modes).
4. Run a throwaway job (a small container with a `service` block) to prove scheduling and
   Consul registration end-to-end.

**Multi-VM readiness, to build in now rather than retrofit (ADR-008)**
- Every agent advertises the VM's routable IP — Consul `advertise_addr`, Nomad
  `advertise { http, rpc, serf }` — sourced from one env var per VM, never a bridge IP.
- Consul 8300/8301/8302/8500/8600 and Nomad 4646/4647/4648 bound on the host address.
- `retry_join` as an address list driven by config, so adding a VM is a list edit.
- `scripts/install-client.sh` takes the server addresses as arguments, so the same script
  provisions VM 2 and VM 3 unchanged.

**Exit criteria** *(counts are per current VM count — 1 today, 3 after scale-out)*
- `consul members` → one agent per VM, all alive
- `consul operator raft list-peers` → leader elected
- `nomad server members` → one per VM, leader elected
- `nomad node status` → one ready client per VM, docker driver healthy
- Test job runs, and its service appears in the Consul catalog with a passing health check
- Consul UI on :8500 and Nomad UI on :4646 reachable
- Every agent's advertised address is the host's routable IP, not a `172.x` bridge address
  — checked with `consul members` and `nomad node status -verbose`

**Scale-out check (when VM 2 and VM 3 exist):** set `BOOTSTRAP_EXPECT=3` and fill
`RETRY_JOIN`, copy the same tree to each VM, `make up`, run `install-client.sh` — and
expect no other edits. If that is not true, ADR-008 was not honoured somewhere.

---

## Phase 2 — Two Doris clusters on Nomad *(blocked on a larger VM)*

Not designed in detail yet — deliberately, since ADR-004 (version) and ADR-005 (identity
under a scheduler) are still open and the answers change the job specs.

**Prerequisites**

Doris's documented dev/test minimum is 8 cores + 8 GB (FE) and 8 cores + 16 GB (BE) *per
cluster*, and CCR additionally wants **≥ 4 GB FE heap per CCR job on both clusters**.
Two ways to meet that:

| Shape | Sizing | Notes |
|---|---|---|
| One VM | **8 vCPU / 32 GB / 200 GB** | 16 GB would be tight enough to mislead. Clusters A and B share a host, so B needs an offset port scheme. |
| Three VMs *(the stated direction)* | VM1 + VM2: **8 vCPU / 24 GB / 100 GB** each, one Doris cluster apiece. VM3: **4 vCPU / 8 GB** for the syncer, ingestion and control plane. | Each VM is smaller and easier to obtain; pinning one cluster per VM lets both use the documented default Doris ports. |

- Host tuning Doris requires, **on every VM that runs a BE or FE**: `vm.max_map_count =
  2000000` (this VM is at 1048576), swap off (already true), THP `madvise`, raised
  file-handle limits, NTP (metadata clock skew must stay under 5000 ms — a real concern
  across separate VMs, not one host).
- Firewall/VPC rules between the VMs for the Doris port set — in particular BE↔BE
  8040 and 8060, which CCR's full sync depends on.

**Work**
1. Resolve ADR-004 (Doris version) and ADR-005 (identity/pinning/ports/volumes). On a
   multi-client cluster ADR-005 is load-bearing: pin each FE/BE to a named node with a
   `constraint`, back it with a `host_volume`, and confirm a drained-and-restarted
   allocation rejoins rather than re-registering as a new node.
2. ~~Job specs for cluster A and cluster B~~ — **done**, see `jobs/`. Each is 1 FE + 1 BE
   with `enable_feature_binlog=true` appended to `fe.conf` and `be.conf` at container
   start, host networking, static ports, host volumes for identity, and placement by
   `meta.doris_cluster`. The FE/BE container contract they target is documented in
   `research.md` §11.
3. FE tuning for CCR: `max_backup_restore_job_num_per_db = 2`,
   `ignore_backup_tmp_partitions = true`, `enable_restore_snapshot_rpc_compression = true`.
   BE tuning: `thrift_max_message_size = 2000000000`.
4. Register BEs with their FE; confirm both clusters healthy via the MySQL protocol on 9030.
5. Ensure BE↔BE reachability **between** clusters — CCR's full sync has the downstream BEs
   pull snapshot data directly from upstream BEs.

**Exit criteria:** both clusters independently healthy; `show backends` reports alive BEs
with addresses the other cluster can actually reach.

**First things to check when a real VM exists**, in order:
1. `make plan-a` places instead of exhausting memory.
2. The FE comes up and `SHOW FRONTENDS` reports the VM's routable IP — not `172.x`.
3. The appended `fe.conf` settings actually took effect:
   `ADMIN SHOW FRONTEND CONFIG LIKE "enable_feature_binlog"`. This is the assumption in
   the job specs least supported by documentation.
4. Restart the FE allocation and confirm it rejoins from `doris-meta` rather than
   re-registering — the whole of ADR-005 rests on this.

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
| 1 — Nomad + Consul | **Done and verified on this VM** (2026-08-28) — `make verify` passes every exit criterion | — |
| 2 — Two Doris clusters | **Job specs written and validated; never run** | A VM that can actually run Doris |
| 3 — CCR | Outlined | Phase 2 |
| 4 — Ingestion | Outlined | Phase 3 |

### What "Phase 2 written but not run" means

`jobs/doris-cluster-a.nomad.hcl` and `jobs/doris-cluster-b.nomad.hcl` exist, pass
`nomad job validate` and `nomad fmt -check`, and `make plan-a` reaches resource
evaluation with the placement constraint satisfied — failing only on
`Dimension "memory" exhausted`, which is the correct answer on a 3.8 GB host.

Nothing about Doris itself has been observed. The Doris images have deliberately **not**
been pulled: `fe-3.0.7` + `be-3.0.7` is ~4.4 GiB compressed against 4.6 GB free disk, and
pulling one cluster's pair would fill the disk. ADR-004 and ADR-005 are decided and
implemented, but they are decided *from the entrypoint source*, not from a running
cluster.

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Doris identity churn under rescheduling corrupts cluster membership | High | ADR-005 — pin allocations, persistent volumes, FQDN mode, static ports |
| No official CCR docs for Doris 3.x/4.x | Medium | Target 3.0 but work from 2.1 docs; or drop to 2.1 |
| CCR FE memory (≥4 GB heap per job, per cluster) | Medium | Size the Phase 2 host accordingly; cap `binlog.max_bytes` / `binlog.ttl_seconds` |
| Syncer is a SPOF without a MySQL backend | Low for a POC | Accept; note it |
| Nomad servers in containers are outside the image's stated purpose | Low | ADR-001a — go fully native if it misbehaves |
| Doris `vm.max_map_count` requirement (2000000) | Low | Set it in Phase 2 host prep, on every Doris-hosting VM |
| Phase 1 built single-host, then rewritten for 3 VMs | High | ADR-008 — decide the topology *before* writing `compose.yaml`; advertise host IPs from day one |
| Scale-in kills a Doris BE without draining it | High | `ALTER SYSTEM DECOMMISSION BACKEND` and confirm empty first; never scale in the Raft server tier casually (ADR-008) |
| Clock skew between VMs breaks Doris metadata | Medium | NTP on every VM; skew < 5000 ms |
