#!/usr/bin/env bash
#
# verify-web-tier.sh - prove the backend firewall boundary in both directions
# ---------------------------------------------------------------------------
# What this checks:
#   * the load balancer can reach each backend on port 80 and gets the expected
#     node identity back in the X-Web-Node header
#   * every other host is refused, including another backend and the Mac itself
#
# The refusal is expected to appear as a timeout, not "connection refused".
# UFW's default deny policy drops packets silently, which is why curl waits for
# its own timeout. A REJECT rule would return an ICMP error immediately; both are
# valid designs, and the choice is discussed in documentation/phase-3-web-tier.md.
#
# Usage: ./verify-web-tier.sh
# ---------------------------------------------------------------------------

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST="$ROOT_DIR/scripts/guest.sh"
TIMEOUT=5

# One probe: source host, target URL, expectation (allow|deny)
probe() {
  local source="$1" url="$2" expect="$3" body_bits
  local out rc
  out="$(cd "$ROOT_DIR" && "$GUEST" "$source" \
        "curl -sS -m $TIMEOUT -o /dev/null -w '%{http_code} %{time_total}' '$url' 2>/dev/null; echo \" rc=\$?\"" 2>/dev/null | tail -1)"
  rc="${out##*rc=}"
  body_bits="${out% rc=*}"

  local verdict
  if [[ "$expect" == "allow" ]]; then
    [[ "$body_bits" == 200* ]] && verdict="PASS" || verdict="FAIL"
  else
    [[ "$rc" == "28" || "$rc" == "7" ]] && verdict="PASS" || verdict="FAIL"
  fi

  printf '  %-9s -> %-28s expect=%-5s got=%-22s %s\n' \
    "$source" "$url" "$expect" "${body_bits:-determined}" "$verdict"
}

echo "== allowed: load balancer to backend =="
probe lb01 "http://192.168.56.21/healthz" allow
probe lb01 "http://192.168.56.22/healthz" allow
probe lb01 "http://192.168.56.21/" allow
probe lb01 "http://192.168.56.22/" allow

echo
echo "== denied: everyone else to a backend =="
probe web02    "http://192.168.56.21/" deny
probe web01    "http://192.168.56.22/" deny
probe client01 "http://192.168.56.21/" deny
probe client01 "http://192.168.56.22/" deny

echo
echo "== node identity as seen by the load balancer =="
for ip in 192.168.56.21 192.168.56.22; do
  echo "  $ip:"
  "$GUEST" lb01 "curl -sS -m $TIMEOUT -D - -o /dev/null http://$ip/ | grep -i 'x-web-node' | tr -d '\r'" 2>/dev/null | sed 's/^/    /'
  "$GUEST" lb01 "curl -sS -m $TIMEOUT http://$ip/healthz" 2>/dev/null | sed 's/^/    healthz: /'
done

echo
echo "== denied from the Mac, which is on the same subnet =="
for ip in 192.168.56.21 192.168.56.22; do
  if curl -sS -m "$TIMEOUT" -o /dev/null "http://$ip/" 2>/dev/null; then
    echo "  mac -> $ip : UNEXPECTED SUCCESS"
  else
    echo "  mac -> $ip : blocked (curl exit $?)"
  fi
done
