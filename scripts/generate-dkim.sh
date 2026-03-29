#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
DOMAINS_FILE="$PROJECT_DIR/domains.txt"
ACCOUNTS_FILE="$PROJECT_DIR/config/postfix-accounts.cf"
KEYS_ROOT="$PROJECT_DIR/config/opendkim/keys"

wait_for_mailserver() {
  attempts=0

  while [ "$attempts" -lt 30 ]; do
    if (cd "$PROJECT_DIR" && docker compose exec -T mailserver setup help >/dev/null 2>&1); then
      return
    fi

    attempts=$((attempts + 1))
    sleep 2
  done

  printf 'Ο mailserver δεν έγινε έτοιμος εγκαίρως για DKIM setup.\n' >&2
  exit 1
}

dkim_config_active() {
  cd "$PROJECT_DIR"
  docker compose exec -T mailserver sh -lc '[ -s /etc/opendkim/KeyTable ] && [ -s /etc/opendkim/SigningTable ] && [ -s /etc/opendkim/TrustedHosts ]'
}

activate_dkim_config() {
  cd "$PROJECT_DIR"
  docker compose exec -T mailserver sh -lc '
    if [ ! -f /tmp/docker-mailserver/opendkim/KeyTable ]; then
      echo "OpenDKIM config δεν βρέθηκε στο mounted path." >&2
      exit 1
    fi

    mkdir -p /etc/opendkim/keys
    cp -a /tmp/docker-mailserver/opendkim/* /etc/opendkim/
    chown -R opendkim:opendkim /etc/opendkim/
    chmod -R 0700 /etc/opendkim/keys/
  '
}

has_accounts() {
  if [ ! -f "$ACCOUNTS_FILE" ]; then
    return 1
  fi

  awk -F '|' 'NF >= 2 && $1 !~ /^#/ { found = 1; exit } END { exit(found ? 0 : 1) }' "$ACCOUNTS_FILE"
}

missing_domains() {
  while IFS= read -r domain || [ -n "$domain" ]; do
    case "$domain" in
      ''|'#'*)
        continue
        ;;
    esac

    if [ ! -d "$KEYS_ROOT/$domain" ] || ! find "$KEYS_ROOT/$domain" -maxdepth 1 -type f -name '*.txt' | grep -q .; then
      printf '%s\n' "$domain"
    fi
  done < "$DOMAINS_FILE"
}

if [ ! -f "$DOMAINS_FILE" ]; then
  printf 'Δεν βρέθηκε το domains file: %s\n' "$DOMAINS_FILE" >&2
  exit 1
fi

domains_to_generate=$(missing_domains | paste -sd ',' -)

wait_for_mailserver

if [ -z "$domains_to_generate" ]; then
  if ! dkim_config_active; then
    printf 'Τα DKIM keys υπάρχουν ήδη, αλλά δεν έχουν ενεργοποιηθεί στο live container. Γίνεται activation.\n' >&2
    activate_dkim_config
    cd "$PROJECT_DIR"
    docker compose restart mailserver >/dev/null
    wait_for_mailserver
  fi

  printf 'Δεν υπάρχουν νέα domains για DKIM generation. Γίνεται μόνο sync των υπαρχόντων records.\n' >&2
  "$SCRIPT_DIR/sync-dkim.sh"
  exit 0
fi

if ! has_accounts; then
  printf 'Απαιτείται τουλάχιστον ένα mailbox πριν δημιουργηθούν DKIM keys για νέα domains.\n' >&2
  exit 1
fi

cd "$PROJECT_DIR"
docker compose exec -T mailserver setup config dkim domain "$domains_to_generate"
activate_dkim_config
docker compose restart mailserver >/dev/null

wait_for_mailserver
"$SCRIPT_DIR/sync-dkim.sh"
