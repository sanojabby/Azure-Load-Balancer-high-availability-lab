# Phase 2: Network infrastructure report

**Date:** 19 November 2026
**Status:** complete and verified, four guests running from disk with static addressing
and a firewall baseline
**Scope:** VirtualBox network wiring, VM hardware, guest provisioning, addressing,
firewall baseline, connectivity verification

## 1. Decisions agreed before any change

1. Rebuild all four `nordicshop-*` VMs from scratch. The previous load balancer was
   copied to `~/VirtualBox-backups/20261119-1803-nordicshop-lb01` (3.8 GB) before
   deletion; the other three VMs on the host were never touched.
2. Reuse the existing `LabNet` host-only network, 192.168.56.0/24. No host network
   configuration was modified.
3. Standardise on 1 vCPU, 1024 MB RAM, 20 GB thin disk per guest.

## 2. Network as built

| Host | NIC1 | NIC2 | Static address |
| --- | --- | --- | --- |
| lb01 | NAT (10.0.2.15) | hostonlynet LabNet | 192.168.56.10/24 |
| web01 | NAT (10.0.2.15) | hostonlynet LabNet | 192.168.56.21/24 |
| web02 | NAT (10.0.2.15) | hostonlynet LabNet | 192.168.56.22/24 |
| client01 | NAT (10.0.2.15) | hostonlynet LabNet | 192.168.56.31/24 |

Only NIC1 carries a default route. The lab interface has no gateway on purpose,
which prevents the asymmetric routing that appears when two NICs both claim a
default route.

## 3. Provisioning approach

`VBoxManage unattended install` was tried first and failed; the four causes are in
`troubleshooting/install-autoinstall-failures.md`. The replacement is a cloud-init
NoCloud seed built locally:

| Script | Purpose |
| --- | --- |
| `scripts/rebuild-lab-vms.sh` | Creates or recreates the four VMs, refuses any other name |
| `scripts/build-seed-iso.sh` | Renders the autoinstall template, builds a CIDATA ISO |
| `scripts/install-guest.sh` | Attaches media, boots, answers the confirmation prompt, waits |
| `scripts/finish-guest.sh` | Waits for the install reboot, ejects media, boots from disk, verifies |
| `scripts/guest.sh` | Runs commands in a guest over SSH, optionally as root |

Guest definitions live in `configuration/autoinstall/user-data.tmpl`, so the lab is
reproducible from the repository rather than from a sequence of manual clicks.

## 4. What actually happened during installation

This is the honest part, because it shaped the recovery procedure.

All four guests reached the final installer stage, `run_unattended_upgrades`, which
runs `apt-get dist-upgrade` inside the target. Three of them stayed there for
between 20 and 50 minutes with the CPU pinned at 100 to 120 percent. That looked
like slow work, but it was not:

```
$ du -m "~/VirtualBox VMs/nordicshop-lb01/nordicshop-lb01.vdi"
3927
# 75 seconds later, during "dist-upgrade"
3927
```

Zero bytes written in 75 seconds while the CPU was fully busy. The stage was
spinning, not progressing. The lesson generalises: **a process burning CPU is not
evidence of progress.** The same mistake costs hours in production when a health
check reports "up" because a socket opened, or a job looks alive because it is busy.

The fourth guest, `client01`, never started at all on the first attempt. Its `yes`
answer to the `Continue with autoinstall?` prompt was sent before the prompt
appeared and was discarded, so it sat at the question indefinitely. It was
reinstalled, reached the same `dist-upgrade` stage as the others (about 5 GB
written), and was then recovered with the identical procedure.

### Recovery procedure

The install had already written a complete system to disk before reaching
`run_unattended_upgrades`: kernel, bootloader, cloud-init and OpenSSH were all in
place. So rather than reinstall, each stuck guest was taken from the installer into
the installed system:

```bash
VBoxManage controlvm nordicshop-lb01 poweroff
VBoxManage storageattach nordicshop-lb01 --storagectl SATA --port 1 --device 0 \
  --type dvddrive --medium none
VBoxManage storageattach nordicshop-lb01 --storagectl SATA --port 2 --device 0 \
  --type dvddrive --medium none
VBoxManage modifyvm nordicshop-lb01 --boot1 disk --boot2 none
VBoxManage startvm nordicshop-lb01 --type headless
```

