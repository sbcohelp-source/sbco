#!/usr/bin/env bash
# Run inside the Ubuntu 26.04 builder. Resolves a complete runtime dependency set.
set -euo pipefail
cd "$(dirname "$0")/.."
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 26.04 && "$(dpkg --print-architecture)" == amd64 ]] || { echo 'Use Ubuntu 26.04 amd64.' >&2; exit 1; }
installer=${1:-apps/desktop/src-tauri/target/debug/bundle/deb/SBCO_0.1.0_amd64.deb}
[[ -f "$installer" ]] || { echo 'Build the desktop installer first.' >&2; exit 1; }
destination=${SBCO_OFFLINE_OUTPUT:-data/offline-linux-ubuntu-26.04-amd64}
mkdir -p "$destination/packages/partial"
destination=$(realpath "$destination")
apt-get update
empty_status=$(mktemp)
trap 'rm -f "$empty_status"' EXIT
# An empty dpkg status prevents dependencies installed on the builder from being omitted.
apt-get -y --download-only --no-install-recommends \
  -o "Dir::State::status=$empty_status" -o "Dir::Cache::archives=$destination/packages" \
  install libwebkit2gtk-4.1-0 libgtk-3-0t64 libssl3t64 ca-certificates
# APT restricts its temporary download directory; it is not part of the bundle.
rmdir "$destination/packages/partial"
cp "$installer" "$destination/SBCO.deb"
cp scripts/install-linux-offline.sh "$destination/install.sh"
chmod 755 "$destination/install.sh"
dpkg-deb -f "$destination/SBCO.deb" Package Version Architecture > "$destination/INSTALLER.txt"
for package in "$destination"/packages/*.deb; do dpkg-deb -f "$package" Package Version Architecture; done > "$destination/PACKAGES.txt"
(cd "$destination" && find . -maxdepth 2 -type f ! -name SHA256SUMS ! -name lock -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
echo "Offline installer and runtime packages are ready in $destination"
