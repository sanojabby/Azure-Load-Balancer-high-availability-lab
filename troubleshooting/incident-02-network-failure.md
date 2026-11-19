# Incident report 2: network connectivity failure

**Date:** 19 November 2026
**System:** NordicShop lab, HAProxy 2.8 on lb01 fronting web01 and web02
**Severity:** customer-visible. Three of eighty sampled requests failed
**Status:** resolved (rule removed), detection and recovery verified

## 1. Scenario

A firewall rule on `web01` starts dropping traffic from the load balancer. Nginx is
healthy the whole time, the port is open, the page is served locally, and the machine
is doing nothing wrong. The only broken thing is the path between the balancer and
the backend.

This is the most realistic failure in the whole set: an ACL change, a security policy
applied from a central tool, or a rule added during an unrelated piece of work.

## 2. Business impact

Different from Incident 1 in a way that matters commercially.

| | Incident 1 (process stopped) | Incident 2 (packets dropped) |
| --- | --- | --- |
| Customer failures | 0 of 120 | 3 of 80 sampled |
| What the customer experiences | nothing | a request that hangs for ~3 s, then fails |
| Why | connection refused instantly, retried in ~1 ms | connection hangs until a timeout expires |

A crashed node fails fast and is retried invisibly. A blackholed node fails slowly,
and the slowness is what customers feel. The remaining healthy node still absorbed
97 percent of requests, so capacity was never the problem; latency and errors were.

## 3. Symptoms

- HAProxy marks `web01` DOWN with `check=L4CON` / `Layer4 timeout`, check duration
  2000 ms.
- `web01` reports itself perfectly healthy: `nginx=active`, `curl localhost` returns
  200, port 80 listening.
- Customer samples show `000 none` entries where a request should have been served.
- `web01`'s Nginx access log stops receiving entries at the moment the rule is added.

## 4. Reproduction

An important detail came out of the first attempt. The obvious rule is:

```bash
ufw insert 1 deny from 192.168.56.10 to any port 80 proto tcp
```

ufw refuses it:

```
Skipping inserting existing rule
```

The existing allow rule (`80/tcp ALLOW from 192.168.56.10`) and the requested deny
have the same from/to/port/proto tuple, and this ufw version deduplicates on that
tuple **regardless of the action**. Nothing changes, no error is raised, and the
balancer keeps working. That is a trap: a failed change looks like a successful one.

The working form, which is also closer to what a stray rule looks like in production,
names the destination explicitly:

```bash
ufw insert 1 deny from 192.168.56.10 to 192.168.56.21 port 80 proto tcp \
  comment "incident2-simulated-acl-break"
```

```
[ 1] 192.168.56.21 80/tcp    DENY IN    192.168.56.10    # incident2-simulated-acl-break
[ 2] 22/tcp                  ALLOW IN   192.168.56.0/24
[ 3] 22/tcp                  ALLOW IN   10.0.2.0/24
[ 4] 80/tcp                  ALLOW IN   192.168.56.10
```

Rule 4 still allows the balancer; rule 1 sits above it and matches first. ufw is
first-match, so position decides the outcome, not the presence of the allow.

## 5. Initial investigation

### 5.1 The balancer's view, seconds after the rule went in

```
lb01 -> 192.168.56.21:80 : 000   curl_exit=28
```

`000` with exit 28 is curl's timeout, not a refusal. Compare Incident 1, where the
same request returned immediately with "Connection refused".

### 5.2 The backend's view, at the same moment

```
web01 -> 127.0.0.1:80      : 200   curl_exit=0
web01 -> 192.168.56.21:80  : 200   curl_exit=0
nginx process state        : active
listener still open        : 2
```

Everything that a check *inside* the machine can verify says the service is fine.
This is exactly why "is the service up?" is the wrong first question. The correct one
is "can the path that matters reach it?".

### 5.3 What HAProxy logged

```
2026-11-19T19:59:22.331667+01:00 lb01 haproxy[3820]: Server nordicshop_web/web01 is DOWN,
reason: Layer4 timeout, check duration: 2000ms. 1 active and 0 backup servers left.
1 sessions active, 0 requeued, 0 remaining in queue.
```

