#!/bin/bash
# Creates a new BOINC project on this host (run as root):
#   - Linux user boinc-<shortname> with rootless Podman (linger on, units run without login)
#   - data directory /srv/boinc/<shortname>/{db,boinc} + env files with random passwords
#   - Quadlet units (network, db, web, daemons) in the project user's systemd user instance
#   - Caddy site /etc/caddy/sites/<shortname>.caddy
#
# Examples:
#   ./new-project.sh -n rkfold -l "Rechenkraft Folding" \
#       -u https://rkfold.example.org/ -s rkfold.example.org
#   ./new-project.sh -n test1 -l "Test project" -u http://192.0.2.10/ -s http://192.0.2.10
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE_DIR="${REPO_DIR}/project-template"
DATA_ROOT="${DATA_ROOT:-/srv/boinc}"
CADDY_SITES="${CADDY_SITES:-/etc/caddy/sites}"
BOINC_IMAGE="${BOINC_IMAGE:-ghcr.io/mblenn/boinc-server:1.6.2}"
MARIADB_IMAGE="${MARIADB_IMAGE:-docker.io/library/mariadb:12.3}"

usage() {
    cat <<EOF
Usage: $0 -n SHORTNAME -l LONGNAME -u URL_BASE -s SITE_ADDRESS [-p WEB_PORT] [-b BIND_IP] [--no-start]
  -n  short name: a-z, 0-9, 2-16 chars, starting with a letter (becomes Linux user boinc-<project>,
      container prefix, DB name and URL path /<project>/)
  -l  long name of the project (display name)
  -u  URL_BASE under which clients reach the project, e.g. https://rkfold.example.org/
      The master URL becomes URL_BASE/<shortname>/  (do not change it once in production!)
  -s  Caddy site address, e.g. rkfold.example.org (automatic TLS) or http://192.0.2.10
  -p  local port for the web container (default: next free port from 18081)
  -b  IP that Caddy binds to for this project (optional)
  --no-start  only create the units, do not start them
Environment: BOINC_IMAGE (${BOINC_IMAGE}), MARIADB_IMAGE (${MARIADB_IMAGE}), DATA_ROOT (${DATA_ROOT})
EOF
    exit 1
}

PROJECT="" PROJECT_LONGNAME="" URL_BASE="" SITE_ADDRESS="" WEB_PORT="" BIND_IP="" START=1
while [ $# -gt 0 ]; do
    case "$1" in
        -n) PROJECT="$2"; shift 2 ;;
        -l) PROJECT_LONGNAME="$2"; shift 2 ;;
        -u) URL_BASE="$2"; shift 2 ;;
        -s) SITE_ADDRESS="$2"; shift 2 ;;
        -p) WEB_PORT="$2"; shift 2 ;;
        -b) BIND_IP="$2"; shift 2 ;;
        --no-start) START=0; shift ;;
        *) usage ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "Please run as root."; exit 1; }
[ -n "$PROJECT" ] && [ -n "$PROJECT_LONGNAME" ] && [ -n "$URL_BASE" ] && [ -n "$SITE_ADDRESS" ] || usage
[[ "$PROJECT" =~ ^[a-z][a-z0-9]{1,15}$ ]] || { echo "Invalid short name: $PROJECT"; exit 1; }
for cmd in podman envsubst openssl loginctl; do
    command -v "$cmd" >/dev/null || { echo "Missing: $cmd (apt install podman gettext-base openssl)"; exit 1; }
done

USER_NAME="boinc-${PROJECT}"
DATA_DIR="${DATA_ROOT}/${PROJECT}"
[ -e "${DATA_DIR}" ] && { echo "${DATA_DIR} already exists. Aborting."; exit 1; }

