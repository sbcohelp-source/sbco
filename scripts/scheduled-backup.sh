#!/usr/bin/env bash
# Runs inside the PostgreSQL tools container. Keeps 14 successful daily backups.
set -euo pipefail
umask 077
mkdir -p /backups
chmod 700 /backups
backup_once() {
  # Avoid capturing the pre-bootstrap empty installation as today's only backup.
  local ready
  ready=$(psql -Atqc "SELECT EXISTS(SELECT 1 FROM users)") || return 1
  [[ "$ready" == t ]] || return 0
  local target="/backups/auto-$(TZ=Asia/Kolkata date +%F).dump"
  if [[ -f "$target" && -f "$target.sha256" ]]; then
    (cd /backups && sha256sum --check "$(basename "$target").sha256" >/dev/null) && return 0
    echo 'Existing daily backup failed checksum verification; retrying.' >&2
  fi
  local temporary="$target.partial"
  pg_dump --format=custom --file="$temporary" || { rm -f "$temporary"; return 1; }
  pg_restore --list "$temporary" >/dev/null || { rm -f "$temporary"; return 1; }
  mv "$temporary" "$target"
  (cd /backups && sha256sum "$(basename "$target")" > "$(basename "$target").sha256")
  # Only prune this service's own filenames, after a valid new backup exists.
  mapfile -t backups < <(find /backups -maxdepth 1 -type f -name 'auto-????-??-??.dump' -printf '%f\n' | sort -r)
  for old in "${backups[@]:14}"; do rm -f -- "/backups/$old" "/backups/$old.sha256"; done
  echo 'Daily SBCO backup verified.'
}
if [[ "${1:-}" == --once ]]; then backup_once; exit; fi
while true; do
  if backup_once; then sleep 3600; else echo 'Backup failed; retrying in five minutes.' >&2; sleep 300; fi
done
