# Edge proxy on a VPS (Tailscale)

When the BOINC host has no public IP of its own (home or office line, no port forwarding),
a small VPS takes the public hostname and forwards the requests through a Tailscale tunnel:

```
Client ──https──► VPS: edge proxy :443 (boinc.example.org, Let's Encrypt)
                     │  Tailscale (WireGuard)
                     ▼
                  BOINC host: Caddy :80 (site http://boinc.example.org)
                     │  routed by path /<project>/, /<project>_cgi/, /<project>_ops/
                     ▼
                  <project>-web (127.0.0.1:<WEB_PORT>)
```

- The DNS record of the public hostname points to the **VPS**.
- The **edge terminates TLS** and obtains the certificate. The ACME HTTP challenge
  arrives at the VPS and is answered there; the BOINC host never sees it and needs no
  certificate.
- The BOINC host's Caddy serves the site with `http://` and routes by path as usual. Several
  projects can share one hostname (`https://boinc.example.org/projecta/`, `.../projectb/`).
- Master URLs contain no port: `https://boinc.example.org/<project>/`. Non-standard ports
  would work for BOINC clients, but they become part of the master URL for good and are
  often blocked in company and university networks.

The edge can be an Apache that already runs on the VPS (name-based virtual host, other sites
stay untouched) or Caddy, if ports 80/443 of the VPS are free.

## 1. Tailscale

Install Tailscale on both machines and join them to the same tailnet. Note:

- the **Tailscale IP of the VPS**: `tailscale ip -4` on the VPS (e.g. `100.101.102.103`)
- the **Tailscale name or IP of the BOINC host**: `tailscale ip -4` / MagicDNS name

Optionally restrict the tailnet ACL so that the VPS may only reach port 80 of the BOINC host.

## 2. BOINC host: project with edge

```bash
./scripts/new-project.sh -n <project> -l "<long name>" \
    -u https://boinc.example.org/ -s http://boinc.example.org -e <Tailscale IP of the VPS>
```

- `-u` is the public URL base (HTTPS, as clients see it).
- `-s http://...`: Caddy listens on port 80 for this hostname without TLS.
- `-e` makes Caddy trust `X-Forwarded-For` and `X-Forwarded-Proto` from the edge, so BOINC
  and the logs see the real client IPs instead of the VPS. Without `-e` everything works,
  but every client appears with the VPS's Tailscale IP.

For an existing project, add `EDGE_IPS="<Tailscale IP of the VPS>"` to
`/srv/boinc/<project>/project.conf` and run `scripts/caddy-sync.sh`.

Port 80 of the BOINC host does not need to be reachable from the internet, only from the VPS
via Tailscale.

## 3a. Edge with Apache (already running on the VPS)

Template: [`proxy/edge/apache-edge.conf`](../proxy/edge/apache-edge.conf). Replace
`boinc.example.org` and `boinc-host`, then:

```bash
a2enmod proxy proxy_http headers ssl
cp apache-edge.conf /etc/apache2/sites-available/boinc.example.org.conf
a2ensite boinc.example.org && apache2ctl configtest && systemctl reload apache2
certbot --apache -d boinc.example.org
```

`certbot --apache` answers the challenge through Apache on the VPS and adds the certificate
to the `*:443` virtual host. Renewals run the same way (`certbot.timer`). The template
excludes `/.well-known/acme-challenge/` from proxying and from the HTTPS redirect.

## 3b. Edge with Caddy

Template: [`proxy/edge/Caddyfile`](../proxy/edge/Caddyfile). Caddy needs ports 80 and 443
of the VPS and obtains the certificate itself. For several hostnames, add one site block each.

## 4. Check

```bash
curl -sI https://boinc.example.org/<project>/                 # 200, no Server header
curl -s https://boinc.example.org/<project>_cgi/cgi | head -3   # scheduler reply (XML)
```

The client IPs appear in the project's Apache log, e.g. in
`podman logs <project>-web` or in the host list of the ops pages after the first contact.

## How the client IP gets through

1. The edge adds `X-Forwarded-For: <client>` (and sets `X-Forwarded-Proto: https`).
2. The BOINC host's Caddy accepts these headers only from the IPs given with `-e`
   (`trusted_proxies`) and appends the edge's address: `<client>, <edge>`.
   From any other peer it replaces the header, so clients cannot inject addresses.
3. Apache in the web container (`mod_remoteip`) trusts private and Tailscale addresses
   (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) and takes the first untrusted address from the
   right, the client.
