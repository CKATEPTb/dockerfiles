#!/usr/bin/env bash
set -uo pipefail

readonly NODE_BINARY="$1"
readonly LOG_STREAM_ENTRYPOINT="$2"

child_pid=""
stop_requested=false
restart_delay=1

# Called indirectly by signal traps.
# shellcheck disable=SC2329
stop_child() {
	stop_requested=true
	if [[ -n "$child_pid" ]] && kill -0 "$child_pid" >/dev/null 2>&1; then
		kill -TERM "$child_pid" >/dev/null 2>&1 || true
	fi
}

trap stop_child INT TERM

while [[ "$stop_requested" == false ]]; do
	started_at="$(date +%s)"
	"$NODE_BINARY" "$LOG_STREAM_ENTRYPOINT" &
	child_pid=$!
	if wait "$child_pid"; then
		exit_status=0
	else
		exit_status=$?
	fi
	child_pid=""

	[[ "$stop_requested" == false ]] || break
	runtime_seconds=$(( $(date +%s) - started_at ))
	if [[ "$runtime_seconds" -ge 300 ]]; then
		restart_delay=1
	fi
	printf '[Nextcloud] WARNING: Compact log helper exited (status %s); restarting in %ss so log rotation remains active.\n' \
		"$exit_status" "$restart_delay" >&2

	sleep "$restart_delay" &
	child_pid=$!
	wait "$child_pid" 2>/dev/null || true
	child_pid=""
	[[ "$stop_requested" == false ]] || break
	if [[ "$restart_delay" -lt 60 ]]; then
		restart_delay=$((restart_delay * 2))
		[[ "$restart_delay" -le 60 ]] || restart_delay=60
	fi
done

exit 0
