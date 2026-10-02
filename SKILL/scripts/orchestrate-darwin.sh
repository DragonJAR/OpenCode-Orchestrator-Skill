#!/bin/sh
# Explicit dispatch for macOS. Usage: orchestrate-darwin.sh <subcmd> [args]
exec sh "$(dirname "$0")/orchestrate.sh" --os darwin "$@"
