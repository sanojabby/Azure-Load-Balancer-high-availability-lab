# Incident report: guest installation failures

**Date:** 19 November 2026
**Phase:** 2, building the Ubuntu guests
**Severity:** blocking, no guest could be provisioned
**Status:** resolved and verified on nordicshop-lb01

This is not one of the five planned production incidents. It is what actually
happened while building the lab, and it is documented because the pattern
(misleading check, wrong assumption, then finding the real error) is the same
one used later against HAProxy.

## Summary

Provisioning four Ubuntu 24.04 guests with `VBoxManage unattended install`
failed. Three separate problems stacked on top of each other, and each one
produced a symptom that pointed somewhere else.

| # | Symptom | Actual cause |
| --- | --- | --- |
| 1 | `nc -z 127.0.0.1 2222` said port open 15 seconds after boot | VirtualBox NAT listens regardless of the guest |
| 2 | Installer reported success-looking progress, then died | `curtin in-target apt-get update` returned 1 |
| 3 | `Malformed autoinstall in 'identity' section` | subiquity requires `identity.password` |
| 4 | `Continue with autoinstall? (yes|no)` | seed detected, but no `autoinstall` on the kernel cmdline |

## Problem 1: the readiness check lied

### Symptom

After starting the VM, a TCP check on the NAT forward reported the SSH port
open within 15 seconds. A full Ubuntu install takes minutes, so that was
impossible.

### Initial investigation

```bash
nc -z 127.0.0.1 2222 && echo "port 2222 open"
```

Open. Then the same check 30 seconds later, after a login attempt:

```
labadmin@127.0.0.1: Permission denied (publickey,password).
```

### Root cause

VirtualBox's NAT port forward binds the host port and accepts connections
itself, whether or not anything is listening inside the guest. `nc -z` proves
the forwarder exists, not that sshd is running.

### Fix

Wait for something only a real sshd produces. The first bytes of an SSH
connection are a protocol banner:

```bash
banner=$(ssh -o BatchMode=yes ... hostname 2>/dev/null || true)
[ "$banner" = "lb01" ] && echo installed
```

A key-based `hostname` call returns nothing until the installed system is up
and the key is in place, so it is a much stronger signal than an open socket.

### Lesson learned

A check that passes too early is more dangerous than one that fails, because it
stops the investigation. When timing looks impossible, suspect the check before
suspecting the system. This is directly relevant to HAProxy health checks: a
TCP connect check passes as soon as the kernel accepts, not when the
application can serve.

## Problem 2: autoinstall crashed at apt

### Symptom

The screen showed the installer progressing normally through network, mirror
and locale stages, then:

```
curtin command in-target returned non-zero exit status 1
An error occurred. Press enter to start a shell
```

### Initial investigation

From the installer's recovery shell:

```
ip -br addr         enp0s3 10.0.2.15/24, enp0s8 192.168.56.12/24
ip r                default via 10.0.2.2 dev enp0s3
cat /etc/resolv.conf    nameserver 127.0.0.53
ping archive.ubuntu.com 64 bytes, 37 ms
```

Guest networking and DNS were fine, and the archive was reachable. So the
failure was not connectivity. `/target` had already been torn down after the
crash, so `chroot /target apt-get update` could not reproduce it.

### Root cause

The installer resolves DNS through systemd-resolved's stub listener on
127.0.0.53. Inside the target chroot, during `curtin in-target`, that stub has
nothing behind it, so apt cannot resolve the archive even though the installer
environment can.

### Fix

Write a real resolver before the target gets configured, so curtin copies a
working one into the chroot:

```yaml
early-commands:
  - sh -c 'printf "nameserver 10.0.2.3\nnameserver 1.1.1.1\n" > /etc/resolv.conf'
```

`10.0.2.3` is VirtualBox's NAT DNS service. After this change the same stage
completed and curtin moved on to installing packages.

### Verification

The installer log moved past the previous failure point:

```
finish: subiquity/Install/install/curtin_install/.../cmd-curthooks/: configuring apt
finish: .../cmd-curthooks/: installing missing packages
finish: .../cmd-curthooks/: installing kernel
```

### Lesson learned

"The network works" and "DNS works in every context that needs it" are
different claims. A resolver that works for the host process can be useless
inside a chroot, which is the same class of problem as a service that listens
on 127.0.0.1 only and is then probed from another machine.

## Problem 3: identity section rejected

### Symptom

```
finish: subiquity/Identity/load_autoinstall_data: Malformed autoinstall in 'identity' section
```

The autoinstall was accepted as a datasource (early-commands had run), so the
seed ISO mechanism was working. This was a schema problem.

### Root cause

subiquity requires `identity.password`. The first version of the template
deliberately omitted it, because macOS cannot produce a SHA-512 crypt hash:
Python's `crypt` module on macOS delegates to libc, which supports DES and MD5
only, and `openssl passwd` on this host offers just `-1`, `-apr1` and `-crypt`.

