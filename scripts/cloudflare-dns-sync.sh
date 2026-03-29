#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TOKEN_FILE=${CLOUDFLARE_TOKEN_FILE:-/run/secrets/cloudflare.ini}
DOMAINS_FILE=${DOMAINS_FILE:-/project/domains.txt}

MAILSERVER_HOSTNAME=${MAILSERVER_HOSTNAME:?MAILSERVER_HOSTNAME is required}
MAILSERVER_ZONE=${MAILSERVER_ZONE:?MAILSERVER_ZONE is required}
PRIMARY_DOMAIN=${PRIMARY_DOMAIN:?PRIMARY_DOMAIN is required}
WEBMAIL_HOSTNAME=${WEBMAIL_HOSTNAME:-}

MAILSERVER_IPV4=${MAILSERVER_IPV4:-}
MAILSERVER_IPV6=${MAILSERVER_IPV6:-}
MAIL_MX_PRIORITY=${MAIL_MX_PRIORITY:-10}
MAIL_HELO_SPF_VALUE=${MAIL_HELO_SPF_VALUE:-v=spf1 a -all}
MAIL_SPF_VALUE=${MAIL_SPF_VALUE:-v=spf1 mx -all}
MAIL_DMARC_VALUE=${MAIL_DMARC_VALUE:-v=DMARC1;p=quarantine;adkim=s;aspf=s;pct=100}

# shellcheck disable=SC1091
. "$SCRIPT_DIR/cloudflare-api.sh"

if [ ! -f "$DOMAINS_FILE" ]; then
  printf 'Domains file not found: %s\n' "$DOMAINS_FILE" >&2
  exit 1
fi

detect_ipv4() {
  curl -4 -fsS https://api.ipify.org || true
}

detect_ipv6() {
  curl -6 -fsS https://api6.ipify.org || true
}

cf_init "$TOKEN_FILE"

if [ "$MAILSERVER_IPV4" = 'auto' ]; then
  MAILSERVER_IPV4=$(detect_ipv4)
fi

if [ "$MAILSERVER_IPV6" = 'auto' ]; then
  MAILSERVER_IPV6=$(detect_ipv6)
fi
MAIL_ZONE_ID=$(cf_get_zone_id_exact "$MAILSERVER_ZONE")

if [ -z "$MAIL_ZONE_ID" ]; then
  printf 'Cloudflare zone not found for mail host zone: %s\n' "$MAILSERVER_ZONE" >&2
  exit 1
fi

if [ -n "$MAILSERVER_IPV4" ]; then
  cf_upsert_record "$MAIL_ZONE_ID" A "$MAILSERVER_HOSTNAME" "$MAILSERVER_IPV4" 300 false any
fi

if [ -n "$MAILSERVER_IPV6" ]; then
  cf_upsert_record "$MAIL_ZONE_ID" AAAA "$MAILSERVER_HOSTNAME" "$MAILSERVER_IPV6" 300 false any
fi

cf_upsert_record "$MAIL_ZONE_ID" TXT "$MAILSERVER_HOSTNAME" "$MAIL_HELO_SPF_VALUE" 300 false spf

if [ -n "$WEBMAIL_HOSTNAME" ]; then
  webmail_zone_info=$(cf_find_zone_for_name "$WEBMAIL_HOSTNAME" || true)
  webmail_zone_id=${webmail_zone_info%%|*}

  if [ -z "$webmail_zone_id" ]; then
    printf 'Cloudflare zone not found for Roundcube host: %s\n' "$WEBMAIL_HOSTNAME" >&2
    exit 1
  fi

  if [ -n "$MAILSERVER_IPV4" ]; then
    cf_upsert_record "$webmail_zone_id" A "$WEBMAIL_HOSTNAME" "$MAILSERVER_IPV4" 300 false any
  fi

  if [ -n "$MAILSERVER_IPV6" ]; then
    cf_upsert_record "$webmail_zone_id" AAAA "$WEBMAIL_HOSTNAME" "$MAILSERVER_IPV6" 300 false any
  fi
fi

if [ -z "$MAILSERVER_IPV4" ] && [ -z "$MAILSERVER_IPV6" ]; then
  printf 'Warning: neither MAILSERVER_IPV4 nor MAILSERVER_IPV6 is set, so no host A/AAAA record was synced.\n' >&2
fi

while IFS= read -r domain || [ -n "$domain" ]; do
  case "$domain" in
    ''|'#'*)
      continue
      ;;
  esac

  zone_info=$(cf_find_zone_for_name "$domain" || true)
  zone_id=${zone_info%%|*}

  if [ -z "$zone_id" ]; then
    printf 'Cloudflare zone not found for hosted domain: %s\n' "$domain" >&2
    exit 1
  fi

  cf_upsert_record "$zone_id" MX "$domain" "$MAILSERVER_HOSTNAME" 300 false any "$MAIL_MX_PRIORITY"
  cf_upsert_record "$zone_id" TXT "$domain" "$MAIL_SPF_VALUE" 300 false spf
  cf_upsert_record "$zone_id" TXT "_dmarc.$domain" "$MAIL_DMARC_VALUE" 300 false dmarc
done < "$DOMAINS_FILE"
