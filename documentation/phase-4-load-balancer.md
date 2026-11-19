# Phase 4: HAProxy load balancer

**Date:** 19 November 2026
**Status:** complete and verified
**Scope:** HAProxy installation, frontend binding, backend pool, HTTP health checks,
algorithm choice, distribution evidence

## 1. Objective

Give NordicShop one stable address that distributes customer traffic across the two
web nodes, stops using a node that fails, and does so without the customer knowing
which machine answered.

## 2. What was installed

```
$ haproxy -v
HAProxy version 2.8.30-0ubuntu0.24.04.2 2026/10/27
Status: long-term supported branch

$ systemctl is-active haproxy
active
```

Listeners after deployment:

```
LISTEN 192.168.56.10:8404   users:(("haproxy",pid=3820,fd=10))
LISTEN 192.168.56.10:80     users:(("haproxy",pid=3820,fd=9))
```

Both sockets are bound to the service address, not `0.0.0.0`. The balancer is not
reachable on the NAT interface, so the lab network is the only path to it.

Note the same `policy-rc.d` behaviour seen in Phase 3: `apt-get install haproxy`
left the service enabled but inactive. The deploy script starts it explicitly, so
"installed" and "running" are never conflated.

## 3. Configuration

Committed at `configuration/haproxy/haproxy.cfg`, deployed by
`scripts/deploy-haproxy.sh`. The script validates with `haproxy -c` before it
restarts anything, and keeps a timestamped backup of the previous file:

```
--- config validation:
Configuration file is valid
```

### Structure

| Section | Purpose |
| --- | --- |
| `global` | Logging to the syslog socket, connection ceiling, admin socket at `/run/haproxy/admin.sock` |
| `defaults` | Mode, timeouts, retry behaviour shared by frontend and backend |
| `frontend nordicshop_front` | Binds 192.168.56.10:80, adds `X-Forwarded-For`, sets a marker header, sends everything to one backend |
| `backend nordicshop_web` | The two nodes, the algorithm, and the health check |
| `listen stats` | Statistics on 192.168.56.10:8404, restricted by UFW to the lab subnet |

### Timeouts, and why these numbers

```
timeout connect      3s
timeout client       30s
timeout server       30s
timeout http-request 10s
```

The backends answer in about 2 ms, so a 3 second connect timeout separates "slow"
from "broken" without waiting a minute. Phase 3 showed what the alternative looks
like: packets dropped by a firewall produce a client-side hang until the client's
own timeout. A load balancer with no connect timeout turns one broken backend into
a slow website for everyone.

`option redispatch` with `retries 2` means a request that fails mid-flight is
retried on another node rather than returned to the customer as an error.

### Frontend

```
bind 192.168.56.10:80
default_backend nordicshop_web
option forwardfor
http-response set-header X-Load-Balancer lb01
```

`option forwardfor` inserts `X-Forwarded-For` with the real client address. At
Layer 7 this is possible because HAProxy parses HTTP; at Layer 4 it cannot, which is
one of the concrete differences covered below. The marker header makes it obvious in
a response that the request passed through the balancer rather than reaching a node
directly.

## 4. Balancing algorithm

```
balance roundrobin
```

**Why roundrobin:** both nodes are identical, serve the same static content, and
answer in milliseconds. There is no long-running request that would make one node
busier than the other, and no session state that would require pinning a client to
a node. Roundrobin hands out requests in strict turn, which makes the distribution
visible and auditable in the test output: exactly 100/100 over 200 requests is
easy to check and hard to misread.

**The alternatives and when they would be right:**

| Algorithm | Behaviour | When it would be the better choice |
| --- | --- | --- |
| `roundrobin` | Strict turn among healthy servers | Identical nodes, uniform request cost (this lab) |
| `leastconn` | Next request goes to the server with fewest active connections | Requests vary a lot in duration: report generation, uploads, database-heavy pages |
| `source` | Hash of client IP pins a client to one server | Backends hold per-user state in local memory or disk, and sticky behaviour is required |
| `uri` | Hash of the URL path | Cache locality matters, for example a CDN-style tier in front of the same objects |

