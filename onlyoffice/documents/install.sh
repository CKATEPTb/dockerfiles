#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly SERVER_DIR=/mnt/server
readonly IMAGE_ROOT=/opt/onlyoffice-egg
readonly EXPECTED_IMAGE_API_VERSION=1

log() {
	printf '[Installer] %s\n' "$*"
}

fatal() {
	printf '[Installer] ERROR: %s\n' "$*" >&2
	exit 1
}

image_api_version() {
	[[ -r "${IMAGE_ROOT}/IMAGE_API_VERSION" ]] || return 1
	tr -d '\r\n' < "${IMAGE_ROOT}/IMAGE_API_VERSION"
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

ensure_secret() {
	local name="$1"
	local configured_value="$2"
	local destination="${SERVER_DIR}/.secrets/${name}"
	local generated

	if [[ -s "$destination" ]]; then
		if [[ -n "$configured_value" ]]; then
			validate_secret "$configured_value"
			if [[ "$(tr -d '\r\n' < "$destination")" != "$configured_value" ]]; then
				log "Keeping the existing ${name}; use the console rotation workflow before changing an active integration."
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

[[ "$(image_api_version || true)" == "$EXPECTED_IMAGE_API_VERSION" ]] \
	|| fatal 'The selected Docker image is not compatible with this egg.'
for command_name in nginx node openssl rsync; do
	command -v "$command_name" >/dev/null 2>&1 \
		|| fatal "Required image command is missing: ${command_name}."
done

log 'Creating the persistent ONLYOFFICE Docs layout.'
mkdir -p \
	"${SERVER_DIR}/.secrets" \
	"${SERVER_DIR}/.state" \
	"${SERVER_DIR}/data/onlyoffice-data/custom-fonts" \
	"${SERVER_DIR}/data/onlyoffice-lib/documentserver/App_Data/cache/files" \
	"${SERVER_DIR}/data/onlyoffice-lib/documentserver/App_Data/docbuilder" \
	"${SERVER_DIR}/logs/onlyoffice" \
	"${SERVER_DIR}/runtime" \
	"${SERVER_DIR}/tmp"
chmod 0700 "${SERVER_DIR}/.secrets"

ensure_secret jwt_secret "${JWT_SECRET:-}"
ensure_secret secure_link_secret ''

log 'ONLYOFFICE Docs persistent state is ready. Application files stay in the immutable image.'
