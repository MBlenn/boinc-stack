#!/bin/bash
# Removes a BOINC project created by new-project.sh (run as root):
#   - stops the project's units and removes containers, images and networks of the project user
#   - removes its routes from the Caddy configuration (caddy-sync.sh)
#   - deletes the Linux user boinc-<project> including its home directory
#   - deletes /srv/boinc/<project> (database, project directory, backups)
#     or, with --keep-data, moves it to /srv/boinc/_removed/<project>-<timestamp>
#
# Examples:
#   ./remove-project.sh -n test1              # asks for confirmation
#   ./remove-project.sh -n test1 --keep-data  # keep DB and project files
#   ./remove-project.sh -n test1 -y           # no confirmation (scripted tests)
set -euo pipefail

DATA_ROOT="${DATA_ROOT:-/srv/boinc}"

usage() {
    cat <<EOF
Usage: $0 -n PROJECT [--keep-data] [-y]
  -n           short name of the project (as given to new-project.sh)
  --keep-data  do not delete ${DATA_ROOT}/<project>, move it to ${DATA_ROOT}/_removed/ instead
  -y           do not ask for confirmation
EOF
    exit 1
}

PROJECT="" KEEP_DATA=0 YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        -n) PROJECT="$2"; shift 2 ;;
        --keep-data) KEEP_DATA=1; shift ;;
        -y) YES=1; shift ;;
        *) usage ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "Please run as root."; exit 1; }
[ -n "$PROJECT" ] || usage
[[ "$PROJECT" =~ ^[a-z][a-z0-9]{1,15}$ ]] || { echo "Invalid short name: $PROJECT (lowercase letters and digits, 2-16 chars)"; exit 1; }

DATA_DIR="${DATA_ROOT}/${PROJECT}"
USER_NAME="boinc-${PROJECT}"
if [ -f "${DATA_DIR}/project.conf" ]; then
    # shellcheck disable=SC1091
    . "${DATA_DIR}/project.conf"
fi

USER_EXISTS=0
id "${USER_NAME}" >/dev/null 2>&1 && USER_EXISTS=1
if [ "$USER_EXISTS" -eq 0 ] && [ ! -e "${DATA_DIR}" ]; then
    echo "Nothing found for project '${PROJECT}' (no user ${USER_NAME}, no ${DATA_DIR})."
    exit 0
fi

echo "This removes project '${PROJECT}':"
[ "$USER_EXISTS" -eq 1 ] && echo "  - user ${USER_NAME} with all its containers, images and home directory"
echo "  - its routes in the Caddy configuration"
if [ -e "${DATA_DIR}" ]; then
    if [ "$KEEP_DATA" -eq 1 ]; then
        echo "  - ${DATA_DIR} is MOVED to ${DATA_ROOT}/_removed/"
    else
        echo "  - ${DATA_DIR} is DELETED (database, project files, keys, backups)"
    fi
fi
if [ "$YES" -ne 1 ]; then
    read -r -p "Type the project name to confirm: " answer
    [ "$answer" = "$PROJECT" ] || { echo "Aborted."; exit 1; }
fi

# --- containers and units of the project user
if [ "$USER_EXISTS" -eq 1 ]; then
    USER_UID="$(id -u "${USER_NAME}")"
    USER_HOME="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
    as_user() {
        runuser -u "${USER_NAME}" -- env XDG_RUNTIME_DIR="/run/user/${USER_UID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" "$@"
    }

    if [ -S "/run/user/${USER_UID}/bus" ]; then
        echo "==> stopping units"
        systemctl --user -M "${USER_NAME}@" stop \
            "${PROJECT}-daemons.service" "${PROJECT}-web.service" "${PROJECT}-db.service" \
            "${PROJECT}-network.service" podman-auto-update.timer 2>/dev/null || true
        systemctl --user -M "${USER_NAME}@" disable podman-auto-update.timer 2>/dev/null || true
    fi

    echo "==> removing quadlet units"
    rm -f "${USER_HOME}/.config/containers/systemd/${PROJECT}".network \
          "${USER_HOME}/.config/containers/systemd/${PROJECT}"-*.container
    if [ -S "/run/user/${USER_UID}/bus" ]; then
        systemctl --user -M "${USER_NAME}@" daemon-reload 2>/dev/null || true
    fi

    echo "==> removing containers, images and networks of ${USER_NAME}"
    as_user podman system reset --force >/dev/null 2>&1 || true

    echo "==> removing user ${USER_NAME}"
    loginctl disable-linger "${USER_NAME}" 2>/dev/null || true
    loginctl terminate-user "${USER_NAME}" 2>/dev/null || true
    for _ in $(seq 1 20); do
        pgrep -u "${USER_NAME}" >/dev/null || break
        sleep 0.5
    done
    pkill -KILL -u "${USER_NAME}" 2>/dev/null || true
    # userdel also removes the subuid/subgid ranges
    userdel -r "${USER_NAME}" 2>/dev/null || userdel "${USER_NAME}"
    case "${USER_HOME}" in
        /home/boinc-"${PROJECT}") rm -rf "${USER_HOME}" ;;
    esac
fi


# --- data directory
if [ -e "${DATA_DIR}" ]; then
    if [ "$KEEP_DATA" -eq 1 ]; then
        target="${DATA_ROOT}/_removed/${PROJECT}-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "${DATA_ROOT}/_removed"
        mv "${DATA_DIR}" "${target}"
        chown -R root:root "${target}"
        chmod 700 "${target}"
        echo "==> data moved to ${target}"
    else
        echo "==> deleting ${DATA_DIR}"
        rm -rf "${DATA_DIR}"
    fi
fi

# --- Caddy: regenerate without this project
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"${REPO_DIR}/scripts/caddy-sync.sh" || echo "WARNING: Caddy configuration not updated (see above)"

echo "Project ${PROJECT} removed."
