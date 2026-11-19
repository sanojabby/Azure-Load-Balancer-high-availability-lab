# Phase 5: mapping the lab to Azure

**Date:** 19 November 2026
**Status:** complete
**Scope:** the lab translated into Azure Load Balancer, NSG and health probe terms,
incident by incident, using measured results

## 1. Purpose and honesty statement

This document does not describe an Azure deployment. **No Azure resources were created
for this lab**, so nothing here is observed Azure behaviour. What it does contain:

- a mapping from every component and setting in the lab to its Azure counterpart;
- the five incidents, each translated into what Azure would have done, with the
  measured lab numbers kept alongside;
- an explicit list of what Azure removes and what it does not.

Where a claim depends on Azure behaviour rather than on this lab, it is about how the
service is defined to work, not a measurement I took. The measurements are all from
the four VMs, and they are the part I would defend hardest in an interview.

## 2. Component mapping

| Lab | Azure | Notes |
| --- | --- | --- |
| `lb01` running HAProxy | **Azure Load Balancer** (Layer 4) or **Application Gateway** (Layer 7) | a managed service, not a VM |
| `bind 192.168.56.10:80` | frontend IP configuration (public IP or internal) | anycast VIP, not a NIC address |
| `backend nordicshop_web` + two servers | backend pool | pool members are NIC/IP configurations |
| `option httpchk GET /healthz` | health probe (HTTP, path `/healthz`) | on Azure LB this is HTTP/HTTPS/TCP |
| `balance roundrobin` | distribution mode / 5-tuple hash | Azure LB has no roundrobin switch |
| `option redispatch`, `retries 2` | **no equivalent** | flow-based: no request-level retry |
| `stats` page on `:8404` | metrics, diagnostic logs, `az monitor` | no per-request view at Layer 4 |
| ufw rules on web01/web02 | **NSG** rules on the subnet or NIC | ordered by priority, lowest first |
| netplan static addresses | VNet/subnet, static private IPs on NICs | |
| `client01` | a client in the VNet, or on-premises via VPN/ExpressRoute | |
| keepalived + VRRP (designed, not built) | **built in**: no VIP election to run | see Incident 4 |

## 3. Configuration mapping, line by line

| `haproxy.cfg` | Azure object | Constraint in Azure |
| --- | --- | --- |
| `bind 192.168.56.10:80` | `frontendIpConfigurations`, LB rule port 80 | one VIP can front many rules/ports |
| `server web01 192.168.56.21:80` | backend pool member + LB rule `backendPort 80` | membership is a NIC IP config |
| `option httpchk GET /healthz` | `probes[].protocol=http`, `path=/healthz` | HTTP probe expects 200 within the timeout |
| `inter 2s` | `intervalInSeconds` | **minimum 5** |
| `fastinter 500ms` | none | Azure cannot shorten the interval after a failure |
| `fall 3` | `probeThreshold` | 1 to 100, default **2** |
| `rise 2` | implied by consecutive successes | not separately configurable |
| `balance roundrobin` | 5-tuple hash (default), Client IP, Client IP + protocol | no algorithm choice |
| `option forwardfor` | automatic (`X-Forwarded-For` at L7 only) | a Layer 4 LB cannot add headers |
| `timeout client/server 30s` | `idleTimeoutInMinutes` (TCP idle) | different mechanism, same intent |
| `option redispatch` | none | see Incident 1 |

Two of these gaps matter more than the rest, and both appear in the incidents: **no
`fastinter`** and **no redispatch**.

## 4. Detection speed: the expensive difference

The lab's check timing, as configured:

```
inter 2s  fastinter 500ms  downinter 5s  fall 3  rise 2
```

What that produced, measured:

| Incident | Failure mode | Measured detection |
| --- | --- | --- |
| 1 | backend process stopped | **~1.5 s** (19:54:06.0 → 19:54:07.40) |
| 2 | packets dropped by firewall | **~9.3 s** (19:59:13.0 → 19:59:22.33) |
| 3 | wrong probe port | **~2.4 s** after reload (20:07:43.918 → 20:07:46.271) |

