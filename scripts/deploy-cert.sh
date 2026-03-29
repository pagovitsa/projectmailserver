#!/usr/bin/env sh
set -eu

TARGET_DIR=${CERTBOT_TARGET_DIR:-/tmp/dms-certs/live}
RENEWED_LINEAGE=${RENEWED_LINEAGE:?RENEWED_LINEAGE is required}

mkdir -p "$TARGET_DIR"

install -m 600 "$RENEWED_LINEAGE/fullchain.pem" "$TARGET_DIR/fullchain.pem.tmp"
install -m 600 "$RENEWED_LINEAGE/privkey.pem" "$TARGET_DIR/privkey.pem.tmp"
mv "$TARGET_DIR/fullchain.pem.tmp" "$TARGET_DIR/fullchain.pem"
mv "$TARGET_DIR/privkey.pem.tmp" "$TARGET_DIR/privkey.pem"

printf 'Deployed renewed certificate to %s\n' "$TARGET_DIR"
