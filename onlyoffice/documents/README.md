# ONLYOFFICE Docs for Pterodactyl

This directory packages ONLYOFFICE Docs as a dedicated Pterodactyl egg. Import
only `egg-onlyoffice-documents.json`; no runtime files need to be uploaded to
the server manually. Wings uses the same custom image for installation and
normal startup:

```text
ghcr.io/ckateptb/dockerfiles:onlyoffice_documents
```

The image is published for `linux/amd64` and `linux/arm64`. Mutable data,
generated configuration, logs, fonts, secrets, and work files live under
`/home/container`; important state therefore remains in the Pterodactyl server
volume across restarts and image replacement.

## Network layout

The egg needs one normal Pterodactyl allocation. Its Nginx listener serves the
ONLYOFFICE HTTP API and WebSocket upgrades on that same port; no second
allocation and no UDP allocation are required. TLS terminates at the external
reverse proxy.

Use a dedicated hostname such as `office.example.com`. Configure the proxy to:

- forward that hostname to the Pterodactyl allocation over HTTP;
- preserve the original `Host` header;
- send `X-Forwarded-Proto: https` when public TLS is enabled;
- pass `Upgrade` and `Connection` for WebSockets;
- allow long-running requests and sufficiently large request bodies; and
- disable response caching and HTML/JavaScript rewriting for this hostname.

Cloudflare's proxied DNS mode supports the required HTTP and WebSocket traffic.
Use Full (strict) TLS between Cloudflare and the origin whenever the origin has
a valid certificate. The egg intentionally has no public URL variable: the
runtime uses the request host and proxy headers, while the Nextcloud connector
stores the public document-server URL.

## First installation

1. Import the egg and create a server with at least 4 GB of memory and two CPU
   cores. The official deployment guidance also recommends swap space.
2. Assign one TCP allocation and point the reverse-proxy hostname at it.
3. Leave `JWT_SECRET` empty to generate a strong secret, or provide the same
   secret that will be configured in Nextcloud. Start the server once.
4. If the secret was generated, enter `jwt:show` in the Pterodactyl console.
   The same value is stored in `/home/container/.secrets/jwt_secret`; treat it
   as a password.
5. Install and enable the official **ONLYOFFICE** app in Nextcloud. In its
   administration settings enter `https://office.example.com/` as the
   document editing service address, then enter the JWT secret and the header
   name `Authorization`.
6. Run the connector check from the Nextcloud console:

   ```text
   occ onlyoffice:documentserver --check
   ```

Both browser clients and Nextcloud itself must be able to reach the public
document-server hostname. ONLYOFFICE Docs must also be able to download files
from and post callbacks to the configured Nextcloud URL.

## Egg variables

- `JWT_SECRET` (generated when empty): shared connector secret.
- `JWT_HEADER` (`Authorization`): JWT HTTP header; it must match Nextcloud.
- `ALLOW_PRIVATE_IP_ADDRESS` (`0`): allows private storage targets.
- `USE_UNAUTHORIZED_STORAGE` (`0`): accepts invalid storage TLS certificates.
- `LOG_LEVEL` (`WARN`): application log threshold.
- `NGINX_ACCESS_LOG` (`0`): enables per-request Nginx access logging.
- `UPLOAD_LIMIT` (`2G`): maximum request body accepted by bundled Nginx.

Allowing private storage addresses relaxes an SSRF protection boundary. Prefer
a public, HTTPS Nextcloud URL. Enable `ALLOW_PRIVATE_IP_ADDRESS` only when the
Document Server must reach a controlled RFC 1918 or loopback endpoint. Likewise,
use `USE_UNAUTHORIZED_STORAGE` only as a temporary measure for a controlled
self-signed deployment.

## Updates and shutdown

The workflow publishes a stable image tag and an immutable commit-SHA tag.
Restart with image pulling enabled, or reinstall the Pterodactyl server, to
refresh the image-managed runtime; the installer preserves server-volume
state. Back up the server volume before a version upgrade.

The persistent JWT value deliberately wins over a changed egg variable, so an
ordinary restart cannot silently break the connector. To rotate it, first run
`prepare-shutdown`, stop the server, update Nextcloud and the egg variable,
remove `.secrets/jwt_secret`, and then start the server. Active editor sessions
become invalid when the secret changes.

Document editing processes need time to flush pending changes. Stop the server
normally and configure Wings with a shutdown timeout of up to five minutes for
this workload. Avoid killing the container while documents are being edited.

## Licensing

ONLYOFFICE Docs / DocumentServer is free software distributed under the GNU
Affero General Public License version 3. See `LICENSE-AGPL-3.0` and `NOTICE` in
this directory. The repository's root license does not replace the upstream
license or trademark terms for software included in the image.
