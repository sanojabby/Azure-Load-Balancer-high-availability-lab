#!/usr/bin/env bash
#
# install-guest.sh - build a guest from scratch with a cloud-init seed
# ---------------------------------------------------------------------------
# Usage: ./install-guest.sh <hostname> <static-ip>
#   e.g. ./install-guest.sh web01 192.168.56.21
#
# Does four things:
#   1. builds the seed ISO with the hostname, address and ssh key baked in
#   2. attaches Ubuntu ISO (port 1) and seed ISO (port 2)
#   3. boots headless and answers subiquity's "Continue with autoinstall?" prompt
#   4. waits until the installed system answers with its hostname over SSH
#
# The hostname check is deliberately a real SSH command, not a TCP probe:
# VirtualBox's NAT forward accepts connections even with no guest behind it,
# which produced a false "installed" result during the first attempt. See
# troubleshooting/install-autoinstall-failures.md.
# ---------------------------------------------------------------------------

set -euo pipefail

hostname_short="${1:?usage: install-guest.sh <hostname> <ip>}"
static_ip="${2:?usage: install-guest.sh <hostname> <ip>}"
vm="nordicshop-${hostname_short}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="${ISO:-$HOME/Downloads/ubuntu-24.04.5-live-server-amd64.iso}"
KEY="$ROOT_DIR/.secrets/lab_ed25519"
WAIT_MINUTES="${WAIT_MINUTES:-25}"

say() { printf '\n==> %s\n' "$*"; }

[[ -f "$ISO" ]] || { echo "ISO not found: $ISO" >&2; exit 1; }
VBoxManage showvminfo "$vm" >/dev/null 2>&1 || { echo "no such VM: $vm" >&2; exit 1; }

say "building seed for $hostname_short at $static_ip"
"$ROOT_DIR/scripts/build-seed-iso.sh" "$hostname_short" "$static_ip"
seed="/tmp/nordicshop-seed-${hostname_short}.iso"

say "stopping $vm if it is running"
VBoxManage controlvm "$vm" poweroff >/dev/null 2>&1 || true
sleep 3

say "attaching media"
VBoxManage storagectl "$vm" --name SATA --portcount 4 >/dev/null 2>&1 || true
for port in 1 2; do
  VBoxManage storageattach "$vm" --storagectl SATA --port "$port" --device 0 \
    --type dvddrive --medium none >/dev/null 2>&1 || true
done
VBoxManage storageattach "$vm" --storagectl SATA --port 1 --device 0 \
  --type dvddrive --medium "$ISO"
VBoxManage storageattach "$vm" --storagectl SATA --port 2 --device 0 \
  --type dvddrive --medium "$seed"

say "booting $vm headless"
VBoxManage startvm "$vm" --type headless | tail -1

# subiquity asks for confirmation because 'autoinstall' is not on the kernel
# command line. The prompt appears after the seed is read, roughly a minute in.
# Sending the answer late is harmless: by then the installer is at a progress
# screen that ignores keystrokes.
say "answering the autoinstall confirmation prompt"
sleep 70
VBoxManage controlvm "$vm" keyboardputstring "yes"
VBoxManage controlvm "$vm" keyboardputscancode 1c 9c

say "waiting for the installed system at $static_ip (up to ${WAIT_MINUTES} minutes)"
deadline=$(( $(date +%s) + WAIT_MINUTES * 60 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  # Poll the address the guest will have after install, not the NAT forward:
  # the forward accepts connections whether or not the guest is ready.
  got="$(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=5 \
        "labadmin@${static_ip}" hostname 2>/dev/null || true)"
  if [ "$got" = "$hostname_short" ]; then
    say "$vm installed and answering as $hostname_short"
    exit 0
  fi
  sleep 20
done

echo "timed out waiting for $vm; capture the console to see where it stopped:" >&2
echo "  VBoxManage controlvm $vm screenshotpng /tmp/${vm}.png" >&2
exit 1
