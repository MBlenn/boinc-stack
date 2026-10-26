#!/bin/bash
# DB dump of all (or one) BOINC projects to /srv/boinc/<project>/backup/, retention KEEP_DAYS.
# Run as root, e.g. daily via systemd timer or cron:
#   15 3 * * *  /opt/boinc-stack/scripts/backup.sh [shortname]
# Additionally back up the project directory (/srv/boinc/<project>/boinc) and the dumps to an
# off-site location with restic/borg. Do NOT keep the code signing key on the server.
set -euo pipefail

DATA_ROOT="${DATA_ROOT:-/srv/boinc}"
KEEP_DAYS="${KEEP_DAYS:-14}"
ONLY="${1:-}"

for conf in "${DATA_ROOT}"/*/project.conf; do
    [ -f "$conf" ] || continue
    # shellcheck disable=SC1090
    . "$conf"
    [ -n "$ONLY" ] && [ "$ONLY" != "$PROJECT" ] && continue
    uid="$(id -u "$USER_NAME")"
    dir="${DATA_ROOT}/${PROJECT}/backup"
    install -d -o "$USER_NAME" -g "$USER_NAME" -m 750 "$dir"
    out="${dir}/db-$(date +%Y%m%d-%H%M%S).sql.gz"
    echo "==> ${PROJECT}: ${out}"
    runuser -u "$USER_NAME" -- env XDG_RUNTIME_DIR="/run/user/${uid}" \
        podman exec "${PROJECT}-db" sh -c \
        'mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" --single-transaction --routines --triggers "$MARIADB_DATABASE"' \
        | gzip > "${out}.tmp"
    mv "${out}.tmp" "$out"
    chown "$USER_NAME:$USER_NAME" "$out"
    find "$dir" -name 'db-*.sql.gz' -mtime +"${KEEP_DAYS}" -delete
done
