#!/usr/bin/env bash
# These constants are consumed by the other modules sourced by start.sh.
# shellcheck disable=SC2034

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly SERVER_ROOT="/home/container"
readonly IMAGE_ROOT="/opt/nextcloud-egg"
readonly IMAGE_RUNTIME_ROOT="${IMAGE_ROOT}/runtime"
readonly WHITEBOARD_ROOT="${IMAGE_ROOT}/whiteboard"
readonly EXPECTED_IMAGE_API_VERSION="1"
readonly WEB_ROOT="${SERVER_ROOT}/www"
readonly STATE_DIR="${SERVER_ROOT}/.state"
readonly SECRETS_DIR="${SERVER_ROOT}/.secrets"
readonly LOG_DIR="${SERVER_ROOT}/logs"
readonly BACKUP_ROOT="${SERVER_ROOT}/backups"
readonly TMP_DIR="${SERVER_ROOT}/tmp"
readonly MAINTENANCE_LOCK_DIR="${STATE_DIR}/maintenance-operation.lock"
readonly BACKUP_MAINTENANCE_MARKER="${STATE_DIR}/backup-maintenance-owned"

log() {
	printf '[Nextcloud] %s\n' "$*"
}

warn() {
	printf '[Nextcloud] WARNING: %s\n' "$*" >&2
}

fatal() {
	printf '[Nextcloud] ERROR: %s\n' "$*" >&2
	exit 1
}

resolve_command() {
	local command_name="$1"
	local command_path
	command_path="$(command -v "$command_name" 2>/dev/null || true)"
	[[ -n "$command_path" && -x "$command_path" ]] \
		|| fatal "Required image command is missing: ${command_name}. Rebuild or select the supported Nextcloud image."
	printf '%s' "$command_path"
}

validate_image_runtime() {
	local version_file="${IMAGE_ROOT}/IMAGE_API_VERSION"
	local actual_version=""
	[[ -r "$version_file" ]] && actual_version="$(tr -d '\r\n' < "$version_file")"
	[[ "$actual_version" == "$EXPECTED_IMAGE_API_VERSION" ]] \
		|| fatal "Incompatible Nextcloud image API '${actual_version:-missing}'; expected ${EXPECTED_IMAGE_API_VERSION}."
}

is_enabled() {
	case "${1:-}" in
		1|true|TRUE|yes|YES|on|ON) return 0 ;;
		*) return 1 ;;
	esac
}

ensure_directories() {
	mkdir -p \
		"$STATE_DIR" \
		"$SECRETS_DIR" \
		"$LOG_DIR" \
		"$BACKUP_ROOT" \
		"$TMP_DIR" \
		"${TMP_DIR}/client-body" \
		"${TMP_DIR}/fastcgi" \
		"${TMP_DIR}/proxy" \
		"${SERVER_ROOT}/services/whiteboard-recordings"
	chmod 700 "$SECRETS_DIR"
}

read_secret() {
	local file="$1"
	[[ -s "$file" ]] || fatal "Required secret is missing: ${file}"
	tr -d '\r\n' < "$file"
}

write_secret_from_env() {
	local env_value="$1"
	local file="$2"
	if [[ -n "$env_value" ]]; then
		printf '%s' "$env_value" > "$file"
		chmod 600 "$file"
	fi
}

wait_for_tcp() {
	local host="$1"
	local port="$2"
	local name="$3"
	local attempts="${4:-60}"
	local attempt

	for ((attempt = 1; attempt <= attempts; attempt++)); do
		if (echo > "/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done

	fatal "${name} did not become ready on ${host}:${port}."
}

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}
