#!/usr/bin/env bash
#
# deploy-haproxy.sh - install and reload the load balancer configuration
# ---------------------------------------------------------------------------
# Usage: ./deploy-haproxy.sh
#
# Copies configuration/haproxy/haproxy.cfg to lb01, validates it with
# `haproxy -c` BEFORE restarting anything, keeps a timestamped backup of the
# previous file, and only then reloads the service. Validation first is the whole
# point: a bad config should never reach a running balancer, because reloading
# with invalid syntax leaves you with a stopped service and no traffic path.
#
# Also opens the stats port to the lab subnet only, and routes HAProxy's syslog
# output to /var/log/haproxy.log when rsyslog is present.
# ---------------------------------------------------------------------------

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="$ROOT_DIR/.secrets/lab_ed25519"
CFG="$ROOT_DIR/configuration/haproxy/haproxy.cfg"
LB_IP=192.168.56.10

[[ -f "$CFG" ]] || { echo "missing $CFG" >&2; exit 1; }

echo "==> copying configuration to lb01"
scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$CFG" "labadmin@$LB_IP:/tmp/haproxy.cfg.new"

echo "==> validating and activating"
"$ROOT_DIR/scripts/guest.sh" lb01 --root '
set -e
if [ -f /etc/haproxy/haproxy.cfg ]; then
  cp /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.bak-$(date +%Y%m%d-%H%M%S)"
fi
install -m 644 /tmp/haproxy.cfg.new /etc/haproxy/haproxy.cfg

echo "--- config validation:"
haproxy -c -f /etc/haproxy/haproxy.cfg

# Statistics port: lab subnet only, never the NAT interface.
ufw allow from 192.168.56.0/24 to any port 8404 proto tcp >/dev/null

# HAProxy logs to the local syslog socket. Without a rule for local0 nothing is
# written, which is a common "why is my log empty" moment.
if systemctl is-active --quiet rsyslog; then
  printf "%s\n" "local0.*    /var/log/haproxy.log" > /etc/rsyslog.d/49-haproxy.conf
  systemctl restart rsyslog
  echo "--- syslog: local0 routed to /var/log/haproxy.log"
else
  echo "--- syslog: rsyslog not active, HAProxy events stay in the journal only"
fi

systemctl enable haproxy >/dev/null 2>&1 || true
systemctl restart haproxy
sleep 2
echo "--- service state:"
systemctl is-active haproxy
echo "--- listeners:"
ss -ltnp | grep -E ":(80|8404) " | awk "{print \$1, \$4, \$6}"
echo "--- health from the balancer itself:"
curl -sS -o /dev/null -w "status=%{http_code}\n" http://192.168.56.10/healthz
'
