# Incident report 3: wrong health-check port

**Date:** 19 November 2026
**System:** NordicShop lab, HAProxy 2.8 on lb01 fronting web01 and web02
**Severity:** capacity halved, no customer errors
**Status:** resolved (config restored and reloaded), verified

## 1. Scenario

A one-word change to the balancer's configuration points web01's health check at
port 8080 instead of 80. Nothing is wrong with web01. Nginx is serving on 80 the
whole time, the machine never falters, and the page loads normally if you ask for it
directly. HAProxy simply stops trusting the node and removes it from the pool.

This is the most common cause of "the load balancer says my server is down but it
isn't". The fault is in the configuration of the observer, not in the observed.

## 2. Business impact

The least visible failure so far, and the most dangerous for that reason.

| | Incident 1 (process stopped) | Incident 2 (packets dropped) | Incident 3 (wrong check port) |
| --- | --- | --- | --- |
| Customer errors | 0 of 120 | 3 of 80 | 0 of 60 |
| Capacity | 1 of 2 nodes | 1 of 2 nodes | 1 of 2 nodes |
| What actually broke | a real service | a real network path | nothing |

Customers saw nothing: 9 requests to web01 (all before the reload took effect), 51 to
web02, every one a 200. The cost is invisible but real. The site is running at half
capacity, and the remaining node is absorbing double its normal load with no notice
at all. If a designed-for-two traffic peak arrives, the single node fails, and the
team will be looking at a genuine outage with a misleading history.

A config error that removes capacity without generating a single error is exactly the
kind of fault that only monitoring on *pool size*, rather than on error rate, catches.

## 3. Symptoms

- `web01` reported as `DOWN` with `check=L4TOUT`, while `web02` is `L7OK 200`.
- HAProxy's log: `Layer4 timeout, check duration: 2001ms`.
- `curl` to web01 on port 80, from the balancer itself, returns 200.
- Nothing is listening on port 8080 anywhere on the host.
- The config passes `haproxy -c` without a complaint.

## 4. Reproduction

The change is a single server-line parameter:

```diff
-    server web01 192.168.56.21:80 check
+    server web01 192.168.56.21:80 check port 8080
```

The `port` parameter sets the port HAProxy uses to connect to that server, and the
check rides on the same connection, so the probe now goes to 8080.

Before applying it I checked which syntax the version actually supports:

```
--- variant A (check port 8080):      Configuration file is valid
--- variant B (check check-port 8080): [ALERT] Error(s) found in configuration file
```

`check-port` is not a 2.8 parameter; `port` is. Then:

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg   # Configuration file is valid
systemctl reload haproxy
```

Note that validation passing is not evidence of correctness. The file is
syntactically perfect and semantically wrong, which is precisely why this class of
mistake survives review.

## 5. Initial investigation

### 5.1 What the pool says

```
web01  DOWN  check=L4TOUT
web02  UP    check=L7OK  code=200
BACKEND UP
```

```
Server nordicshop_web/web01 is DOWN, reason: Layer4 timeout,
check duration: 2001ms. 1 active and 0 backup servers left.
```

### 5.2 What web01 says

```
from lb01, direct to :80 (bypassing the proxy) : 200
on web01, local                                : 200
is anything on 8080?                           : 0
```

The backend answers on 80 for anyone who asks, including the balancer, and serves
nothing at all on 8080.

### 5.3 Why it timed out instead of being refused

My first expectation was `L4CON ... Connection refused`, because a closed port
normally answers with a reset. Instead the check timed out. The firewall explains it:

```
web01 -> 127.0.0.1:8080   curl_exit=7    <- refused, no firewall on loopback
lb01  -> 192.168.56.21:8080 curl_exit=28 <- timeout, dropped by default deny
```

ufw's default incoming policy is deny, and the only rule for port 80 permits
192.168.56.10. A packet to 8080 matches nothing and is **dropped**, not rejected. So
the balancer waits out its full check timeout on every attempt.

**This is the important result of the incident.** Incident 2 and Incident 3 produce
the same fingerprint (`L4TOUT`, ~2 s per check, node removed) from completely
different causes: one is a broken network path, the other is a typo on the balancer.
The fingerprint alone cannot tell them apart. The only thing that distinguishes them
is asking both sides the same question:

| Question | Incident 2 | Incident 3 |
| --- | --- | --- |
| Does the balancer reach the service port? | no | **yes, 200** |
| Is the service running locally? | yes | yes |
| Is the check pointed at the right port? | yes | **no** |

In Incident 2 the service port was unreachable. Here it is reachable and the check
is aimed somewhere else.

## 6. Root cause

The health check was pointed at a port where nothing listens. Timeline, sampled every
200 ms with HAProxy's own stats socket:

```
20:07:43.918  reload issued (bad config)
20:07:44.324  UP 1/3   check=*   INI          <- first failing check counted
20:07:46.271  DOWN     check=L4TOUT           <- removed from the pool
20:07:51.247  DOWN     check=*   L4TOUT        <- another check in flight, still failing
```

**Detection: ~2.4 seconds after the reload.**

One honest note. I expected roughly 6 seconds: `fall 3` needs three failures, and
with dropped packets each check burns its full 2-second timeout, so three serialized
checks should take about 6 s. The measurement says the node left the pool in 2.4 s,
and the counter already read `1/3` four tenths of a second after the reload, before
any 2-second timeout could have elapsed. I am recording the observed behaviour rather
than the theory that fails to explain it; the practical consequence is that a reload
with a bad check takes a node out faster than `fall × interval` suggests.

What is certain from the samples: the new process only ever recorded `L4TOUT` on
8080, never `L7OK`, and web01 was removed while serving perfectly on 80.

## 7. Commands used

```bash
# the change (on lb01)
cp /etc/haproxy/haproxy.cfg /tmp/haproxy.cfg.before-incident3
sed -i 's|^    server web01 192.168.56.21:80 check$|    server web01 192.168.56.21:80 check port 8080|' \
  /etc/haproxy/haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl reload haproxy

