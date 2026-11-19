#!/usr/bin/env bash
#
# rebuild-lab-vms.sh
# ---------------------------------------------------------------------------
# Rebuilds the four NordicShop lab virtual machines on this Mac from scratch.
#
# This script is destructive by design: it unregisters and deletes the VDI
# files of the four nordicshop-* machines before creating fresh ones. It will
# refuse to touch anything whose name does not match the exact list below, so
# the other VMs on the host are never at risk.
#
# Usage:
#   ./rebuild-lab-vms.sh                     # print the plan, change nothing
#   CONFIRM=yes ./rebuild-lab-vms.sh         # delete and rebuild
#   CONFIRM=yes BACKUP=yes ./rebuild-lab-vms.sh   # keep a copy of the old VM folders first
#
# Overridable environment variables:
#   ISO           path to the Ubuntu Server ISO
#   HOSTONLY_NET  VirtualBox host-only network name
#   VMFOLDER      VirtualBox machine folder
#   DISK_MB       virtual disk size (default 20480 = 20 GiB, thin provisioned)
#
# Design decisions recorded in architecture/ip-addressing-plan.md:
#   NIC1 NAT        outbound package installation only
#   NIC2 host-only  private lab network 192.168.56.0/24, static addressing
# ---------------------------------------------------------------------------

set -euo pipefail

ISO="${ISO:-$HOME/Downloads/ubuntu-24.04.5-live-server-amd64.iso}"
HOSTONLY_NET="${HOSTONLY_NET:-LabNet}"
VMFOLDER="${VMFOLDER:-$HOME/VirtualBox VMs}"
OSTYPE_ID="Ubuntu24_LTS_64"
DISK_MB="${DISK_MB:-20480}"
RAM_MB="${RAM_MB:-1024}"
VCPU="${VCPU:-1}"

VMS=(
  "nordicshop-lb01"
  "nordicshop-web01"
  "nordicshop-web02"
  "nordicshop-client01"
)

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight: fail before deleting anything, not halfway through
# ---------------------------------------------------------------------------
preflight() {
  command -v VBoxManage >/dev/null 2>&1 || die "VBoxManage not on PATH"
  [[ -f "$ISO" ]] || die "Ubuntu ISO not found at $ISO"

  # The host-only network must already exist. This script never creates host
  # networks, because changing host networking was out of scope for the lab.
  VBoxManage list hostonlynets | grep -q "Name: *${HOSTONLY_NET}$" \
    || die "host-only network '$HOSTONLY_NET' not found; run VBoxManage list hostonlynets"

  # Belt and braces: only ever operate on the four expected names.
  local vm
  for vm in "${VMS[@]}"; do
    [[ "$vm" =~ ^nordicshop-(lb01|web01|web02|client01)$ ]] \
      || die "refusing unexpected VM name: $vm"
  done
}

vm_state() {
  VBoxManage showvminfo "$1" --machinereadable 2>/dev/null \
    | sed -n 's/^VMState="\(.*\)"$/\1/p'
}

# machinereadable is inconsistent about quoting: strings are quoted, numbers
# and the nic types are not. Strip quotes so callers get a clean value.
vm_field() {
  VBoxManage showvminfo "$1" --machinereadable 2>/dev/null \
    | awk -F= -v key="$2" '$1 == key { gsub(/"/, "", $2); print $2; exit }'
}

# NAT port forward for remote SSH during installation. Only the load balancer
# gets one: the backends are reachable from the host over the host-only
# network, and the live-server installer offers OpenSSH on all four.
nat_pf_rule() {
  if [[ "$1" == "nordicshop-lb01" ]]; then
    echo "ssh,tcp,,2222,,22"
  fi
}

plan() {
  say "Plan"
  printf '  ISO            %s\n' "$ISO"
  printf '  Host-only net  %s\n' "$HOSTONLY_NET"
  printf '  VM folder      %s\n' "$VMFOLDER"
  printf '  Spec           %s vCPU, %s MB RAM, %s MB thin disk each\n' "$VCPU" "$RAM_MB" "$DISK_MB"
  echo
  local vm state size
  for vm in "${VMS[@]}"; do
    if VBoxManage showvminfo "$vm" >/dev/null 2>&1; then
      state="$(vm_state "$vm")"
      size="$(du -sh "$VMFOLDER/$vm" 2>/dev/null | cut -f1 || echo '?')"
      printf '  DELETE + REBUILD  %-24s state=%-9s disk=%s\n' "$vm" "$state" "$size"
    else
      printf '  CREATE            %-24s (does not exist)\n' "$vm"
    fi
  done
}

