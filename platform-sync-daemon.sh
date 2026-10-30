#!/bin/bash
# Synchronize configuration and non-database user files; SQLite uses Online Backup API.
set -uo pipefail
umask 077
exec 8>/run/hermes-platform-sync.lock
flock -n 8 || exit 0
RULES=/bz/rules.txt
if [ -n "${S3_BUCKET:-}${WEBDAV_URL:-}" ]; then
  echo "Explicit S3/WebDAV platform mode requires the original adapter" >&2
  exit 1
fi
while true; do
  # Batch changes, including events which happened during the previous synchronization.
  sleep 60
  rclone sync /root/ /mnt/workspace/root/ --filter-from "$RULES" \
    --delete-excluded --create-empty-src-dirs --links --ignore-errors \
    --log-level ERROR --stats 0 --transfers 2 --checkers 4
done
