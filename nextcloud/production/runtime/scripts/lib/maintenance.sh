#!/usr/bin/env bash

maintenance_lock_acquire() {
	local lock_pid=""
	local lock_start_time=""
	local current_start_time=""
	local quiet="${1:-false}"
	local owner_pid="${BASHPID:-$$}"

	if mkdir "$MAINTENANCE_LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$owner_pid" > "${MAINTENANCE_LOCK_DIR}/pid"
		awk '{ print $22 }' "/proc/${owner_pid}/stat" > "${MAINTENANCE_LOCK_DIR}/start_time" 2>/dev/null || true
		return 0
	fi

	if [[ -r "${MAINTENANCE_LOCK_DIR}/pid" ]]; then
		lock_pid="$(tr -cd '0-9' < "${MAINTENANCE_LOCK_DIR}/pid")"
	fi
	if [[ -r "${MAINTENANCE_LOCK_DIR}/start_time" ]]; then
		lock_start_time="$(tr -cd '0-9' < "${MAINTENANCE_LOCK_DIR}/start_time")"
	fi
	if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" >/dev/null 2>&1; then
		current_start_time="$(awk '{ print $22 }' "/proc/${lock_pid}/stat" 2>/dev/null || true)"
	fi
	if [[ -n "$lock_pid" && -n "$current_start_time" \
		&& ( -z "$lock_start_time" || "$lock_start_time" == "$current_start_time" ) ]]; then
		is_enabled "$quiet" || warn "Another backup, update, or cron operation is already running (PID ${lock_pid})."
		return 1
	fi

	# A console process can be killed independently of the server. Reclaim only its exact stale lock.
	rm -f -- "${MAINTENANCE_LOCK_DIR}/pid" "${MAINTENANCE_LOCK_DIR}/start_time"
	if ! rmdir "$MAINTENANCE_LOCK_DIR" 2>/dev/null || ! mkdir "$MAINTENANCE_LOCK_DIR" 2>/dev/null; then
		warn "Could not reclaim the stale maintenance-operation lock."
		return 1
	fi
	printf '%s\n' "$owner_pid" > "${MAINTENANCE_LOCK_DIR}/pid"
	awk '{ print $22 }' "/proc/${owner_pid}/stat" > "${MAINTENANCE_LOCK_DIR}/start_time" 2>/dev/null || true
}

maintenance_lock_release() {
	local owner=""
	local owner_pid="${BASHPID:-$$}"
	[[ -d "$MAINTENANCE_LOCK_DIR" ]] || return 0
	if [[ -r "${MAINTENANCE_LOCK_DIR}/pid" ]]; then
		owner="$(tr -cd '0-9' < "${MAINTENANCE_LOCK_DIR}/pid")"
	fi
	[[ -z "$owner" || "$owner" == "$owner_pid" ]] || return 0
	rm -f -- "${MAINTENANCE_LOCK_DIR}/pid" "${MAINTENANCE_LOCK_DIR}/start_time"
	rmdir "$MAINTENANCE_LOCK_DIR" 2>/dev/null || true
}

nextcloud_version() {
	local version_file="${WEB_ROOT}/version.php"
	[[ -f "$version_file" ]] || return 1
	sed -n "s/.*OC_VersionString[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$version_file" | head -n 1
}

maintenance_mode_is_enabled() {
	local value
	value="$(occ config:system:get maintenance 2>/dev/null || true)"
	case "$value" in
		1|true|TRUE|yes|YES|on|ON) return 0 ;;
		*) return 1 ;;
	esac
}

recover_backup_maintenance_mode() {
	[[ -f "$BACKUP_MAINTENANCE_MARKER" ]] || return 0
	log "Recovering maintenance mode left by an interrupted backup."
	if ! occ maintenance:mode --off; then
		warn "Could not disable backup-owned maintenance mode."
		return 1
	fi
	rm -f -- "$BACKUP_MAINTENANCE_MARKER"
}

