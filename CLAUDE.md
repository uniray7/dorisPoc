# CLAUDE.md

Guidance for Claude Code sessions working in this repository.

## What this is

A proof of concept: two Apache Doris clusters scheduled by HashiCorp Nomad (with Consul
service discovery), kept in sync by [`selectdb/ccr-syncer`](https://github.com/selectdb/ccr-syncer)
cross-cluster replication, fed by a fake-data ingestion pipeline.

It is a POC, not production. Prefer the simplest thing that demonstrates the behaviour
honestly, and say plainly when something is a shortcut.

## Read these first

| Document | Contents |
|---|---|
| [`docs/plan.md`](docs/plan.md) | Phased plan, current status, exit criteria per phase |
| [`docs/decisions.md`](docs/decisions.md) | ADRs — read before changing architecture |
| [`docs/research.md`](docs/research.md) | Verified facts with citations: ports, versions, sizing, CCR requirements |

`docs/research.md` already contains the port tables, config-block syntax, version
constraints and sizing numbers. **Check there before searching the web again.**

## Source policy — important

The user explicitly requires **primary/official sources only**:

- `developer.hashicorp.com`, `releases.hashicorp.com`, `github.com/hashicorp/*`
- `doris.apache.org`, `github.com/apache/doris`, `github.com/apache/doris-website`
- `github.com/selectdb/ccr-syncer`
- `docs.docker.com`, the Docker Hub registry API

**Do not** cite or rely on blogs, Medium, Stack Overflow, Reddit, or third-party
tutorials. If something can only be found on such a source, say so explicitly and mark it
as unverified rather than presenting it as fact.

Two practical notes:
- `doris.apache.org` renders client-side, so `WebFetch` often returns an empty page. Pull
  the same content as raw markdown from `apache/doris-website` instead
  (`versioned_docs/version-2.1/...`, `docs/...`).
- Nomad/Consul docs no longer live in their product repos; use the docs site.

Distinguish **read from a document** vs. **measured on this machine**. `docs/research.md`
marks the latter with `[measured]`; keep that convention.

## Environment facts

- Working dir `/home/uniray7/dorisPoc`, git repo, branch `main`.
- The user **is** in the `docker` group, but the login session predates it. Use
  `sg docker -c '<command>'` or `sudo docker`. Don't tell the user to re-login mid-task.
- Passwordless `sudo` is available.
- Docker 29.1.3; Docker Compose v2.40.3 (installed via `apt install docker-compose-v2`).
- Host: AMD EPYC 7B12, **2 vCPU, 3.9 GB RAM, ~4.9 GB free disk**, AVX2 present, no swap.

### This host cannot run Doris

Phase 1 (Nomad + Consul) fits fine. Phases 2–4 do not — the Doris FE+BE images alone are
~4.4 GB compressed / ~8–10 GB unpacked against 4.9 GB free, and Doris's documented
dev/test minimum is 8 cores + 24 GB **per cluster**. The user plans to scale the VM up
before Phase 2. **Do not attempt to pull Doris images on this host** — it will fill the
disk. If asked to start Phase 2, confirm the VM has actually been resized first.

## Architecture constraints that are easy to get wrong

1. **Nomad clients must not run in Docker.** Officially unsupported: clients need root,
   `CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, and cgroup access. The control plane (Consul servers,
   Nomad servers) is in Compose; the Nomad client runs natively under systemd. See ADR-001.
   Mounting `docker.sock` into a containerised client "works" but silently breaks cgroup
   isolation, bridge networking and CNI — don't quietly adopt it.
2. **Every Nomad node needs its own local Consul agent** at `127.0.0.1:8500`. Sharing one
   Consul endpoint across Nomad agents is explicitly forbidden. See ADR-002. Under the
   accepted topology that local agent *is* the VM's Consul server — one agent per VM, not
   a server plus a client agent, which would collide on 8500/8301/8600.
3. **Doris is not stateless.** FE/BE persist their own network identity; BEs register with
   the FE by address. Rescheduling onto a different address corrupts membership. Doris
   ports must also be static, not from Nomad's dynamic range. See ADR-005.
4. **CCR needs BE↔BE reachability across both clusters** — full sync has downstream BEs
   pull snapshots from upstream BEs. The two clusters cannot be network-isolated.
5. **`enable_feature_binlog=true` must be in both `fe.conf` and `be.conf` on both
   clusters**, ideally from first boot — enabling it later requires a restart.
6. **Nomad 2.0.4+ enforces `allowed_modes` / `allow_privileged`** (CVE-2026-14891) before a
   task may set host namespace modes. If a Doris job needs `network_mode = "host"`, the
   client's `plugin "docker"` block must permit it.
7. **The target is 3 VMs, not one.** Everything must advertise the VM's routable IP
   (Consul `advertise_addr`, Nomad `advertise {}`) and expose its ports on the host —
   never a Docker bridge address. The cluster is one symmetric node stack per VM; scaling
   out is `bootstrap_expect` 1→3 plus `retry_join`, and nothing else. See ADR-008.
8. **Scale-in is a procedure, not a `down`.** Drain a Doris BE with
   `ALTER SYSTEM DECOMMISSION BACKEND` before removing its host, and let a departing
   Consul/Nomad server leave Raft gracefully. See ADR-008.

## Conventions

- Config lives in `config/<component>/`, job specs in `jobs/`, helper scripts in `scripts/`.
- Pin image tags explicitly. Never use `latest`.
- Prefer `make` targets over long ad-hoc command lines; keep the `Makefile` as the
  discoverable entry point.
- Validate before applying: `nomad job validate`, `nomad fmt -check`, `consul validate`.
  The `hashicorp/nomad` image is fine for exactly this kind of CLI use.
- Keep `docs/research.md` append-only in spirit — if a fact changes, update it and note
  when it was re-checked.

## Current status

Phase 0 (research) is complete. Phase 1 is **designed and unblocked but not yet built** —
no `compose.yaml` or configs exist yet.

Two decisions were settled on 2026-08-28:
- **ADR-008** — the multi-VM target is accepted, option A: one symmetric node stack per
  VM (Consul server + Nomad server in Compose on host networking, Nomad client native).
  ADR-003's 3+3-on-one-host shape is superseded.
- **ADR-009** — no ACLs or gossip encryption in Phase 1; deferred to a hardening pass.

Still open: ADR-004 (Doris version) and ADR-005 (identity under a scheduler — now urgent,
since it must be settled before a second Nomad client joins).
