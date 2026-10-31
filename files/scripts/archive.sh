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

# wal-push retries forever while the storage is down, and PostgreSQL can't shut down while its archiver waits (so a
# restart, e.g. by stolon, hangs). Give up after WALG_ARCHIVE_TIMEOUT seconds (SIGKILL 10 seconds later): the archive
# command fails, and PostgreSQL keeps the WAL file and archives it again later.
exec timeout --kill-after=10 "${WALG_ARCHIVE_TIMEOUT:-60}" /usr/bin/wal-g-pg wal-push "$WAL_PATH"
