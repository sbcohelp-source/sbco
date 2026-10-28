#!/usr/bin/env bash
# Source from any directory; prefer workspace tools without modifying system tools.
SBCO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -d "$SBCO_ROOT/.tools/cargo" ]; then
  export CARGO_HOME="$SBCO_ROOT/.tools/cargo"
  export RUSTUP_HOME="$SBCO_ROOT/.tools/rustup"
  export PATH="$CARGO_HOME/bin:$PATH"
fi
if [ -d "$SBCO_ROOT/.tools/node-v26.12.1-linux-x64" ]; then
  export PATH="$SBCO_ROOT/.tools/node-v26.12.1-linux-x64/bin:$PATH"
fi
if [ -d "$SBCO_ROOT/.tools/js/node_modules/.bin" ]; then
  export PATH="$SBCO_ROOT/.tools/js/node_modules/.bin:$PATH"
fi
if [ -f "$SBCO_ROOT/.env.local" ]; then
  set -a
  source "$SBCO_ROOT/.env.local"
  set +a
fi
export DATABASE_URL="${DATABASE_URL:-postgresql://sbco:${POSTGRES_PASSWORD:-}@127.0.0.1:55438/sbco}"
export SBCO_DATA_DIR="${SBCO_DATA_DIR:-$SBCO_ROOT/data}"
