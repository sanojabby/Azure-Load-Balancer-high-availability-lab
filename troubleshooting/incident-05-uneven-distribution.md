# Incident report 5: uneven traffic distribution

**Date:** 19 November 2026
**System:** NordicShop lab, HAProxy 2.8 on lb01 fronting web01 and web02
**Severity:** no errors, no outage. Silent capacity imbalance
**Status:** resolved (config restored to roundrobin), verified

## 1. Scenario

Every previous incident broke something visibly. This one breaks nothing. Requests
succeed, both nodes are healthy, response times look fine, and the traffic is simply
in the wrong place: one node carries most of the load while the other idles.

The usual cause is a mismatch between what the balancer balances on and what the
application actually does. A load balancer that assigns **connections** is easily
fooled by HTTP keep-alive, because one connection can carry thousands of requests. A
balancer that hashes on **source IP** is easily fooled by NAT, because hundreds of
clients can share one address.

This incident turned into something more interesting than expected, because the first
attempt to reproduce it **failed**, and the reason why is the most valuable finding in
the report.

## 2. Business impact

| | Incident 1 | Incident 2 | Incident 3 | Incident 4 | Incident 5 |
| --- | --- | --- | --- | --- | --- |
| Errors | 0 | 3 | 0 | 33 | **0** |
| Visible to customers | no | yes | no | yes | **no** |
| Measured imbalance | none | none | none | n/a | **16 vs 10 sessions** |

Nothing is down, so nothing is reported. The cost is a node running hot: it reaches
its CPU, connection or memory ceiling earlier than the design intended, and the
capacity that was supposed to absorb a failure is not actually being used. When the
busy node fails, the idle one takes over cleanly, which hides the problem even
further: the architecture appears to work because it was never asked to work at the
load it was designed for.

The commercial risk is a quiet one: you paid for two nodes and are effectively running
on one and a half.

## 3. Symptoms

- Distribution is not proportional to capacity, with no errors anywhere.
- HAProxy's per-server counters do not match the traffic you believe you are sending.
- In Layer 4 mode, `req_tot` is blank: the balancer has no idea how many requests a
  connection carried.
- Two clients out of three can land on the same node while the third sits alone.

## 4. Reproduction

### 4.1 Baseline: the lab does not suffer from this (measured, not assumed)

The lab runs `mode http` with `balance roundrobin`. Ten requests issued through a
single keep-alive connection:

```
client connections: 1
reuses:             9
nodes:              5 web01   5 web02
```

One connection, ten requests, perfectly even. The counters explain why:

```
before:  web01 sessions=31 requests=31    web02 sessions=31 requests=31
after:   web01 sessions=36 requests=36    web02 sessions=36 requests=36
```

Each of the ten requests created a **new backend connection**, five to each node.
`roundrobin` is a static algorithm: HAProxy chooses the next server first, and only
then looks for a reusable connection *to that server*. Choosing the next server means
alternating, so there is never an idle connection to the chosen one, so every request
gets a fresh connection and gets balanced individually.

I also tested the obvious suspect, `http-reuse always`, which tells HAProxy to reuse
idle server connections aggressively:

```
client connections: 1
reuses:             9
nodes:              5 web01   5 web02
```

Still even. `http-reuse` controls whether an existing connection *may* be reused; it
does not change which server is selected. Per-request balancing survived it.

**This is the documented deviation from the original brief paying off.** The brief
called for `mode tcp`; I chose `mode http` so the health check could request
`/healthz`. That choice is precisely what prevents keep-alive from pinning clients
here. The trade-off was written up in Phase 4 as a health-check benefit. It turns out
it is also a distribution benefit, and I did not know that when I made the choice.

### 4.2 Reproducing the real thing: a Layer 4 balancer

At Layer 4 there are no requests, only connections, so a connection is pinned to a
server for its whole life. A temporary second frontend reproduces the brief's
original design without touching the production one:

```conf
frontend nordicshop_tcp_demo
    mode tcp
    bind 192.168.56.10:8081
    default_backend nordicshop_web_tcp

backend nordicshop_web_tcp
    mode tcp
    balance roundrobin
    server web01 192.168.56.21:80 check
    server web02 192.168.56.22:80 check
```

Ten requests over one keep-alive connection:

```
client connections: 1
reuses:             9
responses:          10
nodes:              10 web01
```

**All ten requests on one node.** And the counters:

```
web01  status=UP  check=L4OK  sessions=1  requests=
web02  status=UP  check=L4OK  sessions=0  requests=
```

One session on web01, zero on web02, and `requests` is **blank** because a Layer 4
proxy cannot count HTTP requests. Ten requests look like one unit of load.