`source` is worth calling out as a trap in this project: with a single test client,
every request has the same source IP, so all traffic would land on one node and the
lab would look broken even though it was working as configured. That is the basis of
Incident 5.

## 5. Health checks

```
option httpchk GET /healthz
http-check expect status 200
default-server inter 2s fastinter 500ms downinter 5s fall 3 rise 2
```

- A request for `/healthz` must return **HTTP 200**. Nginx answering with a 404 or
  500 counts as a failure, which is the point: a node that serves errors is not
  healthy even though its port is open.
- Every 2 seconds while healthy; 3 consecutive failures mark a node DOWN, so
  detection takes roughly 6 seconds.
- 2 consecutive successes bring it back, roughly 4 seconds after it recovers.
- Checks are per server, independent of customer traffic, so a node is removed even
  if nobody is browsing.

Evidence that the check is really HTTP-level, read from the statistics endpoint:

```
web01  status=UP  check=L7OK   code=200  desc=Layer7 check passed
web02  status=UP  check=L7OK   code=200  desc=Layer7 check passed
```

`L7OK` with `code=200` is HAProxy reporting that it parsed an HTTP response, not
that a socket accepted a connection. A plain TCP check would report `L4OK` and would
also pass on a node whose Nginx was running but unable to serve.

## 6. Layer 4 and Layer 7 load balancing

The brief asked for this explanation, and this lab is a good place to be precise,
because the original plan said "HAProxy in TCP mode" while this implementation uses
`mode http`.

| | Layer 4 (transport) | Layer 7 (application) |
| --- | --- | --- |
| Decides based on | Source/destination IP and port, protocol | URL, headers, cookies, HTTP method |
| Can read the request | No, it forwards bytes | Yes, it parses and can rewrite |
| Client address at the backend | Lost unless PROXY protocol is used | Preserved with `X-Forwarded-For` |
| Health check | TCP connect (or a protocol-aware check) | HTTP request with an expected status |
| Cost | Very low, no parsing | Slightly higher, protocol aware |
| Typical Azure service | **Azure Load Balancer** | **Azure Application Gateway** |

**Why this lab uses `mode http`:** you asked for health checks against `/healthz`
with a 200 expectation. That check is by definition Layer 7: it requires sending an
HTTP request and parsing the response. In `mode tcp` the equivalent is
`option tcp-check`, which can only assert that the connection opened. That would
pass on a node whose Nginx workers were wedged, which is exactly the failure a load
balancer exists to survive.

**What the TCP version would look like**, and what it costs:

```haproxy
defaults
    mode tcp
backend nordicshop_web
    option tcp-check
    server web01 192.168.56.21:80 check
    server web02 192.168.56.22:80 check
```

That is closer to what Azure Load Balancer does when forwarding, but it gives up
application-level health. The honest summary: this lab is a **Layer 7 proxy in front
of a Layer 4 use case**, and the deviation is deliberate and documented rather than
accidental.

One detail that matters for the Azure comparison: Azure Load Balancer is a Layer 4
forwarder, but its **health probes can be TCP, HTTP or HTTPS**. So the probe design
here maps directly onto Azure even though the forwarding layer does not.

## 7. Distribution evidence

### 7.1 Ten requests from the customer machine

```
 1 -> web02
 2 -> web01
 3 -> web02
 4 -> web01
 5 -> web02
 6 -> web01
 7 -> web02
 8 -> web01
 9 -> web02
10 -> web01
```

### 7.2 Two hundred requests, counted

```
$ for i in $(seq 1 200); do curl ... http://192.168.56.10/ ... done | sort | uniq -c
    100 web01
    100 web02
```

Exact halves. Both nodes healthy throughout, no request failed.

### 7.3 HAProxy's own counters agree

