#!/usr/bin/env sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE="$PROJECT_DIR/.env"
DOMAINS_FILE="$PROJECT_DIR/domains.txt"
TOKEN_FILE="$PROJECT_DIR/secrets/cloudflare.ini"
MAILSERVER_ENV_FILE="$PROJECT_DIR/mailserver.env"
TIMESTAMP=$(date +%F-%H%M%S)

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Λείπει η εντολή: %s\n' "$1" >&2
    exit 1
  fi
}

fetch_url() {
  url=$1

  if command -v curl >/dev/null 2>&1; then
    curl -fsS "$url"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO- "$url"
    return
  fi

  return 1
}

detect_timezone() {
  if [ -n "${TZ:-}" ]; then
    printf '%s' "$TZ"
    return
  fi

  if [ -L /etc/localtime ] || [ -e /etc/localtime ]; then
    timezone=$(readlink -f /etc/localtime 2>/dev/null | sed 's#^.*/zoneinfo/##')
    if [ -n "$timezone" ] && [ "$timezone" != '/etc/localtime' ]; then
      printf '%s' "$timezone"
      return
    fi
  fi

  printf 'UTC'
}

detect_ipv4() {
  fetch_url 'https://api.ipify.org' 2>/dev/null || true
}

detect_ipv6() {
  fetch_url 'https://api6.ipify.org' 2>/dev/null || true
}

ask() {
  prompt=$1
  default_value=${2:-}

  if [ -n "$default_value" ]; then
    printf '%s [%s]: ' "$prompt" "$default_value" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi

  IFS= read -r answer

  if [ -z "$answer" ]; then
    answer=$default_value
  fi

  printf '%s' "$answer"
}

ask_secret() {
  prompt=$1
  allow_empty=${2:-0}

  if [ -t 0 ]; then
    old_stty=$(stty -g)
    trap 'stty "$old_stty"' EXIT INT TERM
    printf '%s: ' "$prompt" >&2
    stty -echo
    IFS= read -r answer
    stty "$old_stty"
    trap - EXIT INT TERM
    printf '\n' >&2
  else
    IFS= read -r answer
  fi

  if [ "$allow_empty" != '1' ] && [ -z "$answer" ]; then
    printf 'Η τιμή δεν μπορεί να είναι κενή.\n' >&2
    exit 1
  fi

  printf '%s' "$answer"
}

ask_yes_no() {
  prompt=$1
  default_value=${2:-n}
  answer=$(ask "$prompt (y/n)" "$default_value")

  case "$answer" in
    y|Y|yes|YES|n|N|no|NO)
      printf '%s' "$answer"
      ;;
    *)
      printf 'Δώσε y ή n.\n' >&2
      exit 1
      ;;
  esac
}

generate_random_password() {
  if command -v openssl >/dev/null 2>&1; then
    password=$(openssl rand -base64 24 | tr -d '\n' | tr '/+' 'AZ')
  else
    password=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  fi

  if [ -z "$password" ]; then
    printf 'Αποτυχία δημιουργίας τυχαίου κωδικού για το πρώτο mailbox.\n' >&2
    exit 1
  fi

  printf '%s' "$password"
}

backup_if_exists() {
  target=$1

  if [ -f "$target" ]; then
    cp "$target" "$target.bak.$TIMESTAMP"
  fi
}

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

