#!/usr/bin/env bash

declare -a SERVICE_PIDS=()
declare -a AUXILIARY_PIDS=()
MARIADB_PID=""
REDIS_PID=""
PHP_FPM_PID=""
WHITEBOARD_PID=""
NGINX_PID=""
LOG_STREAM_PID=""

configure_php_extensions() {
	local php_version="${PHP_VERSION:-8.4}"
	local php_bin="php${php_version}"
	local system_scan="/etc/php/${php_version}/cli/conf.d"
	local extension

	php_bin="$(resolve_command "$php_bin")"
	mkdir -p "${SERVER_ROOT}/php/conf.d"
	for extension in apcu redis imagick; do
		PHP_INI_SCAN_DIR="${system_scan}:${SERVER_ROOT}/php/conf.d" "$php_bin" \
			-c "${SERVER_ROOT}/php/php.ini" -r "exit(extension_loaded('${extension}') ? 0 : 1);" \
			|| fatal "Required PHP extension is missing from the image: ${extension}."
	done

	export PHP_CLI_BIN="$php_bin"
	export PHP_CLI_SCAN_DIR="${system_scan}:${SERVER_ROOT}/php/conf.d"
	export PHP_FPM_SCAN_DIR="/etc/php/${php_version}/fpm/conf.d:${SERVER_ROOT}/php/conf.d"
}

start_mariadb() {
	local mariadbd
	local mariadb
	local socket="${TMP_DIR}/mariadb.sock"
	local db_password

	mariadbd="$(resolve_command mariadbd)"
	mariadb="$(resolve_command mariadb)"
	[[ -d "${SERVER_ROOT}/services/mariadb/data/mysql" ]] || fatal "Embedded MariaDB data directory is not initialized. Reinstall the server."

	log "Starting embedded MariaDB."
	"$mariadbd" \
		--defaults-file="${SERVER_ROOT}/services/mariadb/my.cnf" \
		--datadir="${SERVER_ROOT}/services/mariadb/data" &
	MARIADB_PID=$!
	SERVICE_PIDS+=("$MARIADB_PID")

	for _ in {1..60}; do
		if "$mariadb" --protocol=socket --socket="$socket" --user=root --execute='SELECT 1' >/dev/null 2>&1; then
			break
		fi
		kill -0 "$MARIADB_PID" >/dev/null 2>&1 || fatal "MariaDB stopped during startup. See logs/mariadb.log."
		sleep 1
	done
	"$mariadb" --protocol=socket --socket="$socket" --user=root --execute='SELECT 1' >/dev/null 2>&1 \
		|| fatal "MariaDB did not become ready. See logs/mariadb.log."

	db_password="$(read_secret "${SECRETS_DIR}/database_password")"
	"$mariadb" --protocol=socket --socket="$socket" --user=root <<SQL
CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'nextcloud'@'127.0.0.1' IDENTIFIED BY '${db_password}';
ALTER USER 'nextcloud'@'127.0.0.1' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
}

start_redis() {
	local redis_server
	local redis_cli

	redis_server="$(resolve_command redis-server)"
	redis_cli="$(resolve_command redis-cli)"
	log "Starting Redis for cache and transactional file locking."
	"$redis_server" "${SERVER_ROOT}/services/redis/redis.conf" &
	REDIS_PID=$!
	SERVICE_PIDS+=("$REDIS_PID")

	for _ in {1..30}; do
		if "$redis_cli" -h 127.0.0.1 -p 6379 ping 2>/dev/null | grep -q PONG; then
			return 0
		fi
		kill -0 "$REDIS_PID" >/dev/null 2>&1 || fatal "Redis stopped during startup. See logs/redis.log."
		sleep 1
	done
	fatal "Redis did not become ready. See logs/redis.log."
}

