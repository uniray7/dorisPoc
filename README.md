# dorisPoc

Proof of concept: **two Apache Doris clusters on HashiCorp Nomad + Consul, replicated
with CCR.**

1. A Nomad + Consul cluster (control plane in Docker Compose)
2. Two Apache Doris clusters scheduled onto it
3. Active-standby replication between them via [`selectdb/ccr-syncer`](https://github.com/selectdb/ccr-syncer)
4. A fake-data ingestion pipeline into the active cluster, observing standby convergence

## Status

**Phase 0 (research) complete. Phase 1 (Nomad + Consul) planned, not yet built.**

| Phase | Status |
|---|---|
| 0 — Research | Done |
| 1 — Nomad + Consul cluster | Ready to build |
| 2 — Two Doris clusters | Blocked on a larger VM |
| 3 — CCR replication | Outlined |
| 4 — Ingestion + observation | Outlined |

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
