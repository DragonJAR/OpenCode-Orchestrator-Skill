#!/bin/sh
# Dispatch explícito para Linux. Uso: orchestrate-linux.sh <subcmd> [args]
exec sh "$(dirname "$0")/orchestrate.sh" --os linux "$@"
