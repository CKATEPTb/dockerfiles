# Nextcloud Production for Pterodactyl

Multi-architecture runtime image for the production Nextcloud egg:

```text
ghcr.io/ckateptb/dockerfiles:nextcloud_production
```

The image contains Nginx, PHP 8.4, MariaDB, Redis, Node.js 24, Chromium,
FFmpeg, the patched Nextcloud Whiteboard collaboration backend, and the egg's
installer/runtime scripts. The egg also installs the official Talk app for chat
and basic WebRTC calls. The image supports `linux/amd64` and `linux/arm64`.

Pterodactyl imports only `egg-nextcloud-production.json`. Wings pulls this same
image for installation and normal runtime. No extra files need to be uploaded
to the server.

Immutable image assets live under `/opt/nextcloud-egg`. Persistent Nextcloud
core, user data, MariaDB data, configuration, logs, secrets, recordings, and
backups live under `/home/container` and survive image updates or reinstalls.

The image exposes no additional ports. Nginx, PHP-FPM, MariaDB, Redis, and the
Whiteboard WebSocket backend run in one container; only the Pterodactyl TCP
allocation is public. TLS still terminates at the user's reverse proxy.

Cloudflare's normal HTTP proxy can carry the Nextcloud and WebSocket signaling
traffic, but it does not replace TURN for WebRTC media. Calls between restrictive
NATs may still need a separately configured TURN service; no universal TURN
credential can be bundled safely into a public image.

## Build

Pushes touching `nextcloud/**` build and publish both architectures through
`.github/workflows/nextcloud.yml`. The workflow publishes the stable tag above,
the PHP-version alias `nextcloud_8.4`, and an immutable commit-SHA tag.
