#!/usr/bin/env bash
#
# build-seed-iso.sh - build a cloud-init NoCloud seed ISO for one lab guest
# ---------------------------------------------------------------------------
# Usage: ./build-seed-iso.sh <hostname> <static-ip>
#   e.g. ./build-seed-iso.sh web01 192.168.56.21
#
# Why this exists: VirtualBox's built-in unattended install generated a
# cloud-init autoinstall that crashed in this environment (curtin in-target
# apt-get update returned 1). Owning the autoinstall file makes the guest
# definition reviewable, versionable and repeatable, and lets us set the static
# address and SSH key at install time instead of afterwards.
#
# Output: /tmp/nordicshop-seed-<hostname>.iso, volume label CIDATA, which is
# what cloud-init looks for when auto-detecting a NoCloud datasource.
#
# The password is passed through to chpasswd inside the guest. It is never
# printed, and the seed ISO lives in /tmp, outside the repository.
# ---------------------------------------------------------------------------

set -euo pipefail

hostname_short="${1:?usage: build-seed-iso.sh <hostname> <ip>}"
static_ip="${2:?usage: build-seed-iso.sh <hostname> <ip>}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPL_DIR="$ROOT_DIR/configuration/autoinstall"
SECRETS="$ROOT_DIR/.secrets"

[[ -f "$SECRETS/lab.pass" ]] || { echo "missing $SECRETS/lab.pass" >&2; exit 1; }
[[ -f "$SECRETS/lab_ed25519.pub" ]] || { echo "missing lab ssh public key" >&2; exit 1; }

stage="$(mktemp -d /tmp/nordicshop-seed-XXXXXX)"
out="/tmp/nordicshop-seed-${hostname_short}.iso"

# Subiquity requires identity.password, but macOS libcrypt only supports DES
# and MD5 crypt. Use openssl's MD5 hash for schema validity; the real password
# is applied by the chpasswd late-command inside the guest.
pass_hash="$(openssl passwd -1 -salt nordic1 -in "$SECRETS/lab.pass")"
[[ "$pass_hash" == \$1\$* ]] || { echo "password hashing failed" >&2; exit 1; }

# Render with python rather than sed: the password may contain characters that
# are special to sed, and a literal replacement cannot mangle it.
TMPL_DIR="$TMPL_DIR" STAGE="$stage" \
HOSTNAME_SHORT="$hostname_short" STATIC_IP="$static_ip" PASS_HASH="$pass_hash" \
SSH_PUBLIC_KEY="$(cat "$SECRETS/lab_ed25519.pub")" \
LAB_PASSWORD="$(cat "$SECRETS/lab.pass")" \
python3 - <<'PY'
import os
from pathlib import Path

tmpl_dir = Path(os.environ["TMPL_DIR"])
stage = Path(os.environ["STAGE"])
values = {
    "__HOSTNAME__": os.environ["HOSTNAME_SHORT"],
    "__IP__": os.environ["STATIC_IP"],
    "__SSHKEY__": os.environ["SSH_PUBLIC_KEY"],
    "__PASSWORD__": os.environ["LAB_PASSWORD"],
    "__PASSHASH__": os.environ["PASS_HASH"],
    "__INSTANCE__": f"nordicshop-{os.environ['HOSTNAME_SHORT']}",
}

for name in ("user-data", "meta-data"):
    text = (tmpl_dir / f"{name}.tmpl").read_text()
    for key, value in values.items():
        text = text.replace(key, value)
    if "__" in text:
        raise SystemExit(f"unsubstituted placeholder left in {name}")
    (stage / name).write_text(text)

rendered = (stage / "user-data").read_text()
assert "autoinstall:" in rendered, "no autoinstall section"
assert os.environ["STATIC_IP"] in rendered, "static address missing"
print(f"rendered ok: {stage}/user-data ({len(rendered)} bytes)")
PY

rm -f "$out"
# -default-volume-name CIDATA is what cloud-init matches on; without it the
# seed is silently ignored and the installer falls back to interactive.
hdiutil makehybrid -quiet -o "$out" -hfs -joliet -iso \
  -default-volume-name CIDATA "$stage" >/dev/null

echo "seed iso: $out"
echo "  hostname: $hostname_short"
echo "  address:  $static_ip/24"
echo "  user:     labadmin (ssh key installed, password set via chpasswd)"
