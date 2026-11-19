# Incident report 4: load balancer failure (single point of failure)

**Date:** 19 November 2026
**System:** NordicShop lab, HAProxy 2.8 on lb01 fronting web01 and web02
**Severity:** total outage. 33 of 33 sampled requests failed
**Status:** resolved (service restarted), verified

## 1. Scenario

The load balancer itself is stopped. Not a backend, not a network path, not a check
configuration: the component that was supposed to provide availability.

Both backends keep serving throughout. That is the point of the incident. Every piece
of the redundant design worked exactly as intended, and the site was still completely
unavailable, because the one component with no redundancy sat in front of all of it.

I stopped the `haproxy` service rather than powering off the VM. Powering off is a
different failure (it also removes SSH, the stats page and the management plane) but
the client-visible symptom is identical, and stopping the service kept the host
reachable so the backends could be inspected and proven healthy during the outage.

## 2. Business impact

| | Incident 1 | Incident 2 | Incident 3 | Incident 4 |
| --- | --- | --- | --- | --- |
| Customer errors | 0 of 120 | 3 of 80 | 0 of 60 | **33 of 33** |
| Availability during fault | 100% | ~96% | 100% | **0%** |
| Capacity | halved | halved | halved | **none** |
| Fault was | a backend | a path | a check | **the front door** |

Three incidents reduced capacity and were survivable. This one stops the business.
Thirty-three consecutive failed requests over thirty-four seconds, every one refused,
and nothing on the backend side that could have compensated.

The pattern worth internalising: the failures that hurt are not the ones with the
most alarming logs, they are the ones on the only path.

## 3. Symptoms

- Every request to the frontend fails instantly: `000`, curl exit 7 (connection
  refused).
- No listener on 192.168.56.10, port 80 or 8404.
- `systemctl is-active haproxy` reports `inactive`.
- Both backends report `nginx=active` and return 200.
- `lb01` itself is reachable over SSH, with a load average of 0.00: the machine is
  fine, its service is not running.

## 4. Reproduction

```bash
systemctl stop haproxy
```

```
haproxy=inactive
--- listeners on 192.168.56.10:
none
--- last journal lines:
2026-11-19T20:13:04+01:00 lb01 systemd[1]: Stopped haproxy.service - HAProxy Load Balancer.
2026-11-19T20:13:04+01:00 lb01 systemd[1]: haproxy.service: Consumed 4.069s CPU time, ...
```

That is the entire change. One command, no configuration, no failing check, nothing
to diagnose.

## 5. Initial investigation

### 5.1 The client's view

```
20:13:03.438 code=200 curl_exit=0     <- last successful request
20:13:03.956 code=200 curl_exit=0
20:13:04.475 code=000 curl_exit=7     <- refused from here on
20:13:04.988 code=000 curl_exit=7
```

Across the whole run: **7 × 200, then 33 × `000` with exit 7**. Zero successes during
the outage.

Two things in that output matter for the diagnosis:

- **`000` with exit 7 is a refusal, not a timeout.** Something answered on the
  client's behalf with a reset. The client's path to the frontend IP was intact; the
  service behind that IP was not there.
- **The failures started within 0.5 s of the stop.** There is no detection window to
  speak of. A frontend failure is immediate, because there is no alternate to fail
  over to.

### 5.2 The load balancer's own view

```
ssh to lb01: reachable
load average: 0.00, 0.02, 0.00
haproxy=inactive
```

The host was healthy the entire time. This is what separates "the machine is down"
from "the service is down" in the first ten seconds of an incident, and it changes the
response: no reboot, no console access, no hypervisor work.

### 5.3 The backends during the outage

```
lb01 -> web01:80 : 200
lb01 -> web02:80 : 200
web01 local      : 200
web02 local      : 200
web01 nginx=active
web02 nginx=active
```

Both backends were serving correctly for the entire outage. Two healthy web servers,
an idle load balancer, and a site that is down.

### 5.4 A detail that became important later

```
client01 -> web01:80 direct : 000
client01 -> web02:80 direct : 000
```

The client cannot reach the backends directly. That is deliberate: the Phase 3
firewall allows port 80 on each backend only from `192.168.56.10`. Good security
practice, and it means there is no accidental bypass path when the balancer dies. The
frontend IP is the only way in, so its failure is total by construction.

