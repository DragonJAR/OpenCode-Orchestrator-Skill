#!/bin/sh
# Explicit dispatch for Linux. Usage: orchestrate-linux.sh <subcmd> [args]
exec sh "$(dirname "$0")/orchestrate.sh" --os linux "$@"
