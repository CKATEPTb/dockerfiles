# syntax=docker/dockerfile:1.7

ARG ONLYOFFICE_IMAGE=onlyoffice/documentserver:9.4.0.1@sha256:3ab6ebc7c605e5a32b7ae3ff19daed4925090245acc8100ce2230bd766c88212

FROM ${ONLYOFFICE_IMAGE} AS rootfs

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

# The official Community Edition 9.4 image contains the consolidated editor
# services. Node.js renders safe per-start configuration and rsync supports the
# Pterodactyl installer without downloading application code at runtime.
# hadolint ignore=DL3008
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends nodejs rsync; \
	documentserver_version="$(dpkg-query -W -f='${Version}' onlyoffice-documentserver)"; \
	api_script=/var/www/onlyoffice/documentserver/web-apps/apps/api/documents/api.js; \
	all_fonts_web=/var/www/onlyoffice/documentserver/sdkjs/common/AllFonts.js; \
	all_fonts_converter=/var/www/onlyoffice/documentserver/server/FileConverter/bin/AllFonts.js; \
	font_selection=/var/www/onlyoffice/documentserver/server/FileConverter/bin/font_selection.bin; \
	asset_cache_tag_file=/opt/onlyoffice-egg/ASSET_CACHE_TAG; \
	documentserver-generate-allfonts.sh true true; \
	cache_tag="$( \
		{ \
			printf '%s\n' "$documentserver_version"; \
			sha256sum "$all_fonts_web" "$all_fonts_converter" "$font_selection"; \
		} | sha256sum | cut -c1-16 \
	)"; \
	install -d -m 0755 "$(dirname "$asset_cache_tag_file")"; \
	printf '%s\n' "$cache_tag" > "$asset_cache_tag_file"; \
	documentserver-flush-cache.sh --hash "$cache_tag" --restart false; \
	test -s "$api_script"; \
	grep -Fq "$cache_tag" "$api_script"; \
	! grep -Fq '{{HASH_POSTFIX}}' "$api_script"; \
	test -s "$all_fonts_web"; \
	test -s "$all_fonts_converter"; \
	test -s "$font_selection"; \
	chmod 0644 \
		"$api_script" \
		"$all_fonts_web" \
		"$all_fonts_converter" \
		"$font_selection" \
		"$asset_cache_tag_file"; \
	apt-get clean; \
	rm -rf /var/lib/apt/lists/*; \
	install -d -m 0755 \
		/home/container \
		/opt/onlyoffice-egg/upstream-config; \
	cp -a /etc/onlyoffice/documentserver/. /opt/onlyoffice-egg/upstream-config/; \
	chmod -R a+rX /opt/onlyoffice-egg/upstream-config

COPY documents/runtime/ /opt/onlyoffice-egg/runtime/
COPY documents/entrypoint.sh documents/install.sh documents/IMAGE_API_VERSION /opt/onlyoffice-egg/
COPY documents/LICENSE-AGPL-3.0 /usr/share/licenses/onlyoffice-documentserver/AGPL-3.0.txt
COPY documents/NOTICE /usr/share/licenses/onlyoffice-documentserver/PTERODACTYL-NOTICE.txt

# Flattened symlinks keep all mutable state in the Pterodactyl server volume.
# The final scratch stage intentionally drops the official image's VOLUME and
# root-only ENTRYPOINT metadata while retaining its version-matched rootfs.
RUN set -eux; \
	chmod 0755 \
		/opt/onlyoffice-egg/entrypoint.sh \
		/opt/onlyoffice-egg/install.sh \
		/opt/onlyoffice-egg/runtime/scripts/start.sh \
		/opt/onlyoffice-egg/runtime/scripts/configure.mjs \
		/opt/onlyoffice-egg/runtime/scripts/lib/common.sh \
		/opt/onlyoffice-egg/runtime/scripts/lib/services.sh \
		/opt/onlyoffice-egg/runtime/scripts/lib/console.sh; \
	for mutable_path in \
		/var/log/onlyoffice \
		/var/lib/onlyoffice \
		/var/www/onlyoffice/Data \
		/usr/share/fonts/truetype/custom; do \
		rm -rf -- "$mutable_path"; \
	done; \
	ln -s /home/container/logs/onlyoffice /var/log/onlyoffice; \
	ln -s /home/container/data/onlyoffice-lib /var/lib/onlyoffice; \
	ln -s /home/container/data/onlyoffice-data /var/www/onlyoffice/Data; \
	ln -s /home/container/data/onlyoffice-data/custom-fonts /usr/share/fonts/truetype/custom; \
	bash -n \
		/opt/onlyoffice-egg/entrypoint.sh \
		/opt/onlyoffice-egg/install.sh \
		/opt/onlyoffice-egg/runtime/scripts/start.sh \
		/opt/onlyoffice-egg/runtime/scripts/lib/common.sh \
		/opt/onlyoffice-egg/runtime/scripts/lib/services.sh \
		/opt/onlyoffice-egg/runtime/scripts/lib/console.sh; \
	node --check /opt/onlyoffice-egg/runtime/scripts/configure.mjs; \
	command -v nginx >/dev/null; \
	test -x /var/www/onlyoffice/documentserver/server/DocService/docservice; \
	test -x /var/www/onlyoffice/documentserver/server/FileConverter/converter; \
	test "$(tr -d '\r\n' < /opt/onlyoffice-egg/IMAGE_API_VERSION)" = 1

FROM scratch

COPY --from=rootfs / /

LABEL org.opencontainers.image.source="https://github.com/CKATEPTb/dockerfiles"
LABEL org.opencontainers.image.description="Rootless ONLYOFFICE Docs Community Edition runtime for Pterodactyl"
LABEL org.opencontainers.image.licenses="AGPL-3.0-only"
LABEL org.opencontainers.image.version="9.4.0.1-pterodactyl"

ENV APPLICATION_NAME=onlyoffice \
	COMPANY_NAME=onlyoffice \
	DEBIAN_FRONTEND=noninteractive \
	HOME=/home/container \
	LANG=en_US.UTF-8 \
	LANGUAGE=en_US:en \
	LC_ALL=en_US.UTF-8 \
	NODE_DISABLE_COLORS=1 \
	NODE_ENV=production-linux \
	PRODUCT_EDITION= \
	PRODUCT_NAME=documentserver \
	SERVER_PORT=8080 \
	USER=container

STOPSIGNAL SIGTERM

# The installer must start as root. Wings overrides this UID/GID for runtime.
# hadolint ignore=DL3002
USER root
WORKDIR /home/container

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=5 \
	CMD curl -fsS "http://127.0.0.1:${SERVER_PORT}/healthcheck" | grep -q true || exit 1

CMD ["/opt/onlyoffice-egg/entrypoint.sh"]