This also has a consequence for the fix, covered in section 9.

## 6. Root cause

A single load balancer in front of a redundant backend pool. One destination IP, one
process, one host.

The architecture has two layers of availability thinking and one gap:

```
   client01
      |
      v
  [ 192.168.56.10 ]   <- one IP, one HAProxy, one VM: no redundancy
      |
   +--+--+
   |     |
 web01  web02         <- redundant, health-checked, proven by incidents 1-3
```

The backends were made redundant and the redundancy was proven three times in a row.
The frontend was never made redundant, and nothing in the previous three incidents
tested it — each of those incidents had the balancer as the observer, quietly doing
its job.

Health checks protect the layer *below* the balancer. Nothing in this design protects
the balancer itself, and the client has no second address to try.

## 7. Commands used

```bash
# break it
systemctl stop haproxy

# the two views
curl -s -m2 -o /dev/null -w '%{http_code}\n' http://192.168.56.10/    # client01: 000, exit 7
curl -s -m3 -o /dev/null -w '%{http_code}\n' http://192.168.56.21/    # from lb01: 200
systemctl is-active haproxy
ss -ltn | grep 192.168.56.10
journalctl -u haproxy -n 2 --no-pager

# restore
systemctl start haproxy
```

## 8. Findings and evidence

| Question | Answer | Evidence |
| --- | --- | --- |
| Did the client lose everything? | Yes | 33 × `000`, exit 7, zero successes |
| Was it a timeout or a refusal? | Refusal | exit 7, instant, not exit 28 |
| Was the host down? | No | SSH worked, load 0.00, `inactive` not `failed` |
| Were the backends affected? | No | 200 from lb01 and locally throughout |
| Was there a bypass path? | No | ufw permits 80 only from 192.168.56.10 |
| How long was the outage? | ~34 s | last 200 at 20:13:03.956, restart at 20:13:37 |

## 9. Resolution and the actual fix

The immediate action was one command:

```bash
systemctl start haproxy
```

That restores service in seconds **if you are there**. It is not a fix, it is a
recovery. The fix is one of the two designs below.

### 9.1 The on-premises fix: keepalived and VRRP

Two load balancers, one shared virtual IP, and a protocol between them to decide who
holds it. VRRP (RFC 5798) does the election; keepalived implements it on Linux and
runs the health script that decides whether the local node deserves to keep the VIP.

The shape of the configuration, on both nodes (`lb01` primary, `lb02` standby):

```conf
vrrp_script chk_haproxy {
    script "/usr/bin/systemctl is-active --quiet haproxy"
    interval 2
    fall 3
    rise 2
    weight -20          # drop priority enough to lose the election
}

vrrp_instance NORDICSHOP_VIP {
    state MASTER                 # BACKUP on the standby
    interface enp0s8
    virtual_router_id 51         # must match on both nodes
    priority 150                 # 100 on the standby
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass <shared secret, not in git>
    }
    virtual_ipaddress {
        192.168.56.100/24
    }
    track_script {
        chk_haproxy
    }
}
```

How it behaves:

- Both nodes run HAProxy and both are configured for the same backend pool.
- The VIP lives on one node at a time. Clients only ever use the VIP.
- The nodes exchange adverts every second. If the master's adverts stop for three
  intervals, the standby takes the VIP: failover in roughly 3 seconds.
- `track_script` means a *running but broken* HAProxy also gives up the VIP, not just
  a dead host. Without it, keepalived would happily keep the VIP on a node whose
  HAProxy had stopped, which is this incident with extra steps.

**This is a documented design, not something I built in this lab.** The lab's scope
was to demonstrate the failure; a four-VM lab with one client cannot honestly show a
VIP election it did not run. What I can state from this lab is the requirement it has
to satisfy: the client must reach a VIP that the balancer does not own.

And one consequence the lab *does* prove. The backend firewall currently permits port
80 from `192.168.56.10` only. Under VRRP the VIP is `192.168.56.100`, and a failover
to a second node would arrive from a different source address — so a naive keepalived
setup on top of this firewall would "fail over" into a pool where both backends
silently drop the traffic. If the VIP is added here, the backend rule must allow the
VIP or the balancer subnet, not one hard-coded host. That is the kind of detail that
turns a paper HA design into a real one.

### 9.2 The cloud fix: use a managed load balancer