# the two views
curl -s -m3 -o /dev/null -w '%{http_code}' http://192.168.56.21/        # from lb01: 200
curl -s -m3 -o /dev/null -w '%{http_code}' http://127.0.0.1/healthz     # on web01: 200
ss -ltn | grep ':8080 '                                                # nothing

# proof it is dropped, not refused
curl -s -m3 -o /dev/null http://127.0.0.1:8080/    # exit 7  (refused)
curl -s -m3 -o /dev/null http://192.168.56.21:8080/ # exit 28 (timed out)

# the timeline
watch-pool-timeline.sh 70 0.2 web01

# restore
cp /tmp/inc3-good.cfg /etc/haproxy/haproxy.cfg && systemctl reload haproxy
```

`scripts/watch-pool-timeline.sh` is new. The earlier watcher exits when the stats
socket briefly stops answering during a reload, which loses exactly the window being
measured; this one records `NO-RESPONSE` and keeps going.

## 8. Findings and evidence

| Question | Answer | Evidence |
| --- | --- | --- |
| Is web01 healthy? | Yes | 200 direct from lb01, 200 locally, nginx active |
| Is the check pointed at the service? | No | check goes to 8080, nothing listening there |
| Did the config validate? | Yes | `Configuration file is valid` |
| Did customers see errors? | No | 60 samples, all 200 |
| How fast was detection? | ~2.4 s after reload | 43.918 → 46.271 |
| Why a timeout, not a refusal? | Firewall drops 8080 | refused locally (exit 7) vs timeout remotely (exit 28) |

## 9. Resolution

```bash
cp /tmp/inc3-good.cfg /etc/haproxy/haproxy.cfg
systemctl reload haproxy
```

The node was never restarted, never touched. Only the observer was corrected.

## 10. Verification

```
web01  UP  L7OK  200
web02  UP  L7OK  200
BACKEND UP
```

Traffic after restore: 5 requests to each node out of 10.

One detail worth knowing, because it will confuse anyone reading logs later: after
the restoring reload there is **no `is UP` line** in `haproxy.log`. The last state
change on record is the `is DOWN`. This is not a missed recovery. A reload starts a
fresh worker that assumes every server is UP until a check says otherwise
(`grep server-state-file` returns 0, so nothing is persisted), so there is no DOWN to
UP transition to log. The pool state is authoritative here, not the absence of a log
line.

The same behaviour is a small risk in the other direction: for the first moments
after a reload, HAProxy believes every server is healthy, including one that has been
dead all along.

## 11. Lessons learned

1. **Validate with a request, not with a config check.** `haproxy -c` passed a file
   that took half the capacity out of production. Syntax validation and behavioural
   validation are different tests.
2. **The balancer's opinion is not the backend's health.** The only reason this
   looked like an outage is that one component's belief was treated as fact. Ask the
   backend what it is serving before believing the pool.
3. **Identical symptoms, opposite causes.** Incident 2 and Incident 3 both produced
   `L4TOUT` and a node removal. Distinguishing them required one extra question, not
   more logs.
4. **Firewall policy changes the *shape* of a failure.** A reject gives a 0 ms
   refusal; a drop gives a 2 s timeout. The same broken port looks different
   depending on the default policy in front of it.
5. **Detection speed depends on the failure mode, not just on `fall`.** Instant
   refusal, dropped packets, and a bad check port all reach "DOWN" on different
   clocks.
6. **A reload is not a no-op.** It resets the pool's assumptions, produces no `is UP`
   line for servers that come back healthy, and briefly trusts servers it has not yet
   checked.

## 12. Azure equivalent

| This lab | Azure |
| --- | --- |
| `check port 8080` | Load balancer health probe with the wrong `port` (or an Application Gateway probe with the wrong `path`) |
| `L4TOUT` on a healthy node | Probe failure while the VM serves traffic normally: the instance is removed from the backend pool, the VM is still healthy |
| `haproxy -c` passes | Portal accepts the probe config; no validation catches a port that nothing listens on |
| Backend still reachable on the service port | `curl` from inside the VNet to the VM on the real port still works |
| `fall 3` / `rise 2` | `probeThreshold` and the probe interval decide how long a misconfigured probe takes to remove the instance |

The Azure version of this incident has a famous twist worth memorising for AZ-700:
Azure probes do not come from your subnet. They originate from the platform address
`168.63.129.16`. Put a restrictive NSG on the backend subnet and forget to allow that
source, and every probe fails while the application is perfectly healthy — Incident 3,
with the platform as the observer. The troubleshooting question is the same one used
here: *is the service reachable, and is the observer looking in the right place?*

Second tie-in: on Azure Load Balancer the probe port does not have to equal the
traffic port, which means a probe on 8080 can legitimately coexist with traffic on
80 — the same separation this incident misconfigured on purpose. The setting is
useful, and that is exactly why a wrong value is easy to ship.