read_secret_value() {
  key=$1
  file=$2

  awk -F '=' -v key="$key" '
    {
      current = $1
      gsub(/^[ \t]+|[ \t]+$/, "", current)
      if (current == key) {
        value = substr($0, index($0, "=") + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", value)
        print value
        exit
      }
    }
  ' "$file"
}

looks_like_global_api_key() {
  value=$1
  printf '%s' "$value" | python3 -c 'import re, sys; value=sys.stdin.read().strip(); raise SystemExit(0 if re.fullmatch(r"[0-9A-Fa-f]{37}", value) else 1)'
}

load_existing_defaults() {
  EXISTING_MAILSERVER_HOSTNAME=''
  EXISTING_MAILSERVER_ZONE=''
  EXISTING_PRIMARY_DOMAIN=''
  EXISTING_TZ=''
  EXISTING_CERTBOT_EMAIL=''
  EXISTING_WEBMAIL_HOSTNAME=''
  EXISTING_ROUNDCUBE_HTTP_PORT=''
  EXISTING_MAILSERVER_IPV4=''
  EXISTING_MAILSERVER_IPV6=''

  if [ -f "$ENV_FILE" ]; then
    EXISTING_MAILSERVER_HOSTNAME=$(read_env_value MAILSERVER_HOSTNAME "$ENV_FILE")
    EXISTING_MAILSERVER_ZONE=$(read_env_value MAILSERVER_ZONE "$ENV_FILE")
    EXISTING_PRIMARY_DOMAIN=$(read_env_value PRIMARY_DOMAIN "$ENV_FILE")
    EXISTING_TZ=$(read_env_value TZ "$ENV_FILE")
    EXISTING_CERTBOT_EMAIL=$(read_env_value CERTBOT_EMAIL "$ENV_FILE")
    EXISTING_WEBMAIL_HOSTNAME=$(read_env_value WEBMAIL_HOSTNAME "$ENV_FILE")
    EXISTING_ROUNDCUBE_HTTP_PORT=$(read_env_value ROUNDCUBE_HTTP_PORT "$ENV_FILE")
    EXISTING_MAILSERVER_IPV4=$(read_env_value MAILSERVER_IPV4 "$ENV_FILE")
    EXISTING_MAILSERVER_IPV6=$(read_env_value MAILSERVER_IPV6 "$ENV_FILE")
  fi

  EXISTING_DOMAINS=''
  if [ -f "$DOMAINS_FILE" ]; then
    EXISTING_DOMAINS=$(awk 'NF && $1 !~ /^#/' "$DOMAINS_FILE" | paste -sd ',' -)
  fi

  EXISTING_TOKEN=''
  HAS_LEGACY_CLOUDFLARE_KEY='0'
  if [ -f "$TOKEN_FILE" ]; then
    EXISTING_TOKEN=$(read_secret_value dns_cloudflare_api_token "$TOKEN_FILE")
    legacy_cloudflare_email=$(read_secret_value dns_cloudflare_email "$TOKEN_FILE")
    legacy_cloudflare_api_key=$(read_secret_value dns_cloudflare_api_key "$TOKEN_FILE")

    if [ -n "$legacy_cloudflare_email" ] && [ -n "$legacy_cloudflare_api_key" ]; then
      HAS_LEGACY_CLOUDFLARE_KEY='1'
    elif [ -n "$EXISTING_TOKEN" ] && looks_like_global_api_key "$EXISTING_TOKEN"; then
      HAS_LEGACY_CLOUDFLARE_KEY='1'
      EXISTING_TOKEN=''
    fi
  fi
}

ensure_mailserver_env() {
  if [ -f "$MAILSERVER_ENV_FILE" ]; then
    return
  fi

  cat > "$MAILSERVER_ENV_FILE" <<'EOF'
# docker-mailserver runtime settings
OVERRIDE_HOSTNAME=
LOG_LEVEL=info
TZ=UTC
POSTMASTER_ADDRESS=postmaster@example.com

# Account management through local files in ./config
ACCOUNT_PROVISIONER=FILE

# Mail features
ENABLE_IMAP=1
ENABLE_POP3=0
ENABLE_MANAGESIEVE=1

# Security defaults
ENABLE_FAIL2BAN=1
ENABLE_CLAMAV=0
ENABLE_RSPAMD=0
ENABLE_AMAVIS=0
ENABLE_SPAMASSASSIN=0
MOVE_SPAM_TO_JUNK=0

# TLS defaults
SSL_TYPE=manual
TLS_LEVEL=modern
EOF
}

build_domains_file() {
  primary_domain=$1
  extra_domains=$2

  {
    printf '%s\n' "$primary_domain"

    old_ifs=$IFS
    IFS=','
    set -- $extra_domains
    IFS=$old_ifs

    for domain in "$@"; do
      trimmed=$(printf '%s' "$domain" | tr -d '[:space:]')
      if [ -n "$trimmed" ]; then
        printf '%s\n' "$trimmed"
      fi
    done
  } | awk 'NF && !seen[$0]++'
}

wait_for_mailserver() {
  attempts=0

  while [ "$attempts" -lt 30 ]; do
    if (cd "$PROJECT_DIR" && docker compose exec -T mailserver setup help >/dev/null 2>&1); then
      return
    fi

    attempts=$((attempts + 1))
    sleep 2
  done

  printf 'Ο mailserver δεν έγινε έτοιμος εγκαίρως για δημιουργία mailbox.\n' >&2
  exit 1
}

ensure_local_config_files() {
  mkdir -p "$PROJECT_DIR/config" "$PROJECT_DIR/config/roundcube" "$PROJECT_DIR/config/opendkim/keys"
  touch \
    "$PROJECT_DIR/config/postfix-accounts.cf" \
    "$PROJECT_DIR/config/postfix-virtual.cf" \
    "$PROJECT_DIR/config/dovecot-quotas.cf"
}

config_mount_writable() {
  cd "$PROJECT_DIR"
  docker compose exec -T mailserver sh -lc '
    test -d /tmp/docker-mailserver &&
    : >> /tmp/docker-mailserver/postfix-accounts.cf &&
    : >> /tmp/docker-mailserver/postfix-virtual.cf &&
    : >> /tmp/docker-mailserver/dovecot-quotas.cf
  '
}

ensure_mailserver_config_mount() {
  wait_for_mailserver

  if config_mount_writable; then
    return
  fi

  printf 'Το mounted config path δεν ήταν έτοιμο στην πρώτη εκκίνηση. Γίνεται restart του mailserver και νέα προσπάθεια.\n' >&2
  cd "$PROJECT_DIR"
  docker compose restart mailserver >/dev/null

  wait_for_mailserver

  if ! config_mount_writable; then
    printf 'Αποτυχία πρόσβασης στο mounted config path /tmp/docker-mailserver μετά το retry.\n' >&2
    exit 1
  fi
}

create_first_mailbox() {
  mailbox=$1
  password=$2

  if [ -z "$mailbox" ]; then
    return
  fi

  if account_exists "$mailbox"; then
    printf 'Το mailbox %s υπάρχει ήδη, οπότε δεν ξαναδημιουργείται.\n' "$mailbox" >&2
    return
  fi

  ensure_mailserver_config_mount

  cd "$PROJECT_DIR"
  docker compose exec -T mailserver setup email add "$mailbox" "$password"
}

account_exists() {
  mailbox=$1
  accounts_file="$PROJECT_DIR/config/postfix-accounts.cf"

  if [ ! -f "$accounts_file" ]; then
    return 1
  fi

  awk -F '|' -v mailbox="$mailbox" '$1 == mailbox { found = 1; exit } END { exit(found ? 0 : 1) }' "$accounts_file"
}

require_command docker
load_existing_defaults
ensure_mailserver_env

detected_timezone=$(detect_timezone)
detected_ipv4=$(detect_ipv4)
detected_ipv6=$(detect_ipv6)

primary_default=$EXISTING_PRIMARY_DOMAIN
if [ -z "$primary_default" ] && [ -n "$EXISTING_DOMAINS" ]; then
  primary_default=$(printf '%s' "$EXISTING_DOMAINS" | cut -d ',' -f 1)
fi

primary_domain=$(ask 'Κύριο domain email' "$primary_default")
if [ -z "$primary_domain" ]; then
  printf 'Το κύριο domain είναι υποχρεωτικό.\n' >&2
  exit 1
fi

mail_hostname_default="mail.$primary_domain"
if [ -n "$EXISTING_MAILSERVER_HOSTNAME" ] && [ "$EXISTING_MAILSERVER_HOSTNAME" != "$mail_hostname_default" ]; then
  mail_hostname=$(ask 'Hostname/FQDN του mail server' "$EXISTING_MAILSERVER_HOSTNAME")
else
  mail_hostname=$mail_hostname_default
  printf 'Το mail hostname θα οριστεί αυτόματα σε: %s\n' "$mail_hostname" >&2
fi

webmail_hostname_default="webmail.$primary_domain"
if [ -n "$EXISTING_WEBMAIL_HOSTNAME" ] && [ "$EXISTING_WEBMAIL_HOSTNAME" != "$webmail_hostname_default" ]; then
  webmail_hostname=$(ask 'Hostname/FQDN του Roundcube webmail (κενό για απενεργοποίηση DNS/cert)' "$EXISTING_WEBMAIL_HOSTNAME")
else
  webmail_hostname=$webmail_hostname_default
  printf 'Το webmail hostname θα οριστεί αυτόματα σε: %s\n' "$webmail_hostname" >&2
fi

roundcube_http_port_default=${EXISTING_ROUNDCUBE_HTTP_PORT:-8080}
roundcube_http_port=$(ask 'Localhost port του Roundcube για nginx proxy' "$roundcube_http_port_default")

case "$roundcube_http_port" in
  ''|*[!0-9]*)
    printf 'Το Roundcube port πρέπει να είναι αριθμός.\n' >&2
    exit 1
    ;;
