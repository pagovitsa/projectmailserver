#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
TOKEN_FILE=${CLOUDFLARE_TOKEN_FILE:-$PROJECT_DIR/secrets/cloudflare.ini}
ENV_FILE=${ENV_FILE:-$PROJECT_DIR/.env}

read_env_value() {
  key=$1
  file=$2

  awk -v key="$key" '
    index($0, "=") > 0 {
      current_key = substr($0, 1, index($0, "=") - 1)
      if (current_key == key) {
        print substr($0, index($0, "=") + 1)
        exit
      }
    }
  ' "$file"
}

# shellcheck disable=SC1091
. "$SCRIPT_DIR/cloudflare-api.sh"

if [ ! -f "$ENV_FILE" ]; then
  printf 'Δεν βρέθηκε το env file: %s\n' "$ENV_FILE" >&2
  exit 1
fi

zone=$(read_env_value MAILSERVER_ZONE "$ENV_FILE")

if [ -z "$zone" ]; then
  printf 'Το MAILSERVER_ZONE λείπει από το .env\n' >&2
  exit 1
fi

cf_init "$TOKEN_FILE"
cf_verify_token

zone_id=$(cf_get_zone_id_exact "$zone")

if [ -z "$zone_id" ]; then
  printf 'Το Cloudflare token είναι έγκυρο αλλά δεν βλέπει το zone: %s\n' "$zone" >&2
  printf 'Έλεγξε ότι το token έχει τουλάχιστον Zone:Zone:Read και Zone:DNS:Edit για αυτό το zone.\n' >&2
  exit 1
fi

printf 'Cloudflare token και zone access: OK (%s)\n' "$zone"
