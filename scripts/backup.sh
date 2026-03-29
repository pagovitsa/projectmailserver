#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
STAMP=$(date +%F-%H%M%S)
ARCHIVE="$PROJECT_DIR/backups/mailserver-$STAMP.tar.gz"

mkdir -p "$PROJECT_DIR/backups"

tar czf "$ARCHIVE" \
  -C "$PROJECT_DIR" \
  admin.sh \
  .env \
  .env.example \
  mailserver.env \
  compose.yaml \
  README.md \
  domains.txt \
  config \
  certs \
  data \
  letsencrypt \
  secrets \
  scripts

printf 'Backup created: %s\n' "$ARCHIVE"