esac

mail_zone_default=${EXISTING_MAILSERVER_ZONE:-$primary_domain}
if [ "$mail_zone_default" = "$primary_domain" ]; then
  mail_zone=$primary_domain
  printf 'Το Cloudflare zone θα οριστεί αυτόματα σε: %s\n' "$mail_zone" >&2
else
  mail_zone=$(ask 'Cloudflare zone του mail host' "$mail_zone_default")
fi

postmaster_address="postmaster@$primary_domain"
printf 'Το postmaster mailbox θα οριστεί αυτόματα σε: %s\n' "$postmaster_address" >&2
certbot_email=$(ask "Email ειδοποιήσεων Let's Encrypt" "${EXISTING_CERTBOT_EMAIL:-$postmaster_address}")
timezone=$(ask 'Timezone' "${EXISTING_TZ:-$detected_timezone}")

extra_domains_default=''
if [ -n "$EXISTING_DOMAINS" ]; then
  extra_domains_default=$(printf '%s' "$EXISTING_DOMAINS" | awk -F ',' -v primary="$primary_domain" '{
    for (i = 1; i <= NF; i++) {
      if ($i != primary) {
        if (result == "") {
          result = $i
        } else {
          result = result "," $i
        }
      }
    }
    print result
  }')
fi

extra_domains=$(ask 'Επιπλέον hosted domains, χωρισμένα με κόμμα' "$extra_domains_default")

