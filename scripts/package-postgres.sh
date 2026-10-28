#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_bin="${SBCO_POSTGRES_BIN:-/usr/lib/postgresql/18/bin}"
source_share="${SBCO_POSTGRES_SHARE:-/usr/share/postgresql/18}"
destination=apps/desktop/src-tauri/resources/postgres
"$source_bin/postgres" --version | grep -q ' 18.6' || { echo 'PostgreSQL 18.6 is required'; exit 1; }
mkdir -p "$destination/bin" "$destination/share" "$destination/lib" "$destination/licenses"
cp -a "$source_bin/." "$destination/bin/"
cp -a "$source_share/." "$destination/share/"
cp -a "${source_bin%/bin}/lib/." "$destination/lib/"
# Bundle non-glibc dependencies. The desktop release targets Ubuntu 26.04 x86_64.
while IFS= read -r library; do
  case "$(basename "$library")" in libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*|ld-linux*) continue;; esac
  cp -L "$library" "$destination/lib/"
  owner=$(dpkg-query -S "$library" 2>/dev/null | head -1 | cut -d: -f1 || true)
  if [ -n "$owner" ] && [ -f "/usr/share/doc/$owner/copyright" ]; then
    cp "/usr/share/doc/$owner/copyright" "$destination/licenses/$owner.txt"
  fi
done < <(ldd "$source_bin"/* 2>/dev/null | awk '/=> \/.* \(/ {print $3}' | sort -u)
cp /usr/share/doc/postgresql-18/copyright "$destination/licenses/postgresql.txt"
(cd "$destination" && find bin lib share licenses -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
printf 'Packaged PostgreSQL 18.6 resources in %s\n' "$destination"
