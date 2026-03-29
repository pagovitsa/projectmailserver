#!/usr/bin/env sh
set -eu

MODE=${1:-}

if [ -z "$MODE" ]; then
  printf 'Usage: %s <issue|renew-loop>\n' "$0" >&2
  exit 1
fi

MAILSERVER_HOSTNAME=${MAILSERVER_HOSTNAME:?MAILSERVER_HOSTNAME is required}
CERTBOT_EMAIL=${CERTBOT_EMAIL:?CERTBOT_EMAIL is required}

CREDENTIALS_FILE=${CERTBOT_CLOUDFLARE_CREDENTIALS:-/run/secrets/cloudflare.ini}
TARGET_DIR=${CERTBOT_TARGET_DIR:-/tmp/dms-certs/live}
CERT_NAME=${CERTBOT_CERT_NAME:-$MAILSERVER_HOSTNAME}
KEY_TYPE=${CERTBOT_KEY_TYPE:-ecdsa}
PROPAGATION_SECONDS=${CLOUDFLARE_DNS_PROPAGATION_SECONDS:-60}
EXTRA_DOMAINS=${CERTBOT_EXTRA_DOMAINS:-}

if [ ! -f "$CREDENTIALS_FILE" ]; then
  printf 'Cloudflare credentials file not found: %s\n' "$CREDENTIALS_FILE" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"

build_domain_args() {
  domain_args="-d $MAILSERVER_HOSTNAME"
  OLD_IFS=$IFS
  IFS=', '

  for domain in $EXTRA_DOMAINS; do
    if [ -n "$domain" ]; then
      domain_args="$domain_args -d $domain"
    fi
  done

  IFS=$OLD_IFS
  printf '%s' "$domain_args"
}

requested_domains() {
  printf '%s\n' "$MAILSERVER_HOSTNAME"

  OLD_IFS=$IFS
  IFS=', '

  for domain in $EXTRA_DOMAINS; do
    if [ -n "$domain" ]; then
      printf '%s\n' "$domain"
    fi
  done

  IFS=$OLD_IFS
}

build_common_args() {
  common_args="--non-interactive --agree-tos"
  common_args="$common_args --dns-cloudflare"
  common_args="$common_args --dns-cloudflare-credentials $CREDENTIALS_FILE"
  common_args="$common_args --dns-cloudflare-propagation-seconds $PROPAGATION_SECONDS"
  common_args="$common_args --email $CERTBOT_EMAIL"
  common_args="$common_args --key-type $KEY_TYPE"

  if [ "${CERTBOT_STAGING:-0}" = "1" ]; then
    common_args="$common_args --test-cert"
  fi

  printf '%s' "$common_args"
}

existing_certificate_path() {
  for candidate in \
    "/etc/letsencrypt/live/$CERT_NAME/fullchain.pem" \
    "$TARGET_DIR/fullchain.pem"
  do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  return 1
}

certificate_is_staging() {
  cert_path=$1
  openssl x509 -in "$cert_path" -noout -issuer 2>/dev/null | grep -qi '(STAGING)'
}

certificate_covers_requested_domains() {
  cert_path=$1
  san_output=$(openssl x509 -in "$cert_path" -noout -ext subjectAltName 2>/dev/null || true)

  if [ -z "$san_output" ]; then
    return 1
  fi

  for domain in $(requested_domains); do
    printf '%s' "$san_output" | grep -Fq "DNS:$domain" || return 1
  done

  return 0
}

should_force_renewal() {
  if [ "${CERTBOT_FORCE_RENEWAL:-0}" = "1" ]; then
    return 0
  fi

  if [ "${CERTBOT_STAGING:-0}" != "0" ]; then
    return 1
  fi

  cert_path=$(existing_certificate_path || true)
  if [ -n "$cert_path" ]; then
    if certificate_is_staging "$cert_path"; then
      return 0
    fi

    if ! certificate_covers_requested_domains "$cert_path"; then
      return 0
    fi
  fi

  return 1
}

run_issue() {
  common_args=$(build_common_args)
  domain_args=$(build_domain_args)
  renewal_arg=--keep-until-expiring

  if should_force_renewal; then
    renewal_arg=--force-renewal
    printf 'Forcing certificate re-issuance for %s\n' "$CERT_NAME"
  fi

  # shellcheck disable=SC2086
  certbot certonly \
    $common_args \
    $renewal_arg \
    --cert-name "$CERT_NAME" \
    --deploy-hook /project/scripts/deploy-cert.sh \
    $domain_args
}

run_renew_loop() {
  while :; do
    certbot renew --deploy-hook /project/scripts/deploy-cert.sh || true
    sleep 12h &
    wait $!
  done
}

case "$MODE" in
  issue)
    run_issue
    ;;
  renew-loop)
    run_renew_loop
    ;;
  *)
    printf 'Unsupported mode: %s\n' "$MODE" >&2
    exit 1
    ;;
esac
