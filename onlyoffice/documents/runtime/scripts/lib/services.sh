#!/usr/bin/env bash

declare -A SERVICE_PIDS=()
declare -a SERVICE_ORDER=()

DOCSERVICE_PID=''
CONVERTER_PID=''
NGINX_PID=''

register_service() {
	local name="$1"
	local pid="$2"
	SERVICE_PIDS["$name"]="$pid"
	SERVICE_ORDER+=("$name")
}

service_is_running() {
	local name="$1"
	local pid="${SERVICE_PIDS[$name]:-}"
	[[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1
}

prepare_runtime_configuration() {
	local node
	local status=0
	node="$(resolve_command node)"
	ensure_runtime_secret jwt_secret "${JWT_SECRET:-}"
	ensure_runtime_secret secure_link_secret ''

	log 'Rendering version-matched ONLYOFFICE and Nginx configuration.'
	env \
	SERVER_ROOT="$SERVER_ROOT" \
	IMAGE_RUNTIME_ROOT="$IMAGE_RUNTIME_ROOT" \
	UPSTREAM_CONFIG_ROOT="$UPSTREAM_CONFIG_ROOT" \
	RUNTIME_CONFIG_DIR="$RUNTIME_CONFIG_DIR" \
	NGINX_DIR="$NGINX_DIR" \
	LOG_DIR="$LOG_DIR" \
	TMP_DIR="$TMP_DIR" \
	DATA_DIR="$DATA_DIR" \
	JWT_SECRET_FILE="${SECRETS_DIR}/jwt_secret" \
	SECURE_LINK_SECRET_FILE="${SECRETS_DIR}/secure_link_secret" \
	ASSET_CACHE_TAG_FILE="$ASSET_CACHE_TAG_FILE" \
	SERVER_PORT="${SERVER_PORT:-8080}" \
	JWT_HEADER="${JWT_HEADER:-Authorization}" \
	ALLOW_PRIVATE_IP_ADDRESS="${ALLOW_PRIVATE_IP_ADDRESS:-0}" \
	USE_UNAUTHORIZED_STORAGE="${USE_UNAUTHORIZED_STORAGE:-0}" \
	LOG_LEVEL="${LOG_LEVEL:-WARN}" \
	NGINX_ACCESS_LOG="${NGINX_ACCESS_LOG:-0}" \
	UPLOAD_LIMIT="${UPLOAD_LIMIT:-1G}" \
	NGINX_WORKER_PROCESSES="${NGINX_WORKER_PROCESSES:-1}" \
	NGINX_WORKER_CONNECTIONS="${NGINX_WORKER_CONNECTIONS:-4096}" \
		"$node" "${IMAGE_RUNTIME_ROOT}/scripts/configure.mjs" || status=$?
	[[ "$status" -eq 0 ]] \
		|| fatal "The runtime configuration renderer failed (exit ${status})."
}

start_docservice() {
	local executable="${DOCSERVICE_ROOT}/server/DocService/docservice"
	log 'Starting DocService on the internal editor endpoint.'
	(
		cd "${DOCSERVICE_ROOT}/server/DocService" || exit 1
		export APPLICATION_NAME=onlyoffice
		export NODE_CONFIG_DIR="$RUNTIME_CONFIG_DIR"
		export NODE_DISABLE_COLORS=1
		export NODE_ENV=production-linux
		export PKG_NATIVE_CACHE_PATH="${TMP_DIR}/native-cache"
		exec "$executable"
	) >> "${LOG_DIR}/docservice-stdout.log" 2>> "${LOG_DIR}/docservice-stderr.log" &
	DOCSERVICE_PID=$!
	register_service docservice "$DOCSERVICE_PID"
}

start_converter() {
	local executable="${DOCSERVICE_ROOT}/server/FileConverter/converter"
	log 'Starting the document converter.'
	(
		cd "${DOCSERVICE_ROOT}/server/FileConverter" || exit 1
		export APPLICATION_NAME=onlyoffice
		export LD_LIBRARY_PATH="${DOCSERVICE_ROOT}/server/FileConverter/bin${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
		export NODE_CONFIG_DIR="$RUNTIME_CONFIG_DIR"
		export NODE_DISABLE_COLORS=1
		export NODE_ENV=production-linux
		export PKG_NATIVE_CACHE_PATH="${TMP_DIR}/native-cache"
		exec "$executable"
	) >> "${LOG_DIR}/converter-stdout.log" 2>> "${LOG_DIR}/converter-stderr.log" &
	CONVERTER_PID=$!
	register_service converter "$CONVERTER_PID"
}

wait_for_docservice() {
	local curl_bin
	local response
	curl_bin="$(resolve_command curl)"
	for _ in {1..180}; do
		service_is_running docservice || fatal "DocService stopped during startup. See ${LOG_DIR}/docservice-stderr.log."
		service_is_running converter || fatal "Converter stopped during startup. See ${LOG_DIR}/converter-stderr.log."
		response="$($curl_bin -fsS --max-time 3 http://127.0.0.1:8000/healthcheck 2>/dev/null || true)"
		if [[ "$response" == *true* ]]; then
			return 0
		fi
		sleep 1
	done
	fatal "DocService did not become healthy on 127.0.0.1:8000. See ${LOG_DIR}/docservice-stderr.log."
}

start_nginx() {
	local nginx_bin
	nginx_bin="$(resolve_command nginx)"
	log 'Validating and starting Nginx on the Pterodactyl allocation.'
	"$nginx_bin" -t -c "${NGINX_DIR}/nginx.conf" -p "$SERVER_ROOT"
	"$nginx_bin" -c "${NGINX_DIR}/nginx.conf" -p "$SERVER_ROOT" &
	NGINX_PID=$!
	register_service nginx "$NGINX_PID"
	sleep 1
	service_is_running nginx || fatal "Nginx stopped during startup. See ${LOG_DIR}/nginx-error.log."
}

verify_public_health() {
	local curl_bin
	local response
	curl_bin="$(resolve_command curl)"
	response="$($curl_bin -fsS --max-time 5 \
		-H 'Host: localhost' \
		"http://127.0.0.1:${SERVER_PORT:-8080}/healthcheck" 2>/dev/null || true)"
	[[ "$response" == *true* ]] || fatal 'The public Nginx health check failed.'
}

onlyoffice_health() {
	local response
	response="$(curl -fsS --max-time 5 http://127.0.0.1:8000/healthcheck 2>/dev/null || true)"
	[[ "$response" == *true* ]]
}

run_prepare_shutdown() {
	local timeout_seconds="${1:-25}"
	local preparation_script
	preparation_script="$(command -v documentserver-prepare4shutdown.sh 2>/dev/null || true)"
	[[ -n "$preparation_script" && -x "$preparation_script" ]] || {
		warn 'The official prepare-for-shutdown helper is unavailable.'
		return 0
	}
	log 'Asking ONLYOFFICE Docs to finish active save operations.'
	if ! timeout "${timeout_seconds}s" "$preparation_script" >> "${LOG_DIR}/shutdown.log" 2>&1; then
		warn "The graceful editor drain did not finish within ${timeout_seconds} seconds."
	fi
}

stop_service() {
	local name="$1"
	local pid="${SERVICE_PIDS[$name]:-}"
	if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
		kill -TERM "$pid" >/dev/null 2>&1 || true
	fi
}

stop_services() {
	local name
	local pid
	for name in nginx converter docservice; do
		stop_service "$name"
	done

	for _ in {1..20}; do
		local running=false
		for name in "${SERVICE_ORDER[@]}"; do
			pid="${SERVICE_PIDS[$name]:-}"
			if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
				running=true
			fi
		done
		is_enabled "$running" || break
		sleep 1
	done

	for name in "${SERVICE_ORDER[@]}"; do
		pid="${SERVICE_PIDS[$name]:-}"
		if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
			kill -KILL "$pid" >/dev/null 2>&1 || true
		fi
		[[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
	done
}

wait_for_managed_service() {
	local -a pids=()
	local name
	for name in "${SERVICE_ORDER[@]}"; do
		pids+=("${SERVICE_PIDS[$name]}")
	done
	wait -n "${pids[@]}"
}
