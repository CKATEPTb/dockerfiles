#!/usr/bin/env bash

occ() {
	(
		cd "$WEB_ROOT" || exit 1
		PHP_INI_SCAN_DIR="$PHP_CLI_SCAN_DIR" "$PHP_CLI_BIN" -c "${SERVER_ROOT}/php/php.ini" -f occ -- "$@"
	)
}

nextcloud_is_installed() {
	[[ -f "${WEB_ROOT}/config/config.php" ]] \
		&& grep -Eq "['\"]installed['\"][[:space:]]*=>[[:space:]]*true" "${WEB_ROOT}/config/config.php"
}

nextcloud_public_url() {
	local configured="${NEXTCLOUD_URL:-}"
	local host="${SERVER_IP:-127.0.0.1}"
	local port="${SERVER_PORT:-8080}"

	if [[ -n "$configured" ]]; then
		configured="${configured%/}"
		[[ "$configured" =~ ^https?://[^/]+$ ]] \
			|| fatal "NEXTCLOUD_URL must be a root URL such as https://cloud.example.com (no path)."
		printf '%s' "$configured"
		return 0
	fi

	case "$host" in
		0.0.0.0|::|'') host=127.0.0.1 ;;
	esac
	if [[ "$host" == *:* && "$host" != \[*\] ]]; then
		host="[${host}]"
	fi
	printf 'http://%s:%s' "$host" "$port"
}

install_nextcloud() {
	if nextcloud_is_installed; then
		return 0
	fi

	local admin_user="${NEXTCLOUD_ADMIN_USER:-admin}"
	local admin_password="${NEXTCLOUD_ADMIN_PASSWORD:-}"
	local generated_password=false
	local db_password

	if [[ -z "$admin_password" ]]; then
		admin_password="$(openssl rand -hex 16)"
		generated_password=true
		printf '%s' "$admin_password" > "${SECRETS_DIR}/initial_admin_password"
		chmod 600 "${SECRETS_DIR}/initial_admin_password"
	fi
	db_password="$(read_secret "${SECRETS_DIR}/database_password")"

	log "Installing Nextcloud with embedded MariaDB."
	occ maintenance:install \
		--database=mysql \
		--database-name=nextcloud \
		--database-host=127.0.0.1 \
		--database-port=3306 \
		--database-user=nextcloud \
		--database-pass="$db_password" \
		--admin-user="$admin_user" \
		--admin-pass="$admin_password" \
		--data-dir="${SERVER_ROOT}/data" \
		--no-interaction

	if is_enabled "$generated_password"; then
		log "Generated initial admin login: ${admin_user}"
		log "Generated initial admin password: ${admin_password}"
		log "The password is also stored in .secrets/initial_admin_password. Change it after the first login."
	fi
}

migrate_sqlite_to_mariadb() {
	local db_type
	db_type="$(occ config:system:get dbtype 2>/dev/null || true)"
	if [[ "$db_type" != sqlite* ]]; then
		return 0
	fi

	if ! is_enabled "${AUTO_MIGRATE_SQLITE:-true}"; then
		warn "This installation still uses SQLite because AUTO_MIGRATE_SQLITE is disabled."
		return 0
	fi

	local data_directory
	local sqlite_file
	local backup_directory
	local db_password
	data_directory="$(occ config:system:get datadirectory)"
	sqlite_file="${data_directory}/owncloud.db"
	backup_directory="${SERVER_ROOT}/backups/sqlite-migration-$(date -u +%Y%m%dT%H%M%SZ)"
	db_password="$(read_secret "${SECRETS_DIR}/database_password")"

	mkdir -p "$backup_directory"
	if [[ -f "$sqlite_file" ]]; then
		cp -a "$sqlite_file" "${backup_directory}/owncloud.db"
		log "SQLite backup created at ${backup_directory}/owncloud.db."
	fi

	log "Converting the existing SQLite database to embedded MariaDB."
	occ db:convert-type \
		--password="$db_password" \
		--port=3306 \
		--all-apps \
		--clear-schema \
		--no-interaction \
		mysql nextcloud 127.0.0.1 nextcloud
	occ config:system:set mysql.utf8mb4 --type=boolean --value=true
}

set_system_value() {
	local key="$1"
	local type="$2"
	local value="$3"
	occ config:system:set "$key" --type="$type" --value="$value" >/dev/null
}

configure_trusted_domains() {
	local port="${SERVER_PORT:-8080}"
	local public_url
	local authority
	local configured="${NEXTCLOUD_TRUSTED_DOMAINS:-}"
	local domain
	local index=0
	local -a domains
	local -a additional_domains
	local -A seen=()
	public_url="$(nextcloud_public_url)"
	authority="${public_url#*://}"
	domains=(localhost "localhost:${port}" 127.0.0.1 "127.0.0.1:${port}" "$authority")

	IFS=',' read -r -a additional_domains <<< "$configured"
	for domain in "${additional_domains[@]}"; do
		domain="$(trim "$domain")"
		[[ -n "$domain" ]] || continue
		if [[ ! "$domain" =~ ^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:[0-9]{1,5})?$ ]]; then
			fatal "Invalid trusted domain '${domain}'. Use host names without http://, paths, or wildcards."
		fi
		domains+=("$domain")
	done

	occ config:system:delete trusted_domains >/dev/null 2>&1 || true
	for domain in "${domains[@]}"; do
		[[ -n "${seen[$domain]:-}" ]] && continue
		seen["$domain"]=1
		occ config:system:set trusted_domains "$index" --value="$domain" >/dev/null || return 1
		((index += 1))
	done
}

