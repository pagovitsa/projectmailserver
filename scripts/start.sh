#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")

cd "$PROJECT_DIR"

docker compose run --rm dns-sync
docker compose run --rm certbot-init
docker compose up -d mailserver certbot-renew roundcube
./scripts/sync-dkim.sh
