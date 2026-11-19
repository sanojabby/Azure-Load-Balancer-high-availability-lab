#!/usr/bin/env bash
#
# finish-guest.sh - take a guest from "installer rebooted" to "running on disk"
# ---------------------------------------------------------------------------
# Usage: ./finish-guest.sh <hostname> <static-ip>
#
# Why this step exists: the VMs boot DVD first so the installer runs. After a
# successful autoinstall the guest reboots, and with the DVD still first it goes
# straight back into the installer, which then asks whether to autoinstall
# again. The installed system is never reached.
#
# So: wait for the reboot that ends the installation, power off, eject both
# optical discs, set the disk first in the boot order, then start and verify.
#
# Verification is an SSH command returning the expected hostname, not a TCP
# probe. See troubleshooting/install-autoinstall-failures.md.
# ---------------------------------------------------------------------------

set -euo pipefail

hostname_short="${1:?usage: finish-guest.sh <hostname> <ip>}"
static_ip="${2:?usage: finish-guest.sh <hostname> <ip>}"
vm="nordicshop-${hostname_short}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="$ROOT_DIR/.secrets/lab_ed25519"
WAIT_INSTALL_MINUTES="${WAIT_INSTALL_MINUTES:-45}"
WAIT_BOOT_MINUTES="${WAIT_BOOT_MINUTES:-10}"

say() { printf '\n==> %s\n' "$*"; }

state_change() {
  VBoxManage showvminfo "$vm" --machinereadable \
    | sed -n 's/^VMStateChangeTime="\(.*\)"$/\1/p'
}

start_ts="$(state_change)"
say "watching $vm for the post-install reboot (started $start_ts)"
deadline=$(( $(date +%s) + WAIT_INSTALL_MINUTES * 60 ))
rebooted=no
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 20
  if [ "$(state_change)" != "$start_ts" ]; then
    rebooted=yes
    break
  fi
done

if [ "$rebooted" != "yes" ]; then
  echo "$vm did not reboot within ${WAIT_INSTALL_MINUTES}m; inspect the console:" >&2
  echo "  VBoxManage controlvm $vm screenshotpng /tmp/${vm}.png" >&2
  exit 1
fi

say "$vm rebooted, reconfiguring to boot from disk"
VBoxManage controlvm "$vm" poweroff >/dev/null 2>&1 || true
sleep 3
for port in 1 2; do
  VBoxManage storageattach "$vm" --storagectl SATA --port "$port" --device 0 \
    --type dvddrive --medium none >/dev/null 2>&1 || true
done
VBoxManage modifyvm "$vm" --boot1 disk --boot2 none --boot3 none --boot4 none
VBoxManage startvm "$vm" --type headless | tail -1

say "waiting for $hostname_short at $static_ip"
deadline=$(( $(date +%s) + WAIT_BOOT_MINUTES * 60 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  got="$(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=5 \
        "labadmin@${static_ip}" hostname 2>/dev/null || true)"
  if [ "$got" = "$hostname_short" ]; then
    say "$vm is up: hostname=$got address=$static_ip"
    exit 0
  fi
  sleep 15
done

echo "$vm booted but did not answer on $static_ip within ${WAIT_BOOT_MINUTES}m" >&2
exit 1