A firewall detail cost me twenty minutes here and is worth recording: the first
attempt hung. `lb01`'s ufw allows 22, 80 and 8404 only, so the SYN to 8081 was
dropped, `curl` waited out its timeout, and the frontend counters stayed at
`sessions=0` while the client saw `000`. A listener existed, nothing had accepted a
connection, and the frontend's own counters were the evidence.

### 4.3 `balance source`: stickiness by client address

Restoring the HTTP frontend and switching only the algorithm:

```conf
balance                 source
```

Three clients, ten sequential connections each (every one a separate connection, so
this is not keep-alive):

| Client | Address | Result |
| --- | --- | --- |
| client01 | 192.168.56.31 | **10 × web02** |
| lb01 | 192.168.56.10 | **10 × web01** |
| host mac | 192.168.56.1 | **6 × web02** |

```
web01  sessions=10  requests=10
web02  sessions=16  requests=16
```

Two of the three clients hashed to the same node. **16 versus 10 sessions from three
clients**, a 62/38 split with no error anywhere and no way for a request-level test to
notice it.

## 5. Why connection counts and request counts disagree

The three measurements, side by side:

| Mode | Client connections | Requests | web01 | web02 | What HAProxy counts |
| --- | --- | --- | --- | --- | --- |
| HTTP + roundrobin | 1 | 10 | 5 | 5 | 10 requests = 10 server connections |
| TCP + roundrobin | 1 | 10 | **10** | 0 | **1 session**, requests unknown |
| HTTP + source | 10 (3 clients) | 26 | 10 | 16 | one bucket per source IP |

Three separate reasons for the same number to lie:

1. **A session is a connection, not a request.** In Layer 4 mode, one keep-alive client
   is one session no matter how much traffic it sends. "web02 has fewer sessions" can
   mean "web02 is idle" or "web02 serves one very busy client". You cannot tell from
   the counter.
2. **In Layer 7 mode the two numbers agree only because each request happens to open a
   new connection.** `sessions == requests` here is an artefact of roundrobin choosing
   a different server each time. Change the algorithm to `leastconn` and a long-lived
   connection can serve many requests, at which point the numbers separate again.
3. **Source hashing collapses clients into buckets.** With two nodes there are two
   buckets, so three clients guarantee a collision. Behind a NAT gateway, a corporate
   proxy or a mobile carrier, hundreds of real users share one address and therefore
   one node: `balance source` degenerates into "send everyone to web01".

The monitoring lesson: **measure what you are trying to equalise.** If the goal is
equal request load, alert on the per-node request share. If the goal is equal
connection load, alert on sessions. Watching the wrong one produces a dashboard that
is green during exactly this incident.

## 6. Root cause

The balancing key did not match the traffic pattern:

- Layer 4 balancing keys on the connection. HTTP keep-alive makes connections long and
  few, so each connection concentrates many requests on one node.
- `balance source` keys on the client address. NAT makes addresses few and shared, so
  clients concentrate on one node.

In both cases the balancer is doing exactly what it was told. The design was told the
wrong thing for the traffic it carries.

## 7. Commands used

```bash
# baseline behaviour
curl -sv -o /dev/null $(printf 'http://192.168.56.10/ %.0s' $(seq 1 10))   # 1 connect, 9 reuses
pool-counters.sh                                                            # sessions vs requests

# try the obvious suspect
sed -i 's|^    balance                 roundrobin$|    balance                 roundrobin\n    http-reuse              always|' \
  /etc/haproxy/haproxy.cfg
systemctl reload haproxy

# reproduce pinning at Layer 4 (temporary frontend on 8081, plus a firewall allow)
ufw insert 1 allow from 192.168.56.0/24 to any port 8081 proto tcp
curl -sv --connect-timeout 3 -m 20 -o /dev/null $(printf 'http://192.168.56.10:8081/ %.0s' $(seq 1 10))

# source hashing
sed -i 's|^    balance                 roundrobin$|    balance                 source|' \
  /etc/haproxy/haproxy.cfg
systemctl reload haproxy

# restore
cp /tmp/inc5-base.cfg /etc/haproxy/haproxy.cfg && systemctl reload haproxy
```

`scripts/pool-counters.sh` is new: it resolves `stot`, `req_tot`, `status` and
`check_status` by name from the CSV header, because this file is 40+ columns wide and
positional awk is how a report ends up quoting the wrong field.

## 8. Findings and evidence

