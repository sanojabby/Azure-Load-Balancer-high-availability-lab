#!/usr/bin/env bash
#
# deploy-nginx.sh - install the site config and page on a backend node
# ---------------------------------------------------------------------------
# Usage: ./deploy-nginx.sh web01
#
# Copies the version-controlled files from configuration/nginx/ to the guest and
# puts them in place. Nothing is edited on the guest by hand, so what runs in the
# lab is exactly what is committed to the repository.
#
# The default site is removed rather than left alongside: two server blocks both
# listening on port 80 with default_server would be a configuration error, and an
# orphaned default site is a classic cause of "my config is ignored".
# ---------------------------------------------------------------------------

set -euo pipefail

host="${1:?usage: deploy-nginx.sh <web01|web02>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="$ROOT_DIR/.secrets/lab_ed25519"
CONF_DIR="$ROOT_DIR/configuration/nginx"

case "$host" in
  web01) ip=192.168.56.21 ;;
  web02) ip=192.168.56.22 ;;
  *) echo "only web01 and web02 run nginx in this lab" >&2; exit 1 ;;
esac

for f in "$CONF_DIR/$host-site.conf" "$CONF_DIR/$host-index.html"; do
  [[ -f "$f" ]] || { echo "missing $f" >&2; exit 1; }
done

echo "==> copying files to $host ($ip)"
scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$CONF_DIR/$host-site.conf"   "labadmin@$ip:/tmp/nordicshop-site.conf"
scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$CONF_DIR/$host-index.html"  "labadmin@$ip:/tmp/nordicshop-index.html"

echo "==> installing on $host"
"$ROOT_DIR/scripts/guest.sh" "$host" --root '
set -e
mkdir -p /var/www/nordicshop
install -m 644 /tmp/nordicshop-index.html /var/www/nordicshop/index.html
install -m 644 /tmp/nordicshop-site.conf /etc/nginx/sites-available/nordicshop
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/nordicshop /etc/nginx/sites-enabled/nordicshop
echo "--- config test:"
nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
sleep 1
echo "--- service state:"
systemctl is-active nginx
echo "--- local health check:"
curl -sS -o /dev/null -w "status=%{http_code}\n" http://127.0.0.1/healthz
echo "--- local page title:"
curl -sS http://127.0.0.1/ | grep -o "<title>.*</title>"
'
