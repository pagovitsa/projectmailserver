#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
TOKEN_FILE=${CLOUDFLARE_TOKEN_FILE:-$PROJECT_DIR/secrets/cloudflare.ini}
KEYS_ROOT=${DKIM_KEYS_ROOT:-$PROJECT_DIR/config/opendkim/keys}
DKIM_COMMENT='managed-by=mailserver-dkim'

# shellcheck disable=SC1091
. "$SCRIPT_DIR/cloudflare-api.sh"

extract_dkim_value() {
  dkim_file=$1

  awk '
    {
      line = $0
      while (match(line, /"[^"]*"/)) {
        printf "%s", substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$dkim_file"
}

cf_init "$TOKEN_FILE"

if [ ! -d "$KEYS_ROOT" ]; then
  printf 'Δεν βρέθηκαν DKIM keys για συγχρονισμό ακόμη.\n' >&2
  exit 0
fi

dkim_files=$(find "$KEYS_ROOT" -mindepth 2 -maxdepth 2 -type f -name '*.txt' | sort)

if [ -z "$dkim_files" ]; then
  printf 'Δεν βρέθηκαν DKIM TXT αρχεία για συγχρονισμό ακόμη.\n' >&2
  exit 0
fi

printf '%s\n' "$dkim_files" | while IFS= read -r dkim_file; do
  [ -n "$dkim_file" ] || continue

  domain=$(basename "$(dirname "$dkim_file")")
  selector=$(basename "$dkim_file" .txt)
  record_name="$selector._domainkey.$domain"
  record_value=$(extract_dkim_value "$dkim_file")

  if [ -z "$record_value" ]; then
    printf 'Αδυναμία ανάγνωσης DKIM value από %s\n' "$dkim_file" >&2
    exit 1
  fi

  zone_info=$(cf_find_zone_for_name "$domain" || true)
  if [ -z "$zone_info" ]; then
    printf 'Cloudflare zone δεν βρέθηκε για DKIM domain: %s\n' "$domain" >&2
    exit 1
  fi

  zone_id=${zone_info%%|*}
  cf_upsert_record "$zone_id" TXT "$record_name" "$record_value" 300 false dkim '' "$DKIM_COMMENT"
done
