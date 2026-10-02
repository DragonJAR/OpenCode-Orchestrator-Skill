#!/bin/sh
# Dispatch explícito para WSL. Uso: orchestrate-wsl.sh <subcmd> [args]
exec sh "$(dirname "$0")/orchestrate.sh" --os wsl "$@"
