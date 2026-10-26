#!/bin/bash
# Shows the containers of all BOINC projects on this host (run as root).
# Rootless Podman keeps a separate container store per user, so "podman ps" as root
# only shows root's own containers. This script asks each project user instead.
#   ./status.sh            all projects
#   ./status.sh <project>  one project
#   ./status.sh -a         include stopped containers
set -uo pipefail

DATA_ROOT="${DATA_ROOT:-/srv/boinc}"
ALL="" ONLY=""
for arg in "$@"; do
    case "$arg" in
        -a) ALL="--all" ;;
        *)  ONLY="$arg" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "Please run as root."; exit 1; }

found=0
for conf in "${DATA_ROOT}"/*/project.conf; do
    [ -f "$conf" ] || continue
    PROJECT="" USER_NAME="" WEB_PORT="" SITE_ADDRESS=""
    # shellcheck disable=SC1090
    . "$conf"
    [ -n "$ONLY" ] && [ "$ONLY" != "$PROJECT" ] && continue
    found=1
    echo "=== ${PROJECT}  (user ${USER_NAME}, ${SITE_ADDRESS} -> 127.0.0.1:${WEB_PORT})"
    if ! uid="$(id -u "$USER_NAME" 2>/dev/null)"; then
        echo "    user ${USER_NAME} does not exist"
        continue
    fi
    runuser -u "$USER_NAME" -- env XDG_RUNTIME_DIR="/run/user/${uid}" \
        podman ps ${ALL} --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" \
        || echo "    podman not reachable for ${USER_NAME} (linger enabled?)"
    echo
done
[ "$found" -eq 1 ] || echo "No projects found in ${DATA_ROOT}${ONLY:+ matching '${ONLY}'}."
