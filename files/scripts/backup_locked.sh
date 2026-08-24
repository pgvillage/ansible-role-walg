#!/bin/bash
set -e

function sleep_if_primary() {
	DELAY=${1:-10}
	PGROLE=$(psql -tc "select case when pg_is_in_recovery() then 'standby' else 'primary' end;" | xargs)
	echo "Postgres role is ${PGROLE}"
	if [ "$PGROLE" = 'primary' ]; then
		echo "Running on a primary. Sleep 10 seconds to give standbys the upper hand."
		sleep "$DELAY"
	fi
}

function run_locked_backup() {
	sleep_if_primary
	etcdctl lock "wal-g-${CLUSTER}" \
    "$SCRIPTDIR/backup.sh" "${CLUSTER}"
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

run_locked_backup 2>&1 | tee -a "$WALG_LOGFILE" >"$TMPLOGFILE"

if [ "${PIPESTATUS[0]}" -ne 0 ]; then
	cat "$TMPLOGFILE"
	exit 1
fi
