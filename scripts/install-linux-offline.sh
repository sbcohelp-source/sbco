#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 26.04 && "$(dpkg --print-architecture)" == amd64 ]] || { echo 'This bundle requires Ubuntu 26.04 amd64.' >&2; exit 1; }
[[ "$EUID" == 0 ]] || { echo 'Run this installer with sudo.' >&2; exit 1; }
sha256sum --check SHA256SUMS >/dev/null
# APT may resolve a Pre-Depends by its archive name even for explicit local paths.
# Populate its cache so no package download is necessary during that phase.
mkdir -p /var/cache/apt/archives
cp -n "$PWD"/packages/*.deb /var/cache/apt/archives/
package=$(dpkg-deb -f SBCO.deb Package)
version=$(dpkg-deb -f SBCO.deb Version)
architecture=$(dpkg-deb -f SBCO.deb Architecture)
cp SBCO.deb "/var/cache/apt/archives/${package}_${version}_${architecture}.deb"
sources=$(mktemp -d)
trap 'rm -rf "$sources"' EXIT
touch "$sources/sources.list"
mkdir "$sources/parts"
# Disabling all package sources makes the no-network requirement explicit.
apt-get -y --no-download --no-install-recommends \
  -o "Dir::Etc::sourcelist=$sources/sources.list" -o "Dir::Etc::sourceparts=$sources/parts" \
  install "$PWD"/packages/*.deb "$PWD/SBCO.deb"
echo 'SBCO is installed. Open SBCO from your applications menu as your regular user.'
