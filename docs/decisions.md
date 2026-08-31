# Architecture Decisions

Each decision records the constraint that forced it and the primary source behind it.
Facts are in [`research.md`](./research.md).

---

## ADR-001 — Nomad clients run natively on the host, not in Docker

**Status:** Proposed (needs sign-off — this contradicts the original assumption)

**Context.** The original brief was "set up a HashiCorp Nomad cluster along with Consul on
Docker, I assume it will be a docker compose". Research turned up an explicit
counter-statement in HashiCorp's own documentation:

> "running Nomad clients in Docker containers is not officially supported"
> — [Nomad installation requirements](https://developer.hashicorp.com/nomad/docs/deploy/production/requirements)

with the reasoning that clients need `root`, `CAP_SYS_ADMIN`, `CAP_NET_ADMIN` and direct
cgroup access. The same page states the `hashicorp/nomad` image "is intended to be used in
automated pipelines for CLI operations".

Running the client in a container *appears* to work if you mount `/var/run/docker.sock`,
because the docker driver just talks to the host daemon. But the containers it launches
are siblings on the host daemon, outside Nomad's cgroup hierarchy — so CPU/memory
isolation, `bridge` network mode, CNI, and resource fingerprinting are all
degraded or broken. For a POC whose entire point is to observe resource behaviour of two
Doris clusters, silently losing resource isolation is a bad trade.

**Decision.** Split the plane:

- **Control plane in Docker Compose** — Consul servers and Nomad servers. Servers never
  run workloads, so none of the client constraints apply. Consul-in-Docker is explicitly
  supported by HashiCorp.
- **Data plane native on the host** — the Nomad client agent and its co-located Consul
  client agent, installed from the official HashiCorp apt repository and run as root under
  systemd.

Doris containers are then launched by a properly-privileged native Nomad client onto the
host Docker daemon.

**Consequences.**
- Keeps `docker compose up` as the entry point for the cluster, matching the original intent.
- The client is supported and correctly isolated.
- Cost: a two-step bring-up (compose + a host install script) rather than one command.
- Nomad servers in containers remain slightly outside the image's stated purpose. They do
  not need host privileges, so this is judged acceptable for a POC. **If you want to be
  strictly within documented territory, run the servers natively too** (see ADR-001a).

**Alternatives rejected.**
- *Everything in Compose.* Matches the original assumption, but puts the client in
  explicitly unsupported territory.
- *Everything native.* Most supportable, but discards the "on Docker" requirement and
  makes the cluster harder to reset between experiments.

---

## ADR-001a — Optional: fully-native control plane

**Status:** Recorded as an escape hatch, not planned

If the containerised Nomad servers cause trouble, install Nomad natively on the host as
well, run it in combined server+client mode, and keep only Consul in Compose. The job
specs and everything downstream are unaffected.

---

## ADR-002 — One Consul agent per Nomad node

**Status:** Accepted

**Context.** The obvious POC shortcut is to point every Nomad agent at a single shared
Consul endpoint. HashiCorp forbids this:

> "Each Nomad client should have a local Consul agent running on the same host, reachable by Nomad."
> "Nomad clients should never share a Consul agent or talk directly to the Consul servers."
> — [Nomad + Consul](https://developer.hashicorp.com/nomad/docs/networking/consul)

Nomad's `consul` block also defaults to `address = "127.0.0.1:8500"`, i.e. a local agent
is the assumed topology.

**Decision.** Every Nomad node gets a Consul agent reachable at `127.0.0.1:8500`.

**As built under ADR-008 option A:** each VM runs a single Consul agent — the Consul
server container on the host network namespace — and both the Nomad server and the native
Nomad client on that VM reach it at `127.0.0.1:8500`. The requirement "a local Consul
agent on the same host" is met; the caveat that this agent is a server rather than a
client is flagged in ADR-008 and is not explicitly addressed by the documentation.

*Original per-role plan, retained for the record and applicable if client-only VMs are
added later:* a Consul client agent container sharing the Nomad server container's network
namespace (`network_mode: "service:<nomad-server>"`), and a native Consul client agent
under systemd alongside a native Nomad client.

---

## ADR-003 — Cluster shape: 3 Consul servers, 3 Nomad servers, 1 Nomad client

**Status:** **Superseded by ADR-008.** The 3+3-on-one-host shape does not survive the
multi-VM target. The cluster is now one Consul server + one Nomad server + one Nomad
client *per VM*: today a single node, and a real three-node quorum once the VMs exist.
The reasoning below still stands on its own terms — it simply assumed one host.

Three servers each give a real Raft quorum (HashiCorp recommends 3–5 per region, odd
numbers) and let us demonstrate leader election and failure tolerance, which a single
server cannot. Consul and Nomad servers are small; the measured 3.9 GB host absorbs six
of them plus a client easily.

One Nomad client is enough for Phase 1. Phase 2 revisits this: Doris FE/BE persist their
own identity, so the number of clients interacts with how Doris is pinned (ADR-005).

---

## ADR-004 — Doris version: 3.0.7

**Status:** **Accepted (2026-08-28).** Pinned to `apache/doris:fe-3.0.7` /
`apache/doris:be-3.0.7` in `jobs/`.

**What settled it.** `selectdb/ccr-syncer` publishes no 3.x or 4.x git tag — its tags
stop at `v2.1.3-rc02`, and the only 3.0-era build is the prebuilt
`ccr-syncer-3.0.6-rc05-x64.tar.xz` from the Doris quickstart. The version rule is
`syncer >= downstream >= upstream`, so **Doris 4.0/4.1 have no syncer at all** even
though their images exist. That removes the newest lines from consideration and leaves
2.1 versus 3.0; 3.0 wins on being current, and `fe-3.0.6` does not exist so the 3.0
line pins at 3.0.7. The cost stands: some CCR docs must be read from the 2.1 pages.

**Original reasoning, retained:**

The tension:

- **Doris 2.1** is the newest release line with **complete official CCR documentation**.
  Doris CCR docs are not versioned for 3.x or 4.x at all (verified: those URLs 404).
- **Doris 3.0** is current and clearly CCR-capable — the official quickstart ships a
  `ccr-syncer-3.0.6` binary and the config reference documents 3.0.3/3.0.4-specific CCR
  behaviour. It requires **Java 17** (2.1 requires Java 8).
- The syncer version rule is `Syncer >= downstream Doris >= upstream Doris`, and syncer
  ≥ 3.0.4 dropped Doris 2.0 support entirely.

**Leaning:** Doris 3.0.x, accepting that some CCR docs must be read from the 2.1 pages.
Choosing 2.1 buys documentation fidelity at the cost of starting a new POC on a trailing
line. Not decided yet.

---

## ADR-005 — Doris identity under a scheduler

**Status:** **Accepted (2026-08-28)** and implemented in `jobs/doris-cluster-{a,b}.nomad.hcl`.
Written but **not yet run against real Doris** — this host cannot start it (see below).

**Decision.** Four mechanisms, together:

1. **`network_mode = "host"`.** The container takes the VM's routable IP. That address
   is stable across restarts, reachable from the other cluster's BEs for CCR, and is
   what `SHOW BACKENDS` will report. No client-side permission is needed for this —
   `allowed_modes` allowlists pid/ipc/userns/uts only, not networking (research.md §12).
2. **Static ports, not Nomad's dynamic 20000–32000 range.** FE 8030/9020/9030/9010 and
   BE 9060/8040/9050/8060, declared `static` in the group `network` block so Nomad
   reserves them and refuses a conflicting placement.
3. **Host volumes for identity.** `doris-fe-meta` → `/opt/apache-doris/fe/doris-meta`
   and `doris-be-storage` → `/opt/apache-doris/be/storage`. The official entrypoints
   skip registration entirely when those directories are already populated, so a
   restart rejoins instead of re-registering. Losing a volume is what corrupts
   membership.
4. **Pinned by client meta, not by node name.** Each VM declares
   `meta { doris_cluster = "a" | "b" | "none" }`; the jobs carry
   `constraint { attribute = "${meta.doris_cluster}" ... }`. The job files are
   therefore identical regardless of what the VMs are called.
   **Invariant: exactly one Nomad client per `doris_cluster` value.** The FE and BE are
   separate groups and each interpolates `${attr.unique.network.ip-address}` as the
   cluster address, which is only correct while they land on the same node.

**FQDN mode is rejected, and not by choice.** The official FE image validates
`FE_SERVERS` against a regex that accepts literal IPv4 only and rejects hostnames
(research.md §11). Doris FQDN mode cannot be driven through this entrypoint, so stable
identity has to come from pinning plus host networking instead. Reaching FQDN mode would
mean bypassing the entrypoint, which is a larger change than the POC needs.

**Ports across VMs.** With one Doris cluster pinned per VM, clusters A and B both use
the documented default ports and no offset scheme is needed. Two clusters on one VM
would collide — which is another reason the topology is one cluster per VM (ADR-008).

**Not yet verified.** The job specs pass `nomad job validate` and `nomad fmt`, and
`nomad job plan` reaches resource evaluation with the constraint satisfied — it fails
only on `Dimension "memory" exhausted`, as it must on a 3.8 GB host. Nothing about
Doris's *runtime* behaviour under rescheduling has been observed yet. The specific
assumption most worth testing first is that appending to `fe.conf` / `be.conf` at
container start overrides the shipped defaults (last-value-wins parsing).

**Original framing, retained:**

Doris is not a stateless workload. FE and BE persist their own network identity into
metadata, and BEs are registered with the FE by address. Under a scheduler that can
reschedule an allocation onto a different node with a different address, a naively-written
Doris job will corrupt its own cluster membership.

Options to evaluate in Phase 2 (all require verification against the official docs):
- Enable Doris **FQDN mode** so nodes identify by hostname rather than IP, and give each
  node a stable Consul/DNS name.
- Pin allocations to specific clients with constraints, plus `host_volume` for persistent
  FE metadata and BE storage.
- Static ports rather than Nomad's dynamic 20000–32000 range, since Doris ports must be
  fixed and consistent (notably FE `rpc_port`, which the docs require to be identical
  across FEs).

Additionally, CCR needs BE↔BE reachability across *both* clusters (downstream BEs pull
snapshots from upstream BEs over `webserver_port` 8040), so the two clusters cannot be
isolated on separate networks. On a multi-VM cluster that is inter-VM traffic requiring
firewall/VPC rules, not merely a shared Docker network — see ADR-008.

---

## ADR-006 — CCR syncer is built and containerised in-repo

**Status:** Accepted

`selectdb/ccr-syncer` publishes no container image. Two supply routes exist: build from
source (`bash build.sh`), or download the prebuilt tarball referenced by the official
Doris quickstart. We will add a Dockerfile that does one of these and run the syncer as a
Nomad job like everything else.

Note for later: syncer HA depends on a MySQL backend. Single-syncer is fine for a POC;
just be aware the syncer is a single point of failure without it.

---

## ADR-007 — "Active-standby" is asynchronous and manually failed over

**Status:** Accepted — terminology clarification

The brief describes the two clusters as active-standby. Worth being precise about what
Doris CCR actually provides: **asynchronous, one-directional** replication built on
backup/restore for the initial sync and binlog replay for the incremental stream. It is
not synchronous replication and there is no automatic failover or automatic
promotion. The standby is queryable (it is used for read-write separation), but
promotion is an operational procedure.

The POC should therefore measure **replication lag** (the syncer's `get_lag` endpoint)
rather than assume zero-RPO behaviour.

---

## ADR-008 — Multi-VM target: build Phase 1 so it scales out without a rewrite

**Status:** Accepted (2026-08-28) — **option A**, the symmetric node stack, with the
one-agent-per-VM correction recorded below.

**Context.** The POC will not stay on one VM. The stated intent is that this host scales
in and out as needed, likely to **3 VMs forming one Nomad cluster**, with the two Doris
clusters and `ccr-syncer` scheduled across it.

That invalidates an assumption baked into the Phase 1 design: that every process shares a
single host, so Docker bridge networking and default advertise addresses are sufficient.
Across VMs they are not. Three things break the moment a second VM joins:

1. **Advertise addresses.** A Consul or Nomad agent that advertises its Docker bridge IP
   (`172.x`) is unreachable from another VM. Both products must advertise the VM's
   routable address — Consul `advertise_addr`, Nomad `advertise { http, rpc, serf }`.
   This costs nothing on one VM and is the difference between working and not on three.
2. **Port exposure.** Consul 8300/8301/8302/8500/8600 and Nomad 4646/4647/4648 must be
   reachable on the host address, not just inside a Compose network — plus the firewall
   or VPC rules to match. See the port tables in [`research.md`](./research.md) §4.
3. **Three servers on one host cannot all use standard ports.** ADR-003's shape (3 Consul
   servers + 3 Nomad servers on this VM) only works today because they are on a bridge
   with private IPs. Exposing them on one host means per-server port shifting or host IP
   aliases — carried as permanent complexity for a quorum that is fake anyway: three Raft
   peers in one kernel on one disk tolerate no real failure.

**Options.**

- **A — Symmetric node stack, grown in place.** Each VM runs an identical stack: one
  Consul server, one Nomad server, one native Consul agent, one native Nomad client, all
  on host-routable addresses with standard ports. Today `bootstrap_expect = 1` and an
  empty `retry_join`; at three VMs, `bootstrap_expect = 3` and the peer list filled in.
  Nothing else changes — same files, same ports, no port math. Cost: no leader-election
  demonstration until the other VMs exist.
- **B — Central control plane, client-only workers.** Keep ADR-003's 3+3 control plane on
  this VM and join VMs 2 and 3 as pure Nomad clients via `install-client.sh`. Preserves
  the quorum demonstration and the existing design; costs the per-server port or IP
  juggling from (3) now, and leaves VM1 a control-plane single point of failure.
- **C — Build Phase 1 as designed and rework at scale-out.** Cheapest today, and the
  rework is not small: networking model, config layout, and bring-up all change.

**Decision: A.** The POC's subject is Doris and CCR, not Consul Raft; a symmetric stack
that grows by editing two values is worth more than a leader election on a single failure
domain. B is defensible if the quorum behaviour is itself something you want to watch.

**Correction to the shape as first written: one Consul agent per VM, and it is the
server.** The option was initially described as a Consul *server* plus a separate native
Consul *client* agent on each VM. That cannot work: with the server on the host network
namespace, both agents contend for 8500, 8301 and 8600 on the same host. Under A each VM
therefore runs exactly **one** Consul agent — the server — and the native Nomad client
points at it via the default `127.0.0.1:8500`. `config/consul/agent.hcl` is consequently
not part of Phase 1; it returns only if client-only VMs are ever added beyond the three
server nodes.

**Per-VM stack, final:**

| Process | How it runs |
|---|---|
| Consul server (also the node's local agent) | Compose, `network_mode: host` |
| Nomad server | Compose, `network_mode: host` |
| Nomad client | Native, systemd, root (ADR-001) |

Scaling to 3 VMs: same files on each, `bootstrap_expect` 1 → 3, `retry_join` gains the
peer addresses.

**Note on co-location (unverified interpretation, not doc-backed).** Under A — as
corrected above — a VM's Nomad client uses the Consul agent that is also a Consul
*server*. ADR-002 quotes
"Nomad clients should never share a Consul agent or talk directly to the Consul servers";
read in context that is about pointing a client at a *remote* agent, and a co-located
server agent still satisfies "a local Consul agent on the same host". This reading is
not stated explicitly in the documentation and should be confirmed before relying on it.

**Consequences beyond Phase 1.**

- **ADR-005 stops being theoretical.** With one Nomad client, a rescheduled Doris
  allocation always lands back on the same address, so identity is stable by accident.
  With three clients it is not, and a naive job spec will corrupt cluster membership on
  the first reschedule. Pinning, host volumes and FQDN mode must be resolved *before*
  the second client joins, not merely before Phase 2.
- **Doris port collisions disappear.** Pinned one Doris cluster per VM, cluster A and
  cluster B can both use the documented default ports instead of an offset scheme for B.
  This only holds if the pinning in ADR-005 is real.
- **CCR's BE↔BE requirement becomes a cross-VM firewall concern.** Downstream BEs pull
  snapshots from upstream BEs over 8040/8060; that is now inter-VM traffic and needs
  explicit VPC or firewall rules, not just a shared Docker network.
- **FQDN mode gets more attractive.** One FE per VM under `network_mode = "host"` means
  the VM hostname is a stable identity, which is exactly what Doris FQDN mode wants.

**Scale-in is not symmetric with scale-out.** Removing a VM is a procedure, not a
`docker compose down`:
- A Doris BE must be drained with `ALTER SYSTEM DECOMMISSION BACKEND` and confirmed empty
  before its host goes away; killing it loses replicas.
- A departing Nomad or Consul *server* must leave Raft gracefully; a hard kill leaves a
  dead peer and can cost quorum. Only the **client tier** is safe to scale casually —
  which is another argument for A, where the server tier is deliberately small and fixed.

---

## ADR-009 — No ACLs or gossip encryption in Phase 1

**Status:** Accepted (2026-08-28)

Phase 1 runs Consul and Nomad unsecured: no ACL bootstrap, no gossip encryption key, no
mTLS. Enabling them roughly doubles bring-up complexity and puts token distribution into
every job spec and helper script, in front of the work the POC actually exists to prove.

**Consequence.** The cluster must not be exposed beyond the VMs' private network, and
nothing here is a template for a real deployment. Security is a later hardening pass over
a working POC, and that pass should cover Consul ACLs, gossip encryption, Nomad ACLs, and
the Doris sync account's privileges together rather than piecemeal.