start_php_fpm() {
	local php_fpm="php-fpm${PHP_VERSION:-8.4}"
	command -v "$php_fpm" >/dev/null 2>&1 || fatal "${php_fpm} is missing."

	log "Starting PHP-FPM."
	PHP_INI_SCAN_DIR="$PHP_FPM_SCAN_DIR" "$php_fpm" \
		-c "${SERVER_ROOT}/php/php.ini" \
		--fpm-config "${SERVER_ROOT}/php/php-fpm.conf" \
		--nodaemonize &
	PHP_FPM_PID=$!
	SERVICE_PIDS+=("$PHP_FPM_PID")

	for _ in {1..30}; do
		[[ -S "${TMP_DIR}/php-fpm.sock" ]] && return 0
		kill -0 "$PHP_FPM_PID" >/dev/null 2>&1 || fatal "PHP-FPM stopped during startup. See logs/php-fpm.log."
		sleep 1
	done
	fatal "PHP-FPM did not create its socket."
}

whiteboard_allowed_origins() {
	local primary
	local protocol
	local configured="${NEXTCLOUD_TRUSTED_DOMAINS:-}"
	local domain
	local origin
	local -a domains
	local -a origins=()
	local -A seen=()
	primary="$(nextcloud_public_url)"
	protocol="${primary%%://*}"
	origins+=("$primary")
	seen["$primary"]=1
	IFS=',' read -r -a domains <<< "$configured"
	for domain in "${domains[@]}"; do
		domain="$(trim "$domain")"
		[[ -n "$domain" ]] || continue
		origin="${protocol}://${domain}"
		[[ -n "${seen[$origin]:-}" ]] && continue
		seen["$origin"]=1
		origins+=("$origin")
	done
	local IFS=,
	printf '%s' "${origins[*]}"
}

start_whiteboard() {
	if ! is_enabled "${WHITEBOARD_ENABLED:-true}" || [[ -n "${WHITEBOARD_URL:-}" ]]; then
		return 0
	fi

	local node
	local app="$WHITEBOARD_ROOT"
	local public_url
	local jwt_secret
	local allowed_origins

	node="$(resolve_command node)"
	[[ -f "${app}/websocket_server/main.js" ]] || fatal "Local Whiteboard backend is missing from the image."
	public_url="$(nextcloud_public_url)"
	jwt_secret="$(read_secret "${SECRETS_DIR}/whiteboard_jwt_secret")"
	allowed_origins="$(whiteboard_allowed_origins)"

	log "Starting the Whiteboard real-time collaboration backend."
	(
		cd "$app" || exit 1
		export HOST=127.0.0.1
		export PORT=3002
		export JWT_SECRET_KEY="$jwt_secret"
		export NEXTCLOUD_URL="$public_url"
		export CORS_ORIGINS="$allowed_origins"
		export STORAGE_STRATEGY=redis
		export REDIS_URL=redis://127.0.0.1:6379
		export RECORDINGS_DIR="${SERVER_ROOT}/services/whiteboard-recordings"
		exec "$node" websocket_server/main.js
	) >> "${LOG_DIR}/whiteboard.log" 2>&1 &
	WHITEBOARD_PID=$!
	SERVICE_PIDS+=("$WHITEBOARD_PID")
	wait_for_tcp 127.0.0.1 3002 "Whiteboard backend" 60
}

ensure_nginx_temp_directive() {
	local config="$1"
	local directive="$2"
	local directory="$3"
	local temporary

	mkdir -p "$directory"
	if grep -Eq "^[[:space:]]*${directive}[[:space:]]" "$config"; then
		return 0
	fi

	log "Updating the persistent Nginx config with ${directive}."
	temporary="$(mktemp "${TMP_DIR}/nginx-config.XXXXXX")"
	if ! awk -v line="\t${directive} ${directory};" '
		{ print }
		!inserted && /^[[:space:]]*proxy_temp_path[[:space:]]/ { print line; inserted = 1 }
		END { if (!inserted) exit 1 }
	' "$config" > "$temporary"; then
		rm -f -- "$temporary"
		fatal "Could not update the legacy Nginx temp-path configuration. Reinstall the server with the current egg."
	fi
	mv -- "$temporary" "$config"
	chmod 0644 "$config"
}

