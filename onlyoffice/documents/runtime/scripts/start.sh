#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/services.sh
source "${SCRIPT_DIR}/lib/services.sh"
# shellcheck source=lib/console.sh
source "${SCRIPT_DIR}/lib/console.sh"

SHUTTING_DOWN=false

shutdown() {
	local exit_status=$?
	if is_enabled "$SHUTTING_DOWN"; then
		return "$exit_status"
	fi
	SHUTTING_DOWN=true
	log 'Stopping ONLYOFFICE Docs services.'
	stop_console
	if [[ -n "$DOCSERVICE_PID" ]] && kill -0 "$DOCSERVICE_PID" >/dev/null 2>&1; then
		run_prepare_shutdown 25
	fi
	stop_services
	return "$exit_status"
}

trap shutdown EXIT
trap 'exit 0' INT TERM

validate_runtime
ensure_directories
prepare_runtime_configuration
start_docservice
start_converter
wait_for_docservice
start_nginx
verify_public_health
start_console

log "Version: $(onlyoffice_version)"
log "Public endpoint follows the request Host on allocation port ${SERVER_PORT:-8080}."
log "Run 'jwt:show' once to copy the connector secret into Nextcloud."
log 'ONLYOFFICE Docs successfully launched.'

set +e
wait_for_managed_service
status=$?
set -e

if ! is_enabled "$SHUTTING_DOWN"; then
	warn "A managed service exited unexpectedly (status ${status}); stopping the stack."
	[[ "$status" -ne 0 ]] || status=1
fi
exit "$status"
