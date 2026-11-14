#!/bin/bash
set -e

recovery_conf() {
  # Fetch the WAL from the archive, so PostgreSQL can replay past the end of the backup
  echo "restore_command = '$SCRIPTDIR/archive_restore.sh $CLUSTER %f %p'"
  echo "recovery_target_action = promote"

  # PostgreSQL PITR can use a target timestamp, XID, or restore point name.
  if [ -n "${RESTORETARGETTIME:-}" ]; then
    echo "recovery_target_time = '$RESTORETARGETTIME'"
  elif [ -n "${RESTORETARGETXID:-}" ]; then
    echo "recovery_target_xid = '$RESTORETARGETXID'"
  elif [ -n "${RESTORETARGETNAME:-}" ]; then
    echo "recovery_target_name = '$RESTORETARGETNAME'"
  fi
}

earliest_backup() {
  "${WALG_BIN:-/usr/bin/wal-g-pg}" backup-list | sed -n '2{s/ .*//;p}'
}

latest_backup_before() {
  # backup-list shows the time in UTC (2026-08-20T12:30:00Z): compare in the same format
  local restore_date
  restore_date=$(date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ)
  "${WALG_BIN:-/usr/bin/wal-g-pg}" backup-list |
    awk -v RestoreDate="$restore_date" \
      '{if (FNR > 1 && $2 <= RestoreDate) {print $1}}' |
    tail -n1
}