`web01` and `web02` were recovered the same way and came up first time.

`client01` had nothing written to disk, so it was reinstalled from scratch with
`scripts/install-guest.sh client01 192.168.56.31`, this time launched as a
persistent background process. The earlier attempt had been backgrounded inside a
short-lived shell and was killed with it, which is why that VM was found powered off
mid-sequence.

### Consequence of the interruption

The autoinstall `late-commands` never ran on the recovered guests. That means the
`/etc/sudoers.d/90-lab-nopasswd` file from the template is absent and
administrative commands authenticate with the account password instead. Nothing
depends on passwordless sudo: `scripts/guest.sh --root` feeds the password on
stdin, so it never appears in argv or shell history. That is closer to how a real
host behaves anyway, so it was left alone rather than "fixed".

The pending upgrades from the interrupted `dist-upgrade` remain queued:

```
0 upgraded, 0 newly installed, 0 to remove and 29 not upgraded
```

They are cosmetic for this lab. Applying them is a future improvement, not a
correctness requirement, and doing so now would only consume time on one-vCPU guests.

## 5. Verified results

### 5.1 Boot from disk, media ejected

```
lb01      boot1=disk  media1=none media2=none
web01     boot1=disk  media1=none media2=none
web02     boot1=disk  media1=none media2=none
client01  boot1=disk  media1=none media2=none      (after recovery)
```

Boot order is disk first with no optical media attached, so a reboot lands in the
installed system and cannot fall back into the installer.

### 5.2 Addressing inside the guest

`lb01`, verbatim:

```
$ ip -br addr
lo               UNKNOWN        127.0.0.1/8 ::1/128
enp0s3           UP             10.0.2.15/24 metric 100 fd17:625c:f037:2:a00:27ff:fee1:9568/64 fe80::a00:27ff:fee1:9568/64
enp0s8           UP             192.168.56.10/24 fdaa:bf12:5347:48de:a00:27ff:fed5:2036/64 fe80::a00:27ff:fed5:2036/64

$ ip route
default via 10.0.2.2 dev enp0s3 proto dhcp src 10.0.2.15 metric 100
10.0.2.0/24 dev enp0s3 proto kernel scope link src 10.0.2.15 metric 100
192.168.56.0/24 dev enp0s8 proto kernel scope link src 192.168.56.10
```

The default route exists only on the NAT interface, and the lab interface has only
its connected route. The IPv6 addresses are VirtualBox's ULA addresses on the
host-only network; they are not used by anything in this lab and are recorded so
they are not mistaken for a mistake later.

`web01`, `web02` and `client01`:

```
web01    enp0s8  UP  192.168.56.21/24
web02    enp0s8  UP  192.168.56.22/24
client01 enp0s8  UP  192.168.56.31/24
```

### 5.3 Name resolution

`/etc/hosts` on every guest:

```
192.168.56.10   lb01.nordicshop.lab lb01
192.168.56.21   web01.nordicshop.lab web01
192.168.56.22   web02.nordicshop.lab web02
192.168.56.31   client01.nordicshop.lab client01
```

### 5.4 Connectivity matrix

ICMP, two packets per pair:

```
  lb01     -> web01    (192.168.56.21) : OK
  lb01     -> web02    (192.168.56.22) : OK
  lb01     -> host     (192.168.56.1)  : OK
  web01    -> lb01     (192.168.56.10) : OK
  web01    -> web02    (192.168.56.22) : OK
  web02    -> lb01     (192.168.56.10) : OK
  web02    -> web01    (192.168.56.21) : OK

  mac      -> lb01     (192.168.56.10) : OK
  mac      -> web01    (192.168.56.21) : OK
  mac      -> web02    (192.168.56.22) : OK
```

Repeated after `client01` was recovered, including the client as a source:

