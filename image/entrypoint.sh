#!/bin/bash
# Entrypoint for the BOINC server image.
#   web      Apache/PHP + scheduler CGI + upload handler (waits until the project exists)
#   daemons  creates the project on first start, runs the upgrade when the image carries a
#            newer BOINC release, then runs the BOINC daemons (bin/start, --cron every 5 min)
#   shell    interactive shell as boincadm in the project directory
#   *        any other command
set -euo pipefail

ROLE="${1:-web}"
shift || true

log() { echo "[entrypoint:${ROLE}] $*"; }
die() { log "ERROR: $*"; exit 1; }

: "${PROJECT:?PROJECT (short name) must be set}"
PROJECTS_DIR="/home/boincadm/projects"
PROOT="${PROJECTS_DIR}/${PROJECT}"
BACKUP_DIR="${PROJECTS_DIR}/_backup"
BOINC_SRC="${BOINC_SRC:-/usr/local/src/boinc}"
IMAGE_REF="$(cat "${BOINC_SRC}/BOINC_REF")"

DB_HOST="${DB_HOST:-${PROJECT}-db}"
DB_NAME="${DB_NAME:-${MARIADB_DATABASE:-${PROJECT}}}"
DB_USER="${DB_USER:-${MARIADB_USER:-${PROJECT}}}"
DB_PASSWORD="${DB_PASSWORD:-${MARIADB_PASSWORD:-}}"
BOINC_AUTO_UPGRADE="${BOINC_AUTO_UPGRADE:-1}"

as_boinc() {
    runuser -u boincadm -- env HOME=/home/boincadm USER=boincadm LOGNAME=boincadm "$@"
}
in_project() {
    as_boinc bash -c "cd '${PROOT}' && $*"
}

wait_db() {
    local n=0
    until mariadb-admin --host="${DB_HOST}" --user="${DB_USER}" --password="${DB_PASSWORD}" \
            ping --silent >/dev/null 2>&1; do
        n=$((n + 1))
        [ $n -gt 100 ] && die "database ${DB_HOST} not reachable"
        log "waiting for database ${DB_HOST} ..."
        sleep 3
    done
}

db_dump() {
    local target="$1"
    as_boinc mkdir -p "${BACKUP_DIR}"
    mariadb-dump --host="${DB_HOST}" --user="${DB_USER}" --password="${DB_PASSWORD}" \
        --single-transaction --routines --triggers "${DB_NAME}" \
        | gzip | as_boinc tee "${target}" >/dev/null
    log "DB dump written: ${target}"
}

init_project() {
    : "${URL_BASE:?URL_BASE must be set, e.g. https://project.example.org/}"
    : "${DB_PASSWORD:?DB_PASSWORD/MARIADB_PASSWORD must be set}"
    local url_base="${URL_BASE%/}/"
    local longname="${PROJECT_LONGNAME:-${PROJECT}}"

    log "creating project '${PROJECT}' (BOINC ${IMAGE_REF}, URL ${url_base}) ..."
    as_boinc mkdir -p "${PROJECTS_DIR}"
    # --drop_db_first: the MariaDB image has already created the (empty) database
    ( cd "${BOINC_SRC}/tools" && as_boinc ./make_project \
        --no_query --drop_db_first \
        --srcdir "${BOINC_SRC}" \
        --project_root "${PROOT}" \
        --project_host "$(hostname)" \
        --url_base "${url_base}" \
        --db_host "${DB_HOST}" --db_name "${DB_NAME}" \
        --db_user "${DB_USER}" --db_passwd "${DB_PASSWORD}" \
        --user_name boincadm \
        "${PROJECT}" "${longname}" )

    if [ -n "${OPS_USER:-}" ] && [ -n "${OPS_PASSWORD:-}" ]; then
        as_boinc htpasswd -cbB "${PROOT}/html/ops/.htpasswd" "${OPS_USER}" "${OPS_PASSWORD}"
        log "ops pages login created (user ${OPS_USER})"
    else
        log "WARNING: OPS_USER/OPS_PASSWORD not set, ops pages have no login"
    fi

    echo "${IMAGE_REF}" | as_boinc tee "${PROOT}/.boinc_image_ref" >/dev/null
    log "project created."
}

