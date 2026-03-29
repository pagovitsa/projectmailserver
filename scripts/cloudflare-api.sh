API_BASE=${CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}
MANAGED_COMMENT=${CLOUDFLARE_MANAGED_COMMENT:-managed-by=mailserver}

cf_require_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'Η python3 είναι απαραίτητη για τα Cloudflare helper scripts.\n' >&2
    exit 1
  fi
}

cf_extract_token() {
  cf_token_file=$1

  awk -F '=' '/dns_cloudflare_api_token/ {
    gsub(/^[ \t]+|[ \t]+$/, "", $2)
    print $2
    exit
  }' "$cf_token_file"
}

cf_extract_value() {
  cf_token_file=$1
  cf_key=$2

  awk -F '=' -v target="$cf_key" '
    {
      current = $1
      gsub(/^[ \t]+|[ \t]+$/, "", current)
      if (current == target) {
        value = substr($0, index($0, "=") + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", value)
        print value
        exit
      }
    }
  ' "$cf_token_file"
}

cf_looks_like_global_api_key() {
  cf_value=$1
  printf '%s' "$cf_value" | python3 -c 'import re, sys; value=sys.stdin.read().strip(); raise SystemExit(0 if re.fullmatch(r"[0-9A-Fa-f]{37}", value) else 1)'
}

cf_init() {
  cf_token_file=$1

  cf_require_python

  if [ ! -f "$cf_token_file" ]; then
    printf 'Cloudflare credentials file not found: %s\n' "$cf_token_file" >&2
    exit 1
  fi

  CLOUDFLARE_TOKEN=$(cf_extract_token "$cf_token_file")
  CLOUDFLARE_EMAIL=$(cf_extract_value "$cf_token_file" dns_cloudflare_email)
  CLOUDFLARE_API_KEY=$(cf_extract_value "$cf_token_file" dns_cloudflare_api_key)

  if [ -n "$CLOUDFLARE_TOKEN" ]; then
    if cf_looks_like_global_api_key "$CLOUDFLARE_TOKEN" && [ -z "$CLOUDFLARE_EMAIL" ] && [ -z "$CLOUDFLARE_API_KEY" ]; then
      printf 'Το credential στο %s μοιάζει με Cloudflare Global API Key και όχι με API Token.\n' "$cf_token_file" >&2
      printf 'Χρησιμοποίησε είτε πραγματικό API Token, είτε αποθήκευσε και dns_cloudflare_email + dns_cloudflare_api_key.\n' >&2
      exit 1
    fi

    CLOUDFLARE_AUTH_MODE=token
    return
  fi

  if [ -n "$CLOUDFLARE_EMAIL" ] && [ -n "$CLOUDFLARE_API_KEY" ]; then
    CLOUDFLARE_AUTH_MODE=global-key
    return
  fi

  printf 'Δεν βρέθηκε έγκυρο Cloudflare credential στο %s\n' "$cf_token_file" >&2
  printf 'Υποστήριξη: dns_cloudflare_api_token ή dns_cloudflare_email + dns_cloudflare_api_key\n' >&2
  exit 1
}

cf_json_success() {
  python3 -c 'import sys, json; data=json.load(sys.stdin); print("true" if data.get("success") else "false")'
}

cf_print_api_messages() {
  python3 -c '
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    print("Κενή απάντηση από το Cloudflare API.", file=sys.stderr)
    raise SystemExit(0)
try:
    data = json.loads(raw)
except Exception:
    print(raw, file=sys.stderr)
    raise SystemExit(0)
items = (data.get("errors") or []) + (data.get("messages") or [])
if not items:
    print(raw, file=sys.stderr)
    raise SystemExit(0)
for item in items:
    code = item.get("code")
    message = item.get("message") or str(item)
    if code is None:
        print(f"Cloudflare API: {message}", file=sys.stderr)
    else:
        print(f"Cloudflare API error {code}: {message}", file=sys.stderr)
'
}

cf_request() {
  cf_method=$1
  cf_path=$2
  cf_body=${3:-}

  if [ -n "$cf_body" ]; then
    if [ "$CLOUDFLARE_AUTH_MODE" = 'token' ]; then
      cf_output=$(curl -sS -X "$cf_method" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $CLOUDFLARE_TOKEN" \
        "$API_BASE$cf_path" \
        --data "$cf_body" \
        -w '\n%{http_code}') || {
        printf 'Αποτυχία επικοινωνίας με το Cloudflare API για %s %s\n' "$cf_method" "$cf_path" >&2
        exit 1
      }
    else
      cf_output=$(curl -sS -X "$cf_method" \
        -H 'Content-Type: application/json' \
        -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
        -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
        "$API_BASE$cf_path" \
        --data "$cf_body" \
        -w '\n%{http_code}') || {
        printf 'Αποτυχία επικοινωνίας με το Cloudflare API για %s %s\n' "$cf_method" "$cf_path" >&2
        exit 1
      }
    fi
  else
    if [ "$CLOUDFLARE_AUTH_MODE" = 'token' ]; then
      cf_output=$(curl -sS -X "$cf_method" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $CLOUDFLARE_TOKEN" \
        "$API_BASE$cf_path" \
        -w '\n%{http_code}') || {
        printf 'Αποτυχία επικοινωνίας με το Cloudflare API για %s %s\n' "$cf_method" "$cf_path" >&2
        exit 1
      }
    else
      cf_output=$(curl -sS -X "$cf_method" \
        -H 'Content-Type: application/json' \
        -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
        -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
        "$API_BASE$cf_path" \
        -w '\n%{http_code}') || {
        printf 'Αποτυχία επικοινωνίας με το Cloudflare API για %s %s\n' "$cf_method" "$cf_path" >&2
        exit 1
      }
    fi
  fi

  cf_status=$(printf '%s' "$cf_output" | tail -n 1)
  cf_response=$(printf '%s' "$cf_output" | sed '$d')

  case "$cf_status" in
    2??) ;;
    *)
      printf '%s' "$cf_response" | cf_print_api_messages
      exit 1
      ;;
  esac

  if [ "$(printf '%s' "$cf_response" | cf_json_success)" != 'true' ]; then
    printf '%s' "$cf_response" | cf_print_api_messages
    exit 1
  fi

  printf '%s' "$cf_response"
}

