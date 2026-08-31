# dorisPoc

Proof of concept: **two Apache Doris clusters on HashiCorp Nomad + Consul, replicated
with CCR.**

1. A Nomad + Consul cluster (control plane in Docker Compose)
2. Two Apache Doris clusters scheduled onto it
3. Active-standby replication between them via [`selectdb/ccr-syncer`](https://github.com/selectdb/ccr-syncer)
4. A fake-data ingestion pipeline into the active cluster, observing standby convergence

## Status

**Phase 1 is built and verified on one VM. Phase 2 is written but has never been run.**

| Phase | Status |
|---|---|
| 0 — Research | Done |
| 1 — Nomad + Consul cluster | **Done** — `make verify` passes every exit criterion (2026-08-28) |
| 2 — Two Doris clusters | Job specs written and validated; **never run** — blocked on a larger VM |
| 3 — CCR replication | Outlined |
| 4 — Ingestion + observation | Outlined |

Phase 2 is blocked on cores and RAM, not disk: the job specs request 24 GB against the
7.8 GB / 2 vCPU on the current VM, so `make plan-a` fails on `Dimension "memory"
exhausted` — which is the correct answer. See [docs/plan.md](docs/plan.md).

---

## Getting started

Bring-up is **two steps, not one**. `make up` starts the control plane in Compose;
the Nomad *client* is installed separately and natively, because it cannot run in a
container ([ADR-001](docs/decisions.md)). A control plane with no client schedules
nothing, so don't stop after `make up`.

### Requirements

- A Debian/Ubuntu VM — `scripts/install-client.sh` installs Nomad from the official
  HashiCorp apt repository.
- Docker with the Compose v2 plugin (`apt install docker.io docker-compose-v2`).
- `sudo` — the client install writes `/etc/nomad.d`, `/opt/nomad`, `/opt/doris` and a
  systemd unit.
- A routable IP. Every agent advertises the VM's real address, never a `172.x` bridge
  address; that is the one thing which, if wrong, makes scale-out a rewrite
  ([ADR-008](docs/decisions.md)).

> If your login session predates being added to the `docker` group, `docker` will fail
> with a permission error. The `Makefile` already wraps Docker calls in
> `sg docker -c '...'`; for your own commands do the same, or re-login.

### One VM

```bash
make init      # render this VM's node.hcl files (detects the routable IP)
make up        # start the Consul + Nomad servers in Compose
make client    # install and start the native Nomad client — uses sudo
make verify    # assert the Phase 1 exit criteria
```

`make verify` should end with `All checks passed.` after confirming: a Consul leader, a
Nomad leader, one ready client with a healthy docker driver, the four Doris host volumes,
`meta.doris_cluster` set, that **no agent advertises a Docker bridge address**, and that
both job specs validate.

Then:

- Consul UI — `http://<vm-ip>:8500`
- Nomad UI — `http://<vm-ip>:4646`
- `make status` for `consul members`, `nomad server members`, `nomad node status`

`make init` detects the routable IP with `ip route get`; override any of its inputs by
environment variable:

| Variable | Default | Meaning |
|---|---|---|
| `ADVERTISE_IP` | detected | The address every agent advertises |
| `NODE_NAME` | `hostname -s` | Consul/Nomad node name |
| `BOOTSTRAP_EXPECT` | `1` | Raft quorum size — `3` once three VMs exist |
| `RETRY_JOIN` | empty | Space-separated peer IPs |
| `DORIS_CLUSTER` | `a` | Which Doris cluster this VM hosts (`a` or `b`) |

It writes `config/consul/node.hcl` and `config/nomad/{server,client}/node.hcl`. Those
three are per-VM and **gitignored** — only the `.example` templates are tracked, so a
fresh clone always starts with `make init`.

### Three VMs

The same tree runs on every VM. Scale-out is `bootstrap_expect` 1→3 plus `retry_join`,
and nothing else — if you find yourself editing anything else, ADR-008 was not honoured
somewhere. On **each** VM:

```bash
BOOTSTRAP_EXPECT=3 \
RETRY_JOIN="10.0.0.1 10.0.0.2 10.0.0.3" \
DORIS_CLUSTER=a \
  make init
make up && make client
```

`RETRY_JOIN` is the same list on every VM; `DORIS_CLUSTER` is not — it tags the node so
the Doris jobs land where you intend (`a` on one VM, `b` on another, per ADR-008's one
cluster per VM).

Open Consul 8300/8301/8302/8500/8600 and Nomad 4646/4647/4648 between the VMs, and run
NTP everywhere — Doris metadata tolerates under 5000 ms of clock skew.

### Day to day

`make help` lists every target. The ones worth knowing:

| Target | Does |
|---|---|
| `make status` | Consul members, Nomad servers, nodes, jobs |
| `make logs` | Tail the control plane |
| `make fmt` / `fmt-check` | Format/check the job specs |
| `make plan-a` / `plan-b` | Dry-run a Doris cluster (expect a memory failure on a small VM) |
| `make run-a` / `run-b` | Submit one — **needs a VM that can actually run Doris** |

The `nomad` CLI on the host talks to the *server* on 4646. The native client has its own
pair of ports so the two agents don't collide, so to address the client directly use
`nomad -address=http://127.0.0.1:4656 ...`.

### Teardown

```bash
make down                          # stop the control plane, keep its data volumes
make clean                         # ... and delete the volumes
sudo systemctl disable --now nomad # stop the native client (no make target)
```

`make down` leaves the native client running and `/opt/doris` untouched — that is
deliberate, since those directories hold Doris's identity ([ADR-005](docs/decisions.md)).

## Documentation

- **[docs/plan.md](docs/plan.md)** — the phased plan, with exit criteria
- **[docs/decisions.md](docs/decisions.md)** — architecture decisions and their rationale
- **[docs/research.md](docs/research.md)** — verified reference facts, primary sources only
- **[CLAUDE.md](CLAUDE.md)** — working notes for Claude Code sessions

## Two things to know up front

**Nomad clients cannot run in Docker.** HashiCorp states this explicitly — clients need
root, `CAP_SYS_ADMIN`, `CAP_NET_ADMIN` and cgroups. So the control plane (Consul servers +
Nomad servers) runs in Compose, and the Nomad client runs natively on the host under
systemd. See [ADR-001](docs/decisions.md).

**Doris needs a real machine.** The FE + BE images are ~4.4 GB compressed, and Doris's own
dev/test minimum is 8 cores + 24 GB *per cluster*. Phase 1 runs on a small VM; Phases 2–4
do not.

## Sources

All research uses primary sources only — HashiCorp and Apache Doris official
documentation, the projects' own repositories, and the Docker Hub registry API. No blogs
or third-party tutorials. Citations are inline in `docs/research.md`.
