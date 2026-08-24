#!/bin/bash
set -e

CLUSTER="${1:?Cluster name required}"
WAL_PATH="${2:?WAL path required}"

CONFIG="/etc/default/wal-g-${CLUSTER}"


if [ ! -r "$CONFIG" ]; then
  echo "WAL-G configuration not found: $CONFIG" >&2
  exit 1
fi


eval "$(sed '/#/d;s/^/export /' "$CONFIG")"

/usr/local/bin/wal-g-pg wal-push "$WAL_PATH"