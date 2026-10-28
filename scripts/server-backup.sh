#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
backup_path=${1:?Provide a new output .dump path}
if [ -e "$backup_path" ]; then echo 'Choose a new backup path; existing files are preserved.' >&2; exit 1; fi
umask 077
temporary="${backup_path}.partial"
trap 'rm -f "$temporary"' EXIT
docker --context "${SBCO_DOCKER_CONTEXT:-default}" compose exec -T database pg_dump -U sbco -d sbco --format=custom > "$temporary"
mv "$temporary" "$backup_path"
sha256sum "$backup_path" > "${backup_path}.sha256"
echo 'Database, source workbooks, issued PDFs, accounts and history backed up.'
