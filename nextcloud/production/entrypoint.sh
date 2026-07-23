#!/usr/bin/env bash
set -Eeuo pipefail

cd /home/container
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [[ -z "${STARTUP:-}" ]]; then
	exec /bin/bash
fi

exec /bin/bash -c "$STARTUP"
