# Java Multi-Stack Egg for Pterodactyl
Universal Pterodactyl Egg for Java projects
Supports: Java 8, 11, 16, 17, 21, 22, 24 (OpenJDK & Zulu), MariaDB, MongoDB, Redis, Playwright, custom startup, dynamic ports, and mandatory GitHub cloning.

## Features
* Multiple Java versions: select via JAVA_VERSION
* Optional MariaDB, MongoDB, Redis: run only what you need (just leave the port empty to skip)
* Mandatory GitHub cloning: clones and builds your project from a GitHub repository
  * default build using gradle, you can customize build with build.sh in root of your repository
* Custom startup: configure any launch command via variable
* Up to 10 additional ports
* Pre-installed: Playwright, ffmpeg, webp, and more
* JDK auto-detection: always uses the selected Java version
* Clean startup: only your app’s logs are shown

## Quickstart
1. Import the Egg into your Pterodactyl panel.
2. Create server, fill in the required variables in the server setup form.
3. Enjoy

## Note
To update your project from git, use the re-install button in your server settings.

