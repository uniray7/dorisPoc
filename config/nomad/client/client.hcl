# Static Nomad client configuration — identical on every VM.
# Installed to /etc/nomad.d/client.hcl by scripts/install-client.sh.
# The client runs natively under systemd as root (ADR-001): clients need root,
# CAP_SYS_ADMIN, CAP_NET_ADMIN and cgroup access, so it must not be containerised.

data_dir  = "/opt/nomad/data"
bind_addr = "0.0.0.0"

# This VM also runs a Nomad *server* in a container on the host network namespace,
# which already owns the default 4646/4647. Two Nomad agents cannot share them, so
# the client takes its own pair. `nomad` on the host still talks to the server on
# 4646; use -address=http://127.0.0.1:4656 to address the client directly.
ports {
  http = 4656
  rpc  = 4657
}

client {
  enabled = true

  # The Doris jobs ask for kill_timeout = 60s so the entrypoints can stop_fe.sh /
  # stop_be.sh cleanly. The default ceiling is 30s, which would silently clamp them.
  max_kill_timeout = "5m"

  # Persistent storage for the Doris cluster this VM hosts (ADR-005).
  # Doris is not stateless: the FE persists its own network identity into
  # doris-meta, and a BE that loses its storage dir re-registers as a new node.
  # These paths must survive a job restart, a reschedule, and a VM reboot.
  host_volume "doris-fe-meta" {
    path      = "/opt/doris/fe/doris-meta"
    read_only = false
  }

  host_volume "doris-fe-log" {
    path      = "/opt/doris/fe/log"
    read_only = false
  }

  host_volume "doris-be-storage" {
    path      = "/opt/doris/be/storage"
    read_only = false
  }

  host_volume "doris-be-log" {
    path      = "/opt/doris/be/log"
    read_only = false
  }
}

consul {
  address = "127.0.0.1:8500"
}

plugin "docker" {
  config {
    allow_privileged = false

    # Required so the Doris tasks can bind-mount their config shim out of the
    # allocation's local directory (CVE-2026-14896 hardened the symlink path here).
    volumes {
      enabled = true
    }

    # No allowed_modes block: it allowlists the pid/ipc/userns/uts namespaces only.
    # network_mode = "host" is not gated by it — see docs/research.md §6.
  }
}
