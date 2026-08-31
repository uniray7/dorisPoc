# Static Nomad server configuration — identical on every VM.
# Per-VM values live in node.hcl, in this same directory.

data_dir  = "/nomad/data"
bind_addr = "0.0.0.0"

server {
  enabled = true
}

# The local Consul agent — which on this topology is the VM's Consul server (ADR-002/008).
consul {
  address = "127.0.0.1:8500"
}

# ADR-009: no ACLs, no mTLS, no gossip encryption in Phase 1.