if [ -n "$detected_ipv4" ]; then
  printf 'Βρέθηκε αυτόματα IPv4: %s\n' "$detected_ipv4" >&2
else
  printf 'Δεν βρέθηκε αυτόματα public IPv4 από το host.\n' >&2
fi

ipv4_default=$detected_ipv4
if [ -z "$ipv4_default" ]; then
  ipv4_default=$EXISTING_MAILSERVER_IPV4
fi

mailserver_ipv4=$(ask 'Public IPv4 για DNS sync (κενό για παράλειψη)' "$ipv4_default")

if [ -n "$detected_ipv6" ]; then
  printf 'Βρέθηκε αυτόματα IPv6: %s\n' "$detected_ipv6" >&2
else
  printf 'Δεν βρέθηκε αυτόματα public IPv6 από το host.\n' >&2
fi

ipv6_default=$detected_ipv6
if [ -z "$ipv6_default" ]; then
  ipv6_default=$EXISTING_MAILSERVER_IPV6
fi

mailserver_ipv6=$(ask 'Public IPv6 για DNS sync (κενό για παράλειψη)' "$ipv6_default")

if [ "$HAS_LEGACY_CLOUDFLARE_KEY" = '1' ]; then
  printf 'Βρέθηκε παλιό Cloudflare Global API Key config. Το init.sh πλέον ζητά μόνο API token και θα το αντικαταστήσει.\n' >&2
fi

if [ -n "$EXISTING_TOKEN" ]; then
  cloudflare_token=$(ask_secret 'Cloudflare API token (Enter για διατήρηση του υπάρχοντος)' 1)
  if [ -z "$cloudflare_token" ]; then
    cloudflare_token=$EXISTING_TOKEN
  fi
else
  cloudflare_token=$(ask_secret 'Cloudflare API token')
fi

if looks_like_global_api_key "$cloudflare_token"; then
  printf 'Αυτό που έδωσες μοιάζει με Cloudflare Global API Key, όχι με API Token.\n' >&2
  printf 'Χρησιμοποίησε restricted Cloudflare API token με Zone:DNS:Edit και Zone:Zone:Read.\n' >&2
  exit 1
fi

first_mailbox=$postmaster_address
first_mailbox_password=''
first_mailbox_created='0'

