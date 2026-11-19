# Interview walkthrough

A ten-minute version of this project. The full evidence is in the phase documents and the
five incident reports; this is the thread that connects them.

## Why I built it

I kept reading that Azure Load Balancer "distributes traffic across healthy backends" and
that a health probe "removes unhealthy instances from rotation". Both statements are true
and neither tells you what happens in the second before rotation stops, or what the
customer sees while it does.

So I built the smallest lab that would let me break things for real: four VirtualBox VMs
on my Mac, one HAProxy balancer, two Nginx backends, one client. Then I broke it five
ways with a stopwatch running on both sides. Everything I say in an interview about this
project comes from a timestamp I captured, and where I did not measure something I say so.

## The architecture, in one minute

```
client01 .31  ->  lb01 .10 (HAProxy :80, stats :8404)  ->  web01 .21 (Nginx)
                                                       ->  web02 .22 (Nginx)
```

Four Ubuntu 24.04 guests on a host-only network, `192.168.56.0/24`, one vCPU and 1 GiB
each. Every VM has a second NIC on VirtualBox NAT, used only to install packages, and only
that NIC has a default route, so lab traffic can never leak off the host.

The balancer runs HAProxy 2.8.30 in `mode http`, and its health check is a real HTTP
request: `GET /healthz`, expecting a 200, every 2 seconds while healthy, every 500 ms
while transitioning, three failures to mark a node down, two successes to bring it back.
The backends run Nginx 1.24.0 and each stamps its own name into an `X-Web-Node` header, so
every response says which machine answered.

Two firewall decisions matter later. Backends accept port 80 **only** from the balancer's
address, so nothing else on the network can reach them directly, and the balancer binds
both its sockets to `192.168.56.10` rather than `0.0.0.0`.

One deliberate deviation from my original brief: it called for `mode tcp`, and I chose
`mode http` so the check could assert a 200 instead of only proving that a socket
accepts connections. I documented the trade-off at the time. Incident 5 later showed a
second consequence I had not predicted, which is the most interesting thing in the project.

## How I tested, because the method matters

Before each incident I started two samplers: one on the client sending a request every
300 ms and recording the status code and the answering node, one on the balancer reading
the pool state every 200 to 500 ms. Then I broke something and let both fill up. That is
why the reports contain two clocks running against the same event: what the balancer
believed, and what the customer got.

The gap between those two views is where all five lessons live.

## Incident 1: I stopped Nginx on a backend

HAProxy logged `Connection refused`, `check duration: 0ms`, and marked the node DOWN in
**1.5 seconds**. The client sent 120 requests and got 120 × 200 responses. Not one failure.

That looks like success and it is the most misleading result in the set. The reason is
`option redispatch`: 22 requests in that window had been assigned to the dead node, were
refused, and were retried on the survivor. The customer never knew. A monitoring system
watching HTTP status codes would also never know, even though half the capacity had
disappeared. The alert that matters is the pool transition, not the error rate.

## Incident 2: I blocked the path with a firewall rule

This time the backend was healthy and the network was broken. The check reported
`Layer4 timeout`, `check duration: 2000ms`, and detection stretched to **9.3 seconds** —
6× slower than Incident 1 — because each failed check had to burn its full 2-second
timeout instead of failing instantly.

Customers noticed this one: 3 of 80 requests failed. Dropped packets do not produce a
refusal, they produce silence, and silence is what users experience as a hanging page.

Two things came out of this incident beyond the timing. The obvious firewall rule I tried
first was silently skipped: ufw deduplicates on from/to/port/protocol regardless of the
action, so my deny collapsed into the existing allow and nothing changed. And the block
left no trace in `ufw.log`, because an explicit `deny` without the `log` keyword matches
first and is silent. Both are the kind of detail that makes an incident take twenty
minutes longer than it should.

The useful generalisation: **refused and dropped are different failures**. `0 ms` and a
refusal means the port is closed, so look at the process. `2000 ms` and a timeout means
packets are being dropped, so look at the path.

## Incident 3: I pointed the health check at the wrong port

One word: `check port 8080` on a backend that listens on 80. `haproxy -c` said
`Configuration file is valid`, the reload succeeded, and the node left the pool **2.4
seconds** later while serving perfectly the entire time.

This is the incident I would expect to actually encounter in production, because nothing
about it looks wrong. The backend returns 200 to the balancer on the real port, returns
200 locally, and is still removed. The only thing that distinguishes it from Incident 2 is
one question: *does the balancer reach the service port?* In Incident 2, no. Here, yes,
and the check is aimed somewhere else.

I also learned that a reload is not a no-op. There is no `is UP` line in the log after
restoring the config, because a reload starts a fresh worker that assumes every server is
healthy until a check says otherwise. Absence of that log line is not a missed recovery,
and it is also a small risk: right after a reload the balancer trusts servers it has not
checked yet.

## Incident 4: I stopped the load balancer

Everything else kept working. Both backends answered 200 throughout, from the balancer's
host and from themselves. The client got `000` with curl exit 7 — connection refused, not
timeout — for **33 of 33 requests over 34 seconds**.

That is the whole availability argument in one measurement. Three incidents reduced
capacity and were survivable. This one stopped the business, because the component
providing redundancy had none. Health checks only protect the layer below the balancer;
nothing protects the balancer, and the client has exactly one address to try.