Azure's floors, applied to the same three failures:

| Azure setting | Time to mark unhealthy | Against the lab |
| --- | --- | --- |
| interval 5 s, threshold 2 | ~10 s | slower than Incident 1 by ~6.5× |
| interval 15 s, threshold 2 (defaults) | ~30 s | slower than everything measured here |

So the honest comparison is not "Azure detects faster". **The lab detects faster than
Azure can be configured to**, because HAProxy can drop to a 500 ms interval during a
transition and Azure's minimum is 5 seconds. For a dropped-packet failure (Incident 2)
the two are comparable, because in the lab each check already cost its full 2 s
timeout; for a fast failure (Incident 1) the lab wins by a wide margin.

This is a real design decision, not trivia: the probe interval is the floor on your
mean-time-to-detect, and on a busy site 10 seconds of sending traffic to a dead node is
a measurable number of failed requests.

## 5. The five incidents in Azure terms

### Incident 1: backend process stopped

**Measured in the lab:** Nginx stopped on web01; HAProxy logged
`reason: Layer4 connection problem, info: "Connection refused", check duration: 0ms`,
marked the node DOWN in ~1.5 s, and the client sent **120 requests with 120 × 200**
responses — 98 to web02, 22 to web01 — because `option redispatch` retried the
in-flight requests on the surviving node.

**In Azure:** the probe fails, the instance is removed from the pool, and new flows go
to web02. But **flows already established to web01 keep going to web01**, because
Azure Load Balancer is flow-based and does not retry requests. Azure's Layer 4 data
plane cannot see a request, only packets in a flow.

**What that changes:** the lab's zero-error result is a Layer 7 feature
(`redispatch`), not a property of load balancing. Ported to Azure LB, Incident 1
produces client-visible errors for every request in flight at the moment the node
died — resets or timeouts depending on how the process exited. With an Application
Gateway, request-level retry exists (`retry` policy), which is closer to what HAProxy
did here.

**Azure fix / mitigation:** a second backend so the pool is never empty, and short
keep-alive/idle timeouts so fewer flows are in flight. That is all.

### Incident 2: network path blocked

**Measured in the lab:** ufw deny on web01 for port 80 from lb01; probe failed with
`Layer4 timeout, check duration: 2000ms`; detection **~9.3 s**; the client saw **3 of
80 requests fail** (`000`), because dropped packets hang until the client's own timeout
and redispatch cannot help once the client has given up.

**In Azure:** exactly the same class of failure, and Azure names the mechanism. An NSG
rule with a lower priority number than the allow rule drops the probe traffic. The
usual production version of this incident is not a deliberate deny but an NSG applied
at the subnet level that overrides the one on the NIC — which is why the portal shows
**effective security rules** per NIC.

The most common Azure-specific cause is the probe source: probes originate from the
platform address `168.63.129.16`. The default NSG rule `AllowAzureLoadBalancerInBound`
(source service tag `AzureLoadBalancer`) permits it. Add a broad custom deny with a
lower priority number and probes stop, the instance leaves the pool, and the
application is fine the whole time. That is Incident 3's shape with Incident 2's
fingerprint.

**Azure fix:** allow `AzureLoadBalancer` (or the platform IP) above any custom deny,
and read effective security rules rather than the rules you think you applied.

### Incident 3: wrong health-check port

**Measured in the lab:** `check port 8080` on a healthy backend; `haproxy -c` passed;
the node went DOWN in **~2.4 s** with `L4TOUT`, while web01 answered 200 on port 80 the
whole time; 60 client samples showed zero errors because the node left the pool.

**In Azure:** the identical failure with the identical trap. Azure probes have their
own `port` field, which is allowed to differ from the traffic port — that is a
deliberate feature (probe on a management port) and therefore an easy one to ship
wrong. Set it to a port nothing listens on and the instance is removed while perfectly
healthy. Nothing in the portal validates that the port answers.

