#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
actual=$(mktemp)
trap 'rm -f "$actual"' EXIT
cargo run --quiet --locked -p sbco-api -- --export-types > "$actual"
diff -u packages/client/src/generated.ts "$actual"