cf_verify_token() {
  if [ "$CLOUDFLARE_AUTH_MODE" != 'token' ]; then
    return
  fi

  cf_response=$(cf_request GET "/user/tokens/verify")
  cf_status=$(printf '%s' "$cf_response" | python3 -c 'import sys, json; data=json.load(sys.stdin); print((data.get("result") or {}).get("status", ""))')

  if [ "$cf_status" != 'active' ]; then
    printf 'Το Cloudflare token δεν είναι active. Current status: %s\n' "$cf_status" >&2
    exit 1
  fi
}

cf_get_zone_id_exact() {
  cf_zone_name=$1
  cf_request GET "/zones?name=$cf_zone_name&status=active" | python3 -c 'import sys, json; data=json.load(sys.stdin); result=data.get("result") or []; print((result[0].get("id") if result else ""))'
}

cf_find_zone_for_name() {
  cf_name=$1
  cf_candidate=$cf_name

  while [ -n "$cf_candidate" ]; do
    cf_zone_id=$(cf_get_zone_id_exact "$cf_candidate")
    if [ -n "$cf_zone_id" ]; then
      printf '%s|%s' "$cf_zone_id" "$cf_candidate"
      return 0
    fi

    case "$cf_candidate" in
      *.*)
        cf_candidate=${cf_candidate#*.}
        ;;
      *)
        break
        ;;
    esac
  done

  return 1
}

cf_build_payload() {
  cf_type=$1
  cf_name=$2
  cf_content=$3
  cf_ttl=$4
  cf_proxied=$5
  cf_priority=${6:-}
  cf_comment=${7:-$MANAGED_COMMENT}

  python3 - "$cf_type" "$cf_name" "$cf_content" "$cf_ttl" "$cf_proxied" "$cf_priority" "$cf_comment" <<'PY'
import json
import sys

record_type, name, content, ttl, proxied, priority, comment = sys.argv[1:8]
payload = {
    "type": record_type,
    "name": name,
    "content": content,
    "ttl": int(ttl),
    "comment": comment,
}

if record_type in {"A", "AAAA", "CNAME"}:
    payload["proxied"] = proxied.lower() == "true"

if record_type == "MX" and priority != "":
    payload["priority"] = int(priority)

print(json.dumps(payload, separators=(",", ":")))
PY
}

cf_find_record_id() {
  cf_zone_id=$1
  cf_type=$2
  cf_name=$3
  cf_selector=${4:-any}
  cf_comment=${5:-$MANAGED_COMMENT}
  cf_response=$(cf_request GET "/zones/$cf_zone_id/dns_records?type=$cf_type&name=$cf_name")

  CF_RESPONSE="$cf_response" python3 - "$cf_selector" "$cf_comment" <<'PY'
import json
import os
import sys

selector = sys.argv[1]
comment = sys.argv[2]
records = (json.loads(os.environ["CF_RESPONSE"]).get("result") or [])

def matches(record):
    content = record.get("content") or ""
    record_comment = record.get("comment") or ""
    if selector == "spf":
        return content.startswith("v=spf1") or record_comment == comment
    if selector == "dmarc":
        return content.startswith("v=DMARC1") or record_comment == comment
    if selector == "dkim":
        return content.startswith("v=DKIM1") or record_comment == comment
    if selector == "comment":
        return record_comment == comment
    if selector == "any":
        return True
    raise SystemExit(f"Unsupported record selector: {selector}")

if selector == "any":
    for record in records:
      if (record.get("comment") or "") == comment:
        print(record.get("id") or "")
        raise SystemExit(0)
    print((records[0].get("id") if records else ""))
    raise SystemExit(0)

for record in records:
    if matches(record):
        print(record.get("id") or "")
        break
else:
    print("")
PY
}

cf_upsert_record() {
  cf_zone_id=$1
  cf_type=$2
  cf_name=$3
  cf_content=$4
  cf_ttl=$5
  cf_proxied=$6
  cf_selector=${7:-any}
  cf_priority=${8:-}
  cf_comment=${9:-$MANAGED_COMMENT}

  cf_payload=$(cf_build_payload "$cf_type" "$cf_name" "$cf_content" "$cf_ttl" "$cf_proxied" "$cf_priority" "$cf_comment")
  cf_record_id=$(cf_find_record_id "$cf_zone_id" "$cf_type" "$cf_name" "$cf_selector" "$cf_comment")

  if [ -n "$cf_record_id" ]; then
    cf_request PATCH "/zones/$cf_zone_id/dns_records/$cf_record_id" "$cf_payload" >/dev/null
    printf 'Updated %s %s\n' "$cf_type" "$cf_name"
  else
    cf_request POST "/zones/$cf_zone_id/dns_records" "$cf_payload" >/dev/null
    printf 'Created %s %s\n' "$cf_type" "$cf_name"
  fi
}
