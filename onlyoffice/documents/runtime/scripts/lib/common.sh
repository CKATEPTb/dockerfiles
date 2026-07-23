#!/usr/bin/env bash
# shellcheck disable=SC2034

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly SERVER_ROOT=/home/container
readonly IMAGE_ROOT=/opt/onlyoffice-egg
readonly IMAGE_RUNTIME_ROOT="${IMAGE_ROOT}/runtime"
readonly UPSTREAM_CONFIG_ROOT="${IMAGE_ROOT}/upstream-config"
readonly EXPECTED_IMAGE_API_VERSION=1
readonly STATE_DIR="${SERVER_ROOT}/.state"
readonly SECRETS_DIR="${SERVER_ROOT}/.secrets"
readonly DATA_DIR="${SERVER_ROOT}/data"
readonly LOG_DIR="${SERVER_ROOT}/logs"
readonly TMP_DIR="${SERVER_ROOT}/tmp"
readonly GENERATED_DIR="${SERVER_ROOT}/runtime"
readonly RUNTIME_CONFIG_DIR="${GENERATED_DIR}/config"
readonly NGINX_DIR="${GENERATED_DIR}/nginx"
readonly DOCSERVICE_ROOT=/var/www/onlyoffice/documentserver

log() {
	printf '[ONLYOFFICE] %s\n' "$*"
}

warn() {
	printf '[ONLYOFFICE] WARNING: %s\n' "$*" >&2
}

fatal() {
	printf '[ONLYOFFICE] ERROR: %s\n' "$*" >&2
	exit 1
}

is_enabled() {
	case "${1:-}" in
		1|true|TRUE|yes|YES|on|ON) return 0 ;;
		*) return 1 ;;
	esac
}

resolve_command() {
	local command_name="$1"
	local command_path
	command_path="$(command -v "$command_name" 2>/dev/null || true)"
	[[ -n "$command_path" && -x "$command_path" ]] \
		|| fatal "Required image command is missing: ${command_name}."
	printf '%s' "$command_path"
}

read_secret() {
	local source="$1"
	[[ -s "$source" ]] || fatal "Required secret is missing: ${source}. Reinstall the server."
	tr -d '\r\n' < "$source"
}

validate_secret() {
	local value="$1"
	[[ "${#value}" -ge 32 && "${#value}" -le 512 ]] \
		|| fatal 'JWT_SECRET must contain between 32 and 512 characters.'
	[[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
		|| fatal 'JWT_SECRET must not contain line breaks.'
}

write_secret_atomically() {
	local value="$1"
	local destination="$2"
	local temporary
	temporary="$(mktemp "${destination}.tmp.XXXXXX")"
	printf '%s' "$value" > "$temporary"
	chmod 0600 "$temporary"
	mv -f -- "$temporary" "$destination"
}

ensure_runtime_secret() {
	local name="$1"
	local configured_value="$2"
	local destination="${SECRETS_DIR}/${name}"
	local generated

	if [[ -s "$destination" ]]; then
		if [[ -n "$configured_value" ]]; then
			validate_secret "$configured_value"
			if [[ "$(read_secret "$destination")" != "$configured_value" ]]; then
				warn "The configured ${name} differs from the persistent value; the persistent value was kept."
			fi
		fi
		chmod 0600 "$destination"
		return 0
	fi

	if [[ -n "$configured_value" ]]; then
		validate_secret "$configured_value"
		write_secret_atomically "$configured_value" "$destination"
		return 0
	fi

	generated="$(openssl rand -hex 32)"
	write_secret_atomically "$generated" "$destination"
}

validate_runtime() {
	local actual_version=''
	[[ -r "${IMAGE_ROOT}/IMAGE_API_VERSION" ]] \
		&& actual_version="$(tr -d '\r\n' < "${IMAGE_ROOT}/IMAGE_API_VERSION")"
	[[ "$actual_version" == "$EXPECTED_IMAGE_API_VERSION" ]] \
		|| fatal "Incompatible image API '${actual_version:-missing}'; expected ${EXPECTED_IMAGE_API_VERSION}."
	[[ "$(id -u)" -ne 0 ]] \
		|| fatal 'The runtime must be started by Wings as the unprivileged Pterodactyl user.'
	[[ -d "$UPSTREAM_CONFIG_ROOT" ]] || fatal 'The official ONLYOFFICE configuration seed is missing.'
	[[ -x "${DOCSERVICE_ROOT}/server/DocService/docservice" ]] || fatal 'DocService is missing from the image.'
	[[ -x "${DOCSERVICE_ROOT}/server/FileConverter/converter" ]] || fatal 'Converter is missing from the image.'
	for command_name in curl nginx node openssl rsync; do
		resolve_command "$command_name" >/dev/null
	done
}

ensure_directories() {
	mkdir -p \
		"$STATE_DIR" \
		"$SECRETS_DIR" \
		"${DATA_DIR}/onlyoffice-data/custom-fonts" \
		"${DATA_DIR}/onlyoffice-lib/documentserver/App_Data/cache/files" \
		"${DATA_DIR}/onlyoffice-lib/documentserver/App_Data/docbuilder" \
		"${LOG_DIR}/onlyoffice/documentserver/docservice" \
		"${LOG_DIR}/onlyoffice/documentserver/converter" \
		"${TMP_DIR}/client-body" \
		"${TMP_DIR}/proxy" \
		"${TMP_DIR}/fastcgi" \
		"${TMP_DIR}/uwsgi" \
		"${TMP_DIR}/scgi" \
		"${TMP_DIR}/native-cache" \
		"$GENERATED_DIR"
	chmod 0700 "$SECRETS_DIR"
}

onlyoffice_version() {
	dpkg-query -W -f='${Version}' onlyoffice-documentserver 2>/dev/null || printf 'unknown'
}

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}