if account_exists "$first_mailbox"; then
  printf 'Το mailbox %s υπάρχει ήδη και θα διατηρηθεί ως έχει.\n' "$first_mailbox" >&2
else
  first_mailbox_password=$(generate_random_password)
  first_mailbox_created='1'
fi

certbot_staging='0'
printf "Θα χρησιμοποιηθεί production Let's Encrypt certificate (CERTBOT_STAGING=0).\n" >&2

mkdir -p "$PROJECT_DIR/secrets" "$PROJECT_DIR/certs/live" "$PROJECT_DIR/config" \
  "$PROJECT_DIR/data/mail-data" "$PROJECT_DIR/data/mail-state" "$PROJECT_DIR/data/mail-logs" \
  "$PROJECT_DIR/config/roundcube" "$PROJECT_DIR/data/roundcube/db" "$PROJECT_DIR/data/roundcube/enigma" "$PROJECT_DIR/data/roundcube/temp" \
  "$PROJECT_DIR/letsencrypt/config" "$PROJECT_DIR/letsencrypt/work" "$PROJECT_DIR/letsencrypt/logs" \
  "$PROJECT_DIR/backups"

ensure_local_config_files

certbot_extra_domains=''
if [ -n "$webmail_hostname" ] && [ "$webmail_hostname" != "$mail_hostname" ]; then
  certbot_extra_domains=$webmail_hostname
fi

backup_if_exists "$ENV_FILE"
backup_if_exists "$DOMAINS_FILE"
backup_if_exists "$TOKEN_FILE"

cat > "$ENV_FILE" <<EOF
MAILSERVER_HOSTNAME=$mail_hostname
MAILSERVER_ZONE=$mail_zone
PRIMARY_DOMAIN=$primary_domain
POSTMASTER_ADDRESS=$postmaster_address
TZ=$timezone
WEBMAIL_HOSTNAME=$webmail_hostname
ROUNDCUBE_HTTP_PORT=$roundcube_http_port
CERTBOT_EMAIL=$certbot_email
CERTBOT_CERT_NAME=$mail_hostname
CERTBOT_EXTRA_DOMAINS=$certbot_extra_domains
CERTBOT_KEY_TYPE=ecdsa
CERTBOT_STAGING=$certbot_staging
CLOUDFLARE_DNS_PROPAGATION_SECONDS=60
MAILSERVER_IPV4=$mailserver_ipv4
MAILSERVER_IPV6=$mailserver_ipv6
MAIL_MX_PRIORITY=10
MAIL_HELO_SPF_VALUE=v=spf1 a -all
MAIL_SPF_VALUE=v=spf1 mx -all
MAIL_DMARC_VALUE=v=DMARC1;p=quarantine;adkim=s;aspf=s;pct=100
EOF

build_domains_file "$primary_domain" "$extra_domains" > "$DOMAINS_FILE"

cat > "$TOKEN_FILE" <<EOF
dns_cloudflare_api_token = $cloudflare_token
EOF
chmod 600 "$TOKEN_FILE"

printf 'Γράφτηκαν τα αρχεία ρύθμισης.\n' >&2
./scripts/verify-cloudflare.sh
printf 'Ξεκινάει το αρχικό bootstrap του mailserver...\n' >&2

cd "$PROJECT_DIR"
./scripts/start.sh

if [ "$first_mailbox_created" = '1' ]; then
  create_first_mailbox "$first_mailbox" "$first_mailbox_password"
fi

./scripts/generate-dkim.sh

printf '\nΟ mailserver ξεκίνησε.\n' >&2
if [ "$first_mailbox_created" = '1' ]; then
  printf 'Δημιουργήθηκε αυτόματα το αρχικό mailbox: %s\n' "$first_mailbox" >&2
  printf 'Τυχαίος αρχικός κωδικός: %s\n' "$first_mailbox_password" >&2
else
  printf 'Το αρχικό mailbox %s υπήρχε ήδη, οπότε δεν δημιουργήθηκε νέος κωδικός.\n' "$first_mailbox" >&2
fi
printf 'Χρήσιμα αρχεία: %s %s %s\n' "$ENV_FILE" "$DOMAINS_FILE" "$TOKEN_FILE" >&2
