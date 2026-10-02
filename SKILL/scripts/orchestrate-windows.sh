#!/bin/sh
# Dispatch explícito para Windows Git Bash. Uso: orchestrate-windows.sh <subcmd> [args]
exec sh "$(dirname "$0")/orchestrate.sh" --os windows-gbash "$@"
