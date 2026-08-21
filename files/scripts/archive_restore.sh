#!/bin/bash

# WAL-g config laden
CLUSTER="${1:?Cluster name required}"
WAL_NAME="${2:?WAL name required}"
DESTINATION="${3:?Destination required}"

eval "$(sed '/#/d;s/^/export /' "/etc/default/wal-g-${CLUSTER}")"

/usr/local/bin/wal-g-pg wal-fetch "$WAL_NAME" "$DESTINATION"
