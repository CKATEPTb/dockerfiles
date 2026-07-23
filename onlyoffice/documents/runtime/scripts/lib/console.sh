#!/usr/bin/env bash

CONSOLE_PID=''

console_help() {
	cat <<'EOF'
================ ONLYOFFICE Docs · Pterodactyl console ================

  help                         Show this command list.
  status                       Service PIDs and health.
  version                      Installed ONLYOFFICE Docs package version.
  health                       Check the internal and public health endpoints.
  jwt:show                     Show the JWT secret for the Nextcloud connector.
  logs                         Show persistent log locations.
  logs:tail <source> [lines]   Tail nginx, docservice, converter, or shutdown.
  nginx:test                   Validate the generated Nginx configuration.
  prepare-shutdown             Drain active editors before a planned restart.

Nextcloud integration
  ONLYOFFICE Docs address: https://office.example.com/
  Secret key:              output of jwt:show
  Authorization header:    JWT_HEADER (Authorization by default)

No public database, TCP side-port, or UDP allocation is used. HTTP and
WebSocket traffic share the server's single Pterodactyl allocation.
=======================================================================
EOF
}

console_status() {
	local name
	printf 'ONLYOFFICE Docs %s\n' "$(onlyoffice_version)"
	for name in docservice converter nginx; do
		if service_is_running "$name"; then
			printf '  %-12s running (pid %s)\n' "$name" "${SERVICE_PIDS[$name]}"
		else
			printf '  %-12s stopped\n' "$name"
		fi
	done
	if onlyoffice_health; then
		printf '  health       OK\n'
	else
		printf '  health       FAILED\n'
		return 1
	fi
}

console_health() {
	local internal
	local public
	internal="$(curl -fsS --max-time 5 http://127.0.0.1:8000/healthcheck 2>/dev/null || true)"
	public="$(curl -fsS --max-time 5 -H 'Host: localhost' \
		"http://127.0.0.1:${SERVER_PORT:-8080}/healthcheck" 2>/dev/null || true)"
	printf 'internal 127.0.0.1:8000: %s\n' "${internal:-FAILED}"
	printf 'public allocation:          %s\n' "${public:-FAILED}"
	[[ "$internal" == *true* && "$public" == *true* ]]
}

console_log_overview() {
	cat <<EOF
Persistent logs: ${LOG_DIR}
  nginx       ${LOG_DIR}/nginx-access.log and nginx-error.log
  docservice  ${LOG_DIR}/docservice-stdout.log and docservice-stderr.log
  converter   ${LOG_DIR}/converter-stdout.log and converter-stderr.log
  application ${LOG_DIR}/onlyoffice/documentserver/
EOF
}

console_log_tail() {
	local source="${1:-}"
	local lines="${2:-50}"
	local file
	[[ "$lines" =~ ^[0-9]+$ && "$lines" -ge 1 && "$lines" -le 500 ]] || {
		warn 'Line count must be between 1 and 500.'
		return 2
	}
	case "$source" in
		nginx) file="${LOG_DIR}/nginx-access.log" ;;
		nginx-error) file="${LOG_DIR}/nginx-error.log" ;;
		docservice) file="${LOG_DIR}/docservice-stderr.log" ;;
		converter) file="${LOG_DIR}/converter-stderr.log" ;;
		shutdown) file="${LOG_DIR}/shutdown.log" ;;
		*)
			warn 'Usage: logs:tail <nginx|nginx-error|docservice|converter|shutdown> [1-500]'
			return 2
			;;
	esac
	[[ -f "$file" ]] || {
		warn "Log file does not exist yet: ${file}"
		return 1
	}
	tail -n "$lines" -- "$file"
}

dispatch_console_command() {
	local line="$1"
	local -a arguments=()
	read -r -a arguments <<< "$line"
	case "${arguments[0]:-}" in
		help|'?'|commands) console_help ;;
		status) console_status ;;
		version) onlyoffice_version; printf '\n' ;;
		health) console_health ;;
		jwt:show)
			printf 'JWT secret: %s\n' "$(read_secret "${SECRETS_DIR}/jwt_secret")"
			printf 'Store it as the ONLYOFFICE connector secret in Nextcloud.\n'
			;;
		logs) console_log_overview ;;
		logs:tail) console_log_tail "${arguments[1]:-}" "${arguments[2]:-50}" ;;
		nginx:test) nginx -t -c "${NGINX_DIR}/nginx.conf" -p "$SERVER_ROOT" ;;
		prepare-shutdown) run_prepare_shutdown 300 ;;
		'') return 0 ;;
		*)
			warn "Unknown console command '${arguments[0]}'. Type 'help' for available commands."
			return 2
			;;
	esac
}

console_loop() {
	local line
	while IFS= read -r line; do
		line="$(trim "$line")"
		[[ -n "$line" ]] || continue
		if ! dispatch_console_command "$line"; then
			warn "Console command failed; type 'help' for usage."
		fi
	done
}

start_console() {
	log "Pterodactyl command console is ready. Type 'help' to list commands."
	exec 3<&0
	console_loop <&3 &
	CONSOLE_PID=$!
}

stop_console() {
	if [[ -n "$CONSOLE_PID" ]] && kill -0 "$CONSOLE_PID" >/dev/null 2>&1; then
		kill -TERM "$CONSOLE_PID" >/dev/null 2>&1 || true
		wait "$CONSOLE_PID" 2>/dev/null || true
	fi
	exec 3<&- || true
}
