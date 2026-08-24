#!/bin/bash
CLUSTER="${1:?Cluster name required}"
SCRIPTDIR=$(dirname "$0")

"$SCRIPTDIR/log_cleanup.sh" "$CLUSTER"
"$SCRIPTDIR/delete.sh" "$CLUSTER"
