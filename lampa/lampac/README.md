# Lampac Runtime for Pterodactyl

Universal Pterodactyl Egg and Docker image for running [Lampac](https://github.com/immisterio/Lampac) — a media content
aggregator.

## Features

* ✅ Pre-installed Lampac (.NET 6 runtime)
* ✅ Built-in Chromium for scraping
* ✅ Built-in ffprobe for stream info
* ✅ TorrServer auto-download (no config needed)
* ✅ Playwright Node binary (for headless tasks)
* ✅ Docker-friendly runtime: clean structure, auto-update support
* ✅ Symlink `/home/lampac → /home/container` for Pterodactyl compatibility
* ✅ GitHub auto-update via `update.sh`
* ✅ Ready for multiplatform build (amd64 + arm64)

## Quickstart

1. Import the Egg into your Pterodactyl panel.
2. Create server, fill in the required variables in the server setup form.
3. Done. Lampac will auto-update on first run.

## Updating Lampac

To update Lampac:

- Run the `Reinstall` button in Pterodactyl panel.

## Notes

- The image includes only what is necessary to run Lampac efficiently.
- Full compatibility with `x86_64` and `arm64` via BuildKit (`buildx`).
- Based on `debian:12.5-slim` for minimum overhead.

## Links

- [Lampac on GitHub](https://github.com/immisterio/Lampac)
- [TorrServer](https://github.com/YouROK/TorrServer)
- [Pterodactyl Panel](https://pterodactyl.io/)
