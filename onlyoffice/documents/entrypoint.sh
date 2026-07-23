#!/usr/bin/env bash
set -Eeuo pipefail

readonly START_SCRIPT=/opt/onlyoffice-egg/runtime/scripts/start.sh

if [[ "$#" -gt 0 ]]; then
	exec "$@"
fi

exec /bin/bash "$START_SCRIPT"
