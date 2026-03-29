#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s <backup-archive>\n' "$0" >&2
  exit 1
fi

ARCHIVE=$1
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")

if [ ! -f "$ARCHIVE" ]; then
  printf 'Backup archive not found: %s\n' "$ARCHIVE" >&2
  exit 1
fi

printf 'Make sure docker compose is stopped before restore.\n' >&2
tar xzf "$ARCHIVE" -C "$PROJECT_DIR"
printf 'If you restored onto a new server, review .env and rerun ./scripts/start.sh.\n' >&2
printf 'Restore completed into: %s\n' "$PROJECT_DIR"
