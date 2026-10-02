#!/bin/sh
# Explicit dispatch for Windows Git Bash. Usage: orchestrate-windows.sh <subcmd> [args]
exec sh "$(dirname "$0")/orchestrate.sh" --os windows-gbash "$@"
