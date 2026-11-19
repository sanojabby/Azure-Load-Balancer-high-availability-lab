# Phase 3: Backend web tier

**Date:** 19 November 2026
**Status:** complete and verified
**Scope:** Nginx installation, distinct page content, health endpoint, firewall proof

## 1. Objective

The load balancer in Phase 4 is only meaningful if it has two backends that can be
told apart. This phase delivers that:

- two web servers running the same software with identical configuration,
- a different page on each, so a response identifies its node,
- a health endpoint a load balancer can probe meaningfully,
- and a proven boundary: only the load balancer may reach port 80.

## 2. What was installed

```
$ nginx -v
nginx version: nginx/1.24.0 (Ubuntu)

$ systemctl is-enabled nginx
enabled

$ systemctl is-active nginx
active
```

Both `web01` (192.168.56.21) and `web02` (192.168.56.22) report the same version and
state, from the Ubuntu 24.04 repositories.

### A quirk worth recording: nginx was installed but not running

Immediately after `apt-get install nginx`, the service was `inactive (dead)` even
though its configuration tested clean:

```
$ systemctl status nginx
○ nginx.service - A high performance web server and a reverse proxy server
     Loaded: loaded (/usr/lib/systemd/system/nginx.service; enabled; preset: enabled)
     Active: inactive (dead)

$ nginx -t
nginx: configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

The cause was a leftover from provisioning:

```
$ ls -l /usr/sbin/policy-rc.d
-rwxr-xr-x 1 root root 181 Nov 19 19:08 /usr/sbin/policy-rc.d
```

`policy-rc.d` is the Debian mechanism that tells package maintainer scripts not to
start services. It exists so a service is not started inside an installer or a
chroot before the system is ready. On these guests it survived the install, so
every `apt-get install` after that added the package without starting it.

systemd's journal confirms the service only ever started when the deploy script
asked for it explicitly:

```
Nov 19 19:43:51 web01 systemd[1]: Starting nginx.service - A high performance web server...
Nov 19 19:43:51 web01 systemd[1]: Started nginx.service - A high performance web server...
```

Resolution: `scripts/deploy-nginx.sh` ends with an explicit
`systemctl enable nginx` and `systemctl restart nginx`, so the tier does not depend
on package post-install behaviour. This is the kind of detail that matters in an
Ansible role later: "install" and "running" are separate states, and automation
that assumes otherwise produces a silent outage.

## 3. Configuration

Both nodes run the same site file with two differences: the node name and the
health response. Config as committed:

`configuration/nginx/web01-site.conf`

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name web01.nordicshop.lab web01;

    root /var/www/nordicshop;
    index index.html;

    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "ok web01\n";
    }

    location / {
        try_files $uri $uri/ =404;
        add_header X-Web-Node "web01" always;
        add_header Cache-Control "no-store" always;
    }

    access_log /var/log/nginx/nordicshop-access.log;
    error_log  /var/log/nginx/nordicshop-error.log;
}
```

Decisions and reasons:

| Choice | Why |
| --- | --- |
| `default_server` on port 80 | Requests arrive by IP, not by Host header. Without a default server, Nginx answers the first matching block and the result becomes order-dependent |
| `location = /healthz` | An exact-match location, so a health probe cannot be served by a cached file or by an error page. `access_log off` keeps probe noise out of the request log |
| `X-Web-Node` header | Makes the responding backend visible in one line of curl output. Round-robin balancing is otherwise indistinguishable from a single fast server |
| `Cache-Control: no-store` | Prevents a browser or proxy from hiding which node answered during the distribution tests in Phase 4 |
| Default site removed | Two blocks listening on 80 with `default_server` is a conflict; an orphaned default site silently wins and looks like "my config is ignored" |
| Different page content per node | The page is the human-visible proof of which server responded, and it is what a screenshot can show convincingly |

## 4. Deployment

```
scripts/deploy-nginx.sh <web01|web02>
```

The script copies the two files from `configuration/nginx/` over SCP and installs
them with `install -m 644`, then removes the default site, enables the site symlink,
tests the configuration, restarts the service and checks `/healthz` locally.
Nothing on the guest is edited by hand, so what runs in the lab is what is committed
to the repository.

Real output from both runs:

```
==> copying files to web01 (192.168.56.21)
==> installing on web01
--- config test:
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
--- service state:
active
--- local health check:
status=200
--- local page title:
<title>NordicShop - Web Node 1</title>

==> copying files to web02 (192.168.56.22)
==> installing on web02
--- config test:
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
--- service state:
active
--- local health check:
status=200
--- local page title:
<title>NordicShop - Web Node 2</title>
```

Both nodes listening:

```
web01: LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=3010,fd=7),...)
web02: LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=2943,fd=7),...)
```

## 5. Firewall proof

Run with `scripts/verify-web-tier.sh`.

