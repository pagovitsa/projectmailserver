#!/usr/bin/env sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DOMAINS_FILE="$PROJECT_DIR/domains.txt"
ENV_FILE="$PROJECT_DIR/.env"
TOKEN_FILE="$PROJECT_DIR/secrets/cloudflare.ini"
ACCOUNTS_FILE="$PROJECT_DIR/config/postfix-accounts.cf"
ALIASES_FILE="$PROJECT_DIR/config/postfix-virtual.cf"
KEYTABLE_FILE="$PROJECT_DIR/config/opendkim/KeyTable"
SCRIPTS_DIR="$PROJECT_DIR/scripts"
CLOUDFLARE_HELPER="$SCRIPTS_DIR/cloudflare-api.sh"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Λείπει η εντολή: %s\n' "$1" >&2
    exit 1
  fi
}

read_env_value() {
  key=$1
  file=$2

  if [ ! -f "$file" ]; then
    return 0
  fi

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

prompt() {
  question=$1
  default_value=${2:-}

  if [ -n "$default_value" ]; then
    printf '%s [%s]: ' "$question" "$default_value" >&2
  else
    printf '%s: ' "$question" >&2
  fi

  IFS= read -r answer
  if [ -z "$answer" ]; then
    answer=$default_value
  fi

  printf '%s' "$answer"
}

prompt_secret() {
  question=$1

  if [ ! -t 0 ]; then
    printf 'Ο κωδικός πρέπει να δοθεί διαδραστικά ή ως όρισμα.\n' >&2
    exit 1
  fi

  old_stty=$(stty -g)
  trap 'stty "$old_stty"' EXIT INT TERM
  printf '%s: ' "$question" >&2
  stty -echo
  IFS= read -r answer
  stty "$old_stty"
  trap - EXIT INT TERM
  printf '\n' >&2

  if [ -z "$answer" ]; then
    printf 'Η τιμή δεν μπορεί να είναι κενή.\n' >&2
    exit 1
  fi

  printf '%s' "$answer"
}

confirm() {
  question=$1

  if [ "${ADMIN_SUITE_ASSUME_YES:-0}" = '1' ]; then
    return 0
  fi

  if [ ! -t 0 ]; then
    printf 'Απαιτείται επιβεβαίωση για: %s\n' "$question" >&2
    printf 'Θέσε ADMIN_SUITE_ASSUME_YES=1 αν θέλεις non-interactive επιβεβαίωση.\n' >&2
    exit 1
  fi

  answer=$(prompt "$question (y/n)" 'n')
  case "$answer" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_domain() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

validate_domain() {
  domain=$1
  printf '%s' "$domain" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
}

validate_mailbox() {
  mailbox=$1
  printf '%s' "$mailbox" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
}

domain_exists() {
  domain=$1
  [ -f "$DOMAINS_FILE" ] && grep -Fqx "$domain" "$DOMAINS_FILE"
}

primary_domain() {
  read_env_value PRIMARY_DOMAIN "$ENV_FILE"
}

mailserver_running() {
  cd "$PROJECT_DIR"
  docker compose ps --status running --services 2>/dev/null | grep -Fxq 'mailserver'
}

ensure_mailserver_running() {
  if ! mailserver_running; then
    printf 'Ο mailserver δεν τρέχει. Ξεκίνησέ τον πρώτα με ./scripts/start.sh\n' >&2
    exit 1
  fi
}

ensure_project_files() {
  if [ ! -f "$ENV_FILE" ] || [ ! -f "$DOMAINS_FILE" ]; then
    printf 'Δεν βρέθηκαν .env/domains.txt. Τρέξε πρώτα ./init.sh\n' >&2
    exit 1
  fi
}

list_domains() {
  ensure_project_files
  awk 'NF && $1 !~ /^#/ { printf "%d. %s\n", ++count, $1 } END { if (count == 0) print "Δεν υπάρχουν hosted domains ακόμη." }' "$DOMAINS_FILE"
}

list_domain_users() {
  domain=$1

  if [ ! -f "$ACCOUNTS_FILE" ]; then
    return 0
  fi

  awk -F '[|@]' -v domain="$domain" '$2 == domain { print $1 "@" $2 }' "$ACCOUNTS_FILE"
}

domain_has_users() {
  domain=$1
  list_domain_users "$domain" | grep -q .
}

list_domain_alias_matches() {
  domain=$1

  if [ ! -f "$ALIASES_FILE" ]; then
    return 0
  fi

  grep -F "@$domain" "$ALIASES_FILE" || true
}

domain_has_aliases() {
  domain=$1
  list_domain_alias_matches "$domain" | grep -q .
}

write_domains_file() {
  tmp_file=$(mktemp)
  cat > "$tmp_file"
  mv "$tmp_file" "$DOMAINS_FILE"
}

run_domain_sync() {
  printf 'Γίνεται DNS sync...\n' >&2
  "$SCRIPTS_DIR/sync-dns.sh"

  if mailserver_running && [ -f "$ACCOUNTS_FILE" ]; then
    printf 'Γίνεται DKIM generation/sync όπου χρειάζεται...\n' >&2
    "$SCRIPTS_DIR/generate-dkim.sh"
  else
    printf 'Παραλείφθηκε το DKIM generation γιατί ο mailserver δεν τρέχει ή δεν υπάρχουν mailbox accounts ακόμη.\n' >&2
  fi
}

cf_delete_record_if_exists() {
  zone_id=$1
  record_type=$2
  record_name=$3
  selector=${4:-any}
  comment=${5:-$MANAGED_COMMENT}

  record_id=$(cf_find_record_id "$zone_id" "$record_type" "$record_name" "$selector" "$comment")
  if [ -n "$record_id" ]; then
    cf_request DELETE "/zones/$zone_id/dns_records/$record_id" >/dev/null
    printf 'Deleted %s %s\n' "$record_type" "$record_name"
  fi
}

cleanup_domain_dns() {
  domain=$1

  if [ ! -f "$TOKEN_FILE" ]; then
    printf 'Παραλείφθηκε DNS cleanup για %s γιατί δεν βρέθηκε %s\n' "$domain" "$TOKEN_FILE" >&2
    return 0
  fi

  # shellcheck disable=SC1090
  . "$CLOUDFLARE_HELPER"
  cf_init "$TOKEN_FILE"

  zone_info=$(cf_find_zone_for_name "$domain" || true)
  zone_id=${zone_info%%|*}

  if [ -z "$zone_id" ]; then
    printf 'Δεν βρέθηκε Cloudflare zone για cleanup του domain %s\n' "$domain" >&2
    return 0
  fi

  cf_delete_record_if_exists "$zone_id" MX "$domain" any
  cf_delete_record_if_exists "$zone_id" TXT "$domain" spf
  cf_delete_record_if_exists "$zone_id" TXT "_dmarc.$domain" dmarc

  if [ -f "$KEYTABLE_FILE" ]; then
    awk -v domain="$domain" '$2 ~ ("^" domain ":") { print $1 }' "$KEYTABLE_FILE" | while IFS= read -r dkim_record || [ -n "$dkim_record" ]; do
      [ -n "$dkim_record" ] || continue
      cf_delete_record_if_exists "$zone_id" TXT "$dkim_record" dkim
    done
  fi
}

add_domain() {
  ensure_project_files
  domain=${1:-}

  if [ -z "$domain" ]; then
    domain=$(prompt 'Domain για προσθήκη')
  fi

  domain=$(normalize_domain "$domain")

  if [ -z "$domain" ] || ! validate_domain "$domain"; then
    printf 'Μη έγκυρο domain: %s\n' "$domain" >&2
    exit 1
  fi

  if domain_exists "$domain"; then
    printf 'Το domain %s υπάρχει ήδη στο hosted list.\n' "$domain" >&2
    return 0
  fi

  {
    cat "$DOMAINS_FILE"
    printf '%s\n' "$domain"
  } | awk 'NF && !seen[$0]++' | write_domains_file

  printf 'Το domain %s προστέθηκε στο hosted list.\n' "$domain"
  run_domain_sync
}

remove_domain() {
  ensure_project_files
  domain=${1:-}

  if [ -z "$domain" ]; then
    domain=$(prompt 'Domain για αφαίρεση')
  fi

  domain=$(normalize_domain "$domain")

  if [ -z "$domain" ] || ! validate_domain "$domain"; then
    printf 'Μη έγκυρο domain: %s\n' "$domain" >&2
    exit 1
  fi

  if ! domain_exists "$domain"; then
    printf 'Το domain %s δεν υπάρχει στο hosted list.\n' "$domain" >&2
    return 0
  fi

  if [ "$domain" = "$(primary_domain)" ]; then
    printf 'Το PRIMARY_DOMAIN (%s) δεν αφαιρείται από το admin suite.\n' "$domain" >&2
    exit 1
  fi

  if domain_has_users "$domain"; then
    printf 'Δεν μπορεί να αφαιρεθεί το domain %s γιατί έχει mailbox users:\n' "$domain" >&2
    list_domain_users "$domain" >&2
    exit 1
  fi

  if domain_has_aliases "$domain"; then
    printf 'Δεν μπορεί να αφαιρεθεί το domain %s γιατί υπάρχουν aliases που το χρησιμοποιούν.\n' "$domain" >&2
    list_domain_alias_matches "$domain" >&2
    exit 1
  fi

  if ! confirm "Να αφαιρεθεί το domain $domain από το hosted list και να γίνει DNS cleanup"; then
    printf 'Η αφαίρεση ακυρώθηκε.\n'
    return 0
  fi

  cleanup_domain_dns "$domain"

  awk -v domain="$domain" '$0 != domain' "$DOMAINS_FILE" | awk 'NF && !seen[$0]++' | write_domains_file

  printf 'Το domain %s αφαιρέθηκε από το hosted list.\n' "$domain"
  printf 'Γίνεται sync για τα υπόλοιπα hosted domains...\n' >&2
  "$SCRIPTS_DIR/sync-dns.sh"
}

list_users() {
  ensure_mailserver_running
  cd "$PROJECT_DIR"
  "$SCRIPTS_DIR/dms.sh" email list
}

mailbox_exists() {
  mailbox=$1
  [ -f "$ACCOUNTS_FILE" ] && awk -F '|' -v mailbox="$mailbox" '$1 == mailbox { found = 1; exit } END { exit(found ? 0 : 1) }' "$ACCOUNTS_FILE"
}

add_user() {
  ensure_project_files
  ensure_mailserver_running
  mailbox=${1:-}
  password=${2:-}

  if [ -z "$mailbox" ]; then
    mailbox=$(prompt 'Mailbox για δημιουργία (π.χ. user@domain.tld)')
  fi

  if ! validate_mailbox "$mailbox"; then
    printf 'Μη έγκυρο mailbox: %s\n' "$mailbox" >&2
    exit 1
  fi

  domain=${mailbox##*@}
  if ! domain_exists "$domain"; then
    printf 'Το domain %s δεν υπάρχει στο hosted list. Πρόσθεσέ το πρώτα.\n' "$domain" >&2
    exit 1
  fi

  if mailbox_exists "$mailbox"; then
    printf 'Το mailbox %s υπάρχει ήδη.\n' "$mailbox" >&2
    return 0
  fi

  if [ -z "$password" ]; then
    password=$(prompt_secret "Κωδικός για $mailbox")
  fi

  cd "$PROJECT_DIR"
  "$SCRIPTS_DIR/dms.sh" email add "$mailbox" "$password"
  printf 'Το mailbox %s δημιουργήθηκε.\n' "$mailbox"
}

delete_user() {
  ensure_project_files
  ensure_mailserver_running
  mailbox=${1:-}

  if [ -z "$mailbox" ]; then
    mailbox=$(prompt 'Mailbox για διαγραφή')
  fi

  if ! validate_mailbox "$mailbox"; then
    printf 'Μη έγκυρο mailbox: %s\n' "$mailbox" >&2
    exit 1
  fi

  if ! mailbox_exists "$mailbox"; then
    printf 'Το mailbox %s δεν υπάρχει.\n' "$mailbox" >&2
    return 0
  fi

  if ! confirm "Να διαγραφεί ο χρήστης $mailbox"; then
    printf 'Η διαγραφή ακυρώθηκε.\n'
    return 0
  fi

  cd "$PROJECT_DIR"
  "$SCRIPTS_DIR/dms.sh" email del "$mailbox"
  printf 'Ο χρήστης %s διαγράφηκε.\n' "$mailbox"
}

update_user_password() {
  ensure_project_files
  ensure_mailserver_running
  mailbox=${1:-}
  password=${2:-}

  if [ -z "$mailbox" ]; then
    mailbox=$(prompt 'Mailbox για αλλαγή κωδικού')
  fi

  if ! validate_mailbox "$mailbox"; then
    printf 'Μη έγκυρο mailbox: %s\n' "$mailbox" >&2
    exit 1
  fi

  if ! mailbox_exists "$mailbox"; then
    printf 'Το mailbox %s δεν υπάρχει.\n' "$mailbox" >&2
    return 0
  fi

  if [ -z "$password" ]; then
    password=$(prompt_secret "Νέος κωδικός για $mailbox")
  fi

  cd "$PROJECT_DIR"
  "$SCRIPTS_DIR/dms.sh" email update "$mailbox" "$password"
  printf 'Ο κωδικός του χρήστη %s ενημερώθηκε.\n' "$mailbox"
}

list_aliases() {
  ensure_mailserver_running

  if [ ! -f "$ALIASES_FILE" ]; then
    printf 'Δεν υπάρχουν aliases ακόμη.\n'
    return 0
  fi

  cd "$PROJECT_DIR"
  "$SCRIPTS_DIR/dms.sh" alias list
}

alias_mapping_exists() {
  alias_address=$1
  recipient=$2

  [ -f "$ALIASES_FILE" ] && awk -v alias_address="$alias_address" -v recipient="$recipient" '
    $1 == alias_address && $2 == recipient { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$ALIASES_FILE"
}

list_alias_recipients() {
  alias_address=$1

  if [ ! -f "$ALIASES_FILE" ]; then
    return 0
  fi

  awk -v alias_address="$alias_address" '$1 == alias_address { print $2 }' "$ALIASES_FILE"
}

alias_address_exists() {
  alias_address=$1
  list_alias_recipients "$alias_address" | grep -q .
}

add_alias() {
  ensure_project_files
  ensure_mailserver_running
  alias_address=${1:-}
  recipient=${2:-}

  if [ -z "$alias_address" ]; then
    alias_address=$(prompt 'Alias address για δημιουργία (π.χ. info@domain.tld)')
  fi

  if [ -z "$recipient" ]; then
    recipient=$(prompt 'Recipient mailbox/email για το alias')
  fi

  if ! validate_mailbox "$alias_address"; then
    printf 'Μη έγκυρο alias address: %s\n' "$alias_address" >&2
    exit 1
  fi

  if ! validate_mailbox "$recipient"; then
    printf 'Μη έγκυρος recipient: %s\n' "$recipient" >&2
    exit 1
  fi

  alias_domain=${alias_address##*@}
  if ! domain_exists "$alias_domain"; then
    printf 'Το domain %s δεν υπάρχει στο hosted list. Πρόσθεσέ το πρώτα.\n' "$alias_domain" >&2
    exit 1
  fi

  if alias_mapping_exists "$alias_address" "$recipient"; then
    printf 'Το alias %s -> %s υπάρχει ήδη.\n' "$alias_address" "$recipient" >&2
    return 0
  fi

  cd "$PROJECT_DIR"
  "$SCRIPTS_DIR/dms.sh" alias add "$alias_address" "$recipient"
  printf 'Το alias %s -> %s δημιουργήθηκε.\n' "$alias_address" "$recipient"
}

delete_alias() {
  ensure_project_files
  ensure_mailserver_running
  alias_address=${1:-}
  recipient=${2:-}

  if [ -z "$alias_address" ]; then
    alias_address=$(prompt 'Alias address για διαγραφή')
  fi

  if [ -z "$recipient" ]; then
    recipient=$(prompt 'Recipient που θα αφαιρεθεί από το alias')
  fi

  if ! validate_mailbox "$alias_address"; then
    printf 'Μη έγκυρο alias address: %s\n' "$alias_address" >&2
    exit 1
  fi

  if ! validate_mailbox "$recipient"; then
    printf 'Μη έγκυρος recipient: %s\n' "$recipient" >&2
    exit 1
  fi

  if [ ! -f "$ALIASES_FILE" ]; then
    printf 'Δεν υπάρχουν aliases ακόμη.\n'
    return 0
  fi

  if ! alias_mapping_exists "$alias_address" "$recipient"; then
    if alias_address_exists "$alias_address"; then
      printf 'Το alias %s υπάρχει, αλλά όχι με recipient %s.\n' "$alias_address" "$recipient" >&2
      printf 'Τρέχον recipients:\n' >&2
      list_alias_recipients "$alias_address" >&2
    else
      printf 'Το alias %s -> %s δεν υπάρχει.\n' "$alias_address" "$recipient" >&2
    fi
    return 0
  fi

  if ! confirm "Να διαγραφεί το alias $alias_address -> $recipient"; then
    printf 'Η διαγραφή ακυρώθηκε.\n'
    return 0
  fi

  cd "$PROJECT_DIR"
  "$SCRIPTS_DIR/dms.sh" alias del "$alias_address" "$recipient"
  printf 'Το alias %s -> %s διαγράφηκε.\n' "$alias_address" "$recipient"
}

usage() {
  cat <<'EOF'
Χρήση:
  ./admin.sh
  ./admin.sh 1
  ./admin.sh 1 1
  ./admin.sh 1 2 <domain>
  ./admin.sh 1 3 <domain>
  ./admin.sh 2
  ./admin.sh 2 1
  ./admin.sh 2 2 <mailbox> [password]
  ./admin.sh 2 3 <mailbox> [password]
  ./admin.sh 2 4 <mailbox>
  ./admin.sh 3
  ./admin.sh 3 1
  ./admin.sh 3 2 <alias-email> <recipient-email>
  ./admin.sh 3 3 <alias-email> <recipient-email>
  ./admin.sh 4
  ./admin.sh 5

Main menu:
  1) Domains
  2) Users
  3) Aliases
  4) Init / bootstrap
  5) Exit

Domains submenu:
  1) List domains
  2) Add domain
  3) Remove domain
  4) Back

