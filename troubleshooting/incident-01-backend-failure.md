# Incident report 1: backend server failure

**Date:** 19 November 2026
**System:** NordicShop lab, HAProxy 2.8 on lb01 fronting web01 and web02
**Severity:** none observed by customers; one of two backends lost
**Status:** resolved (service restored), detection and failover verified

## 1. Scenario

`web01` processes stop. This is the realistic version of "the web server crashed"
and of "someone restarted the service during a maintenance window". The question is
whether customers notice and how quickly the balancer reacts.

## 2. Business impact

Expected impact if this design did not work: half of all customer requests fail
while HAProxy keeps sending traffic to a dead node.

Measured impact: **zero failed customer requests out of 120** during the incident.
Requests that were in flight to the failing node were retried on the healthy node.
A single node carried the whole load for about 66 seconds, so capacity was halved
during that window.

## 3. Symptoms

- No customer-visible error. Every response was `200`.
- HAProxy statistics showed `web01` as `DOWN` with `check=L4CON`.
- `web01`'s port 80 stopped listening; `systemctl status nginx` reported `inactive`.

The absence of customer-visible symptoms is the interesting part: this is what a
working failover looks like from the outside, and it is why the evidence has to be
collected on the balancer, not only at the client.

## 4. Reproduction

```bash
# stop the application on one backend
./scripts/guest.sh web01 --root 'systemctl stop nginx'

# and to recover
./scripts/guest.sh web01 --root 'systemctl start nginx'
```

Two samplers were started before the failure so the timeline exists from both ends:

| Script | Runs on | What it records |
| --- | --- | --- |
| `scripts/probe-frontend.sh 120 0.3` | client01 | timestamp, HTTP status, which node answered |
| `scripts/watch-pool.sh 90 0.5 web01` | lb01 | status, check result, `lastchg`, `downtime` |

Both were started with `nohup`, so the sampling continued across the SSH session
that issued the stop.

## 5. Initial investigation

### 5.1 Is the backend actually down?

```
nginx=inactive
0                      # listeners on port 80
```

`systemctl stop nginx` returned at ~19:54:06. The socket is gone, so nothing can
accept a connection.

### 5.2 What does the balancer think?

Pool state sampled every 500 ms:

```
19:54:06.168 web01 status=UP       check=L7OK  code=200 lastchg=267s downtime=0s
19:54:06.683 web01 status=UP 2/3   check=L4CON code=     lastchg=267s downtime=0s
19:54:07.198 web01 status=UP 1/3   check=L4CON code=     lastchg=268s downtime=0s
19:54:07.717 web01 status=DOWN     check=L4CON code=     lastchg=0s   downtime=0s
19:54:08.234 web01 status=DOWN     check=L4CON code=     lastchg=1s   downtime=1s
...
```

Read the failure counter: `UP 2/3`, `UP 1/3`, then `DOWN`. Three consecutive failed
checks, exactly as configured with `fall 3`. The `check=` field changes from `L7OK`
with a `200` to `L4CON` with no code, which is the important detail below.

### 5.3 What did HAProxy log?

```
2026-11-19T19:54:07.401758+01:00 lb01 haproxy[3820]: Server nordicshop_web/web01 is DOWN,
reason: Layer4 connection problem, info: "Connection refused", check duration: 0ms.
1 active and 0 backup servers left. 0 sessions active, 0 requeued, 0 remaining in queue.
```

That single line answers most of the investigation: the balancer noticed, it gives
the reason, and it states how many servers remain (`1 active and 0 backup`).

### 5.4 Did customers notice?

Client-side samples around the transition:

```
19:54:04.956 200 web01
19:54:05.283 200 web02
19:54:05.609 200 web01
19:54:05.938 200 web02
19:54:06.271 200 web01     <- last request that reached web01
19:54:06.599 200 web02
19:54:06.927 200 web02     <- alternation stops; everything goes to web02
```

Totals for the run:

```
     22 200 web01
     98 200 web02
```

No `503`, no timeouts, no `000` in the sample file. HAProxy's own request log for
the whole period shows only `200` responses for customer traffic.

## 6. Root cause

The application process was stopped deliberately as part of the test. The mechanism
that mattered was the sequence afterwards:

1. Nginx stops listening on port 80.
2. HAProxy's next health check cannot open a TCP connection.
3. That check is configured as HTTP (`option httpchk GET /healthz`), but a refused
   TCP connection never reaches HTTP. HAProxy reports `L4CON` rather than `L7STS`:
   the failure happened below the layer the check was written for.
4. Three failed checks at `fastinter 500ms` mark the server `DOWN`.

**Detection time measured: ~1.5 seconds**, from the stop to the `DOWN` log line
(`19:54:06.0` to `19:54:07.40`). The configured `inter 2s` would have allowed up to
6 seconds; `fastinter 500ms` shortens the interval after the first failure, which is
why it was faster than the worst case.

## 7. Commands used

```bash
# stop / start the application
systemctl stop nginx
systemctl start nginx
systemctl is-active nginx
ss -ltn | grep ":80 "

# pool state, sampled
./scripts/watch-pool.sh 90 0.5 web01

# pool state, one shot
curl -s 'http://192.168.56.10:8404/stats;csv' \
  | awk -F, '$1=="nordicshop_web"{print $2, $18, $37, $38}'

# state changes only
grep -E "is DOWN|is UP" /var/log/haproxy.log

# customer view
./scripts/probe-frontend.sh 120 0.3
```