backup_source_paths() {
	local data_directory
	local data_relative
	local resolved_data
	data_directory="$(occ config:system:get datadirectory 2>/dev/null || true)"
	[[ -n "$data_directory" ]] || {
		warn "Nextcloud data directory is not configured."
		return 1
	}
	resolved_data="$(readlink -f -- "$data_directory" 2>/dev/null || true)"
	case "$resolved_data" in
		"${SERVER_ROOT}/"*) data_relative="${resolved_data#"${SERVER_ROOT}"/}" ;;
		*)
			warn "The data directory must be inside ${SERVER_ROOT} for an in-panel backup: ${data_directory}"
			return 1
			;;
	esac
	[[ -n "$data_relative" && "$data_relative" != backups && "$data_relative" != backups/* ]] || {
		warn "Refusing to back up an unsafe data-directory path: ${data_directory}"
		return 1
	}

	printf '%s\n' www .secrets services/whiteboard-recordings
	case "$data_relative" in
		www|www/*|.secrets|.secrets/*|services/whiteboard-recordings|services/whiteboard-recordings/*) ;;
		*) printf '%s\n' "$data_relative" ;;
	esac
}

estimate_backup_bytes() {
	local relative
	local bytes
	local total=0
	for relative in "$@" services/mariadb/data; do
		[[ -e "${SERVER_ROOT}/${relative}" ]] || continue
		bytes="$(du -sb -- "${SERVER_ROOT}/${relative}" | awk 'NR == 1 { print $1 }')"
		[[ "$bytes" =~ ^[0-9]+$ ]] || return 1
		total=$((total + bytes))
	done
	printf '%s\n' "$total"
}

create_full_backup() {
	local timestamp
	local partial_directory
	local final_directory
	local dump_binary
	local available_bytes
	local estimated_bytes
	local required_bytes
	local version
	local maintenance_changed=false
	local status=0
	local command_name
	local -a source_paths=()

	for command_name in tar gzip sha256sum du df awk readlink mariadb-dump; do
		command -v "$command_name" >/dev/null 2>&1 || {
			warn "${command_name} is unavailable in the runtime image."
			return 1
		}
	done
	dump_binary="$(command -v mariadb-dump)"
	mapfile -t source_paths < <(backup_source_paths) || return 1
	[[ "${#source_paths[@]}" -gt 0 ]] || {
		warn "No backup sources were found."
		return 1
	}
	estimated_bytes="$(estimate_backup_bytes "${source_paths[@]}")" || {
		warn "Could not estimate the backup size."
		return 1
	}
	available_bytes="$(df -PB1 -- "$BACKUP_ROOT" | awk 'NR == 2 { print $4 }')"
	required_bytes=$((estimated_bytes + 1073741824))
	if [[ ! "$available_bytes" =~ ^[0-9]+$ || "$available_bytes" -lt "$required_bytes" ]]; then
		warn "Not enough free disk space for a safe backup. Estimated source size: ${estimated_bytes} bytes; free: ${available_bytes:-unknown} bytes."
		return 1
	fi

	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	partial_directory="${BACKUP_ROOT}/.nextcloud-${timestamp}.partial"
	final_directory="${BACKUP_ROOT}/nextcloud-${timestamp}"
	if [[ -e "$partial_directory" || -e "$final_directory" ]]; then
		warn "A backup with timestamp ${timestamp} already exists; wait one second and retry."
		return 1
	fi
	if ! mkdir -m 700 "$partial_directory"; then
		warn "Could not create the partial backup directory: ${partial_directory}"
		return 1
	fi

	if ! maintenance_mode_is_enabled; then
		log "Enabling maintenance mode for a consistent backup."
		if ! printf '%s\n' "${BASHPID:-$$}" > "$BACKUP_MAINTENANCE_MARKER"; then
			warn "Could not create the backup maintenance ownership marker."
			return 1
		fi
		if ! occ maintenance:mode --on; then
			rm -f -- "$BACKUP_MAINTENANCE_MARKER"
			warn "Could not enable maintenance mode; backup was not started."
			return 1
		fi
		maintenance_changed=true
	fi

	version="$(nextcloud_version || printf unknown)"
	log "Creating a full backup of Nextcloud ${version}; estimated uncompressed source size is ${estimated_bytes} bytes."
	if ! "$dump_binary" \
		--protocol=socket \
		--socket="${TMP_DIR}/mariadb.sock" \
		--user=root \
		--single-transaction \
		--quick \
		--lock-tables=false \
		--default-character-set=utf8mb4 \
		--routines \
		--events \
		--triggers \
		--hex-blob \
		nextcloud > "${partial_directory}/database.sql"; then
		warn "MariaDB dump failed."
		status=1
	fi
	if [[ "$status" -eq 0 && ! -s "${partial_directory}/database.sql" ]]; then
		warn "MariaDB produced an empty dump."
		status=1
	fi

	local data_directory
	local data_relative
	data_directory="$(readlink -f -- "$(occ config:system:get datadirectory)")"
	data_relative="${data_directory#"${SERVER_ROOT}"/}"
	if [[ "$status" -eq 0 ]] && ! tar \
		--exclude="${data_relative}/updater-*/backups" \
		--exclude="${data_relative}/updater-*/downloads" \
		-czf "${partial_directory}/files.tar.gz" -C "$SERVER_ROOT" -- "${source_paths[@]}"; then
		warn "File archive creation failed."
		status=1
	fi

	if [[ "$status" -eq 0 ]]; then
		printf 'created_utc=%s\nnextcloud_version=%s\ndatabase=database.sql\nfiles=files.tar.gz\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$version" > "${partial_directory}/manifest.txt"
		chmod 600 "${partial_directory}/database.sql" "${partial_directory}/files.tar.gz" "${partial_directory}/manifest.txt"
		(
			cd "$partial_directory" || exit 1
			sha256sum database.sql files.tar.gz manifest.txt > SHA256SUMS
			sha256sum --check --status SHA256SUMS
			tar -tzf files.tar.gz >/dev/null
		) || status=1
		chmod 600 "${partial_directory}/SHA256SUMS"
	fi

	if is_enabled "$maintenance_changed"; then
		log "Disabling maintenance mode after backup."
		if ! occ maintenance:mode --off; then
			warn "Backup finished, but maintenance mode could not be disabled automatically."
			status=1
		else
			rm -f -- "$BACKUP_MAINTENANCE_MARKER"
		fi
	fi

	if [[ "$status" -ne 0 ]]; then
		warn "Backup failed. Incomplete files were retained at ${partial_directory} for diagnosis."
		return 1
	fi

	if ! mv -- "$partial_directory" "$final_directory"; then
		warn "Backup was verified but could not be finalized; it remains at ${partial_directory}."
		return 1
	fi
	log "Full backup completed and verified: ${final_directory}"
}

backup_nextcloud() {
	local status=0
	maintenance_lock_acquire || return 1
	create_full_backup || status=$?
	maintenance_lock_release
	return "$status"
}

run_post_upgrade_jobs() {
	local attempt
	local status=0
	log "Running background migrations after the version change."
	for attempt in 1 2 3; do
		if ! run_nextcloud_cron >> "${1}" 2>&1; then
			warn "Background migration run ${attempt}/3 failed; details are in ${1}."
			status=1
		fi
	done
	return "$status"
}

update_core_to_latest() {
	local updater="${WEB_ROOT}/updater/updater.phar"
	local update_log
	local before
	local after
	local pass
	local settled=false
	local channel
	local before_major
	local after_major
	local final_app_update_failed=false
	local -A seen_versions=()
	update_log="${LOG_DIR}/updater-$(date -u +%Y%m%dT%H%M%SZ).log"

	[[ -f "$updater" ]] || {
		warn "The official Nextcloud updater is missing: ${updater}"
		return 1
	}

	channel="$(occ config:system:get updater.release.channel 2>/dev/null || true)"
	[[ -n "$channel" ]] || channel=stable
	log "Updating through the official '${channel}' release channel without skipping major versions."

	for ((pass = 1; pass <= 12; pass++)); do
		before="$(nextcloud_version || true)"
		[[ -n "$before" ]] || {
			warn "Could not determine the installed Nextcloud version."
			return 1
		}
		if [[ -n "${seen_versions[$before]:-}" ]]; then
			warn "The updater returned to an already-seen version (${before}); stopping the loop."
			return 1
		fi
		seen_versions["$before"]=1

		log "Official updater pass ${pass}/12 (currently ${before})."
		if ! (
			cd "$WEB_ROOT" || exit 1
			PHP_INI_SCAN_DIR="$PHP_CLI_SCAN_DIR" "$PHP_CLI_BIN" -c "${SERVER_ROOT}/php/php.ini" \
				updater/updater.phar --no-interaction
		) 2>&1 | tee -a "$update_log"; then
			warn "The official updater failed. Review ${update_log}; maintenance mode may intentionally remain enabled after an updater error."
			return 1
		fi

		after="$(nextcloud_version || true)"
		[[ -n "$after" ]] || {
			warn "The updater completed but the installed version can no longer be determined."
			return 1
		}
		if [[ "$after" == "$before" ]]; then
			settled=true
			break
		fi
		if [[ "$(printf '%s\n%s\n' "$before" "$after" | sort -V | tail -n 1)" != "$after" ]]; then
			warn "The updater produced a non-increasing version transition: ${before} -> ${after}."
			return 1
		fi

		log "Nextcloud core updated: ${before} -> ${after}."
		before_major="${before%%.*}"
		after_major="${after%%.*}"
		if [[ "$before_major" != "$after_major" ]]; then
			if ! run_post_upgrade_jobs "$update_log"; then
				warn "Background migrations did not finish cleanly after ${after}; stopping before the next major upgrade."
				return 1
			fi
		fi
		if ! occ app:update --all 2>&1 | tee -a "$update_log"; then
			warn "One or more apps could not be updated after ${after}; the core update will continue."
		fi
	done

	if ! is_enabled "$settled"; then
		warn "The updater changed the version on all 12 passes. Stopping to avoid an unbounded upgrade loop; rerun 'update' after reviewing ${update_log}."
		return 1
	fi
	if [[ -n "${PHP_FPM_PID:-}" ]] && kill -0 "$PHP_FPM_PID" >/dev/null 2>&1; then
		kill -USR2 "$PHP_FPM_PID" >/dev/null 2>&1 || warn "PHP-FPM could not be gracefully reloaded; restart the server to clear OPcache."
	fi

	log "Updating all compatible installed apps."
	if ! occ app:update --all 2>&1 | tee -a "$update_log"; then
		warn "One or more apps could not be updated; review ${update_log}."
		final_app_update_failed=true
	fi
	if ! configure_nextcloud; then
		warn "Core update completed, but production settings could not be fully reapplied. Review ${update_log}."
		return 1
	fi
	if ! run_version_maintenance; then
		warn "Post-update database maintenance failed. Review ${update_log}."
		return 1
	fi
	if ! check_core_integrity 2>&1 | tee -a "$update_log"; then
		warn "Core integrity validation failed after the update; review ${update_log}."
		return 1
	fi
	if ! occ status 2>&1 | tee -a "$update_log"; then
		warn "Nextcloud status validation failed after the update; review ${update_log}."
		return 1
	fi
	if is_enabled "$final_app_update_failed"; then
		warn "Nextcloud core is updated, but at least one installed app is not fully updated. Review ${update_log}."
		return 1
	fi
	log "Update completed at Nextcloud $(nextcloud_version), the highest release offered by channel '${channel}' for this installation. Full updater log: ${update_log}"
}

update_nextcloud() {
	local create_backup=false
	local status=0
	case "${1:-}" in
		'') ;;
		--backup) create_backup=true ;;
		*)
			warn "Usage: update [--backup]"
			return 2
			;;
	esac
	[[ "$#" -le 1 ]] || {
		warn "Usage: update [--backup]"
		return 2
	}

	maintenance_lock_acquire || return 1
	if is_enabled "$create_backup"; then
		if ! create_full_backup; then
			maintenance_lock_release
			warn "Update cancelled because the requested full backup failed."
			return 1
		fi
	else
		warn "No full data/database backup was requested. Use 'update --backup' for a verified restorable backup first."
		log "The official updater may keep its own code snapshot, but that is not a full backup."
	fi

	update_core_to_latest || status=$?
	maintenance_lock_release
	return "$status"
}