Users submenu:
  1) List users
  2) Add user
  3) Change user password
  4) Delete user
  5) Back

Aliases submenu:
  1) List aliases
  2) Add alias
  3) Delete alias
  4) Back

Το script χωρίς ορίσματα ανοίγει interactive numeric menu με submenus.
EOF
}

execute_domain_choice() {
  choice=$1

  case "$choice" in
    1)
      list_domains
      ;;
    2)
      add_domain "${2:-}"
      ;;
    3)
      remove_domain "${2:-}"
      ;;
    4)
      return 0
      ;;
    *)
      printf 'Άγνωστη επιλογή domains. Δώσε αριθμό από 1 έως 4.\n' >&2
      return 1
      ;;
  esac
}

execute_user_choice() {
  choice=$1

  case "$choice" in
    1)
      list_users
      ;;
    2)
      add_user "${2:-}" "${3:-}"
      ;;
    3)
      update_user_password "${2:-}" "${3:-}"
      ;;
    4)
      delete_user "${2:-}"
      ;;
    5)
      return 0
      ;;
    *)
      printf 'Άγνωστη επιλογή users. Δώσε αριθμό από 1 έως 5.\n' >&2
      return 1
      ;;
  esac
}

execute_alias_choice() {
  choice=$1

  case "$choice" in
    1)
      list_aliases
      ;;
    2)
      add_alias "${2:-}" "${3:-}"
      ;;
    3)
      delete_alias "${2:-}" "${3:-}"
      ;;
    4)
      return 0
      ;;
    *)
      printf 'Άγνωστη επιλογή aliases. Δώσε αριθμό από 1 έως 4.\n' >&2
      return 1
      ;;
  esac
}