configure_trusted_proxies() {
	local configured="${TRUSTED_PROXIES:-127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
	local proxy
	local index=0
	local -a proxies

	occ config:system:delete trusted_proxies >/dev/null 2>&1 || true
	IFS=',' read -r -a proxies <<< "$configured"
	for proxy in "${proxies[@]}"; do
		proxy="$(trim "$proxy")"
		[[ -n "$proxy" ]] || continue
		occ config:system:set trusted_proxies "$index" --value="$proxy" >/dev/null || return 1
		((index += 1))
	done
}

configure_public_url() {
	local public_url
	local protocol

	# Preserve the validated Host of each web request so trusted aliases remain usable.
	occ config:system:delete overwritehost >/dev/null 2>&1 || true
	if [[ -z "${NEXTCLOUD_URL:-}" ]]; then
		occ config:system:delete overwriteprotocol >/dev/null 2>&1 || true
		occ config:system:delete overwrite.cli.url >/dev/null 2>&1 || true
		return 0
	fi

	public_url="$(nextcloud_public_url)"
	protocol="${public_url%%://*}"

	set_system_value overwriteprotocol string "$protocol" || return 1
	set_system_value overwrite.cli.url string "$public_url"
}

configure_cache() {
	set_system_value memcache.local string '\OC\Memcache\APCu' || return 1
	set_system_value memcache.distributed string '\OC\Memcache\Redis' || return 1
	set_system_value memcache.locking string '\OC\Memcache\Redis' || return 1
	set_system_value filelocking.enabled boolean true || return 1
	occ config:system:set redis host --value=127.0.0.1 >/dev/null || return 1
	occ config:system:set redis port --type=integer --value=6379 >/dev/null || return 1
	occ config:system:set redis dbindex --type=integer --value=0 >/dev/null || return 1
	occ config:system:set redis timeout --type=float --value=1.5 >/dev/null
}

configure_apps_paths() {
	mkdir -p "${WEB_ROOT}/custom_apps"
	occ config:system:set apps_paths --type=json \
		--value="[{\"path\":\"${WEB_ROOT}/apps\",\"url\":\"/apps\",\"writable\":false},{\"path\":\"${WEB_ROOT}/custom_apps\",\"url\":\"/custom_apps\",\"writable\":true}]" >/dev/null
}

configure_smtp() {
	[[ -n "${SMTP_HOST:-}" ]] || return 0

	local auth=false
	local smtp_secure="${SMTP_SECURE:-tls}"
	[[ -n "${SMTP_USER:-}" ]] && auth=true
	set_system_value mail_smtpmode string smtp || return 1
	set_system_value mail_smtphost string "$SMTP_HOST" || return 1
	set_system_value mail_smtpport integer "${SMTP_PORT:-587}" || return 1
	set_system_value mail_smtpauth boolean "$auth" || return 1
	set_system_value mail_smtpauthtype string "${SMTP_AUTHTYPE:-LOGIN}" || return 1
	set_system_value mail_from_address string "${MAIL_FROM_ADDRESS:-nextcloud}" || return 1
	set_system_value mail_domain string "${MAIL_DOMAIN:-localhost}" || return 1

	if [[ "$smtp_secure" != none ]]; then
		set_system_value mail_smtpsecure string "$smtp_secure" || return 1
	else
		occ config:system:delete mail_smtpsecure >/dev/null 2>&1 || true
	fi
	if [[ -n "${SMTP_USER:-}" ]]; then
		set_system_value mail_smtpname string "$SMTP_USER" || return 1
	fi
	if [[ -n "${SMTP_PASSWORD:-}" ]]; then
		set_system_value mail_smtppassword string "$SMTP_PASSWORD" || return 1
	fi
}