### 5.1 Allowed: load balancer to backend

```
== allowed: load balancer to backend ==
  lb01      -> http://192.168.56.21/healthz expect=allow got=200 0.002096           PASS
  lb01      -> http://192.168.56.22/healthz expect=allow got=200 0.001733           PASS
  lb01      -> http://192.168.56.21/        expect=allow got=200 0.002029           PASS
  lb01      -> http://192.168.56.22/        expect=allow got=200 0.003129           PASS
```

### 5.2 Denied: every other host

```
== denied: everyone else to a backend ==
  web02     -> http://192.168.56.21/        expect=deny  got=000 5.002340           PASS
  web01     -> http://192.168.56.22/        expect=deny  got=000 5.000241           PASS
  client01  -> http://192.168.56.21/        expect=deny  got=000 5.000241           PASS
  client01  -> http://192.168.56.22/        expect=deny  got=000 5.000886           PASS

== denied from the Mac, which is on the same subnet ==
  mac -> 192.168.56.21 : blocked (curl exit 28)
  mac -> 192.168.56.22 : blocked (curl exit 28)
```

Three things this proves:

1. **A backend cannot reach another backend on port 80.** `web02` to `web01` is
   refused, so the rule really is "from the load balancer" and not "from the
   subnet".
2. **The client cannot bypass the load balancer.** `client01` is on the same subnet
   as both backends and still cannot reach port 80 directly. Customers have one
   address to use, and it is the balancer's.
3. **The Mac is blocked too**, even though it is 192.168.56.1 on the same /24.
   Administrative access is preserved on port 22 only.

The `000` status with a 5.00 second duration is a timeout, not a refusal: UFW's
default policy `deny` drops the packets silently. A `REJECT` rule would answer with
an ICMP port-unreachable and curl would fail immediately. Silent drop is
intentional here (a scanner learns nothing), and it is worth knowing that the same
behaviour appears as 5-second hangs in an application unless the client sets a
timeout. Phase 4's HAProxy timeouts are the answer to exactly that problem.

### 5.3 Which node answered

```
$ curl -D - -o /dev/null http://192.168.56.21/     (run from lb01)
Date: Thu, 19 Nov 2026 18:45:14 GMT
Content-Type: text/html
Content-Length: 1183
Last-Modified: Thu, 19 Nov 2026 18:43:50 GMT
X-Web-Node: web01
Cache-Control: no-store
Accept-Ranges: bytes
```

Health endpoints:

```
192.168.56.21 -> X-Web-Node: web01   healthz: ok web01
192.168.56.22 -> X-Web-Node: web02   healthz: ok web02
```

### 5.4 Server-side evidence

The access log on `web01` shows the request source as the load balancer's address,
which is the same fact seen from the other end of the connection:

```
192.168.56.10 - - [19/Nov/2026:19:44:26 +0100] "GET / HTTP/1.1" 200 1183 "-" "curl/8.5.0"
192.168.56.10 - - [19/Nov/2026:19:44:49 +0100] "GET / HTTP/1.1" 200 1183 "-" "curl/8.5.0"
192.168.56.10 - - [19/Nov/2026:19:45:14 +0100] "GET / HTTP/1.1" 200 1183 "-" "curl/8.5.0"
```

## 6. Why this matters for Phase 4

The `/healthz` endpoint is deliberately a real HTTP response with a body, not just
an open port. In Phase 4 the load balancer will be configured to request it, which
means:

- a node whose Nginx processes are wedged but whose socket still accepts connections
  is detected as unhealthy,
- a node that returns an error page is detected as unhealthy,
- a node whose firewall blocks the balancer is detected as unhealthy rather than
  silently failing half the customer requests.

That last case is what Incident 2 will simulate, using the rule proven here.

## 7. Azure mapping

| Local element | Azure equivalent | Who manages it |
| --- | --- | --- |
| UFW rule allowing 80 from 192.168.56.10 | NSG rule on the backend subnet or NIC, source = load balancer | Customer |
| Backend not reachable from client01 | Backend VMs have no public IP; only the load balancer has one | Customer configuration, platform enforcement |
| `/healthz` endpoint | Target of a health probe (`/healthz`, port 80, HTTP) | Customer |
| Nginx process and configuration | Guest OS and application inside the VM | Customer |
| `X-Web-Node` header | Same idea; custom headers are how you identify a backend instance in Azure too | Customer |

The boundary drawn here is the same boundary Azure draws by default: a backend pool
member has no inbound path from the internet, and an NSG decides whether anything
else may talk to it.

## 8. Next steps

Phase 4: install HAProxy on `lb01`, bind a frontend to 192.168.56.10:80, add both
nodes as backends, enable HTTP health checks against `/healthz`, choose the
balancing algorithm, and demonstrate the distribution with repeated requests.
