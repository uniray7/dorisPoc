# Static Consul server configuration — identical on every VM.
# Per-VM values (node name, advertise address, quorum size, peers) live in node.hcl.
# ADR-008: one Consul agent per VM, and it is the server; the Nomad server and the
# native Nomad client on this VM both reach it at 127.0.0.1:8500.

server     = true
datacenter = "dc1"
data_dir   = "/consul/data"

# Bind to everything, but *advertise* the VM's routable address (node.hcl).
# Advertising a Docker bridge address is the mistake ADR-008 exists to prevent.
bind_addr   = "0.0.0.0"
client_addr = "0.0.0.0"

ui_config {
  enabled = true
}

# ADR-009: no ACLs and no gossip encryption in Phase 1. Keep this on a private network.
