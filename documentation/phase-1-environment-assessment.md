# Phase 1: Environment assessment

**Project:** NordicShop highly available load balancing lab
**Phase:** 1 of 6, infrastructure assessment
**Date:** 19 November 2026
**Author:** Sanoj Abby, Junior Cloud Infrastructure Engineer, NordicShop

## Purpose

Before creating anything in VirtualBox I needed two answers: can this laptop actually
run four Ubuntu machines at the same time without falling over, and does any of the lab
already exist from earlier experiments.

Everything in this phase was read-only. No software was installed, no virtual machine was
created, changed or deleted, and no host network setting was touched.

## 1. Host platform

| Item | Value |
| --- | --- |
| Operating system | macOS 26.5.2 (build 25F84) |
| Kernel | Darwin 25.5.0, x86_64 |
| Architecture | Intel x86_64 (not Apple Silicon) |
| Machine | sanos-MacBook-Pro.local |

The architecture matters more than the version. This is an Intel host, so VirtualBox runs
the standard AMD64 builds of Ubuntu at near native speed. On Apple Silicon the same design
would need ARM64 images and a different hypervisor, and the lab notes would read very
differently.

## 2. CPU

```
$ sysctl -n machdep.cpu.brand_string
Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz
$ sysctl -n hw.ncpu hw.physicalcpu hw.logicalcpu
16 8 16
```

Eight physical cores with hyper-threading, so sixteen logical CPUs. A four machine lab can
run comfortably on four vCPUs, which leaves most of the host free for the browser, the
terminal and the documentation I am writing as I go.

Load average sampled during the assessment was `4.91 4.60 4.38`. That is other work on the
machine, not the lab, and it is well below the sixteen logical CPUs available. I will
re-check it before starting the VMs in Phase 2, because load is not a fixed number.

## 3. Memory

```
$ sysctl -n hw.memsize
34359738368          # 32 GiB
$ vm_stat
Pages free:                        51644
Pages active:                    3443082
Pages inactive:                  3437881
Pages wired down:                1005414
Pages stored in compressor:      1878082
Pages occupied by compressor:     445549
$ memory_pressure | tail -3
System-wide memory free percentage: 82%
```

Reading this honestly rather than trusting the headline number:

- 32 GiB installed, roughly 14 GiB genuinely available once active and wired pages are counted.
- The compressor is holding about 1.8 million pages compressed into 1.7 GB, which tells me the
  machine has been under memory pressure at some point in this boot.
- Swap in and out counters are in the tens of millions of pages across the uptime. Historical,
  but a reminder not to oversubscribe.

Practical conclusion: a lab ceiling of 4 to 5 GB of guest RAM, which is around a seventh of
the physical total. That is enough for HAProxy and two Nginx servers and leaves a wide margin
so the host does not start swapping while I am troubleshooting.

## 4. Storage

```
$ df -h /
/dev/disk1s4s1   466Gi   12Gi   162Gi   7%   /
```

162 GiB free on the system volume, 285 GiB used on the data volume. Plenty for the lab.

Disk policy for the VMs: dynamically allocated VDI, 20 GB virtual size each. Thin
provisioning means the files grow only as the guest writes. A finished Ubuntu Server install
plus Nginx and HAProxy lands around 3 to 5 GB per machine, so the four disk files together
should stay near 20 GB rather than the 80 GB of virtual size.

## 5. Hardware virtualisation

```
$ sysctl -n kern.hv_support
1
```

VT-x is exposed by the firmware, so VirtualBox can use hardware assisted virtualisation
rather than software emulation. This is the single most important line in the assessment. A
`0` here would mean 64-bit guests run painfully slowly or refuse to start.

## 6. VirtualBox installation

```
$ VBoxManage --version
7.2.14r174565
$ ls -d /Applications/VirtualBox.app
/Applications/VirtualBox.app
```

VirtualBox 7.2.14 is installed and the management CLI is on `PATH` at `/usr/local/bin/VBoxManage`.
Because guests already run on this host, the kernel extension is approved and loaded. No
install or upgrade is needed, so I am not touching it.

VirtualBox 7.x replaced the old host-only *interface* concept with named host-only
*networks*. This shows up in the commands later, so I noted it now: `VBoxManage list
hostonlyifs` returns nothing on 7.2, while `VBoxManage list hostonlynets` returns the
networks this lab cares about.

## 7. Existing lab footprint

An earlier attempt at this project left four machines behind. I inventoried them before
planning so nothing gets duplicated or silently deleted.