In Azure this entire failure mode is designed out, because the load balancer is not a
VM you can stop. The frontend is an anycast VIP served by the platform, the service is
zone-redundant, and there is no single host holding it.

| This lab | Azure Load Balancer |
| --- | --- |
| HAProxy process on lb01 | managed service, nothing to `systemctl stop` |
| 192.168.56.10 on one NIC | frontend IP configuration, anycast, zone-redundant (Standard SKU) |
| one VM = one point of failure | SLA 99.99% on Standard LB (Basic has no SLA) |
| keepalived + VRRP | not needed: the platform owns the VIP |
| `fall 3` / `rise 2` | `probeThreshold`, `intervalInSeconds` |
| manual restart after outage | platform-level, no customer action |

What the managed service does *not* fix is everything around it. This lab's own
lessons still apply:

- A single backend VM in the pool is still a single point of failure. Redundancy has
  to exist on both sides of the balancer.
- A single-region deployment is still single-region. Cross-region load balancing, or
  Traffic Manager / Front Door in front, is the multi-region answer.
- A single Application Gateway instance is still one instance; the v2 SKU is
  autoscaling but starts from a configured minimum.
- The VIP moving is not the same as the DNS name moving. Clients resolve a name to the
  VIP, and TTL matters when the VIP changes.

The honest summary for an interview: **Azure Load Balancer removes the failure I just
created, and removes none of the failures in incidents 1 to 3.** Those were all about
what sits behind the front door.

## 10. Verification

```
systemctl start haproxy
haproxy=active
LISTEN 192.168.56.10:80
LISTEN 192.168.56.10:8404
```

Pool state and distribution after restart:

```
     5 web01
     5 web02
  web01  UP  check=L7OK  code=200  sessions=5
  web02  UP  check=L7OK  code=200  sessions=5
  pool   UP  total_sessions=10
```

Both backends were re-checked and returned to `L7OK 200` within a second of the
service starting, because they had been healthy the whole time. No backend restart, no
config change, no cache warm-up: the frontend came back and the pool was already good.

Client requests through the frontend after recovery: 200, distributed across both
nodes.

## 11. Lessons learned

1. **Redundancy has to reach the edge.** Two backends behind one balancer is 50%
   availability, not 100%. The layer with one instance decides the outcome.
2. **A frontend failure has no detection window.** Incidents 1 to 3 had 1.5 to 9
   seconds of graceful degradation. This one had none, because there was nothing to
   fail over to. Detection speed is irrelevant when there is no alternate.
3. **"The host is up" and "the service is up" are different facts.** SSH answered and
   the load average was 0.00 while the site was fully down. Check the service, then
   the host.
4. **Refused versus timed out tells you which layer died.** Exit 7 here, against exit
   28 in incident 2, against exit 0 with a `DOWN` server in incidents 1 and 3. The
   client's error code is a diagnostic tool, not just a failure message.
5. **Blocking direct backend access is right, and it also removes your fallback.**
   During other incidents, a manual `curl` to a backend was possible from the
   balancer's host. When the balancer is gone, nobody has a path.
6. **Restarting is recovery, not repair.** `systemctl start` ended this outage in
   seconds only because a human was watching. The repair is a second frontend with a
   VIP, or a managed balancer that does not need one.

## 12. Azure mapping summary

| Concept | Lab | Azure |
| --- | --- | --- |
| Frontend failure | HAProxy stopped on lb01 | not possible on a managed LB: no host to stop |
| Single point of failure | one VM, one IP | zone-redundant Standard LB frontend |
| VIP failover | keepalived / VRRP (designed, not built here) | platform-managed, no customer configuration |
| Probe-driven removal | `fall 3`, `fastinter` | `probeThreshold`, `intervalInSeconds` |
| Backend redundancy | web01 + web02 | two VMs, or a VMSS, in the backend pool |
| Multi-region | not covered in this lab | cross-region LB, Traffic Manager, Front Door |
| Client bypass path | blocked by ufw by design | NSG on backend subnet, same trade-off |

The AZ-700 point to carry: **availability is a property of the whole path, and the
weakest single instance sets the ceiling.** Azure gives you a highly available front
door as a default; it does not give you a highly available design. That part is still
the architect's job, and this lab now has four incidents showing where it can go wrong.