```
nordicshop_web,web01,0,106,UP,1
nordicshop_web,web02,0,105,UP,1
nordicshop_web,BACKEND,0,211,UP,2
```

The client side and the balancer side describe the same distribution, which is the
difference between "it looked balanced" and "it was balanced".

### 7.4 Both ends of the connection

Backend access logs, last request before the run ended:

```
web01  192.168.56.10 - - [19/Nov/2026:19:50:10 +0100] "GET / HTTP/1.1" 200 1183 "-" "curl/8.5.0"
web02  192.168.56.10 - - [19/Nov/2026:19:50:10 +0100] "GET / HTTP/1.1" 200 1184 "-" "curl/8.5.0"
```

The source is the balancer, and the byte counts differ by one because the two pages
are genuinely different files.

HAProxy's request log shows the real client and the chosen server:

```
192.168.56.31:48068 ... nordicshop_front nordicshop_web/web01 0/0/0/2/2 200 1430 ... "GET / HTTP/1.1"
192.168.56.31:48070 ... nordicshop_front nordicshop_web/web02 0/0/1/1/3 200 1431 ... "GET / HTTP/1.1"
192.168.56.31:48076 ... nordicshop_front nordicshop_web/web01 0/0/0/2/2 200 1430 ... "GET / HTTP/1.1"
```

`192.168.56.31` is `client01`. The timings show the time spent waiting for the
balancer, for the connection, and for the response.

## 8. Connections and requests are not the same thing

Every test above used a **new connection per request** (a separate `curl` process),
which is why the split is perfect.

With HTTP keep-alive, one connection is pinned to one backend for its lifetime. A
browser that opens six connections to the frontend will use six backends, and then
keep reusing them, so a single user can appear to send all their traffic to one node.
Nothing is broken in that case; the unit of balancing is the connection, not the
request.

This distinction is the whole point of Incident 5, and it is also why "the load
balancer is not balancing" is usually a measurement error rather than a
configuration error. The correct check is HAProxy's session counters, not five
browser refreshes.

## 9. Azure mapping

| Local | Azure Load Balancer | Notes |
| --- | --- | --- |
| `bind 192.168.56.10:80` | Frontend IP configuration (public or internal) | Customer configures |
| `server web01 ...:80 check` | Backend pool member | Customer configures; membership can also be by NIC or IP |
| `option httpchk GET /healthz` + `expect status 200` | Health probe: protocol HTTP, path `/healthz`, expected 200 | Azure supports TCP, HTTP and HTTPS probes |
| `inter 2s fall 3 rise 2` | Probe interval and unhealthy threshold | Azure uses interval and threshold counts; the idea is identical |
| `balance roundrobin` | Distribution is a **5-tuple hash**, not roundrobin; session persistence is a separate setting | This is the biggest conceptual difference |
| `listen stats` | Azure Monitor metrics and Load Balancer insights | Microsoft runs the telemetry pipeline |
| Timeouts in `defaults` | Load balancing rule idle timeout, TCP reset on idle | Platform setting |
| Frontend is not on 0.0.0.0 | Public IP is attached to the LB resource only | Backends have no inbound internet path |

The distribution difference deserves emphasis: Azure Load Balancer does **not**
implement roundrobin. Its default is a hash of source IP, source port, destination
IP, destination port and protocol, which spreads connections statistically over many
clients but is not a strict turn. Azure also offers session persistence
(none, client IP, client IP and protocol), which has no direct HAProxy equivalent
apart from `balance source`.

## 10. Why this is still not highly available

`lb01` is now a single point of failure. Every customer request depends on one VM
whose loss stops the entire service, which is precisely the problem the architecture
was supposed to remove. Incident 4 examines this, and the fix is either two HAProxy
nodes with a floating address (keepalived and VRRP) or a managed service where the
balancer's availability is contractual.

## 11. Next steps

Phase 5, the incident simulations: backend failure, network failure, wrong health
check, load balancer failure, and uneven distribution. Each is recorded with its
own report under `troubleshooting/`.