## 8. Findings and evidence

| Question | Answer | Evidence |
| --- | --- | --- |
| Did HAProxy notice? | Yes, in ~1.5 s | `UP 2/3` -> `UP 1/3` -> `DOWN` samples; `is DOWN` log at 19:54:07.401 |
| Did it stop sending new traffic? | Yes, immediately on `DOWN` | Every client sample after 19:54:06.6 was served by `web02` |
| Were customers served throughout? | Yes, 120 of 120 requests returned 200 | `probe-frontend.sh` output |
| Was the failure visible in the logs? | Yes, with a reason string | `reason: Layer4 connection problem, info: "Connection refused"` |
| Did the remaining node take all traffic? | Yes | `1 active and 0 backup servers left` |

### Why no request failed, and what that hides

Requests alternate between nodes. In the ~1.5 s between Nginx stopping and the pool
marking `web01` down, roughly three requests were still assigned to `web01` and their
connection was refused. They still returned `200` because of two settings:

```
option redispatch
retries 2
```

HAProxy retried those requests on `web02` instead of returning an error. That is why
the client log shows `200 web02` in slots that should have gone to `web01`.

This is a real design decision with a cost: retries mask a failing node and make the
incident invisible to customers, which is good, but they also hide the failure from
any monitoring that only counts HTTP status codes. The `DOWN` event in the pool, not
the 200s, is the signal worth alerting on.

Without `redispatch`, the same test would have produced a handful of `503`s, and
that is worth measuring deliberately later, because "how many requests fail when a
node dies" is a number an interviewer will ask about.

## 9. Resolution

```bash
./scripts/guest.sh web01 --root 'systemctl start nginx'
nginx=active
```

HAProxy brought the node back on its own. No configuration change and no reload.

## 10. Verification

State after restart:

```
19:55:10.387 web01 status=DOWN check=L4CON code=     lastchg=63s
19:55:11.404 web01 status=DOWN check=L4CON code=     lastchg=64s
19:55:13.436 web01 status=UP   check=L7OK  code=200  lastchg=1s
19:55:14.453 web01 status=UP   check=L7OK  code=200  lastchg=2s
```

The `L4CON` -> `L7OK` transition is the proof that the HTTP check re-ran and passed,
not merely that a socket opened. HAProxy logged:

```
2026-11-19T19:55:12.942577+01:00 lb01 haproxy[5820]: Server nordicshop_web/web01 is UP,
reason: Layer7 check passed, code: 200, check duration: 1ms.
2 active and 0 backup servers online. 0 sessions requeued, 0 total in queue.
```

Recovery time ~2 seconds after Nginx started, against a configured `rise 2` at
`fastinter 500ms`.

Traffic distribution after recovery:

```
 1 -> web02    7 -> web02
 2 -> web01    8 -> web01
 3 -> web02    9 -> web02
 4 -> web01   10 -> web01
 5 -> web02   11 -> web02
 6 -> web01   12 -> web01
```

Both nodes back in service, alternating again.

## 11. Lessons learned

1. **Health check state, not client status codes, is the failure signal.** With
   redispatch enabled, a dead backend can be invisible at the HTTP layer. Alerting on
   "all responses are 200" would have missed this incident entirely.
2. **A check's configured layer is not the layer it fails at.** The check is HTTP, but
   a closed port fails at TCP and reports `L4CON`. Reading the `check` field tells you
   where the problem is: `L4CON` means the service is gone, `L7STS`/`code=503` would
   mean the application is up but unhealthy. That distinction halves the diagnosis
   time in a real incident.
3. **`fastinter` pays for itself.** The worst case was 6 seconds; the observed
   detection was 1.5 seconds, because the check interval shortens after the first
   failure.
4. **Retries hide incidents from the wrong people.** Good for customers, bad for
   monitoring. Both behaviours are correct as long as it is deliberate.
5. **Sample both ends.** The client log alone showed a perfectly healthy service. Only
   the pool sampler and the HAProxy log revealed that anything had happened.

## 12. Azure equivalent

| This lab | Azure Load Balancer |
| --- | --- |
| Health check fails, server set `DOWN` | Probe marks the backend instance unhealthy and stops new flows to it |
| `fall 3` at 2 s / 500 ms | `probeThreshold` (number of failed probes) and `intervalInSeconds` |
| `L4CON` "Connection refused" | Probe failure with a TCP-level cause |
| `redispatch` + `retries 2` | Not a Load Balancer feature; retries belong to the client or to a Layer 7 service such as Application Gateway |
| Node returns automatically on `rise 2` | Backend returns to the pool after `probeThreshold` successful probes |

Two practical differences worth remembering for AZ-700:

- Azure Load Balancer is a Layer 4 forwarder, so a failed flow to a dead backend is a
  connection reset to the client unless the client retries. What hides that from the client is
  HAProxy's Layer 7 retry, which a pure Layer 4 balancer does not do.
- Azure's default probe behaviour (probe every 15 s, two failures) is much slower than
  the 1.5 s achieved here. Faster detection is available by lowering the interval, and
  the trade-off is probe traffic versus detection speed, exactly as configured in
  `inter 2s fastinter 500ms`.
