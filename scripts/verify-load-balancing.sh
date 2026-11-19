#!/usr/bin/env bash
#
# verify-load-balancing.sh - show where traffic actually went
# ---------------------------------------------------------------------------
# Usage: ./verify-load-balancing.sh [request-count]
#
# Sends requests from client01 to the frontend address and counts which node
# answered, then reads the pool state from HAProxy's statistics endpoint.
#
# Why the count matters more than a single response: one request proves the
# balancer forwards. Only a sequence proves the distribution, and only the
# counters prove HAProxy's own view agrees with what the client observed.
#
# Each request opens a new connection (a separate curl process). That is
# deliberate: with HTTP keep-alive, a connection is pinned to one server, so a
# loop that reuses a connection would show one node repeatedly and say nothing
# about balancing. See documentation/phase-4-load-balancer.md.
# ---------------------------------------------------------------------------

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUESTS="${1:-20}"
FRONTEND="http://192.168.56.10/"

echo "== $REQUESTS requests from client01 to $FRONTEND =="
"$ROOT_DIR/scripts/guest.sh" client01 \
  "for i in \$(seq 1 $REQUESTS); do curl -sS -m5 -o /dev/null -D - $FRONTEND | grep -i '^x-web-node' | tr -d '\r' | awk '{print \$2}'; done" \
  | sort | uniq -c | sed 's/^/  /'

echo
echo "== HAProxy pool state =="
"$ROOT_DIR/scripts/guest.sh" lb01 --root "curl -s 'http://192.168.56.10:8404/stats;csv' | python3 -c \"
import sys, csv
lines = sys.stdin.read().splitlines()
lines[0] = lines[0].lstrip('#').lstrip()
for r in csv.DictReader(lines):
    if r['pxname'] == 'nordicshop_web' and r['svname'] in ('web01', 'web02'):
        print('  %-6s %-3s check=%-6s code=%-4s sessions=%s' % (
            r['svname'], r['status'], r['check_status'], r['check_code'], r['stot']))
    if r['pxname'] == 'nordicshop_web' and r['svname'] == 'BACKEND':
        print('  %-6s %-3s total_sessions=%s' % ('pool', r['status'], r['stot']))
\"" 2>/dev/null
