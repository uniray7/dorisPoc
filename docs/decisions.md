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
- Containerised Nomad servers: a Consul client agent container sharing the Nomad
  container's network namespace (`network_mode: "service:<nomad-server>"`), so
  `127.0.0.1:8500` resolves correctly.
- Native Nomad client: a native Consul client agent under systemd.

---

## ADR-003 — Cluster shape: 3 Consul servers, 3 Nomad servers, 1 Nomad client

**Status:** Accepted for Phase 1; client count revisited in Phase 2

Three servers each give a real Raft quorum (HashiCorp recommends 3–5 per region, odd
numbers) and let us demonstrate leader election and failure tolerance, which a single
server cannot. Consul and Nomad servers are small; the measured 3.9 GB host absorbs six
of them plus a client easily.

One Nomad client is enough for Phase 1. Phase 2 revisits this: Doris FE/BE persist their
own identity, so the number of clients interacts with how Doris is pinned (ADR-005).

---

## ADR-004 — Doris version: target 3.0.x, decide at Phase 2

**Status:** Open — needs a decision before Phase 2

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

## ADR-005 — Doris identity under a scheduler (deferred, Phase 2)

**Status:** Open — flagged early because it shapes the job specs

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
isolated on separate networks.

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
