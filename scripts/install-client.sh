#!/usr/bin/env bash
# Install and start the native Nomad client on this VM.
#
# The client cannot run in Docker (ADR-001): it needs root, CAP_SYS_ADMIN,
# CAP_NET_ADMIN and direct cgroup access, and HashiCorp does not support it.
# Consul is NOT installed here — this VM's Consul server container is already the
# local agent on 127.0.0.1:8500 (ADR-008).
#
# Run this on every VM, unchanged. Per-VM values come from config/nomad/client/node.hcl,
# which scripts/init-node.sh generates.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOMAD_VERSION="${NOMAD_VERSION:-2.0.5}"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

for f in config/nomad/client/client.hcl config/nomad/client/node.hcl; do
  if [ ! -f "$REPO_ROOT/$f" ]; then
    echo "ERROR: $f missing. Run scripts/init-node.sh first." >&2
    exit 1
  fi
done

echo "==> Installing Nomad ${NOMAD_VERSION} from the official HashiCorp apt repository"
if ! command -v nomad >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq wget gpg coreutils lsb-release >/dev/null
  wget -qO- https://apt.releases.hashicorp.com/gpg \
    | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/hashicorp.list
  apt-get update -qq
  apt-get install -y -qq "nomad=${NOMAD_VERSION}-1" || apt-get install -y -qq nomad
fi
nomad version

echo "==> Creating Doris host volume directories (ADR-005: Doris identity must persist)"
install -d -m 0755 /opt/doris/fe/doris-meta /opt/doris/fe/log \
                   /opt/doris/be/storage    /opt/doris/be/log
# The Doris images run as root inside the container and write to these paths.

echo "==> Installing client configuration into /etc/nomad.d"
install -d -m 0755 /etc/nomad.d /opt/nomad/data
# The package ships a combined server+client sample; this VM's server is the container.
rm -f /etc/nomad.d/nomad.hcl
install -m 0644 "$REPO_ROOT/config/nomad/client/client.hcl" /etc/nomad.d/client.hcl
install -m 0644 "$REPO_ROOT/config/nomad/client/node.hcl"   /etc/nomad.d/node.hcl

echo "==> Starting nomad.service"
systemctl daemon-reload
systemctl enable --now nomad
sleep 5
systemctl --no-pager --lines=0 status nomad || true

echo
echo "==> Done. Check with: nomad node status"