The fix on-premises is keepalived and VRRP: two balancers, one shared VIP, an election
every second, and a `track_script` that gives up the VIP if HAProxy stops, so a running
but broken balancer does not keep the address. I designed that and did **not** build it —
a four-VM lab with one client cannot honestly demonstrate a VIP election, and I would
rather say that than show a diagram as if it were a test.

There is a detail I only found because of this lab: the backend firewall permits port 80
from `192.168.56.10` specifically. Under VRRP the traffic would arrive from the VIP, so a
naive keepalived setup layered on this firewall would fail over into a pool where both
backends drop everything. That is the kind of thing that separates a paper HA design from
a working one.

## Incident 5: I tried to make the distribution uneven, and failed

The classic story is that HTTP keep-alive pins clients to one backend. I sent ten requests
over a single keep-alive connection and got a perfect 5/5 split. One connection, nine
reuses, ten backend connections.

The reason is that `roundrobin` is a static algorithm: HAProxy picks the next server
first, then looks for a reusable connection to *that* server, and since it just advanced
to a different one, there never is one. So every request is balanced individually. I
tested `http-reuse always` expecting it to change that. It did not.

So I built a Layer 4 frontend, which is what my original brief would have deployed, and
the same ten requests went **10 of 10 to web01**, with `sessions=1` on that node, `0` on
the other, and `req_tot` blank because a Layer 4 proxy cannot count HTTP requests. Ten
requests looked like one unit of load.

Then `balance source`, which hashes on client address. Three clients split 16 to 10
sessions, because two of them hashed to the same node. Behind a NAT gateway or a corporate
proxy, where hundreds of users share one address, that becomes "everyone to web01".

The lesson is not "one algorithm is better". It is that **the balancing key has to match
the traffic**, and the metric you watch has to match the key. If you equalise connections
and monitor requests, or the reverse, your dashboard is green during a real imbalance.

## What the five add up to

Five failures, five different clocks, one taxonomy:

| Failure mode | Detection | Customer impact |
| --- | --- | --- |
| Process stopped (fast failure) | 1.5 s | none, masked by retry |
| Path dropped (silent failure) | 9.3 s | timeouts |
| Wrong probe (configuration failure) | 2.4 s | none, capacity halved |
| Balancer stopped (single point of failure) | none | total outage, 34 s |
| Wrong balancing key (design failure) | n/a | none, silent imbalance |

Two of them were invisible to error-rate monitoring, one was invisible to everything
except the pool state, and one produced no errors at all while halving capacity. That is
the argument for monitoring pool membership and per-node request share, not just status
codes.

## The Azure mapping

The translation is mostly one-to-one: `bind` becomes a frontend IP configuration, the
server lines become a backend pool, `option httpchk GET /healthz` becomes an HTTP probe
with `path=/healthz`, `inter` becomes `intervalInSeconds`, `fall` becomes
`probeThreshold`, and the ufw rules become NSG rules, which are also first-match by
priority so Incident 2 translates directly.

Two settings have **no Azure equivalent**, and both matter:

**There is no `fastinter`.** Azure's probe interval floor is 5 seconds. At threshold 2
that is about 10 seconds to remove a dead node; at the defaults (15 s interval, threshold
2) it is about 30. Incident 1 was detected in 1.5 seconds here. So the honest statement is
not that the cloud detects faster — it is that a tuned HAProxy detects faster than Azure
can be configured to, and that difference is measured in failed requests.

**There is no redispatch.** Azure Load Balancer is flow-based: it cannot retry a request
on another backend. My 120/120 with zero errors in Incident 1 was a Layer 7 feature.
Ported to Azure LB, that incident produces visible errors for every request in flight at
the moment the node died.

For Incident 4, Azure genuinely removes the failure: there is no balancer VM to stop, the
Standard SKU frontend can be zone-redundant, and the SLA is 99.99%. The keepalived design
becomes the platform's job.

And Incident 5 maps almost literally. Azure LB is Layer 4 with a 5-tuple hash by default,
and its persistence options are the same trade: "Client IP" *is* `balance source`, with the
same NAT collapse. Its metrics count flows, packets and bytes; they cannot tell you how
many HTTP requests a backend served. If you need request-level distribution and
request-level metrics, that is Application Gateway or Front Door, with cookie affinity
when the requirement is really "same user, same node".

So the split I would say out loud: **Azure takes over the availability of the balancer and
leaves you owning the probe, the firewall rules, the pool and the balancing key.** Those
four are exactly what the five incidents are about.

## What I would say if asked what I did not do

- Keepalived and VRRP are designed, not built, so the failover time is a design claim, not
  a measurement. I would build it next.
- No Azure resources were created, so nothing in the mapping is observed Azure behaviour.
  It is how the service is defined to work, mapped onto failures I did measure.
- The lab has one client, so the distribution numbers show the mechanism, not a realistic
  traffic mix.
- Detection times come from this hardware with these intervals; the mechanism generalises,
  the milliseconds do not.

## The one-sentence version

I built a small HA lab, broke it five ways, measured what the balancer believed against
what the customer received, and mapped each failure to what Azure removes and what it
still leaves to me.