| VM | State | vCPU | RAM | Disk file | Assessment |
| --- | --- | --- | --- | --- | --- |
| nordicshop-lb01 | running | 1 | 2048 MB | 3.8 GB | Ubuntu installed, already answering on 192.168.56.10 |
| nordicshop-web01 | poweroff | 1 | 1024 MB | 2 MB | Empty shell, install never ran |
| nordicshop-web02 | poweroff | 1 | 1024 MB | 2 MB | Empty shell, install never ran |
| nordicshop-client01 | poweroff | 1 | 1024 MB | 2 MB | Empty shell, install never ran |

All four are defined as Ubuntu 24.04 LTS (Noble Numbat) 64-bit. Three of them are 2 MB
placeholder disks, which means the installer was started and never finished. Nothing is lost
by rebuilding those three. `nordicshop-lb01` holds a real install and is currently powered on.

It is not just installed, it is already addressed. A ping from the host was answered and the
ARP entry matches the VM's second adapter MAC address:

```
$ ping -c 2 192.168.56.10
2 packets transmitted, 2 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 0.395/0.716/1.036/0.321 ms
$ arp -an | grep 192.168.56.10
? (192.168.56.10) at 8:0:27:eb:84:c4 on bridge100 ifscope [bridge]
```

`8:0:27:eb:84:c4` is `macaddress2` of that VM. So the earlier attempt had already applied
part of the addressing plan to the load balancer. Phase 2 will audit the guest configuration
before changing anything, so I know what state it is in rather than guessing.

The nine other VMs on the host (`test 1`, `jabby`, `sano`, `server`, `Bruce`, `flöckii`,
`bruce`, `pazza`, `Brune(new employee)`) belong to other work and are out of scope. They will
not be modified.

## 8. Network configuration found on the host

```
$ VBoxManage list hostonlynets
Name:            LabNet
GUID:            4fb0aacb-924e-404b-b461-3993bd43e750
State:           Enabled
NetworkMask:     255.255.255.0
LowerIP:         192.168.56.1
UpperIP:         192.168.56.199
VBoxNetworkName: hostonly-LabNet

$ VBoxManage list dhcpservers
NetworkName:     HostInterfaceNetworking-vboxnet0
Dhcpd IP:        192.168.56.100
LowerIPAddress:  192.168.56.101
UpperIPAddress:  192.168.56.254
NetworkMask:     255.255.255.0
Enabled:         Yes
```

Two things worth recording.

**A host-only network already exists.** It is called `LabNet`, it is enabled, and it uses
192.168.56.0/24 with the host at 192.168.56.1. Every lab VM already has NIC2 attached to it.
Reusing it means I do not have to create or change any host network, which was one of the
constraints I was given.

**There are two overlapping DHCP configurations in that subnet.** `LabNet` offers
192.168.56.100 to 192.168.56.199, and a legacy VirtualBox DHCP server on `vboxnet0` offers
192.168.56.101 to 192.168.56.254. Both are enabled. They do not currently fight, because no
guest is using DHCP in that range, but I am treating 192.168.56.100 and above as unusable for
static addressing anyway. Cleanup of the stale entry is optional and I am not doing it
without approval, since it is host configuration rather than lab configuration.

Each lab VM has two network adapters:

| Adapter | Attachment | Role |
| --- | --- | --- |
| NIC1 | NAT | Outbound internet for `apt`, plus the host's SSH forward (lb01 has `127.0.0.1:2222 -> :22`) |
| NIC2 | Host-only `LabNet` | The private lab network where all load balancing traffic flows |

`nordicshop-lb01` also carries a NAT port forward: host port 2222 to guest port 22. Useful as
a fallback if the host-only addressing is ever wrong.

On macOS, VirtualBox 7.2 does not expose the host-only network as a `vboxnet` interface. It
appears as a bridge:

```
$ ifconfig -a | grep -B3 192.168.56.1
bridge100: flags=8a63<UP,BROADCAST,SMART,RUNNING,ALLMULTI,SIMPLEX,MULTICAST> mtu 1500
        inet 192.168.56.1 netmask 0xffffff00 broadcast 192.168.56.255
$ netstat -rn | grep 192.168.56
192.168.56    link#21    UC    bridge100
```

This explains why `VBoxManage list hostonlyifs` printed nothing and it is worth writing down:
the absence of a `vboxnet0` adapter is normal here, not a broken network. The host address
192.168.56.1 responds to ping, so the bridge is up and the host can reach the lab subnet.

