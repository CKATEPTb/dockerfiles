#!/usr/bin/env bash
set -Eeuo pipefail

readonly TEST_ROOT=/tmp/onlyoffice-services-test
readonly SERVER_ROOT="${TEST_ROOT}/server"
readonly IMAGE_RUNTIME_ROOT="${TEST_ROOT}/image-runtime"
readonly UPSTREAM_CONFIG_ROOT="${TEST_ROOT}/upstream-config"
readonly RUNTIME_CONFIG_DIR="${SERVER_ROOT}/runtime/config"
readonly NGINX_DIR="${SERVER_ROOT}/runtime/nginx"
readonly LOG_DIR="${SERVER_ROOT}/logs"
readonly TMP_DIR="${SERVER_ROOT}/tmp"
readonly DATA_DIR="${SERVER_ROOT}/data"
readonly SECRETS_DIR="${SERVER_ROOT}/.secrets"

resolve_command() {
	[[ "$1" == node ]] || return 1
	printf 'true'
}

ensure_runtime_secret() {
	return 0
}

onlyoffice_version() {
	printf '9.4.0-test'
}

log() {
	return 0
}

fatal() {
	printf '[test-services] %s\n' "$*" >&2
	return 1
}

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../runtime/scripts/lib/services.sh
source "${SCRIPT_DIR}/../runtime/scripts/lib/services.sh"

# These values deliberately remain readonly. The renderer must pass them
# through external `env`; shell prefix assignments would abort before `true`.
prepare_runtime_configuration

printf '[test-services] OK: readonly runtime paths reach the renderer\n'
