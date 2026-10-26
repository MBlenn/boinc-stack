# Reverse proxy (Caddy)

Caddy runs system-wide (distribution package, managed by the technical admin) and is the
only service that opens ports to the outside. Each project listens on `127.0.0.1:<WEB_PORT>` only.

```bash
apt install caddy
mkdir -p /etc/caddy/sites
cp proxy/Caddyfile /etc/caddy/Caddyfile
systemctl reload caddy
```

`scripts/new-project.sh` creates `/etc/caddy/sites/<shortname>.caddy` for each project.

- **Site address with a hostname** (`rkfold.example.org`): Caddy obtains a Let's Encrypt
  certificate automatically. The DNS record must point to the server and ports 80/443 must
  be reachable from the internet.
- **Site address with `http://`** (`http://192.0.2.10`): no TLS, for LAN testing.
- **Dedicated IP per project**: `-b <IP>` on `new-project.sh` adds `bind <IP>` to the site.
  The IP must be configured on the host (e.g. via netplan).

Caddy sets `X-Forwarded-For` and `X-Forwarded-Proto`. Apache in each project takes the real
client IP from it (`mod_remoteip`), so BOINC records the correct host IPs.
