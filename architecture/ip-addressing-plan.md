# IP addressing plan

**Project:** NordicShop highly available load balancing lab
**Network:** VirtualBox host-only network `LabNet`
**Subnet:** 192.168.56.0/24
**Status:** proposed, pending approval before any guest is configured

## 1. Why this subnet

The host already has `LabNet` defined as 192.168.56.0/24 with the Mac at 192.168.56.1, and
all four lab VMs already have a second adapter attached to it. Reusing it means no new host
network and no change to existing host configuration.

192.168.56.0/24 is also the VirtualBox default for host-only networking, so anyone cloning
this repository and letting VirtualBox pick the default gets the same addressing with no
edits. That matters for a portfolio project: the plan should work on someone else's laptop.

The alternative, a 10.10.10.0/24 network, is cleaner in a real enterprise but would mean
creating a host network and editing every VM. Not worth it here.

## 2. Address allocation

| Host | Role | NIC1 (NAT) | NIC2 (host-only, static) | Notes |
| --- | --- | --- | --- | --- |
| Host Mac | Management and testing | n/a | 192.168.56.1 | VirtualBox `LabNet` adapter, fixed by VirtualBox |
| nordicshop-lb01 | HAProxy load balancer | DHCP 10.0.2.15 | **192.168.56.10** | Virtual IP of the service from the client's point of view |
| nordicshop-web01 | Nginx backend 1 | DHCP 10.0.2.15 | **192.168.56.21** | |
| nordicshop-web02 | Nginx backend 2 | DHCP 10.0.2.15 | **192.168.56.22** | |
| nordicshop-client01 | Test client | DHCP 10.0.2.15 | **192.168.56.31** | Simulates a customer |

Reserved and deliberately unused:

| Range | Owner | Why we stay out of it |
| --- | --- | --- |
| 192.168.56.1 | VirtualBox host adapter | Assigned by VirtualBox |
| 192.168.56.100 | Legacy DHCP server on `vboxnet0` | Leftover host configuration |
| 192.168.56.100 - .199 | `LabNet` DHCP pool | Enabled on the host |
| 192.168.56.101 - .254 | Legacy `vboxnet0` DHCP pool | Enabled on the host |

The two DHCP pools overlap in this subnet. Since every lab guest is configured statically
below .100 and DHCP is never relied on for the host-only adapter, the overlap has no effect on
the lab. It is recorded here because a future reader will see it in
`VBoxManage list dhcpservers` and wonder.

Address numbering is grouped by role so the diagram stays readable: .10 for the distribution
layer, .21 and .22 for the web tier, .31 for clients. Thirty-one is also inside the range a
`/27` would cover, which is roughly the smallest practical subnet for a tier like this, and
that is a useful thing to remember for AZ-700 subnet sizing questions.

## 3. Interface roles

Each guest has two interfaces on purpose:

| Interface | Purpose | Address | Analogy in Azure |
| --- | --- | --- | --- |
| NIC1 (NAT) | Package installation, updates | 10.0.2.15/24, gateway 10.0.2.2, DNS 10.0.2.3 | Not required. Azure VMs reach the internet through the platform, management access comes from Bastion or a jump host |
| NIC2 (host-only) | All lab traffic: HTTP, health checks, SSH from host | 192.168.56.0/24, no gateway | The VNet subnet with the VM's private IP |

Assigning a default gateway only to the NAT interface matters. If both interfaces claim a
default route, replies can leave through the wrong one and the lab produces confusing
asymmetric routing symptoms that have nothing to do with load balancing.

## 4. Ubuntu 24.04 netplan configuration

Ubuntu Server 24.04 uses netplan with systemd-networkd as the renderer. The NIC names on
VirtualBox guests are normally `enp0s3` (NIC1) and `enp0s8` (NIC2); Phase 2 confirms this with
`ip -br link` before the file is written, because guessing the name is a classic time waster.

Proposed file for `nordicshop-lb01` at `/etc/netplan/50-lab-static.yaml`:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s3:
      dhcp4: true
    enp0s8:
      dhcp4: false
      addresses:
        - 192.168.56.10/24
      # deliberately no default route on the lab interface
```

Applied with `sudo netplan try` first, so a mistake rolls back automatically after 120 seconds
instead of locking me out of the machine.

Same pattern for the others with .21, .22 and .31. In the repository these become three small
templates under `/configuration` with the address as the only difference.

## 5. Service ports

| Port | Protocol | Where | Purpose |
| --- | --- | --- | --- |
| 22 | TCP | All guests | SSH administration from the host over the host-only network |
| 80 | TCP | lb01 | HAProxy frontend, the address customers use |
| 80 | TCP | web01, web02 | Nginx, and the port HAProxy health checks |
| 8404 | TCP | lb01, optional | HAProxy statistics page, bound to the host-only network only |
| ICMP echo | ICMP | All guests | Connectivity testing with `ping` |

No port 80 rule is opened on the backends to the NAT interface. Customers reach the
application through the load balancer, not by addressing a backend directly. UFW on web01 and
web02 will allow 80 only from 192.168.56.10, which is the same idea as an Azure NSG rule with
`source = load balancer subnet, destination port = 80`.

## 6. Name resolution

No DNS server is deployed. The lab uses `/etc/hosts` entries on each guest:

```
192.168.56.10   lb01.nordicshop.lab   lb01
192.168.56.21   web01.nordicshop.lab  web01
192.168.56.22   web02.nordicshop.lab  web02
192.168.56.31   client01.nordicshop.lab client01
```

`nordicshop.lab` is an invented domain. Using a real domain would be the kind of detail that
looks careless in a portfolio repository, and `.lab` or `.test` avoids any chance of
resolving to something real. In Azure this becomes an Azure Private DNS zone, or simply the
platform's internal name resolution on the VNet.

## 7. Azure mapping for the addressing design

| Local | Azure | Who configures it |
| --- | --- | --- |
| `LabNet` 192.168.56.0/24 | VNet address space plus one subnet, for example 10.20.0.0/16 with 10.20.1.0/24 for backends and 10.20.2.0/24 for the load balancer | Customer |
| 192.168.56.10 on lb01 | Frontend IP configuration of a public or internal Standard Load Balancer | Customer |
| 192.168.56.21, .22 on the backends | Private IPs on backend NICs, members of a backend pool | Customer |
| No default route on the lab NIC | Azure supplies the subnet gateway; no manual route needed | Microsoft (platform), customer sets route tables if required |
| `/etc/hosts` | Azure Private DNS zone, or default VNet name resolution | Customer |

One design note carried into the Azure phase: the lab subnet must not overlap the Azure VNet
range if the two ever connect over a VPN or ExpressRoute. Choosing 192.168.56.0/24 locally and
10.20.0.0/16 in Azure keeps that door open, and that is exactly the kind of overlap that
blocks a hybrid design in real projects.

## 8. Verification plan for Phase 2

After addressing is applied, the following checks prove the network before any application
is installed:

```bash
ip -br addr                 # both interfaces up with the expected addresses
ip route                    # only 10.0.2.0/24 via 10.0.2.2, no default on the lab NIC
ping -c3 192.168.56.1       # host reachable
ping -c3 192.168.56.10      # from each guest, load balancer reachable
ss -ltnp                    # nothing listening yet, this is the baseline
```

Expected results and the actual output from the lab are recorded in
`documentation/phase-2-network.md` once complete.
