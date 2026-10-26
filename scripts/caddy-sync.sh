#!/bin/bash
# Regenerates the Caddy configuration for all BOINC projects on this host (run as root).
#
# Projects are read from /srv/boinc/*/project.conf. Projects with the same site address
# (e.g. http://192.0.2.10 or boinc.example.org) share one Caddy site and are routed by
# path: /<project>/, /<project>_ops/ and /<project>_cgi/ go to that project's web container.
# One file per site address is written to /etc/caddy/sites/boinc-<address>.caddy.
#
# new-project.sh and remove-project.sh call this script; run it by hand after editing
# a project.conf. Files in /etc/caddy/sites that do not start with "boinc-" are not touched.
set -euo pipefail

DATA_ROOT="${DATA_ROOT:-/srv/boinc}"
CADDY_SITES="${CADDY_SITES:-/etc/caddy/sites}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
MARKER="# managed by boinc-stack scripts/caddy-sync.sh - do not edit"

[ "$(id -u)" -eq 0 ] || { echo "Please run as root."; exit 1; }
[ -d "${CADDY_SITES}" ] || { echo "WARNING: ${CADDY_SITES} missing, Caddy not configured (see proxy/README.md)"; exit 0; }

site_key() { echo "$1" | sed -E 's#^[a-z]+://##; s#[^A-Za-z0-9.-]+#_#g; s#_+$##'; }

# --- collect projects per site address
declare -A SITE_PROJECTS=() SITE_BIND=() SITE_ADDR=()
for conf in "${DATA_ROOT}"/*/project.conf; do
    [ -f "$conf" ] || continue
    PROJECT="" WEB_PORT="" SITE_ADDRESS="" BIND_IP=""
    # shellcheck disable=SC1090
    . "$conf"
    [ -n "$PROJECT" ] && [ -n "$WEB_PORT" ] && [ -n "$SITE_ADDRESS" ] || { echo "WARNING: incomplete $conf, skipped"; continue; }
    key="$(site_key "$SITE_ADDRESS")"
    SITE_ADDR[$key]="$SITE_ADDRESS"
    SITE_PROJECTS[$key]="${SITE_PROJECTS[$key]:-} ${PROJECT}:${WEB_PORT}"
    if [ -n "$BIND_IP" ]; then
        if [ -n "${SITE_BIND[$key]:-}" ] && [ "${SITE_BIND[$key]}" != "$BIND_IP" ]; then
            echo "WARNING: projects on ${SITE_ADDRESS} request different bind IPs, using ${SITE_BIND[$key]}"
        else
            SITE_BIND[$key]="$BIND_IP"
        fi
    fi
done

# --- write into a staging directory first, swap in only if Caddy accepts it
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

for key in "${!SITE_PROJECTS[@]}"; do
    f="${stage}/boinc-${key}.caddy"
    read -r -a entries <<< "${SITE_PROJECTS[$key]}"
    {
        echo "$MARKER"
        echo "${SITE_ADDR[$key]} {"
        [ -n "${SITE_BIND[$key]:-}" ] && printf '\tbind %s\n' "${SITE_BIND[$key]}"
        printf '\t# do not reveal server software (Caddy and Apache)\n'
        printf '\theader -Server\n'
        printf '\tlog {\n\t\toutput file /var/log/caddy/boinc-%s.log\n\t}\n' "$key"
        for e in "${entries[@]}"; do
            p="${e%%:*}" port="${e##*:}"
            printf '\n\t# project %s\n' "$p"
            printf '\t@%s path /%s /%s/* /%s_ops /%s_ops/* /%s_cgi /%s_cgi/*\n' "$p" "$p" "$p" "$p" "$p" "$p" "$p"
            printf '\thandle @%s {\n\t\treverse_proxy 127.0.0.1:%s {\n\t\t\theader_down -Server\n\t\t}\n\t}\n' "$p" "$port"
        done
        if [ "${#entries[@]}" -eq 1 ]; then
            printf '\n\tredir / /%s/ 302\n' "${entries[0]%%:*}"
        fi
        printf '\n\thandle {\n\t\trespond "Not found" 404\n\t}\n'
        echo "}"
    } > "$f"
done

# --- swap: back up managed (and old per-project) files, install new ones, validate
backup="$(mktemp -d)"
shopt -s nullglob
for f in "${CADDY_SITES}"/*.caddy; do
    first="$(head -n1 "$f")"
    case "$(basename "$f")" in
        boinc-*) mv "$f" "$backup/" ;;
        *) [[ "$first" == "# BOINC project "* ]] && mv "$f" "$backup/" ;;   # pre-sync format
    esac
done
cp "$stage"/*.caddy "${CADDY_SITES}/" 2>/dev/null || true

if command -v caddy >/dev/null && ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
    echo "ERROR: Caddy rejects the generated configuration, restoring the previous one:"
    caddy validate --config "$CADDYFILE" --adapter caddyfile 2>&1 | grep -i error | tail -3
    rm -f "${CADDY_SITES}"/boinc-*.caddy
    cp "$backup"/*.caddy "${CADDY_SITES}/" 2>/dev/null || true
    rm -rf "$backup"
    exit 1
fi
rm -rf "$backup"

for key in "${!SITE_PROJECTS[@]}"; do
    echo "==> Caddy site ${SITE_ADDR[$key]}:${SITE_PROJECTS[$key]}"
done
if systemctl is-active --quiet caddy 2>/dev/null; then
    systemctl reload caddy && echo "==> Caddy reloaded"
fi
