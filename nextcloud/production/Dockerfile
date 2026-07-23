# syntax=docker/dockerfile:1.7

FROM --platform=$TARGETPLATFORM node:24-bookworm-slim AS whiteboard-builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG WHITEBOARD_VERSION=1.5.9
ARG WHITEBOARD_SHA256=35df7cac14ca69e34c183c9feee932ccfdaf1383406058480061c94db37164fc

ENV PUPPETEER_SKIP_DOWNLOAD=1

# hadolint ignore=DL3008
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends ca-certificates curl g++ make python3; \
	rm -rf /var/lib/apt/lists/*

COPY production/runtime/scripts/patch-whiteboard.mjs /tmp/patch-whiteboard.mjs

WORKDIR /opt/nextcloud-egg/whiteboard

RUN set -eux; \
	curl -fsSL --retry 5 --retry-delay 2 \
		-o /tmp/whiteboard.tar.gz \
		"https://github.com/nextcloud/whiteboard/archive/refs/tags/v${WHITEBOARD_VERSION}.tar.gz"; \
	echo "${WHITEBOARD_SHA256}  /tmp/whiteboard.tar.gz" | sha256sum --check --status; \
	tar -xzf /tmp/whiteboard.tar.gz -C /tmp; \
	install -d /opt/nextcloud-egg/whiteboard/src; \
	cp "/tmp/whiteboard-${WHITEBOARD_VERSION}/package.json" \
		"/tmp/whiteboard-${WHITEBOARD_VERSION}/package-lock.json" \
		/opt/nextcloud-egg/whiteboard/; \
	cp -a "/tmp/whiteboard-${WHITEBOARD_VERSION}/websocket_server" \
		/opt/nextcloud-egg/whiteboard/; \
	cp -a "/tmp/whiteboard-${WHITEBOARD_VERSION}/src/shared" \
		/opt/nextcloud-egg/whiteboard/src/; \
	if [[ -f "/tmp/whiteboard-${WHITEBOARD_VERSION}/COPYING" ]]; then \
		cp "/tmp/whiteboard-${WHITEBOARD_VERSION}/COPYING" \
			/opt/nextcloud-egg/whiteboard/; \
	fi; \
	echo "${WHITEBOARD_VERSION}" > /opt/nextcloud-egg/whiteboard/VERSION; \
	node /tmp/patch-whiteboard.mjs \
		/opt/nextcloud-egg/whiteboard/websocket_server/Utilities/ConfigUtility.js; \
	npm ci --omit=dev --no-audit --no-fund; \
	node --input-type=module --eval \
		"await Promise.all([import('./websocket_server/Services/SocketService.js'), import('./websocket_server/Services/VotingService.js')])"; \
	npm cache clean --force; \
	rm -rf /tmp/whiteboard.tar.gz "/tmp/whiteboard-${WHITEBOARD_VERSION}" /root/.npm

FROM --platform=$TARGETPLATFORM debian:bookworm-slim

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

LABEL org.opencontainers.image.source="https://github.com/CKATEPTb/dockerfiles"
LABEL org.opencontainers.image.description="Production Nextcloud runtime for Pterodactyl"
LABEL org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
	USER=container \
	HOME=/home/container \
	PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
	CHROME_EXECUTABLE_PATH=/usr/bin/chromium \
	CHROME_BIN=/usr/bin/chromium

# Debian/Sury package versions intentionally follow the rebuilt Bookworm snapshot.
# hadolint ignore=DL3008
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
	install -d -m 0755 /etc/apt/keyrings; \
	curl -fsSL --retry 5 https://packages.sury.org/php/apt.gpg -o /tmp/php.gpg; \
	gpg --dearmor --yes --output /etc/apt/keyrings/deb.sury.org-php.gpg /tmp/php.gpg; \
	echo "deb [signed-by=/etc/apt/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ bookworm main" \
		> /etc/apt/sources.list.d/php.list; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		chromium \
		ffmpeg \
		libmagickcore-6.q16-6-extra \
		librsvg2-2 \
		mariadb-client \
		mariadb-common \
		mariadb-server-core \
		nginx \
		openssl \
		php8.4-apcu \
		php8.4-bcmath \
		php8.4-bz2 \
		php8.4-cli \
		php8.4-common \
		php8.4-curl \
		php8.4-fpm \
		php8.4-gd \
		php8.4-gmp \
		php8.4-imagick \
		php8.4-intl \
		php8.4-ldap \
		php8.4-mbstring \
		php8.4-mysql \
		php8.4-opcache \
		php8.4-redis \
		php8.4-smbclient \
		php8.4-xml \
		php8.4-zip \
		redis-server \
		rsync \
		tar \
		unzip \
		util-linux \
		xz-utils; \
	apt-get purge -y --auto-remove gnupg; \
	apt-get clean; \
	rm -rf /tmp/php.gpg /var/lib/apt/lists/* /var/lib/mysql /var/lib/redis; \
	rm -f /etc/nginx/sites-enabled/default; \
	install -d -m 0755 /home/container /opt/nextcloud-egg

COPY --from=whiteboard-builder /usr/local/ /usr/local/
COPY --from=whiteboard-builder /opt/nextcloud-egg/whiteboard/ /opt/nextcloud-egg/whiteboard/
COPY production/runtime/ /opt/nextcloud-egg/runtime/
COPY production/install.sh production/entrypoint.sh production/IMAGE_API_VERSION /opt/nextcloud-egg/

WORKDIR /opt/nextcloud-egg/whiteboard

# The single-quoted PHP snippets intentionally prevent shell interpolation.
# hadolint ignore=SC2016
RUN set -eux; \
	chmod 0755 \
		/opt/nextcloud-egg/install.sh \
		/opt/nextcloud-egg/entrypoint.sh \
		/opt/nextcloud-egg/runtime/scripts/start.sh \
		/opt/nextcloud-egg/runtime/scripts/log-stream-supervisor.sh \
		/opt/nextcloud-egg/runtime/scripts/lib/*.sh; \
	for command_name in \
		chromium ffmpeg mariadb mariadb-admin mariadb-dump mariadb-install-db mariadbd \
		nginx node npm php8.4 php-fpm8.4 redis-cli redis-server rsync setpriv; do \
		command -v "$command_name" >/dev/null; \
	done; \
	php8.4 -r 'foreach (["apcu", "imagick", "redis"] as $extension) { if (!extension_loaded($extension)) { fwrite(STDERR, "Missing PHP extension: $extension\n"); exit(1); } }'; \
	php8.4 -r 'exit(count(Imagick::queryFormats("SVG")) > 0 ? 0 : 1);'; \
	node --input-type=module --eval \
		"await Promise.all([import('./websocket_server/Services/SocketService.js'), import('./websocket_server/Services/VotingService.js')])"; \
	grep -Fq 'readonly INSTALL_TMP="${SERVER_DIR}/.nextcloud-egg-install"' \
		/opt/nextcloud-egg/install.sh; \
	env -i STARTUP='command -v mariadbd >/dev/null' \
		/bin/bash /opt/nextcloud-egg/entrypoint.sh; \
	env -i /bin/bash -c \
		'source /opt/nextcloud-egg/runtime/scripts/lib/common.sh; resolve_command mariadbd >/dev/null'; \
	cp -a /opt/nextcloud-egg/runtime/nginx /home/container/nginx; \
	install -d /home/container/logs /home/container/www \
		/home/container/tmp/{client-body,fastcgi,proxy,scgi,uwsgi}; \
	chown -R 65534:65534 /home/container; \
	setpriv --reuid=65534 --regid=65534 --clear-groups \
		nginx -t -c /home/container/nginx/nginx.conf -p /home/container; \
	rm -rf /home/container/logs /home/container/nginx /home/container/tmp /home/container/www; \
	test "$(cat /opt/nextcloud-egg/IMAGE_API_VERSION)" = 1

# Pterodactyl's installer must start as root; Wings overrides the runtime UID/GID.
# hadolint ignore=DL3002
USER root
WORKDIR /home/container

CMD ["/bin/bash", "/opt/nextcloud-egg/entrypoint.sh"]