## 9. Proposed virtual machine specification

Target: enough to run the lab, not enough to hurt the host.

| VM | Role | vCPU | RAM | Disk (dynamic VDI) | Swap |
| --- | --- | --- | --- | --- | --- |
| nordicshop-lb01 | HAProxy load balancer | 1 | 1024 MB | 20 GB | 1 GB |
| nordicshop-web01 | Nginx backend | 1 | 1024 MB | 20 GB | 1 GB |
| nordicshop-web02 | Nginx backend | 1 | 1024 MB | 20 GB | 1 GB |
| nordicshop-client01 | Test client | 1 | 1024 MB | 20 GB | 1 GB |
| **Total** | | **4 vCPU** | **4 GB** | **80 GB virtual, ~20 GB actual** | |

Reasoning per component:

- **HAProxy at 1 vCPU and 1 GB.** HAProxy is a single-process event driven proxy. A lab
  serving a handful of `curl` loops will use well under 100 MB. The existing VM has 2048 MB
  assigned, which is harmless; I would rather standardise on 1024 MB so the numbers are
  predictable and easy to explain in the write-up.
- **Nginx backends at 1 vCPU and 1 GB.** A static page plus a health endpoint is trivial. The
  disk headroom is for `apt`, logs and `tcpdump` captures.
- **Client at 1 vCPU and 1 GB.** Deliberately separate, so traffic origin is separate from
  traffic distribution and I can prove the client cannot reach a backend directly in the
  Azure design later.
- **1 GB swap per guest.** Ubuntu Server creates a swap file by default. Keeping it explicit
  means memory pressure inside a VM degrades performance rather than killing Nginx, which
  would corrupt the Incident 1 test result.

Host budget after the lab starts: about 4 GB of 32 GB RAM and 4 of 16 logical CPUs. This
leaves room for the browser, terminal and documentation, and keeps the host clear of swap.

## 10. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Host already loaded (load average ~4.9 before lab) | Medium | Slow guest responses confuse timing evidence | Re-measure load at the start of Phase 2, record it in the report |
| Memory pressure from other applications | Medium | Guests swap, Nginx appears slow, tests look flaky | Cap lab at 4 GB, keep guests at 1 GB, verify with `free -m` in guest |
| Two DHCP servers on 192.168.56.0/24 | Low | A guest picks up an unexpected lease | All lab guests get static addresses below .100; DHCP is never used |
| macOS kernel extension blocked after a VirtualBox update | Low | Guests will not boot | VirtualBox 7.2.14 already runs guests; no upgrade planned |
| Disk growth from dynamic VDI files | Low | Fills the 162 GiB free space | 20 GB cap per guest, `du -sh` check after each phase |
| Accidentally touching the other nine VMs | Low | Destroys unrelated work | Explicit naming convention, every command names a `nordicshop-*` machine |

## 11. Decisions taken in this phase

1. Use the existing `LabNet` host-only network on 192.168.56.0/24. No new network is created
   and no host network setting is changed.
2. Keep the existing four VM names. They match the company scenario and are already
   referenced in the diagram.
3. Rebuild `web01`, `web02` and `client01` from the Ubuntu 24.04.5 ISO: their disks are empty.
   Decision on rebuilding `lb01` is pending approval.
4. Standardise on 1 vCPU and 1024 MB per guest, 20 GB dynamic disks.
5. Use static addressing in the lower part of the subnet, well away from both DHCP pools.
6. Keep NIC1 on NAT for package installation and NIC2 on host-only for all lab traffic. This
   mirrors the Azure split between a management path and the application subnet.

## 12. Phase 1 progress report

Phase 1 is complete and no changes were made to the machine.

The host is an Intel i9 with 8 cores and 16 logical CPUs, 32 GiB of RAM with roughly 14 GiB
realistically available, 162 GiB of free disk and hardware virtualisation enabled.
VirtualBox 7.2.14 is installed and already runs guests. A host-only network `LabNet`
(192.168.56.0/24, host at .1) exists and is enabled, and an Ubuntu 24.04.5 server ISO is
downloaded and ready.

Four `nordicshop-*` machines exist from an earlier attempt. One is installed, three are empty
shells. Proposed sizing is 1 vCPU and 1 GB RAM each, 20 GB dynamic disks, total host cost
about 4 GB RAM and 4 vCPUs.

Next phase, after approval: create or confirm the private network wiring, install Ubuntu on
the guests, apply the static addressing plan and verify connectivity between all four hosts.
