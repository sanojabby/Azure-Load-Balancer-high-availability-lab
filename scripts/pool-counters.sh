#!/usr/bin/env bash
# Print per-server session and request counters from the HAProxy stats CSV.
# Columns are resolved by name from the header, because the CSV column order is
# long and positional awk is how you end up quoting the wrong number in a report.
#
# usage: pool-counters.sh [pxname]
set -u

STATS=${STATS_URL:-"http://192.168.56.10:8404/stats;csv"}
PXNAME=${1:-nordicshop_web}

curl -s -m 3 "$STATS" | awk -F, -v px="$PXNAME" '
  NR == 1 {
    h = $0; sub(/^# /, "", h); n = split(h, nm, ",")
    for (i = 1; i <= n; i++) {
      if (nm[i] == "stot")     s = i
      if (nm[i] == "req_tot")  r = i
      if (nm[i] == "status")   st = i
      if (nm[i] == "check_status") cs = i
    }
    next
  }
  $1 == px {
    printf "%-6s status=%-5s check=%-7s sessions=%-4s requests=%-4s\n", $2, $(st), $(cs), $(s), $(r)
  }
'