# backup-fetch, working around a wal-g bug with symlinks in delta backups (wal-g/wal-g#910): stolon makes
# postgresql.auto.conf a symlink to /dev/null, every backup has it, and wal-g creates it for the full backup and again
# for each delta on top of it. That fails with "failed to create symlink <path>: ... file exists", and wal-g retries
# the part after a minute. Remove the symlink when wal-g reports this, so the retry succeeds. Costs a minute per delta.
backup_fetch() {
  local line link
  "${WALG_BIN:-/usr/bin/wal-g-pg}" backup-fetch "$1" "$2" 2>&1 |
    while IFS= read -r line; do
      echo "$line"
      case "$line" in
        *"failed to create symlink "*": file exists"*)
          link=${line#*failed to create symlink }
          link=${link%%: *}
          if [[ "$link" == "${1%/}"/* ]] && [ -L "$link" ]; then
            rm -f "$link"
            echo "restore.sh: removed symlink $link, so wal-g can create it again when it retries"
          fi
          ;;
      esac
    done
  return "${PIPESTATUS[0]}"
}

latest_backup() {
  # shellcheck disable=SC2016
  "${WALG_BIN:-/usr/bin/wal-g-pg}" backup-list | sed -n '${s/ .*//;p}'
}

#
# Arguments:
#
#   $1 = cluster name
#   $2 = restore directory (optional, defaults to PGDATA)
#   $3 = restore target (optional)
#
# Examples:
#
#   restore.sh cluster1
#   restore.sh cluster1 /data/restore/cluster1
#   restore.sh cluster1 /data/restore/cluster1 "2026-08-20 14:30:00"
#   restore.sh cluster1 /data/restore/cluster1 12345678
#   restore.sh cluster1 /data/restore/cluster1 before_migration
#

SCRIPTDIR=$(dirname "$(readlink -f "$0")")
CLUSTER="${1:?Cluster name required}"
CONFIG="/etc/default/wal-g-${CLUSTER}"

if [ ! -r "$CONFIG" ]; then
  echo "WAL-G configuration not found: $CONFIG" >&2
  exit 1
fi

# Load cluster-specific WAL-G/PostgreSQL configuration.
eval "$(sed '/#/d;s/^/export /' "$CONFIG")"

PGRESTORE="${2:-${PGRESTORE:-$PGDATA}}"
RESTORETARGETINPUT="${3:-${RESTORETARGETINPUT:-}}"

# When restoring outside the normal PGDATA, use a separate PostgreSQL port.
# Example:
#   cluster1: PGPORT=5432 -> restore port 15432
#   cluster2: PGPORT=5433 -> restore port 15433
PGRESTOREPORT="${PGRESTOREPORT:-$((PGPORT + 10000))}"

mkdir -p "$PGRESTORE"

if [ -e "$PGRESTORE/PG_VERSION" ]; then
  echo "File $PGRESTORE/PG_VERSION exists."
  echo "This is not an empty data directory."
  echo "Clean the directory or choose another restore directory, then rerun this script."
  exit 1
fi

#
# Determine which backup to fetch and, if applicable, which PITR target
# PostgreSQL should recover to.
#
if [ -z "$RESTORETARGETINPUT" ]; then

  # No target supplied: restore the latest backup.
  RESTORETARGET=$(latest_backup)

elif [[ "$RESTORETARGETINPUT" =~ ^[0-9]+$ ]]; then

  # Numeric target: assume PostgreSQL transaction ID.
  echo "$RESTORETARGETINPUT seems like an XID."
  echo "We cannot determine exactly which backup contains this XID."
  echo "Restoring the earliest available backup and leaving PITR to PostgreSQL."

  RESTORETARGET=$(earliest_backup)
  RESTORETARGETXID="$RESTORETARGETINPUT"

else

  # First try interpreting the value as a date/time.
  if RESTORETARGETTIME=$(
    date -d "$RESTORETARGETINPUT" --rfc-3339 seconds 2>/dev/null
  ); then

    echo "$RESTORETARGETINPUT seems like a timestamp."

    RESTORETARGET=$(latest_backup_before "$RESTORETARGETTIME")

    if [ -z "$RESTORETARGET" ]; then
      echo "No WAL-G backup was found before $RESTORETARGETTIME." >&2
      exit 1
    fi

  else

    RESTORETARGETTIME=""

    # Not a timestamp or XID: assume PostgreSQL restore point name.
    echo "$RESTORETARGETINPUT does not seem like a date or XID."
    echo "Assuming it is a PostgreSQL recovery target name."
    echo "We cannot determine exactly which backup contains this restore point."
    echo "Restoring the earliest available backup and leaving PITR to PostgreSQL."

    RESTORETARGET=$(earliest_backup)
    RESTORETARGETNAME="$RESTORETARGETINPUT"

  fi
fi

if [ -z "$RESTORETARGET" ]; then
  echo "Could not determine a WAL-G backup to restore." >&2
  exit 1
fi

echo "Fetching backup $RESTORETARGET into $PGRESTORE"

backup_fetch "$PGRESTORE" "$RESTORETARGET"

chmod 0700 "$PGRESTORE"

# wal-g restores postgresql.auto.conf of stolon (a symlink to /dev/null) as a symlink to a path that doesn't exist (or
# to itself). Remove it: PostgreSQL doesn't need it, and stolon creates it again.
if [ -L "$PGRESTORE/postgresql.auto.conf" ] && [ ! -e "$PGRESTORE/postgresql.auto.conf" ]; then
  rm -f "$PGRESTORE/postgresql.auto.conf"
fi

#
# Determine PostgreSQL version from the restored backup itself.
#
PGVERSION=$(cat "$PGRESTORE/PG_VERSION")

# wal-g doesn't restore pg_wal: it leaves out its contents, and the directory itself when it is a symlink (the wal on
# its own disk, as with stolon). PostgreSQL doesn't start without it.
if [ "$PGVERSION" -ge 10 ]; then
  WALDIR="$PGRESTORE/pg_wal"
else
  WALDIR="$PGRESTORE/pg_xlog"
fi
if [ ! -d "$WALDIR" ]; then
  mkdir -m 0700 "$WALDIR"
fi

#
# If we're restoring somewhere other than the cluster's normal PGDATA,
# make sure the restored PostgreSQL instance cannot conflict with the
# running Stolon instance and doesn't archive WAL back into the repository.
#
if [ "$PGRESTORE" != "$PGDATA" ]; then
  {
    echo
    echo "# Added by WAL-G restore.sh"
    echo "port = $PGRESTOREPORT"
    echo "archive_command = '/bin/true'"
  } >> "$PGRESTORE/postgresql.conf"
fi

if [ "$PGVERSION" -ge 12 ]; then
  touch "$PGRESTORE/recovery.signal"
  recovery_conf >> "$PGRESTORE/postgresql.conf"
else
  recovery_conf >> "$PGRESTORE/recovery.conf"
fi

echo "Starting restored PostgreSQL instance from $PGRESTORE"

"$PGBIN/pg_ctl" start -D "$PGRESTORE"
