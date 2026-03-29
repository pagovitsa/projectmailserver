#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")

cd "$PROJECT_DIR"
docker compose run --rm dns-sync
./scripts/sync-dkim.sh