refresh_nginx_managed_files() {
	local relative
	local source
	local destination
	local -a managed_files=(
		fastcgi_params
		mime.types
		snippets/security-headers.conf
	)

	for relative in "${managed_files[@]}"; do
		source="${IMAGE_RUNTIME_ROOT}/nginx/${relative}"
		destination="${SERVER_ROOT}/nginx/${relative}"
		[[ -f "$source" ]] || fatal "Image-owned Nginx file is missing: ${relative}."
		mkdir -p "$(dirname -- "$destination")"
		install -m 0644 -- "$source" "$destination"
	done
}

prepare_nginx_runtime() {
	local config="${SERVER_ROOT}/nginx/nginx.conf"
	refresh_nginx_managed_files
	[[ -f "$config" ]] || fatal "Nginx configuration is missing. Reinstall the server."
	ensure_nginx_temp_directive "$config" uwsgi_temp_path "${TMP_DIR}/uwsgi"
	ensure_nginx_temp_directive "$config" scgi_temp_path "${TMP_DIR}/scgi"
}

start_nginx() {
	prepare_nginx_runtime
	log "Validating and starting Nginx on the Pterodactyl allocation."
	nginx -t -c "${SERVER_ROOT}/nginx/nginx.conf" -p "$SERVER_ROOT"
	nginx -c "${SERVER_ROOT}/nginx/nginx.conf" -p "$SERVER_ROOT" &
	NGINX_PID=$!
	SERVICE_PIDS+=("$NGINX_PID")
	sleep 1
	kill -0 "$NGINX_PID" >/dev/null 2>&1 || fatal "Nginx stopped during startup."
}

start_log_stream() {
	local node
	local entrypoint="${IMAGE_RUNTIME_ROOT}/scripts/log-stream.mjs"
	local supervisor="${IMAGE_RUNTIME_ROOT}/scripts/log-stream-supervisor.sh"
	node="$(command -v node 2>/dev/null || true)"
	if [[ -z "$node" || ! -x "$node" || ! -f "$entrypoint" || ! -f "$supervisor" ]]; then
		warn "Compact activity log helper is unavailable; raw log files remain in ${LOG_DIR}."
		return 0
	fi

	if is_enabled "${CONSOLE_ACTIVITY_LOGS:-true}"; then
		log "Starting compact Nginx, Nextcloud, and audit event stream."
	else
		log "Compact activity output is disabled; starting log rotation only."
	fi
	bash "$supervisor" "$node" "$entrypoint" &
	LOG_STREAM_PID=$!
	AUXILIARY_PIDS+=("$LOG_STREAM_PID")
	sleep 0.2
	if ! kill -0 "$LOG_STREAM_PID" >/dev/null 2>&1; then
		warn "Compact activity log supervisor stopped during startup; raw log files remain in ${LOG_DIR}."
	fi
}

stop_services() {
	local mariadb_admin
	local pid
	mariadb_admin="$(command -v mariadb-admin 2>/dev/null || true)"

	if [[ -n "$MARIADB_PID" ]] && kill -0 "$MARIADB_PID" >/dev/null 2>&1 && [[ -x "$mariadb_admin" ]]; then
		"$mariadb_admin" --protocol=socket --socket="${TMP_DIR}/mariadb.sock" --user=root shutdown >/dev/null 2>&1 || true
	fi

	for pid in "${AUXILIARY_PIDS[@]}"; do
		if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
			kill -TERM "$pid" >/dev/null 2>&1 || true
		fi
	done

	for pid in "${SERVICE_PIDS[@]}"; do
		if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
			kill -TERM "$pid" >/dev/null 2>&1 || true
		fi
	done

	for pid in "${SERVICE_PIDS[@]}"; do
		wait "$pid" 2>/dev/null || true
	done
	for pid in "${AUXILIARY_PIDS[@]}"; do
		wait "$pid" 2>/dev/null || true
	done
}
