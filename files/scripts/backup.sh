#!/bin/bash
set -e

function backup() {
  echo
  # if there are existing backups younger then WALG_BACKUP_SKIP_WINDOW, then we can skip backup.
  SKIP_AFTER=$(date -d "0${WALG_BACKUP_SKIP_WINDOW} hour ago" --iso-8601=seconds)
  BACKUPS_SINCE=$(/usr/local/bin/wal-g-pg backup-list | awk -v skipAfter="$SKIP_AFTER" '{if (FNR>1 && skipAfter<=$2) {print}}' | wc -l)
  if [ "${BACKUPS_SINCE}" -gt 0 ]; then
    echo "There is already ${BACKUPS_SINCE} backups since ${SKIP_AFTER} (WALG_BACKUP_SKIP_WINDOW of ${WALG_BACKUP_SKIP_WINDOW})."
    echo "So I am skipping backup on this node."
    return 0
  fi
  
  "$SCRIPTDIR/maintenance.sh" "$CLUSTER"
  
  echo "Pushing backup"
  /usr/local/bin/wal-g-pg backup-push "${PGDATA}"
  
  "$SCRIPTDIR/maintenance.sh" "$CLUSTER"
}

SCRIPTDIR=$(dirname "$0")

# WAL-g config laden
CLUSTER="${1:?Cluster name required}"
CONFIG="/etc/default/wal-g-${CLUSTER}"

if [ ! -r "$CONFIG" ]; then
    echo "WAL-G configuration not found: $CONFIG" >&2
    exit 1
fi

eval "$(sed '/#/d;s/^/export /' "$CONFIG")"

# log output to a logfile in the logdir
WALG_LOG_FOLDER=${WALG_LOG_FOLDER:-/var/log/wal-g}
WALG_LOGFILE="$WALG_LOG_FOLDER/$(date +%Y%m%d)_$(basename $0 .sh).log"
TMPLOGFILE=$(mktemp)

backup 2>&1 | tee -a "$WALG_LOGFILE" > "$TMPLOGFILE"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  cat "$TMPLOGFILE"
  exit 1
fi