configure_logging() {
	set_system_value log_type string file || return 1
	set_system_value logfile string "${LOG_DIR}/nextcloud.log" || return 1
	set_system_value loglevel integer "${NEXTCLOUD_LOG_LEVEL:-2}" || return 1
	set_system_value log_rotate_size integer 104857600 || return 1
	set_system_value log_type_audit string file || return 1
	set_system_value logfile_audit string "${LOG_DIR}/audit.log" || return 1

	if ! occ app:enable admin_audit >/dev/null 2>&1; then
		warn "The bundled admin_audit app could not be enabled; login email correlation will be unavailable."
		return 0
	fi

	# Keep normal logs at warning level while allowing the audit app's INFO events.
	occ config:system:delete log.condition >/dev/null 2>&1 || true
	occ config:system:set log.condition apps 0 --value=admin_audit >/dev/null
}

enable_or_install_app() {
	local app_id="$1"
	local display_name="$2"
	if occ app:enable "$app_id" >/dev/null 2>&1; then
		return 0
	fi

	log "Installing the official Nextcloud ${display_name} app."
	occ app:install "$app_id" --no-interaction
}

configure_talk() {
	if ! is_enabled "${TALK_ENABLED:-true}"; then
		occ app:disable spreed >/dev/null 2>&1 || true
		return 0
	fi

	if ! enable_or_install_app spreed Talk; then
		warn "Talk is not compatible with this Nextcloud release or could not be downloaded."
	fi
}

configure_whiteboard() {
	if ! is_enabled "${WHITEBOARD_ENABLED:-true}"; then
		occ app:disable whiteboard >/dev/null 2>&1 || true
		return 0
	fi

	local backend_url="${WHITEBOARD_URL:-}"
	local jwt_secret
	if [[ -z "$backend_url" ]]; then
		backend_url="$(nextcloud_public_url)/whiteboard"
	fi
	jwt_secret="$(read_secret "${SECRETS_DIR}/whiteboard_jwt_secret")"

	if ! enable_or_install_app whiteboard Whiteboard; then
		warn "Whiteboard is not compatible with this Nextcloud release yet; the core service will remain available."
		return 0
	fi
	if ! occ config:app:set whiteboard collabBackendUrl --value="$backend_url" >/dev/null \
		|| ! occ config:app:set whiteboard jwt_secret_key --value="$jwt_secret" >/dev/null; then
		warn "Whiteboard was enabled, but its collaboration backend settings could not be applied."
	fi
}

configure_nextcloud() {
	log "Applying production Nextcloud settings."
	configure_trusted_domains || return 1
	configure_trusted_proxies || return 1
	configure_public_url || return 1
	configure_cache || return 1
	configure_apps_paths || return 1
	configure_smtp || return 1
	configure_logging || return 1

	set_system_value default_phone_region string "${DEFAULT_PHONE_REGION:-DE}" || return 1
	set_system_value maintenance_window_start integer "${MAINTENANCE_WINDOW_START:-1}" || return 1
	set_system_value mysql.utf8mb4 boolean true || return 1
	set_system_value htaccess.RewriteBase string / || return 1
	occ background:cron >/dev/null || return 1
	configure_talk
	configure_whiteboard
}

upgrade_nextcloud() {
	log "Checking the Nextcloud database schema."
	occ upgrade --no-interaction
}

run_version_maintenance() {
	local version
	local marker
	version="$(occ config:system:get version | tr -cd '0-9.')"
	[[ -n "$version" ]] || version=unknown
	marker="${STATE_DIR}/maintenance-${version}.done"
	[[ -f "$marker" ]] && return 0

	log "Running one-time maintenance and expensive mimetype migrations for Nextcloud ${version}."
	occ maintenance:repair --include-expensive || return 1
	occ db:add-missing-indices --no-interaction || true
	occ db:add-missing-columns --no-interaction || true
	occ db:add-missing-primary-keys --no-interaction || true
	touch "$marker" || return 1
}

check_core_integrity() {
	if ! occ integrity:check-core; then
		warn "Core integrity still reports a problem. Reinstall with REPAIR_EXISTING_CORE enabled."
		return 1
	fi
}

run_nextcloud_cron() {
	(
		cd "$WEB_ROOT" || exit 1
		PHP_INI_SCAN_DIR="$PHP_CLI_SCAN_DIR" "$PHP_CLI_BIN" -c "${SERVER_ROOT}/php/php.ini" -f cron.php
	)
}

cron_loop() {
	while true; do
		sleep 300
		maintenance_lock_acquire true || continue
		if ! recover_backup_maintenance_mode; then
			maintenance_lock_release
			continue
		fi
		run_nextcloud_cron >/dev/null 2>&1 || warn "A Nextcloud cron run failed; see logs/nextcloud.log."
		maintenance_lock_release
	done
}