Read the three differences from Incident 1:

| Field | Incident 1 | Incident 2 |
| --- | --- | --- |
| reason | `Layer4 connection problem` | `Layer4 timeout` |
| info | `"Connection refused"` | none: nothing replied |
| check duration | `0ms` | `2000ms` |

`Connection refused` with a 0 ms duration means something answered at the TCP layer
with a reset: the port is closed. `Layer4 timeout` with a 2000 ms duration means
nothing answered at all: the packets were dropped. That distinction tells an engineer
which side to look at before opening a single log.

### 5.4 The backend's own access log

```
192.168.56.10 - - [19/Nov/2026:19:59:13 +0100] "GET / HTTP/1.1" 200 1183 "-" "curl/8.5.0"
```

That is the last line before the block. The rule was applied at 19:59:13, and from
then on the log is silent, even though Nginx never stopped and continued logging
local requests.

## 6. Root cause

The firewall rule inserted at position 1 drops SYNs from 192.168.56.10 to port 80 on
192.168.56.21. The health check therefore never completes:

1. HAProxy opens a TCP connection to 192.168.56.21:80 every 2 seconds.
2. The SYN is dropped. Nothing comes back, so the attempt runs to HAProxy's check
   timeout: `check duration: 2000ms`.
3. Three consecutive failures at `fall 3` mark the server DOWN.

**Detection time measured: ~9.3 seconds** (rule applied 19:59:13.0, `is DOWN` logged
19:59:22.33). That is far slower than Incident 1's 1.5 seconds, and the reason is
mechanical: a refused connection fails instantly, so three failures take 1.5 s; a
dropped connection costs the full 2 s timeout per check, so three failures take ~6 s
plus scheduling.

The cause of the outage is the rule. The cause of the *slow* detection is the
timeout, and that is the tunable part: `timeout connect` and the check timeout set the
floor for how fast a blackhole can be detected.

## 7. Commands used

```bash
# break the path (on web01)
ufw insert 1 deny from 192.168.56.10 to 192.168.56.21 port 80 proto tcp \
  comment "incident2-simulated-acl-break"
ufw status numbered

# prove the two views disagree
curl -s -m3 -o /dev/null -w '%{http_code}' http://192.168.56.21/healthz   # from lb01
curl -s -m3 -o /dev/null -w '%{http_code}' http://127.0.0.1/healthz       # on web01

# evidence
grep -E "is DOWN|is UP" /var/log/haproxy.log
tail -1 /var/log/nginx/nordicshop-access.log
ss -ltn | grep ":80 "
grep "SRC=192.168.56.10" /var/log/ufw.log

# restore
ufw delete deny from 192.168.56.10 to 192.168.56.21 port 80 proto tcp
```

## 8. Findings and evidence

| Question | Answer | Evidence |
| --- | --- | --- |
| Did the balancer notice? | Yes, after ~9.3 s | `is DOWN ... Layer4 timeout ... 2000ms` |
| Was the backend actually broken? | No | `nginx=active`, local and own-IP requests return 200, port listening |
| Did customers notice? | Yes, unlike Incident 1 | three `000 none` samples; requests hung 3 s |
| Where was the failure? | Between the balancer and the backend | `curl` from lb01 times out while `curl` from web01 succeeds |
| Was the backend's log any help? | Indirectly | access log stops at 19:59:13, proving traffic never arrived |

Customer samples across the change:

```
19:59:12.946 200 web02
19:59:13.274 200 web01     <- last successful request to web01
19:59:13.601 200 web02
19:59:13.928 200 web01     <- already assigned, connection hung
19:59:14.260 200 web02
19:59:17.615 000 none      <- 3 s client timeout expired
19:59:20.947 000 none
...
totals:   3 000 none
          6 200 web01
         71 200 web02
```

The gap between `19:59:14.260` and `19:59:17.615` is the probe script waiting for its
own 3 second timeout. That gap is the customer experience of a blackholed backend.

### A note on the missing firewall log

