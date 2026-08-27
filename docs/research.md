# Research Findings (Primary Sources Only)

**Collected:** 2026-08-27
**Source policy:** Only official/primary sources were used — `developer.hashicorp.com`,
`releases.hashicorp.com`, `github.com/hashicorp/*`, `doris.apache.org`,
`github.com/apache/doris-website`, `github.com/selectdb/ccr-syncer`, and the Docker Hub
registry API. **No blogs, Medium posts, Stack Overflow, or third-party tutorials were
consulted.** Every non-obvious claim below is attributed. Where a fact was measured on
this machine rather than read from a document, it is marked **[measured]**.

---

## 1. Blocking constraint: Nomad clients in Docker are not supported

This is the single most important finding and it changes the intended architecture.

> "Nomad clients require extensive access to the underlying host machine... Docker
> containers introduce a non-trivial abstraction layer that makes it hard to properly
> configure clients and task drivers therefore **running Nomad clients in Docker
> containers is not officially supported**."
>
> — [Nomad installation requirements](https://developer.hashicorp.com/nomad/docs/deploy/production/requirements), heading "Running Nomad in Docker"

Supporting statements from the same page:

- "Nomad clients must be run as `root` due to the OS isolation mechanisms that require root privileges"
- "Nomad clients require `CAP_SYS_ADMIN` for creating the tmpfs used for secrets, bind-mounting task directories, mounting volumes, and running some task driver plugins."
- "Nomad clients require `CAP_NET_ADMIN` for a variety of tasks to set up networking."
- "On Linux, Nomad uses cgroups to control access to resources like CPU and memory. Nomad supports both cgroups v2 and the legacy cgroups v1."
- Running Nomad clients inside a **user namespace** is also unsupported.

And on the purpose of the published image:

> "The `hashicorp/nomad` Docker image is intended to be used in automated pipelines for
> CLI operations, such as `nomad job plan`, `nomad fmt`, and others."

**Consequence:** the Nomad *client* (the agent that actually runs workloads) must run
natively on the host as root. Nomad *servers* do not need cgroups, CAP_SYS_ADMIN or
task-driver access, so containerising them does not hit these constraints — but note it
is still outside the image's stated purpose. See `decisions.md` ADR-001.

## 2. Consul in Docker *is* officially supported

Consul has a dedicated official deployment guide for Docker
([Consul on Docker](https://developer.hashicorp.com/consul/docs/deploy/server/docker)):

- Official image: `hashicorp/consul`.
- Server flags: `-server`, `-ui`, `-bootstrap-expect=N`, `-data-dir`, `-retry-join`.
- Configurable via CLI flags or the `CONSUL_LOCAL_CONFIG` environment variable (JSON).
- "The Consul configuration directory is not exposed as a volume and does not persist
  data." → volumes must be mounted explicitly to persist state.
- Multi-server clusters are formed with `-retry-join` peers plus a matching
  `-bootstrap-expect`.

## 3. Nomad requires a local Consul agent per node

From [Nomad + Consul networking](https://developer.hashicorp.com/nomad/docs/networking/consul):

> "Each Nomad client should have a local Consul agent running on the same host, reachable by Nomad."

> "Nomad clients should never share a Consul agent or talk directly to the Consul servers."

Also: the `consul` binary must be in Nomad's `$PATH` for Envoy sidecar (Consul Connect)
operation. This rules out the simplification of pointing every Nomad agent at a single
shared Consul endpoint.

## 4. Ports

### Nomad
Source: [Nomad installation requirements](https://developer.hashicorp.com/nomad/docs/deploy/production/requirements)

| Port | Protocol | Purpose | Servers | Clients |
|---|---|---|---|---|
| 4646 | TCP | HTTP API | yes | yes |
| 4647 | TCP | RPC (internal) | yes | yes |
| 4648 | TCP + UDP | Serf gossip | yes | no |
| 20000–32000 | TCP/UDP | dynamically allocated task ports | — | yes |

### Consul
Source: [Consul ports reference](https://developer.hashicorp.com/consul/docs/reference/architecture/ports)

| Port | Protocol | Purpose | Notes |
|---|---|---|---|
| 8300 | TCP | Server RPC | server-only |
| 8301 | TCP + UDP | Serf LAN | servers + clients |
| 8302 | TCP + UDP | Serf WAN | server-only |
| 8500 | TCP | HTTP API | |
| 8501 | TCP | HTTPS API | disabled by default |
| 8502 | TCP | gRPC | disabled by default |
| 8503 | TCP | gRPC TLS | enabled by default |
| 8600 | TCP + UDP | DNS | |

### Apache Doris
Source: [Doris cluster planning](https://doris.apache.org/docs/install/preparation/cluster-planning/)
(raw markdown from `apache/doris-website`)

| Instance | Port name | Default | Direction | Purpose |
|---|---|---|---|---|
| FE | `http_port` | 8030 | FE↔FE, Client→FE | HTTP server |
| FE | `rpc_port` | 9020 | BE→FE, FE↔FE | Thrift; must be identical across FEs |
| FE | `query_port` | 9030 | Client→FE | MySQL protocol |
| FE | `edit_log_port` | 9010 | FE↔FE | BDBJE metadata replication |
| BE | `be_port` | 9060 | FE→BE | Thrift server |
| BE | `webserver_port` | 8040 | BE↔BE | HTTP server |
| BE | `heartbeat_service_port` | 9050 | FE→BE | Heartbeat (Thrift) |
| BE | `brpc_port` | 8060 | FE↔BE, BE↔BE | BRPC |

Note `webserver_port` (8040) and `brpc_port` (8060) are **BE↔BE** — this matters for CCR,
where the downstream BEs pull snapshot data from the upstream BEs.

## 5. Versions (as of 2026-08-27)

| Component | Latest OSS | Source |
|---|---|---|
| Nomad | **2.0.5** (2026-08-12) | releases.hashicorp.com API + Docker Hub tag list |
| Consul | **2.0.3** | releases.hashicorp.com API + Docker Hub tag list |
| Docker Engine (this host) | 29.1.3 | **[measured]** |
| Docker Compose (this host) | 2.40.3 | **[measured]**, installed during research |

Nomad 2.0.0 (2026-04-21) changelog review: the only listed breaking change is
`DriverNetwork.Hash` removal from the `plugin/drivers` Go package — an SDK change, not a
config change. **No breaking changes affect the `server`, `client`, `consul`, or
`plugin "docker"` configuration blocks**, so 2.0.5 is safe to target.

Two Nomad 2.0.4 security fixes are directly relevant to running Doris containers:

- **CVE-2026-14891** — the docker driver now enforces `allowed_modes` or
  `allow_privileged` before a task may set host namespace modes. If a Doris job needs
  `network_mode = "host"`, the client's `plugin "docker"` block must permit it explicitly.
- **CVE-2026-14896** — fixed a symlink bypass of `volumes.enabled = false`.

## 6. Configuration reference (exact syntax)

### Nomad `server` block
Source: [server block](https://developer.hashicorp.com/nomad/docs/configuration/server)

```hcl
server {
  enabled          = true
  bootstrap_expect = 3
  data_dir         = "/opt/nomad/server"

  server_join {
    retry_join     = ["10.0.1.1", "10.0.1.2"]
    retry_max      = 3
    retry_interval = "15s"
  }
}
```
`encrypt` takes a base64 32-byte key from `nomad operator gossip keyring generate`; it is
persisted to the data dir after first start.

### Nomad `client` block
Source: [client block](https://developer.hashicorp.com/nomad/docs/configuration/client)

```hcl
client {
  enabled           = true
  servers           = ["1.2.3.4:4647", "5.6.7.8:4647"]
  node_pool         = "default"
  memory_total_mb   = 0   # override autodetection
  cpu_total_compute = 0   # cores * MHz

  meta { key = "value" }

  reserved { memory = 512 }

  host_volume "volume_name" {
    path      = "/path/on/host"
    read_only = false
  }
}
```

### Nomad `consul` block
Source: [consul block](https://developer.hashicorp.com/nomad/docs/configuration/consul)

| Field | Default |
|---|---|
| `address` | `"127.0.0.1:8500"` |
| `grpc_address` | `"127.0.0.1:8502"` |
| `token` | `""` |
| `auto_advertise` | `true` |
| `server_auto_join` | `true` |
| `client_auto_join` | `true` |

### Nomad `plugin "docker"` block
Source: [Docker task driver](https://developer.hashicorp.com/nomad/docs/deploy/task-driver/docker)

```hcl
plugin "docker" {
  config {
    allow_privileged = false

    allowed_modes {
      pid = ["", "host", "container"]
      ipc = ["", "none", "host", "container", "private", "sharable"]
    }

    volumes {
      enabled      = true
      selinuxlabel = "z"
    }
  }
}
```

### Consul server config
Source: [Consul agent configuration](https://developer.hashicorp.com/consul/docs/reference/agent/configuration-file/general)

```hcl
server           = true
bootstrap_expect = 3
datacenter       = "dc1"
data_dir         = "/var/lib/consul"
bind_addr        = "0.0.0.0"
client_addr      = "0.0.0.0"
retry_join       = ["10.0.0.1", "10.0.0.2", "10.0.0.3"]
ui_config { enabled = true }
```
`datacenter` must be an RFC 1035 DNS label (letters, digits, hyphens; ≤63 chars).
`data_dir` must support filesystem locking and survive reboots.

## 7. Sizing guidance

### Nomad servers (production guidance)
"4-8+ cores, 16-32 GB+ of memory, 40-80 GB+ of fast disk"; disk ≥2× memory under high
load. 3–5 servers per region (odd numbers), maximum 7. Sub-10 ms server-to-server
latency; client-to-server may exceed 100 ms.
*(These are production figures. A POC runs far below them.)*

### Apache Doris
Source: [Doris environment check](https://doris.apache.org/docs/install/preparation/env-checking/)

| Check | Minimum | Recommended |
|---|---|---|
| CPU | AVX2 instruction set | AVX2 |
| Memory | cores × 4 GB | cores × 8 GB |
| Storage | SSD or HDD | SSD |
| Filesystem | ext4 or xfs | ext4 or xfs |

Per-component memory: **FE minimum 16 GB** (recommended 64 GB+); **BE cores × 4 GB**
(recommended cores × 8 GB).

Development/test environment (FE and BE co-located on one server):

| Module | Min CPU | Min memory | Min disk |
|---|---|---|---|
| Frontend | 8 cores | 8 GB | SSD/SATA 10 GB+ |
| Backend | 8 cores | 16 GB | SSD/SATA 50 GB+ |

Disk: FE 100 GB+; BE = total data × 3 × 1.4 (LZ4 ratio 0.3–0.5, 3 replicas, +40 % for
compaction).

If AVX2 is unavailable, Doris publishes a **no-AVX2 build**.

**Java:** Doris ≤ 2.1 requires Java 8 (jdk-8u352+); Doris ≥ 3.0 requires **Java 17**
(jdk-17.0.10+).

### Doris OS prerequisites
Source: [Doris OS check](https://doris.apache.org/docs/install/preparation/os-checking/)

- Disable swap (`swapoff -a`, comment the fstab entry)
- THP set to `madvise`
- **`vm.max_map_count = 2000000`**
- Raise file-handle limits
- Disable CPU power-saving mode
- NTP installed; metadata clock skew must stay < 5000 ms
- Required ports open

## 8. Doris CCR

### Documentation availability — important caveat

**[measured]** Official Doris CCR documentation is versioned only for **2.0 and 2.1**.
Live URL checks:

| URL | Result |
|---|---|
| `/docs/2.1/admin-manual/data-admin/ccr/overview/` | 200 |
| `/docs/3.x/admin-manual/data-admin/ccr/overview/` | 404 |
| `/docs/4.x/admin-manual/data-admin/ccr/overview/` | 404 |
| `/docs/admin-manual/data-admin/ccr/overview/` (current) | 404 |
| `/docs/dev/admin-manual/data-admin/ccr/quickstart/` | 200, but silently redirects to `/docs/dev/getting-started/what-is-apache-doris/` |

In the `apache/doris-website` repository, CCR pages exist only under
`versioned_docs/version-2.0/`, `versioned_docs/version-2.1/`, and `deprecated-docs/`.
There is **no CCR documentation for 3.x or 4.x.** CCR itself is clearly still supported
(the docs reference 3.0-specific behaviour and ship a 3.0 syncer binary) — only the
*documentation* has not been carried forward. Plan for a documentation gap when targeting
Doris 3.x.

### Syncer
- Repo: [`selectdb/ccr-syncer`](https://github.com/selectdb/ccr-syncer), default branch
  `dev`, last push 2026-04-10 **[measured via GitHub API]**. Go project, built with
  `bash build.sh`. **No official container image is published** — one must be built.
- The official Doris quickstart also links a prebuilt tarball:
  `https://apache-doris-releases.oss-accelerate.aliyuncs.com/ccr-release/ccr-syncer-3.0.6-rc05-x64.tar.xz`
- Control API listens on **port 9190**.
- Start/stop: `sh bin/start_syncer.sh --daemon` / `sh bin/stop_syncer.sh`.
- **Syncer HA depends on MySQL** as backend storage; syncers then discover each other and
  take over jobs from a crashed peer.

### Enabling CCR
1. `enable_feature_binlog=true` in **both `fe.conf` and `be.conf`**, on **both clusters**.
2. Enable binlog on the data:
   - whole database: `bash bin/enable_db_binlog.sh -h host -p port -u user -P password -d db`
   - single table: `ALTER TABLE tbl SET ("binlog.enable" = "true");`
3. Create the job:

```shell
curl -X POST -H "Content-Type: application/json" -d '{
    "name": "ccr_test",
    "src":  { "host": "...", "port": "9030", "thrift_port": "9020",
              "user": "root", "password": "", "database": "db", "table": "tbl" },
    "dest": { "host": "...", "port": "9030", "thrift_port": "9020",
              "user": "root", "password": "", "database": "db", "table": "tbl" }
}' http://127.0.0.1:9190/create_ccr
```

`host`/`port` are the **Master FE** and its MySQL port; `thrift_port` is the FE `rpc_port`.
For database-level sync, set `table` to empty. A job `name` may only be used once.

### CCR requirements
Source: [CCR operation manual](https://doris.apache.org/docs/2.1/admin-manual/data-admin/ccr/manual/)

**Network**
- Syncer must reach the FE **and BE** of both clusters.
- "The downstream BE must have direct access to the IP used by the Doris BE process (as
  seen in `show frontends/backends`)."

**Permissions** — the sync account needs on both sides: `Select_priv`, `Load_priv`,
`Alter_priv`, `Create_priv`, `Drop_priv`, plus Admin (to read the binlog config).

**Versions**
- `Syncer version >= downstream Doris version >= upstream Doris version`. Upgrade order:
  syncer → downstream → upstream.
- Doris 2.0 minimum 2.0.15; Doris 2.1 minimum 2.1.6.
- Syncer 2.1.8 / 3.0.4 and later **dropped support for Doris 2.0**.

**Table property** — `light_schema_change` must be set on both upstream and downstream
tables (set by default on modern Doris).

### CCR memory and tuning
- "it is recommended to allocate **at least 4GB or more heap memory for each CCR job in
  FE** (both source and target clusters)" — backup/restore jobs and binlogs are held in
  FE memory.
- FE: `max_backup_restore_job_num_per_db = 2` (default 10);
  `restore_reset_index_id = false` if inverted/bitmap indexes are used (2.1.8+/3.0.4+);
  `ignore_backup_tmp_partitions = true` if upstream creates temp partitions (2.1.8+/3.0.4+);
  `enable_restore_snapshot_rpc_compression = true` (recommended);
  raise `label_num_threshold`, `stream_load_default_timeout_second`,
  `label_keep_max_second`, `streaming_label_keep_max_second`;
  `restore_download_job_num_per_be = 0` (unlimited) — no longer needed from 2.1.8/3.0.4.
- BE: `thrift_max_message_size = 2000000000` when many tablets are involved;
  `max_download_speed_kbps` default 50 MB/s per thread; `download_worker_count` default 1.
- Table properties: `binlog.max_bytes` (keep ≥ 4 GB); `binlog.ttl_seconds`
  (default 86400 from 2.0.5 onward; unlimited before).
- `is_being_synced` is managed by the syncer — **do not set it manually.**

### Syncer API surface
`create_ccr`, `get_lag` (progress), `pause`, `resume`, `delete`, `version`, `job_status`,
`desync` (end synchronization), `list_jobs`.

## 9. Doris image sizes **[measured, Docker Hub registry API, amd64]**

| Tag | Compressed | Layers |
|---|---|---|
| `apache/doris:fe-3.0.5` | 1447 MB | 9 |
| `apache/doris:be-3.0.5` | 2939 MB | 10 |
| `apache/doris:fe-4.0.8` | 1407 MB | 12 |
| `apache/doris:be-4.0.8` | 2656 MB | 13 |

One FE + one BE image is ~4.4 GB compressed, roughly 8–10 GB unpacked. Both clusters can
share the same two images.

## 10. This host **[all measured]**

| Property | Value |
|---|---|
| CPU | AMD EPYC 7B12, 2 vCPU, **AVX2 present** |
| Memory | 3.9 GB total |
| Disk free | 4.9 GB on `/` (8.7 GB total) |
| Swap | none (matches Doris requirement) |
| `vm.max_map_count` | 1048576 — **below Doris's required 2000000** |
| Docker | 29.1.3, daemon reachable |
| Docker group | user *is* in group `docker`, but the login session predates it — use `sg docker -c '...'` or re-login |
| sudo | passwordless |
| Network | github.com, registry-1.docker.io, releases.hashicorp.com all reachable |

**Conclusion:** this host can run the Nomad + Consul control plane comfortably. It cannot
run even one Doris cluster — the images alone exceed free disk, and Doris's own dev/test
minimum is 8 cores / 24 GB for a single FE+BE pair.