Also in this incident: the lab's check timed out rather than being refused, because
ufw drops unmatched ports. Azure behaves the same way for a port closed by NSG:
silent drop, probe timeout, no refusal.

**Azure fix:** confirm the probe port with a request, not with a configuration review.
`Test-NetConnection`/`curl` from another host in the VNet to the exact port and path.

### Incident 4: the balancer itself failed

**Measured in the lab:** `systemctl stop haproxy` on lb01 produced a **total outage**:
33 of 33 sampled requests failed with exit 7 (connection refused), from 20:13:04 to
20:13:37 (~34 s), while both backends answered 200 throughout.

**In Azure:** this failure mode does not exist. There is no load balancer VM to stop,
no process to crash, no single host holding the VIP. A Standard SKU public frontend can
be zone-redundant across availability zones, and the SLA is 99.99%. The keepalived +
VRRP design that would fix this on-premises is replaced by the platform.

**What Azure does not fix, and the lab proves it:** the backend pool is still yours.
A pool with one VM is still a single point of failure; a single-region deployment is
still single-region; a single Application Gateway v2 sits at its configured minimum
instance count. Incident 4's real lesson — *the weakest single instance sets the
ceiling* — moves to a different component rather than disappearing.

### Incident 5: uneven distribution

**Measured in the lab:** with a Layer 4 frontend, 10 requests over one keep-alive
connection went **10/10 to web01**; counters read `web01 sessions=1`, `web02
sessions=0`, and `req_tot` was blank. With `balance source`, three clients split
**16 vs 10 sessions** because two of the three hashed to the same node. With HTTP mode
and `roundrobin`, the same traffic balanced 5/5, because each request opened its own
backend connection.

**In Azure:** Azure Load Balancer is Layer 4, so the first behaviour is the default
one. Distribution is a 5-tuple hash (source IP, source port, destination IP,
destination port, protocol): a client opening many connections spreads across
backends, while a client reusing one connection stays on one backend. Session
persistence settings are the same trade as `balance source`:

| Azure LB persistence | Lab equivalent | Consequence |
| --- | --- | --- |
| None (5-tuple) | `mode tcp` + `roundrobin` | good spread across connections, no per-request fairness |
| Client IP | `balance source` | every flow from an address to one backend; NAT collapses users |
| Client IP + protocol | `balance source` keyed further | same, split by protocol |

And the metrics point from Incident 5 carries over directly: **an Azure Load Balancer
reports flows, packets and bytes, not HTTP requests.** If you need per-request
distribution and per-request metrics, that is Application Gateway or Front Door, with
cookie-based affinity (`ApplicationGatewayAffinity`) available when the requirement is
really "same user, same node".

## 6. What Azure removes

Tied to what this lab actually measured:

1. **The balancer as a single point of failure** (Incident 4). No VM, no process, no
   VIP election, no keepalived to build and test, 99.99% SLA on Standard SKU.
2. **VIP failover engineering.** Thirty-four seconds of total outage in the lab becomes
   a non-event; there is nothing to fail over.
3. **Patching and hardening a balancer OS.** No HAProxy upgrades, no ufw on the
   balancer, no `policy-rc.d` surprises.
4. **Probe state persistence across reloads.** The lab's reload reset server state and
   produced no `is UP` log line; a managed probe has no reload.
5. **Capacity planning for the balancer host.** `maxconn 2048` on lb01 is a real
   ceiling; the managed service scales without a config edit.

## 7. What Azure does not remove

This is the part worth saying out loud in an interview, because it is where the lab
earns its keep:

1. **Probe misconfiguration** (Incident 3). Wrong port, wrong path, wrong protocol:
   Azure cannot tell that your application is fine and the probe is wrong. `haproxy -c`
   and the Azure portal both accept the mistake.