### Fix

Two parts:

1. `identity.password` gets an MD5 crypt hash from `openssl passwd -1` so the
   schema is satisfied.
2. The account's real password is set inside the guest by a late-command, so
   the modern hashing happens in the guest's own PAM stack:

```yaml
late-commands:
  - curtin in-target -- sh -c 'printf "%s:%s\n" "labadmin" "__PASSWORD__" | chpasswd'
```

### Lesson learned

Do the hashing where the right library exists. Fighting a missing host feature
cost more time than moving the work to the machine that has it.

## Problem 4: autoinstall asked for confirmation

### Symptom

```
Confirmation is required to continue.
Add 'autoinstall' to your kernel command line to avoid this
Continue with autoinstall? (yes|no)
```

### Root cause

subiquity found the seed ISO by label (`CIDATA`), but the kernel command line
is the stock ISO's, without the `autoinstall` parameter. Without that
parameter, subiquity asks before destroying a disk.

### Fix

Answer the prompt. On a headless VM that means injecting keystrokes into the
console:

```bash
VBoxManage controlvm nordicshop-lb01 keyboardputstring "yes"
VBoxManage controlvm nordicshop-lb01 keyboardputscancode 1c 9c   # Enter
```

The alternative, editing the ISO's grub configuration, is not worth it for a
lab.

### Lesson learned

An unattended install is only unattended up to the first prompt nobody
planned for. Reading the console at the point of a hang is faster than
guessing at YAML.

## Problem 5: installer spins forever in unattended upgrades

### Symptom

Three guests sat in the final installer stage for 20 to 50 minutes:

```
start: subiquity/Install/install/postinstall/run_unattended_upgrades/downloading and installing security updates
start: subiquity/Install/install/postinstall/run_unattended_upgrades/cmd-in-target: curtin command in-target
start: subiquity/Network/_send_update: CHANGE enp0s8
finish: subiquity/Network/_send_update: CHANGE enp0s8
```

That stage runs `apt-get dist-upgrade` inside the target.

### Initial investigation

CPU said "working":

```
30095 112.5  50:10 /Applications/VirtualBox.app/Contents/Resources/VBoxHeadless.app/...
```

Disk said something else:

```
$ du -m "~/VirtualBox VMs/nordicshop-lb01/nordicshop-lb01.vdi"
3927
# 75 seconds later, still in the same stage
$ du -m "~/VirtualBox VMs/nordicshop-lb01/nordicshop-lb01.vdi"
3927
```

### Root cause

Not conclusively identified, and that is stated honestly rather than invented. What
is certain is that the stage was spinning without writing, on guests with 1 vCPU and
1 GB of RAM whose swap was already in use. Zero disk growth over 75 seconds rules out
"slow package installation" as the explanation. The most likely contributors are
memory pressure during dpkg post-install scripts and the target chroot's resolver
being restored to a stub that cannot answer.

### Resolution

The install had already written a complete system before that stage: kernel,
bootloader, cloud-init and OpenSSH. So the guests were taken out of the installer
instead of being reinstalled:

```bash
VBoxManage controlvm nordicshop-lb01 poweroff
VBoxManage storageattach nordicshop-lb01 --storagectl SATA --port 1 --device 0 --type dvddrive --medium none
VBoxManage storageattach nordicshop-lb01 --storagectl SATA --port 2 --device 0 --type dvddrive --medium none
VBoxManage modifyvm nordicshop-lb01 --boot1 disk --boot2 none
VBoxManage startvm nordicshop-lb01 --type headless
```

### Verification

```
lo      UNKNOWN  127.0.0.1/8
enp0s3  UP       10.0.2.15/24
enp0s8  UP       192.168.56.10/24

default via 10.0.2.2 dev enp0s3
192.168.56.0/24 dev enp0s8 proto kernel scope link src 192.168.56.10

# dpkg --audit
(no output)
```

SSH key authentication worked, the static address was correct, and no package was
left half-configured.

### Lesson learned

A process consuming CPU is not evidence of progress, and neither is a service that
accepts a TCP connection. Measure the thing that has to change: bytes written,
requests served, a response body. This is exactly why the HAProxy backend health
check in Phase 4 must test the application response and not only the socket.

## Final working configuration

The durable version of all four fixes lives in
`configuration/autoinstall/user-data.tmpl` and `scripts/build-seed-iso.sh`.
The generated seed ISO is served on SATA port 2, the Ubuntu ISO on port 1, and
the VM answers the confirmation prompt via keyboard injection.

## What I would do differently

- Decide up front whether guest definition is VirtualBox's job or mine. Owning
  the autoinstall file from the start would have avoided problems 2, 3 and 4.
- Never trust a readiness check that cannot fail for the right reason.
- Keep the console visible from the first boot. All four problems were visible
  on screen long before they were visible in any host-side check.
