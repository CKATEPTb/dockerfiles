#!/usr/bin/env bash

CONSOLE_PID=""

console_help() {
	local topic="${1:-}"
	case "$topic" in
		'')
			cat <<'EOF'
================ Nextcloud · Pterodactyl console ================

Overview
  help                          This compact help.
  commands                      Every command provided by Nextcloud and its apps.
  help <occ-command>            Detailed help, for example: help files:scan
  status | version              Installation and version status.

Users
  user:list                     List users.
  user:info <username>          User profile, quota, email, and status.
  user:add <username> [pass]    Create a user; omitted password is generated.
  user:password <user> [pass]   Reset a password; omitted password is generated.

Maintenance
  backup                        Verified full files + MariaDB backup.
  update                        Stepwise update to the highest offered release.
  update --backup               Full verified backup, then the same update.

Logs
  logs                          Show live-stream and raw-log locations.
  logs:tail <source> [lines]    Raw tail; use "help logs" for source names.

Advanced
  occ [command] [arguments...]  Run any native Nextcloud command.

Examples
  user:add alice
  user:password admin
  help user:add
  occ app:list
  occ files:scan --all
==================================================================
EOF
			;;
		occ|all|commands) occ list ;;
		backup)
			printf '%s\n' "backup" "  Enables maintenance mode if needed and writes a verified full backup under backups/."
			;;
		update)
			printf '%s\n' "update [--backup]" "  Repeats the official updater without skipping major versions." "  --backup creates a full files/database backup before the first update pass."
			;;
		logs|logs:tail)
			printf '%s\n' "logs" "logs:tail <nextcloud|audit|nginx|nginx-error|mariadb|redis|php-fpm|php-errors|whiteboard> [1-500]"
			;;
		user:password)
			printf '%s\n' "user:password <username> [password]" "  Without a password, generates a temporary one and prints it once."
			;;
		*) occ help "$topic" ;;
	esac
}

generate_user_password() {
	openssl rand -hex 16
}

console_user_password_command() {
	local action="$1"
	shift

	local username="${1:-}"
	[[ -n "$username" ]] || {
		warn "Usage: user:${action} <username> [password]"
		return 2
	}
	shift

	local password
	local generated=false
	if [[ "$#" -gt 0 ]]; then
		password="$*"
	else
		password="$(generate_user_password)"
		generated=true
	fi

	local -a occ_arguments
	case "$action" in
		add) occ_arguments=(user:add --password-from-env "$username") ;;
		password) occ_arguments=(user:resetpassword --password-from-env "$username") ;;
		*) return 2 ;;
	esac

	if ! (
		export OC_PASS="$password"
		occ "${occ_arguments[@]}"
	); then
		return 1
	fi

	if is_enabled "$generated"; then
		log "Temporary password for '${username}': ${password}"
		log "Save it now; it will not be shown again. The user should change it after signing in."
	fi
}

require_console_username() {
	local command="$1"
	local username="${2:-}"
	[[ -n "$username" ]] || {
		warn "Usage: ${command} <username>"
		return 2
	}
	occ "$command" "$username"
}

console_log_overview() {
	cat <<EOF
Compact live stream: ${CONSOLE_ACTIVITY_LOGS:-true}
  [WEB]   visits, HTTP errors, and 15-second request summaries
  [AUTH]  successful/failed logins and resolved user email
  [NC]    Nextcloud warnings/errors with duplicate collapsing
  [AUDIT] grouped administrative and file activity

Raw files:
  nextcloud  ${LOG_DIR}/nextcloud.log
  audit      ${LOG_DIR}/audit.log
  nginx      ${LOG_DIR}/nginx-access.log
  nginx-error ${LOG_DIR}/nginx-error.log
  mariadb    ${LOG_DIR}/mariadb.log
  redis      ${LOG_DIR}/redis.log
  php-fpm    ${LOG_DIR}/php-fpm.log
  php-errors ${LOG_DIR}/php-errors.log
  whiteboard ${LOG_DIR}/whiteboard.log
EOF
}

console_log_tail() {
	local source="${1:-}"
	local lines="${2:-50}"
	local file
	case "$source" in
		nextcloud) file="${LOG_DIR}/nextcloud.log" ;;
		audit) file="${LOG_DIR}/audit.log" ;;
		nginx) file="${LOG_DIR}/nginx-access.log" ;;
		nginx-error) file="${LOG_DIR}/nginx-error.log" ;;
		mariadb) file="${LOG_DIR}/mariadb.log" ;;
		redis) file="${LOG_DIR}/redis.log" ;;
		php-fpm) file="${LOG_DIR}/php-fpm.log" ;;
		php-errors) file="${LOG_DIR}/php-errors.log" ;;
		whiteboard) file="${LOG_DIR}/whiteboard.log" ;;
		*)
			warn "Usage: logs:tail <nextcloud|audit|nginx|nginx-error|mariadb|redis|php-fpm|php-errors|whiteboard> [1-500]"
			return 2
			;;
	esac
	[[ "$lines" =~ ^[0-9]+$ ]] && [[ "$lines" -ge 1 && "$lines" -le 500 ]] || {
		warn "Line count must be between 1 and 500."
		return 2
	}
	[[ -f "$file" ]] || {
		warn "Log file does not exist yet: ${file}"
		return 1
	}
	tail -n "$lines" -- "$file"
}

run_console_maintenance() (
	# Keep fatal errors and cleanup traps inside one command, so the console remains usable.
	trap 'recover_backup_maintenance_mode || true; maintenance_lock_release' EXIT
	"$@"
)

parse_console_arguments() {
	local line="$1"
	local destination="$2"
	local node
	local parser="${IMAGE_RUNTIME_ROOT}/scripts/parse-command.mjs"
	node="$(command -v node 2>/dev/null || true)"
	[[ -n "$node" && -x "$node" && -f "$parser" ]] || {
		warn "The safe console command parser is unavailable."
		return 1
	}
	printf '%s' "$line" | "$node" "$parser" > "$destination"
}

dispatch_console_command() {
	local line="$1"
	local parsed_file
	local -a arguments=()
	parsed_file="$(mktemp "${TMP_DIR}/console-arguments.XXXXXX")" || return 1
	if ! parse_console_arguments "$line" "$parsed_file"; then
		rm -f -- "$parsed_file"
		return 2
	fi
	mapfile -d '' -t arguments < "$parsed_file"
	rm -f -- "$parsed_file"

	case "${arguments[0]:-}" in
		help|'?') console_help "${arguments[1]:-}" ;;
		commands) occ list ;;
		status|version) occ status ;;
		user:list) occ user:list ;;
		user:info) require_console_username user:info "${arguments[1]:-}" ;;
		user:add) console_user_password_command add "${arguments[@]:1}" ;;
		user:password|user:resetpassword) console_user_password_command password "${arguments[@]:1}" ;;
		backup)
			[[ "${#arguments[@]}" -eq 1 ]] || { warn "Usage: backup"; return 2; }
			run_console_maintenance backup_nextcloud
			;;
		update) run_console_maintenance update_nextcloud "${arguments[@]:1}" ;;
		logs) console_log_overview ;;
		logs:tail) console_log_tail "${arguments[1]:-}" "${arguments[2]:-50}" ;;
		occ) occ "${arguments[@]:1}" ;;
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