`ufw status verbose` reports `Logging: on (low)`, yet after the block there were
**zero** entries from 192.168.56.10 in `/var/log/ufw.log`. The reason: an explicit
`deny` rule that does not carry the `log` keyword matches first and is silent. The
low logging level records packets that fall through to the default policy, not
explicit blocking rules.

Verified by repeating the test with the keyword:

```
[ 1] 192.168.56.21 80/tcp   DENY IN   192.168.56.10   (log)

[UFW BLOCK] IN=enp0s8 ... SRC=192.168.56.10 DST=192.168.56.21 ... DPT=80 ... SYN URGP=0
count=8
```

Note the timestamp format: kernel log entries are UTC (`19:00:49+00:00`) while Nginx
logs local time (`20:00:49+0100`). Correlating an incident across those two files
without noticing the offset is a classic way to conclude "nothing happened".

## 9. Resolution

```bash
ufw delete deny from 192.168.56.10 to 192.168.56.21 port 80 proto tcp
# Rule deleted
```

No reload of HAProxy, no restart of Nginx. The path came back and the balancer
noticed on its own.

## 10. Verification

```
2026-11-19T20:00:16.866436+01:00 lb01 haproxy[3820]: Server nordicshop_web/web01 is UP,
reason: Layer7 check passed, code: 200, check duration: 1ms.
2 active and 0 backup servers online. 0 sessions requeued, 0 total in queue.
```

Recovery ~3.5 seconds after the rule was removed, and the `reason: Layer7 check
passed, code: 200` line proves the HTTP check ran end to end, not just a TCP connect.

Traffic after recovery:

```
 1 -> web02    6 -> web01
 2 -> web01    7 -> web02
 3 -> web02    8 -> web01
 4 -> web01    9 -> web02
 5 -> web02   10 -> web01
```

Final pool state: `web01 UP L7OK 200`, `web02 UP L7OK 200`.

## 11. Lessons learned

1. **"The service is up" is not the same as "the service is reachable."** Every
   local check passed while the service was effectively down. The only useful test is
   from the consumer's position.
2. **Refused and dropped are different failures with different costs.** Refused:
   instant, retried invisibly, ~1.5 s detection. Dropped: 3 s of customer latency per
   request, real errors, ~9 s detection. Knowing which one you have changes both the
   diagnosis and the urgency.
3. **`0ms` versus `2000ms` is a fingerprint.** HAProxy's check duration distinguishes
   the two cases before you look at anything else.
4. **First-match ordering beats rule presence.** The allow rule for the balancer was
   still in the table the whole time; the deny above it decided the outcome.
5. **A silent firewall is a logging choice.** Without the `log` keyword the block was
   invisible in `ufw.log`. If you rely on firewall logs for investigations, put the
   keyword in the rule.
6. **A failed change can look like a success.** ufw's deduplication silently skipped
   the deny because a rule with the same 5-tuple already existed. Always verify a
   change with an actual request, not with the exit status of the command.

## 12. Azure equivalent

| This lab | Azure |
| --- | --- |
| `ufw deny` rule on web01 | NSG rule with a lower priority number than the allow rule |
| First-match ordering | NSGs evaluate by priority (lowest number first); same trap, same silent failure |
| Traffic dropped, no response | NSG denies are silent drops; the client sees a timeout, not a refusal |
| Health probe fails with timeout | Azure probe marks the instance unhealthy after `probeThreshold` |
| `ufw.log` missing entries | NSG flow logs and "effective security rules" are how you see what actually applied |
| Restoring by deleting the rule | Rules apply within seconds; no VM change needed |

Two AZ-700 points worth carrying:

- **Effective security rules matter more than the rules you think you set.** In Azure
  the portal shows the *effective* rules per NIC precisely because NSG rules can be
  overridden by a subnet-level NSG. The lab reproduced that class of bug with rule
  ordering.
- **Probe design decides detection speed.** Azure's default (every 15 s, two
  failures) would have taken ~30 s to notice this, three times slower than the
  measured 9 s here, and that number is a business decision, not a default to accept.
