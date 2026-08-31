#!/usr/bin/env bash
# Assert Phase 1 exit criteria. Exits non-zero on the first failure.
set -uo pipefail

DOCKER="${DOCKER:-sg docker -c}"
fails=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fails=$((fails+1)); }
run()  { $DOCKER "$1" 2>/dev/null; }

echo "== Consul =="
members="$(run 'docker exec consul-server consul members')"
alive=$(echo "$members" | grep -c ' alive ')
[ "$alive" -ge 1 ] && pass "$alive agent(s) alive" || fail "no Consul agents alive"

if run 'docker exec consul-server consul operator raft list-peers' | grep -q leader; then
  pass "Consul Raft leader elected"
else
  fail "no Consul Raft leader"
fi

echo "== Nomad servers =="
sm="$(run 'docker exec nomad-server nomad server members')"
if echo "$sm" | grep -q true; then
  pass "Nomad leader elected ($(echo "$sm" | grep -c alive) server(s) alive)"
else
  fail "no Nomad leader"
fi

echo "== Nomad client =="
ns="$(run 'docker exec nomad-server nomad node status')"
ready=$(echo "$ns" | grep -c ' ready')
[ "$ready" -ge 1 ] && pass "$ready client(s) ready" || fail "no ready Nomad clients"

nid=$(echo "$ns" | awk 'NR==2{print $1}')
if [ -n "$nid" ]; then
  detail="$(run "docker exec nomad-server nomad node status -verbose $nid")"
  echo "$detail" | grep -qE '^docker +true +true' \
    && pass "docker driver healthy" || fail "docker driver not healthy"
  for v in doris-fe-meta doris-fe-log doris-be-storage doris-be-log; do
    echo "$detail" | grep -q "$v" && pass "host volume $v" || fail "host volume $v missing"
  done
  echo "$detail" | grep -q "doris_cluster" \
    && pass "meta.doris_cluster set ($(echo "$detail" | grep doris_cluster | awk '{print $NF}'))" \
    || fail "meta.doris_cluster not set"
fi

echo "== Multi-VM readiness (ADR-008) =="
# The one thing that, if wrong, makes scale-out a rewrite.
bad=0
echo "$members" | awk 'NR>1{print $2}' | grep -qE '^(172\.1[6-9]|172\.2[0-9]|172\.3[01])\.' && bad=1
echo "$sm"      | awk 'NR>1{print $2}' | grep -qE '^(172\.1[6-9]|172\.2[0-9]|172\.3[01])\.' && bad=1
[ "$bad" -eq 0 ] && pass "no agent advertises a Docker bridge address" \
                 || fail "an agent advertises a 172.16/12 bridge address — scale-out will break"

echo "== Job specs =="
for f in jobs/*.nomad.hcl; do
  if $DOCKER "docker exec -i nomad-server nomad job validate -" < "$f" >/dev/null 2>&1; then
    pass "$(basename "$f") validates"
  else
    fail "$(basename "$f") does not validate"
  fi
done

echo
if [ "$fails" -eq 0 ]; then
  echo "All checks passed."
else
  echo "$fails check(s) failed."
fi
exit $fails
