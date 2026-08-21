#!/bin/bash
set -e

recovery_conf() {
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
  /usr/local/bin/wal-g-pg backup-list | sed -n '2{s/ .*//;p}'
}

latest_backup_before() {
  /usr/local/bin/wal-g-pg backup-list |
    awk -v RestoreDate="$1" \
      '{if (FNR > 1 && $2 <= RestoreDate) {print $1}}' |
    tail -n1
}

latest_backup() {
  # shellcheck disable=SC2016
  /usr/local/bin/wal-g-pg backup-list | sed -n '${s/ .*//;p}'
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

/usr/local/bin/wal-g-pg backup-fetch \
  "$PGRESTORE" \
  "$RESTORETARGET"

chmod 0700 "$PGRESTORE"

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

#
# Determine PostgreSQL version from the restored backup itself.
#
PGVERSION=$(cat "$PGRESTORE/PG_VERSION")

if [ "$PGVERSION" -ge 12 ]; then
  touch "$PGRESTORE/recovery.signal"
  recovery_conf >> "$PGRESTORE/postgresql.conf"
else
  recovery_conf >> "$PGRESTORE/recovery.conf"
fi

echo "Starting restored PostgreSQL instance from $PGRESTORE"

"$PGBIN/pg_ctl" start -D "$PGRESTORE"
