#!/usr/bin/env bash
#
# probe-frontend.sh - sample the customer experience through the load balancer
# ---------------------------------------------------------------------------
# Runs on a client host. Sends requests to the frontend and records, per request,
# a timestamp, the HTTP status and which node answered.
#
# Usage: ./probe-frontend.sh [count] [interval-seconds]
#   ./probe-frontend.sh 90 0.3
#
# Each request opens a new connection on purpose, so the node reported is the
# node that served that specific request (see the connection-vs-request note in
# documentation/phase-4-load-balancer.md).
#
# Used during incident simulations to prove whether customers were served
# continuously while a backend was being removed from the pool.
# ---------------------------------------------------------------------------

set -u

count="${1:-60}"
interval="${2:-0.3}"
frontend="${3:-http://192.168.56.10/}"

for _ in $(seq 1 "$count"); do
  hdr="$(mktemp)"
  code="$(curl -sS -m3 -D "$hdr" -o /dev/null -w '%{http_code}' "$frontend" 2>/dev/null)"
  [[ -n "$code" ]] || code="000"
  node="$(awk 'tolower($1) == "x-web-node:" { print $2 }' "$hdr" 2>/dev/null | tr -d '\r')"
  printf '%s %s %s\n' "$(date +%T.%3N)" "$code" "${node:-none}"
  rm -f "$hdr"
  sleep "$interval"
done