# --- pick a free port
if [ -z "$WEB_PORT" ]; then
    WEB_PORT=18081
    while grep -qs "^WEB_PORT=${WEB_PORT}$" "${DATA_ROOT}"/*/project.conf \
          || ss -ltn "sport = :${WEB_PORT}" | grep -q LISTEN; do
        WEB_PORT=$((WEB_PORT + 1))
    done
fi

echo "==> project ${PROJECT}: user ${USER_NAME}, data ${DATA_DIR}, port 127.0.0.1:${WEB_PORT}"

# --- Linux user with subuid/subgid (for rootless Podman)
if ! id "${USER_NAME}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -c "BOINC project ${PROJECT}" "${USER_NAME}"
fi
# useradd normally assigns subuids itself; if not, take the next free range
next_subid() { awk -F: 'BEGIN{m=100000} {e=$2+$3; if (e>m) m=e} END{print m}' "$1" 2>/dev/null || echo 100000; }
if ! grep -q "^${USER_NAME}:" /etc/subuid 2>/dev/null; then
    s="$(next_subid /etc/subuid)"; usermod --add-subuids "${s}-$((s + 65535))" "${USER_NAME}"
fi
if ! grep -q "^${USER_NAME}:" /etc/subgid 2>/dev/null; then
    s="$(next_subid /etc/subgid)"; usermod --add-subgids "${s}-$((s + 65535))" "${USER_NAME}"
fi
USER_UID="$(id -u "${USER_NAME}")"
USER_HOME="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
loginctl enable-linger "${USER_NAME}"

# --- data directory + secrets
mkdir -p "${DATA_DIR}/db" "${DATA_DIR}/boinc"
DB_PASSWORD="$(openssl rand -hex 24)"
DB_ROOT_PASSWORD="$(openssl rand -hex 24)"
OPS_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=')"
export PROJECT PROJECT_LONGNAME URL_BASE DB_PASSWORD DB_ROOT_PASSWORD OPS_PASSWORD \
       DATA_DIR WEB_PORT BOINC_IMAGE MARIADB_IMAGE SITE_ADDRESS

umask 077
envsubst < "${TEMPLATE_DIR}/boinc.env.template" > "${DATA_DIR}/boinc.env"
envsubst < "${TEMPLATE_DIR}/db-root.env.template" > "${DATA_DIR}/db-root.env"
umask 022
cat > "${DATA_DIR}/project.conf" <<EOF
# Metadata for the host scripts (not read by containers)
PROJECT=${PROJECT}
USER_NAME=${USER_NAME}
WEB_PORT=${WEB_PORT}
SITE_ADDRESS=${SITE_ADDRESS}
BIND_IP=${BIND_IP}
EOF
chown -R "${USER_NAME}:${USER_NAME}" "${DATA_DIR}"
chmod 750 "${DATA_DIR}"

# --- Quadlet units
QUADLET_DIR="${USER_HOME}/.config/containers/systemd"
mkdir -p "${QUADLET_DIR}"
VARS='${PROJECT} ${DATA_DIR} ${WEB_PORT} ${BOINC_IMAGE} ${MARIADB_IMAGE}'
envsubst "$VARS" < "${TEMPLATE_DIR}/quadlet/project.network"   > "${QUADLET_DIR}/${PROJECT}.network"
envsubst "$VARS" < "${TEMPLATE_DIR}/quadlet/db.container"      > "${QUADLET_DIR}/${PROJECT}-db.container"
envsubst "$VARS" < "${TEMPLATE_DIR}/quadlet/web.container"     > "${QUADLET_DIR}/${PROJECT}-web.container"
envsubst "$VARS" < "${TEMPLATE_DIR}/quadlet/daemons.container" > "${QUADLET_DIR}/${PROJECT}-daemons.container"
chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config"

# --- Caddy site
if [ -d "${CADDY_SITES}" ]; then
    if [ -n "${BIND_IP}" ]; then BIND_LINE="	bind ${BIND_IP}"; else BIND_LINE=""; fi
    export BIND_LINE
    envsubst '${PROJECT} ${WEB_PORT} ${SITE_ADDRESS} ${BIND_LINE}' \
        < "${TEMPLATE_DIR}/caddy-site.template" > "${CADDY_SITES}/${PROJECT}.caddy"
    if systemctl is-active --quiet caddy; then
        caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null && systemctl reload caddy
    fi
else
    echo "WARNING: ${CADDY_SITES} missing, Caddy site not created (see proxy/README.md)"
fi

# --- load and start the units (in the project user's systemd user instance)
user_systemctl() {
    systemctl --user -M "${USER_NAME}@" "$@"
}
# the user manager must be running (linger), wait briefly
for _ in $(seq 1 20); do
    [ -S "/run/user/${USER_UID}/bus" ] && break
    sleep 0.5
done
user_systemctl daemon-reload
# picks up rebuilt images (same tag) automatically, daily by default
user_systemctl enable --now podman-auto-update.timer
if [ "$START" -eq 1 ]; then
    echo "==> starting ${PROJECT}-daemons (pulls in db and web; images are downloaded if needed) ..."
    user_systemctl start "${PROJECT}-daemons.service"
fi

cat <<EOF

Done. Project ${PROJECT}
  Master URL:     ${URL_BASE%/}/${PROJECT}/
  Ops pages:      ${URL_BASE%/}/${PROJECT}_ops/   (user admin, password: ${OPS_PASSWORD})
  Data:           ${DATA_DIR}
  Project user:   ${USER_NAME}   (add SSH keys to ${USER_HOME}/.ssh/authorized_keys)

As ${USER_NAME} (e.g. ssh ${USER_NAME}@host or machinectl shell ${USER_NAME}@):
  systemctl --user status ${PROJECT}-web ${PROJECT}-daemons ${PROJECT}-db
  journalctl --user -u ${PROJECT}-daemons -f
  podman exec -it ${PROJECT}-daemons /usr/local/bin/entrypoint.sh shell

The ops password is also stored in ${DATA_DIR}/boinc.env.
EOF
