# Reverse proxy (Caddy)

Caddy runs system-wide (distribution package, managed by the technical admin) and is the
only service that opens ports to the outside. Each project listens on `127.0.0.1:<WEB_PORT>` only.

```bash
apt install caddy
mkdir -p /etc/caddy/sites
cp proxy/Caddyfile /etc/caddy/Caddyfile
systemctl reload caddy
```

`scripts/caddy-sync.sh` generates the configuration from `/srv/boinc/*/project.conf`.
`new-project.sh` and `remove-project.sh` call it automatically. Run it by hand after
editing a `project.conf`. It writes one file per site address,
`/etc/caddy/sites/boinc-<address>.caddy`, and leaves other files in `/etc/caddy/sites` alone.
If Caddy rejects the result, the previous configuration is restored.

**Several projects on one address:** projects with the same site address share one Caddy site
and are routed by path. `/<project>/`, `/<project>_ops/` and `/<project>_cgi/` go to that
project's web container. BOINC master URLs always contain the project name, so
`http://192.0.2.10/projecta/` and `http://192.0.2.10/projectb/` can live side by side.
With a single project on an address, `/` redirects to `/<project>/`.


- **Site address with a hostname** (`rkfold.example.org`): Caddy obtains a Let's Encrypt
  certificate automatically. The DNS record must point to the server and ports 80/443 must
  be reachable from the internet.
- **Site address with `http://`** (`http://192.0.2.10`): no TLS, for LAN testing.
- **Dedicated IP per project**: `-b <IP>` on `new-project.sh` adds `bind <IP>` to the site.
  Give such a project its own site address (a hostname or that IP).
  The IP must be configured on the host (e.g. via netplan).

Caddy sets `X-Forwarded-For` and `X-Forwarded-Proto`. Apache in each project takes the real
client IP from it (`mod_remoteip`), so BOINC records the correct host IPs.
