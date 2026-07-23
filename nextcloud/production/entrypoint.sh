#!/usr/bin/env bash
set -Eeuo pipefail

cd /home/container

if [[ -z "${STARTUP:-}" ]]; then
	exec /bin/bash
fi

exec /bin/bash -lc "$STARTUP"