# ---------------------------------------------------------------------------
# Destroy: graceful shutdown, optional backup, then unregister and delete
# ---------------------------------------------------------------------------
destroy() {
  local vm state i
  for vm in "${VMS[@]}"; do
    VBoxManage showvminfo "$vm" >/dev/null 2>&1 || continue
    state="$(vm_state "$vm")"

    if [[ "$state" == "running" || "$state" == "paused" ]]; then
      say "Shutting down $vm gracefully (ACPI power button)"
      VBoxManage controlvm "$vm" acpipowerbutton || true
      for i in $(seq 1 30); do
        sleep 1
        [[ "$(vm_state "$vm")" == "poweroff" ]] && break
      done
      if [[ "$(vm_state "$vm")" != "poweroff" ]]; then
        say "$vm did not shut down in 30s, forcing power off"
        VBoxManage controlvm "$vm" poweroff || true
        sleep 2
      fi
    fi

    if [[ "${BACKUP:-no}" == "yes" && -d "$VMFOLDER/$vm" ]]; then
      local dest="$HOME/VirtualBox-backups/$(date +%Y%m%d-%H%M)-$vm"
      mkdir -p "$(dirname "$dest")"
      say "Backing up $vm to $dest"
      cp -R "$VMFOLDER/$vm" "$dest"
    fi

    say "Deleting $vm and its virtual disk"
    VBoxManage unregistervm "$vm" --delete
  done
}

# ---------------------------------------------------------------------------
# Create: hardware, storage, ISO, networking
# ---------------------------------------------------------------------------
create() {
  local vm dir pf
  for vm in "${VMS[@]}"; do
    say "Creating $vm"
    dir="$VMFOLDER/$vm"
    pf="$(nat_pf_rule "$vm")"

    VBoxManage createvm --name "$vm" --ostype "$OSTYPE_ID" --register >/dev/null
    VBoxManage modifyvm "$vm" \
      --memory "$RAM_MB" \
      --cpus "$VCPU" \
      --vram 16 \
      --graphicscontroller vmsvga \
      --audio-enabled off \
      --ioapic on \
      --rtc-use-utc on \
      --boot1 dvd --boot2 disk --boot3 none --boot4 none \
      --nic1 nat --nic-type1 82540EM \
      --nic2 hostonlynet --host-only-net2="$HOSTONLY_NET" --nic-type2 82540EM

    # The NAT forward goes on after the NIC exists so the rule is validated.
    if [[ -n "$pf" ]]; then
      VBoxManage modifyvm "$vm" --nat-pf1="$pf"
    fi

    mkdir -p "$dir"
    VBoxManage createmedium disk \
      --filename "$dir/$vm.vdi" \
      --size "$DISK_MB" \
      --format VDI \
      --variant Standard >/dev/null

    VBoxManage storagectl "$vm" \
      --name SATA --add sata --controller IntelAhci --portcount 2 --bootable on

    VBoxManage storageattach "$vm" \
      --storagectl SATA --port 0 --device 0 --type hdd \
      --medium "$dir/$vm.vdi"

    VBoxManage storageattach "$vm" \
      --storagectl SATA --port 1 --device 0 --type dvddrive \
      --medium "$ISO"
  done
}

summary() {
  say "Result"
  VBoxManage list vms
  echo
  local vm
  for vm in "${VMS[@]}"; do
    printf '%-24s %s vCPU  %s MB  nic1=%s  nic2=%s(%s)\n' \
      "$vm" \
      "$(vm_field "$vm" cpus)" \
      "$(vm_field "$vm" memory)" \
      "$(vm_field "$vm" nic1)" \
      "$(vm_field "$vm" nic2)" \
      "$(vm_field "$vm" host-only-net2)"
  done
  cat <<'NEXT'

Next steps, per machine:
  1. VBoxManage startvm <name> --type gui     (or --type headless + VRDE)
  2. Install Ubuntu Server 24.04.5, hostname <name>, OpenSSH enabled
  3. Apply the static addressing from architecture/ip-addressing-plan.md
  4. Verify with: ip -br addr; ip route; ping -c3 192.168.56.1

NEXT
}

# ---------------------------------------------------------------------------
main() {
  preflight
  plan

  if [[ "${CONFIRM:-no}" != "yes" ]]; then
    cat <<'EOF'

Dry run only. Nothing was deleted or created.
Re-run with:  CONFIRM=yes ./rebuild-lab-vms.sh
Add BACKUP=yes to keep a copy of the existing VM folders first.
EOF
    exit 0
  fi

  destroy
  create
  summary
}

main "$@"
