#!/bin/bash
set -e

CLUSTER="${1:?Cluster name required}"
WAL_PATH="${2:?WAL path required}"

CONFIG="/etc/default/wal-g-${CLUSTER}"
eval "$(sed '/#/d;s/^/export /' "$CONFIG")"

/usr/local/bin/wal-g-pg wal-push "$WAL_PATH"