| Question | Answer | Evidence |
| --- | --- | --- |
| Does keep-alive pin in this lab? | No | 1 connection, 10 requests, 5/5 |
| Why not? | HTTP mode balances per request | sessions == requests, +5 on each node |
| Does `http-reuse always` pin it? | No | still 5/5, measured |
| Does a Layer 4 frontend pin? | Yes | 10/10 on web01 from one connection |
| Can L4 count requests? | No | `req_tot` blank, `sessions=1` |
| Does `balance source` imbalance? | Yes | 16 vs 10 sessions from 3 clients |
| Any errors during all of this? | No | every response 200 |

## 9. Resolution

The config was restored to `balance roundrobin` and the temporary frontend removed:

```
config identical to repo
```

The fix, though, depends on the traffic, and this is the decision-making part:

- **Requests of similar cost, no session state:** `roundrobin` or `leastconn` in
  `mode http`. Balances per request, which is what most people mean by "even".
- **Requests of very different duration:** `leastconn` beats `roundrobin`, because
  roundrobin can pile slow requests onto one node.
- **Layer 4 is required** (non-HTTP protocol, TLS passthrough): accept that balance is
  per connection, keep connections short where possible, and size nodes for the
  busiest single client. Do not read `sessions` as load.
- **Stickiness is required** (stateful sessions): prefer a cookie (`stick-table`,
  `stick on`) over source hashing, because a cookie identifies a user rather than an
  address. If source hashing is unavoidable, use `hash-type consistent` so that
  adding or removing a node does not remap almost every client.

## 10. Verification

```
balance                 roundrobin
demo leftovers:         0
ufw rules:              4
config identical to repo

10 separate connections:   5 web01   5 web02
10 requests, 1 connection: 5 web01   5 web02
counters:                  web01 sessions=10 requests=10
                           web02 sessions=10 requests=10
```

Both traffic patterns balance evenly and the counters agree, which is the healthy
state for this design.

## 11. Lessons learned

1. **Test the assumption, not the theory.** I expected keep-alive to pin clients and it
   did not. The measurement is more valuable than the expectation, and the reason it
   did not is the most interesting thing in this incident.
2. **A session is a connection; a request is a request.** In Layer 4 mode they are
   completely different quantities, and `sessions=1` can mean one request or ten
   thousand.
3. **Static algorithms choose the server before the connection.** `http-reuse` cannot
   pin a client under `roundrobin`, because the server is chosen first and the
   connection is opened to whichever server won.
4. **`balance source` is a NAT trap.** Two nodes give two buckets; a corporate proxy
   with a thousand users behind it fills one bucket.
5. **The right monitoring metric depends on the balancing key.** Sessions for
   connection balancing, requests for request balancing. Watching the other one shows
   green during a real imbalance.
6. **A firewall rule on the balancer applies to demo ports too.** Twenty minutes were
   lost to a dropped SYN on 8081, and the clue was the frontend's `sessions=0` while a
   listener existed.

## 12. Azure equivalent

This is the cleanest mapping of the five incidents, because Azure exposes the same
choice explicitly.

| This lab | Azure |
| --- | --- |
| `mode tcp` + `roundrobin` | Load Balancer (Layer 4) with 5-tuple hash |
| keep-alive pinning a connection | same behaviour: a flow maps to one backend for its life |
| `balance source` | LB distribution mode **Client IP** (or Client IP and protocol) |
| `balance roundrobin` per request | Application Gateway, `cookieBasedAffinity` disabled |
| cookie stickiness | Application Gateway affinity cookie, or LB Client IP mode |
| `sessions` counter | LB metrics: connection/flow counts, bytes, SYN count |
| `req_tot` | App Gateway request-level metrics; **not available** on a Layer 4 LB |

Two AZ-700 points worth carrying:

- **Azure Load Balancer is Layer 4 and cannot see requests.** Its default distribution
  is a 5-tuple hash, so a single client opening many connections spreads across
  backends by port, while a client reusing one connection stays on one backend. Its
  metrics count flows, not requests. If you need request-level distribution and
  request-level metrics, you need a Layer 7 service (Application Gateway, Front Door),
  not a better algorithm on the LB.
- **"Session persistence: Client IP" is `balance source`.** Same benefit for stateful
  applications, same failure under NAT: many users behind one egress address collapse
  onto one backend. Cookie-based affinity on Application Gateway exists precisely to
  avoid that, and it is the option to reach for when the requirement is really "keep
  this user on the same node", not "keep this address on the same node".

The general principle, and the one I would say in an interview: **availability is
about surviving failure, distribution is about using what you have.** Incidents 1 to 4
were the first problem. This one is the second, and it fails silently, which makes it
the one most likely to be discovered during a peak rather than before it.