2. **NSG ordering mistakes** (Incident 2). Priority-based first match, silent drops,
   and rules that override each other across subnet and NIC. Same incident, new name.
3. **Backend single points of failure** (Incidents 1 and 4). A one-VM pool is not highly
   available because the front door is.
4. **Request-level retry** (Incident 1). Azure LB cannot redispatch a request; the lab's
   120/120 with zero errors was a Layer 7 feature.
5. **Detection speed** (section 4). Azure's probe floor is slower than a tuned HAProxy
   for fast failures. 10 s versus 1.5 s is a real difference in failed requests.
6. **Traffic imbalance** (Incident 5). 5-tuple hashing and Client IP persistence are the
   same trade-offs as `balance tcp` and `balance source`. Azure's metrics will not tell
   you the request counts at Layer 4.
7. **Anything global.** Cross-region load balancing, DNS-based failover and multi-region
   data are separate services (cross-region LB, Traffic Manager, Front Door) and separate
   design work.

## 8. Migration sketch (not executed)

Illustrative only. This was not run, there is no subscription behind it, and the names
are placeholders.

```bash
# network and firewall: the lab's ufw rules become NSG rules
az network nsg rule create -g nordicshop-rg --nsg-name web-nsg \
  --name allow-lb-probe --priority 100 --access Allow --protocol Tcp \
  --destination-port-ranges 80 --source-address-prefixes AzureLoadBalancer

# frontend, pool, probe, rule
az network public-ip create -g nordicshop-rg -n lb-pip --sku Standard --zone 1 2 3
az network lb create -g nordicshop-rg -n nordicshop-lb --sku Standard \
  --public-ip-address lb-pip --frontend-ip-name fe --backend-pool-name webpool
az network lb probe create -g nordicshop-rg --lb-name nordicshop-lb -n http-healthz \
  --protocol Http --port 80 --path /healthz --interval 5 --threshold 2
az network lb rule create -g nordicshop-rg --lb-name nordicshop-lb -n http-80 \
  --protocol Tcp --frontend-port 80 --backend-port 80 \
  --probe-name http-healthz --idle-timeout 4
```

Every value in those commands is a decision this lab already made and measured: the
probe path is `/healthz` because Phase 3 built it, port 80 because the site is plain
HTTP, threshold 2 because 3 was too slow on a 5-second floor.

## 9. Cost and scope note

No Azure resources were created, so this lab cost nothing beyond the laptop. For
anyone porting it:

- **Standard Load Balancer** is billed per hour for the resource, per rule, and per GB
  processed; a public IP has its own hourly charge.
- **Application Gateway v2** is billed per capacity unit hour plus data processed, and
  is materially more expensive than an LB — the right choice only when you need Layer 7
  features (path routing, TLS termination, cookie affinity, retries, WAF).
- Probe interval does not affect price; choosing 5 s over 15 s costs nothing but is the
  difference between 10 s and 30 s of failed traffic.

Check the current pricing page before quoting figures; they change and this document
deliberately contains none.

## 10. Summary

The lab and Azure solve the same three problems — **stay reachable, detect failure,
share load** — with different ownership boundaries:

| Problem | Lab answer | Azure answer | Ownership |
| --- | --- | --- | --- |
| Stay reachable | keepalived + VRRP with a VIP (designed) | managed, zone-redundant frontend | Azure owns it |
| Detect failure | `inter/fastinter/fall` tuning | probe interval + threshold | you own the config |
| Share load | `balance roundrobin` / `source` | 5-tuple hash / Client IP | you own the choice |
| Protect the backends | ufw rules | NSG rules (priority order) | you own it |

Everything the managed service takes over is the part this lab had to build and could
not fully test: the VIP election in Incident 4. Everything the managed service leaves
alone is the part the lab could measure precisely: probe design, firewall ordering,
pool size, and the balancing key. That split is the transferable lesson, and it is the
one thing I would want an interviewer to take from this project.