domains_menu() {
  while :; do
    cat <<'EOF'

Domains Menu
1) For list domains
2) For add domain
3) For remove domain
4) For back
EOF

    choice=$(prompt 'option number')
    if [ "$choice" = '4' ]; then
      return 0
    fi

    if ! execute_domain_choice "$choice"; then
      continue
    fi
  done
}

users_menu() {
  while :; do
    cat <<'EOF'

Users Menu
1) For list users
2) For add user
3) For change user password
4) For delete user
5) For back
EOF

    choice=$(prompt 'option number')
    if [ "$choice" = '5' ]; then
      return 0
    fi

    if ! execute_user_choice "$choice"; then
      continue
    fi
  done
}

aliases_menu() {
  while :; do
    cat <<'EOF'

Aliases Menu
1) For list aliases
2) For add alias
3) For delete alias
4) For back
EOF

    choice=$(prompt 'option number')
    if [ "$choice" = '4' ]; then
      return 0
    fi

    if ! execute_alias_choice "$choice"; then
      continue
    fi
  done
}

menu() {
  while :; do
    cat <<'EOF'

Mailserver Admin Suite
1) For domain actions
2) For user actions
3) For alias actions
4) For init / bootstrap
5) For exit
EOF

    choice=$(prompt 'option number')

    case "$choice" in
      1)
        domains_menu
        ;;
      2)
        users_menu
        ;;
      3)
        aliases_menu
        ;;
      4)
        "$PROJECT_DIR/init.sh"
        ;;
      5)
        exit 0
        ;;
      *)
        printf 'Άγνωστη επιλογή. Δώσε αριθμό από 1 έως 5.\n' >&2
        ;;
    esac
  done
}

