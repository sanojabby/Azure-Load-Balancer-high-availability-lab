#!/usr/bin/env bash
#
# watch-pool.sh - sample one backend's state from HAProxy's statistics endpoint
# ---------------------------------------------------------------------------
# Runs on the load balancer. Prints a timestamped line per sample so the moment a
# node leaves the pool can be read off against the client-side probe.
#
# Usage: ./watch-pool.sh [count] [interval-seconds] [server]
#   ./watch-pool.sh 40 0.5 web01
#
# Columns reported (from the stats CSV):
#   status       UP / DOWN
#   check        L7OK, L4OK, L7STS, ... (how the health check passed or failed)
#   code         HTTP status the check received, when it got that far
#   lastchg      seconds since the state last changed
#   downtime     total seconds this server has spent down
#
# The `lastchg` value is what makes the detection time measurable: when it reads
# 1s on a DOWN sample, the transition happened one second earlier.
# ---------------------------------------------------------------------------

set -u

count="${1:-40}"
interval="${2:-0.5}"
server="${3:-web01}"

for _ in $(seq 1 "$count"); do
  line="$(curl -s 'http://192.168.56.10:8404/stats;csv' \
    | awk -F, -v s="$server" '$1 == "nordicshop_web" && $2 == s {
        printf "status=%s check=%s code=%s lastchg=%ss downtime=%ss", $18, $37, $38, $24, $25
      }')"
  printf '%s %s %s\n' "$(date +%T.%3N)" "$server" "${line:-no-data}"
  sleep "$interval"
done
