# Pterodactyl eggs and container images

This repository contains custom container images and importable Pterodactyl
eggs. Deployment notes live beside each egg.

Custom image-backed eggs:

| Application | Image | Egg and documentation |
| --- | --- | --- |
| Nextcloud Production | `ghcr.io/ckateptb/dockerfiles:nextcloud_production` | [`nextcloud/production`](nextcloud/production) |
| ONLYOFFICE Docs | `ghcr.io/ckateptb/dockerfiles:onlyoffice_documents` | [`onlyoffice/documents`](onlyoffice/documents) |

Both entries above delegate installation to their matching custom image, so
only the egg JSON needs to be imported into a panel.
