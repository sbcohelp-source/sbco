#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
standalone=apps/web/.next-web/standalone/apps/web
[ -f "$standalone/server.js" ] || { echo 'Build the web application first with yarn build:web.' >&2; exit 1; }
mkdir -p "$standalone/.next-web"
cp -a apps/web/.next-web/static "$standalone/.next-web/"
cp -a apps/web/public "$standalone/"
exec env HOSTNAME="${SBCO_WEB_BIND:-127.0.0.1}" PORT="${PORT:-3091}" node "$standalone/server.js"