require_command docker

case "${1:-menu}" in
  menu|'')
    menu
    ;;
  1)
    case "${2:-menu}" in
      menu|'')
        domains_menu
        ;;
      1|2|3|4)
        execute_domain_choice "$2" "${3:-}"
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
    ;;
  2)
    case "${2:-menu}" in
      menu|'')
        users_menu
        ;;
      1)
        execute_user_choice "$2"
        ;;
      2|3)
        execute_user_choice "$2" "${3:-}" "${4:-}"
        ;;
      4|5)
        execute_user_choice "$2" "${3:-}"
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
    ;;
  3)
    case "${2:-menu}" in
      menu|'')
        aliases_menu
        ;;
      1)
        execute_alias_choice "$2"
        ;;
      2|3)
        execute_alias_choice "$2" "${3:-}" "${4:-}"
        ;;
      4)
        execute_alias_choice "$2"
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
    ;;
  4)
    "$PROJECT_DIR/init.sh"
    ;;
  5)
    exit 0
    ;;
  init)
    "$PROJECT_DIR/init.sh"
    ;;
  domain)
    case "${2:-}" in
      list)
        execute_domain_choice 1
        ;;
      add)
        execute_domain_choice 2 "${3:-}"
        ;;
      remove|delete|del)
        execute_domain_choice 3 "${3:-}"
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
    ;;
  user)
    case "${2:-}" in
      list)
        execute_user_choice 1
        ;;
      add)
        execute_user_choice 2 "${3:-}" "${4:-}"
        ;;
      update|password|passwd)
        execute_user_choice 3 "${3:-}" "${4:-}"
        ;;
      remove|delete|del)
        execute_user_choice 4 "${3:-}"
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
    ;;
  alias)
    case "${2:-}" in
      list)
        execute_alias_choice 1
        ;;
      add)
        execute_alias_choice 2 "${3:-}" "${4:-}"
        ;;
      remove|delete|del)
        execute_alias_choice 3 "${3:-}" "${4:-}"
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    printf 'Δώσε αριθμητική επιλογή 1-5 ή τρέξε ./admin.sh για το menu.\n' >&2
    usage >&2
    exit 1
    ;;
esac