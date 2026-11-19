#!/usr/bin/env bash
# Sample one backend's health status from the HAProxy stats socket, tolerating
# the short window during a reload or crash when the socket does not answer.
# The Incident 1/2 watcher exits at that point, which loses the interesting
# part of the timeline.
#
# usage: watch-pool-timeline.sh [samples] [interval] [server]
set -u

SAMPLES=${1:-60}
INTERVAL=${2:-0.5}
SERVER=${3:-web01}
STATS=${STATS_URL:-"http://192.168.56.10:8404/stats;csv"}

for _ in $(seq 1 "$SAMPLES"); do
  row=$(curl -s -m 1 "$STATS" 2>/dev/null \
    | awk -F, -v s="$SERVER" '$1 == "nordicshop_web" && $2 == s {print $18, $37, $38}')
  [ -z "$row" ] && row="NO-RESPONSE"
  printf '%s %s\n' "$(date +%H:%M:%S.%3N)" "$row"
  sleep "$INTERVAL"
done