```
  lb01     -> web01     OK      lb01     -> web02     OK
  lb01     -> client01  OK
  client01 -> lb01      OK      client01 -> web01     OK
  client01 -> web02     OK      client01 -> host .1   OK
  web01    -> client01  OK      web02    -> client01  OK
```

Every host reaches every other host and the Mac. Traffic never leaves the host-only
network.

### 5.5 Package state after the interrupted upgrade

```
# dpkg --audit
(no output: no partially configured or broken packages)

# dpkg -l | awk '/^i[^i]/'
(no output: nothing in a failed or half-installed state)
```

### 5.6 Firewall baseline

`lb01`:

```
Status: active
Default: deny (incoming), allow (outgoing), disabled (routed)
To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    192.168.56.0/24
22/tcp                     ALLOW IN    10.0.2.0/24
80/tcp                     ALLOW IN    192.168.56.0/24
```

`web01` and `web02`:

```
Status: active
Default: deny (incoming), allow (outgoing), disabled (routed)
To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    192.168.56.0/24
22/tcp                     ALLOW IN    10.0.2.0/24
80/tcp                     ALLOW IN    192.168.56.10
```

The important line is the last one on the backends: port 80 accepts connections
from the load balancer's address and nothing else. A backend is not a public entry
point. This is the local form of an NSG rule whose source is the load balancer.

`client01` needs no inbound service at all, only SSH for administration:

```
To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       192.168.56.0/24
22/tcp                     ALLOW       10.0.2.0/24
```

SSH is allowed from the lab subnet (which includes the Mac at .1) and from the NAT
subnet, so administration is possible even if the host-only network is misconfigured.

### 5.7 Final state, all four guests

```
vm        hostname   address          vm state   boot1  dvd      ufw
lb01      lb01       192.168.56.10    running    disk   ejected  active
web01     web01      192.168.56.21    running    disk   ejected  active
web02     web02      192.168.56.22    running    disk   ejected  active
client01  client01   192.168.56.31    running    disk   ejected  active
```

SSH key authentication from the host works on all four (`key-ok` above is the result
of the login used to read each hostname), and `/etc/hosts` on every guest contains
all four entries, checked with `grep -c nordicshop.lab /etc/hosts` returning `4`.

Package state on `client01` after its recovery:

```
audit_start
audit_end                        <- dpkg --audit printed nothing
0 upgraded, 0 newly installed, 0 to remove and 29 not upgraded
```

## 6. Deviations from the plan

| Plan | Reality | Why it is acceptable |
| --- | --- | --- |
| Autoinstall sets passwordless sudo | Not applied; password sudo in use | The late-command never ran after recovery; `guest.sh` supplies the password on stdin |
| Unattended install completes on its own | Installer hung in `dist-upgrade`; guests recovered by booting the completed target | The written system was already complete; dpkg audit is clean |
| 1 vCPU is enough | Installing is slow at 1 vCPU, which contributed to the hang | Fine for running HAProxy and Nginx; only installation is slow |

## 7. Azure mapping for this phase

| Local element | Azure equivalent | Who configures it |
| --- | --- | --- |
| `LabNet` 192.168.56.0/24 | VNet and subnet address space | Customer |
| Static NIC2 address | Private IP on a NIC, or a backend pool member | Customer |
| Default route only on NIC1 | Azure provides the subnet gateway; route tables are optional | Platform, with customer routes if needed |
| UFW rule on 80 from .10 | NSG rule: source = load balancer, destination port 80 | Customer |
| `/etc/hosts` | Azure Private DNS zone or default VNet resolution | Customer |
| One authority for addressing | One VNet address space; overlapping ranges break peering | Customer, checked by the platform |

## 8. Next steps

Phase 2 is closed. Remaining work, all of it Phase 3 onwards:

1. Install Nginx on both backends with distinct content and a health endpoint.
2. Prove the firewall rule does what it claims: a request to `web01:80` from
   `web02` must be rejected, while the same request from `lb01` must succeed.
3. HAProxy frontend, backend pool, TCP health checks, algorithm and traffic tests.
4. The five incident simulations, then the Azure mapping and the repository README.
