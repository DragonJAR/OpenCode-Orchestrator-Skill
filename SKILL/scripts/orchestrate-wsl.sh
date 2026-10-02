#!/bin/sh
# Explicit dispatch for WSL. Usage: orchestrate-wsl.sh <subcmd> [args]
exec sh "$(dirname "$0")/orchestrate.sh" --os wsl "$@"
