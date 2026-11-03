#!/bin/bash
# Creates the ZFS datasets for a new BOINC project (run as root, BEFORE new-project.sh):
#
#   <parent>/<project>          mountpoint ${DATA_ROOT}/<project>   env files, project.conf
#   <parent>/<project>/db       recordsize=16K, lz4                 MariaDB data
#   <parent>/<project>/boinc    recordsize=1M                       project dir, uploads, results, _backup/
#   <parent>/<project>/backup   recordsize=1M                       daily dumps of backup.sh
#
# The project dataset gets compression=zstd and atime=off, the children inherit them
# (db overrides compression with lz4). The mountpoints are always under DATA_ROOT
# (default /srv/boinc), so new-project.sh, backup.sh, status.sh and remove-project.sh
# find the project as usual; the admin only chooses the pool/parent dataset.
#
# Writes ${ZFS_CONF_DIR}/<project>.conf (default /etc/boinc-stack/zfs/). new-project.sh
# uses the datasets if this file exists, remove-project.sh destroys or renames them.
#
# Examples:
#   ./zfs-project.sh -n rkfold -d tank/boinc
#   ./zfs-project.sh -n rkfold -d tank/boinc --dry-run
set -euo pipefail
DATA_ROOT="${DATA_ROOT:-/srv/boinc}"
ZFS_CONF_DIR="${ZFS_CONF_DIR:-/etc/boinc-stack/zfs}"

usage() {
    cat <<EOF
Usage: $0 -n SHORTNAME -d PARENT_DATASET [--dry-run]
  -n  short name of the project (as for new-project.sh)
  -d  existing parent dataset, e.g. tank/boinc. Create it once with e.g.
        zfs create -o mountpoint=${DATA_ROOT} -o compression=zstd -o atime=off tank/boinc
  --dry-run  only show the zfs commands
Environment: DATA_ROOT (${DATA_ROOT}), ZFS_CONF_DIR (${ZFS_CONF_DIR})
EOF
    exit 1
}

PROJECT="" PARENT="" DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        -n) PROJECT="$2"; shift 2 ;;
        -d) PARENT="${2%/}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) usage ;;
    esac
done
[ -n "$PROJECT" ] && [ -n "$PARENT" ] || usage
[[ "$PROJECT" =~ ^[a-z][a-z0-9]{1,15}$ ]] || { echo "Invalid short name: $PROJECT (lowercase letters and digits, 2-16 chars, starting with a letter)"; exit 1; }
[ "$DRY" -eq 1 ] || [ "$(id -u)" -eq 0 ] || { echo "Please run as root."; exit 1; }
command -v zfs >/dev/null || { echo "Missing: zfs (apt install zfsutils-linux)"; exit 1; }

DS="${PARENT}/${PROJECT}"
DATA_DIR="${DATA_ROOT}/${PROJECT}"
CONF="${ZFS_CONF_DIR}/${PROJECT}.conf"

zfs list -H -o name "${PARENT}" >/dev/null 2>&1 || { echo "Parent dataset ${PARENT} does not exist (see -d in the usage)."; exit 1; }
zfs list -H -o name "${DS}" >/dev/null 2>&1 && { echo "Dataset ${DS} already exists. Aborting."; exit 1; }
[ -e "${CONF}" ] && { echo "${CONF} already exists. Aborting."; exit 1; }
if [ -e "${DATA_DIR}" ] && [ -n "$(ls -A "${DATA_DIR}" 2>/dev/null)" ]; then
    echo "${DATA_DIR} exists and is not empty. Aborting."; exit 1
fi

run() {
    echo "+ $*"
    [ "$DRY" -eq 1 ] || "$@"
}

echo "==> ZFS datasets for project ${PROJECT} under ${PARENT}, mounted at ${DATA_DIR}"
run zfs create -o mountpoint="${DATA_DIR}" -o compression=zstd -o atime=off "${DS}"
# MariaDB/InnoDB: 16K pages, fast compression
run zfs create -o recordsize=16K -o compression=lz4 "${DS}/db"
# project files, uploads, results and dumps: large records compress better
run zfs create -o recordsize=1M "${DS}/boinc"
run zfs create -o recordsize=1M "${DS}/backup"

if [ "$DRY" -eq 1 ]; then
    echo "(dry run: nothing created, ${CONF} not written)"
    exit 0
fi

mkdir -p "${ZFS_CONF_DIR}"
cat > "${CONF}" <<EOF
# ZFS datasets of BOINC project ${PROJECT}, written by zfs-project.sh on $(date -Iseconds).
# new-project.sh uses them if this file exists; remove-project.sh destroys or renames them.
PROJECT=${PROJECT}
DATA_DIR=${DATA_DIR}
ZFS_DATASET=${DS}
ZFS_DATASETS="${DS} ${DS}/db ${DS}/boinc ${DS}/backup"
EOF
echo "==> written: ${CONF}"
zfs list -r -o name,mountpoint,recordsize,compression,atime "${DS}"
echo
echo "Next: ./new-project.sh -n ${PROJECT} ...  (uses these datasets)"
