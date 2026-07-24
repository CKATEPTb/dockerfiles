#!/usr/bin/env bash
set -Eeuo pipefail

cd /home/container
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/services.sh
source "${SCRIPT_DIR}/lib/services.sh"
# shellcheck source=lib/nextcloud.sh
source "${SCRIPT_DIR}/lib/nextcloud.sh"
# shellcheck source=lib/maintenance.sh
source "${SCRIPT_DIR}/lib/maintenance.sh"
# shellcheck source=lib/console.sh
source "${SCRIPT_DIR}/lib/console.sh"

SHUTTING_DOWN=false

# Called indirectly by the EXIT trap.
# shellcheck disable=SC2329
shutdown() {
	SHUTTING_DOWN=true
	log "Stopping services."
	stop_console
	stop_services
}

trap shutdown EXIT
trap 'exit 0' INT TERM

ensure_directories
validate_image_runtime
write_secret_from_env "${WHITEBOARD_JWT_SECRET:-}" "${SECRETS_DIR}/whiteboard_jwt_secret"
configure_php_extensions

start_mariadb
start_redis
recover_backup_maintenance_mode || fatal "Backup-owned maintenance mode could not be recovered."
install_nextcloud
migrate_sqlite_to_mariadb
upgrade_nextcloud
configure_nextcloud
run_version_maintenance
check_core_integrity || true

start_php_fpm
start_whiteboard
start_nginx
start_log_stream
cron_loop &
CRON_PID=$!
SERVICE_PIDS+=("$CRON_PID")
start_console

log "Services successfully launched."
log "Public URL: $(nextcloud_public_url)"

set +e
wait -n "${SERVICE_PIDS[@]}"
status=$?
set -e

if ! is_enabled "$SHUTTING_DOWN"; then
	warn "A managed service exited unexpectedly (status ${status}); stopping the stack."
	[[ "$status" -ne 0 ]] || status=1
fi
exit "$status"