upgrade_project() {
    local current
    current="$(cat "${PROOT}/.boinc_image_ref" 2>/dev/null || echo unknown)"
    [ "${current}" = "${IMAGE_REF}" ] && return 0

    if [ "${BOINC_AUTO_UPGRADE}" != "1" ]; then
        log "WARNING: project is on '${current}', image is on '${IMAGE_REF}'. BOINC_AUTO_UPGRADE=0, not upgrading."
        return 0
    fi

    log "BOINC upgrade ${current} -> ${IMAGE_REF}"
    db_dump "${BACKUP_DIR}/pre-upgrade-$(date +%Y%m%d-%H%M%S)-${current//\//_}.sql.gz"
    # tools/upgrade asks twice (overwrite files, apply DB updates)
    # (yes || true): SIGPIPE from "yes" must not count as a failure under pipefail
    ( cd "${BOINC_SRC}" && (yes y || true) | as_boinc ./tools/upgrade --srcdir "${BOINC_SRC}" "${PROOT}" )
    echo "${IMAGE_REF}" | as_boinc tee "${PROOT}/.boinc_image_ref" >/dev/null
    log "upgrade finished."
}

check_host() {
    local cfg_host
    cfg_host="$(sed -n 's:.*<host>\(.*\)</host>.*:\1:p' "${PROOT}/config.xml" | head -1)"
    if [ "${cfg_host}" != "$(hostname)" ]; then
        log "WARNING: <host> in config.xml is '${cfg_host}', container hostname is '$(hostname)'."
        log "         bin/start only starts daemons for its own host. Check the hostname in the Quadlet."
    fi
}

role_daemons() {
    wait_db
    if [ ! -f "${PROOT}/config.xml" ]; then
        init_project
    else
        upgrade_project
    fi
    check_host

    stop_daemons() {
        log "stopping BOINC daemons ..."
        in_project bin/stop || true
        exit 0
    }
    trap stop_daemons TERM INT

    in_project bin/start
    log "daemons started. Periodic tasks run every 5 minutes (bin/start --cron)."
    while true; do
        sleep 300 &
        wait $!
        in_project bin/start --cron || log "bin/start --cron reported an error"
    done
}

role_web() {
    until [ -f "${PROOT}/config.xml" ] && [ -f "${PROOT}/${PROJECT}.httpd.conf" ] \
          && [ "$(cat "${PROOT}/.boinc_image_ref" 2>/dev/null)" = "${IMAGE_REF}" ]; do
        log "waiting for project ${PROJECT} (creation or upgrade runs in the daemons container) ..."
        sleep 5
    done

    cat > /etc/apache2/conf-enabled/zz-project.conf <<EOF
Include ${PROOT}/${PROJECT}.httpd.conf
RedirectMatch 302 ^/$ /${PROJECT}/
EOF

    set +u
    # shellcheck disable=SC1091
    . /etc/apache2/envvars
    set -u
    export APACHE_RUN_USER=boincadm APACHE_RUN_GROUP=boincadm
    mkdir -p "${APACHE_RUN_DIR}" "${APACHE_LOCK_DIR}"
    rm -f "${APACHE_PID_FILE}"
    log "starting Apache for ${PROJECT}"
    exec apache2 -DFOREGROUND
}

case "${ROLE}" in
    web)     role_web ;;
    daemons) role_daemons ;;
    shell)   cd "${PROOT}" 2>/dev/null || true; exec runuser -u boincadm -- bash -l ;;
    *)       exec "${ROLE}" "$@" ;;
esac
