#!/bin/bash
set -e

function list_backups() {
	echo "BACKUP:"
	echo "======="
	/usr/local/bin/wal-g-pg backup-list
	echo
	echo "WAL:"
	echo "===="
	/usr/local/bin/wal-g-pg wal-show
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

list_backups
