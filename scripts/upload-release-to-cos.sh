#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "[Release] No files specified"
  exit 0
fi

for name in API_BASE ADMIN_EMAIL ADMIN_PASSWORD COS_SECRET_ID COS_SECRET_KEY COS_BUCKET_URL COS_REGION COS_CDN_DOMAIN; do
  if [ -z "${!name:-}" ]; then
    echo "[Release] $name not set"
    exit 1
  fi
done

echo "::add-mask::$COS_SECRET_ID"
echo "::add-mask::$COS_SECRET_KEY"

echo "[Release] Logging in..."
TOKEN=$(curl -sf "$API_BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")
[ -z "$TOKEN" ] && echo "Login failed" && exit 1

echo "[Release] Installing coscmd..."
python3 -m pip install --user --disable-pip-version-check -q coscmd
USER_BASE=$(python3 -m site --user-base)
export PATH="$USER_BASE/bin:$HOME/.local/bin:$PATH"

COS_BUCKET=$(python3 - <<'PY'
import os
from urllib.parse import urlparse

raw = os.environ["COS_BUCKET_URL"].strip()
parsed = urlparse(raw if "://" in raw else "https://" + raw)
host = parsed.netloc or parsed.path
bucket = host.split(".cos.")[0]
if not bucket:
    raise SystemExit("invalid COS_BUCKET_URL")
print(bucket)
PY
)
CDN_DOMAIN="${COS_CDN_DOMAIN#https://}"
CDN_DOMAIN="${CDN_DOMAIN#http://}"
CDN_BASE="https://${CDN_DOMAIN%/}"

echo "[Release] Configuring coscmd for bucket ${COS_BUCKET} via accelerate endpoint..."
coscmd config \
  -a "$COS_SECRET_ID" \
  -s "$COS_SECRET_KEY" \
  -b "$COS_BUCKET" \
  -e cos.accelerate.myqcloud.com \
  -m 16 \
  -p 8 \
  --retry 5 \
  --timeout 120

CONFIRM_DIR=$(mktemp -d)
trap 'rm -rf "$CONFIRM_DIR"' EXIT

file_size() {
  stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null
}

file_checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

add_confirm_item() {
  local filename="$1"
  local cdn_url="$2"
  local fsize="$3"
  local checksum="$4"
  local item_file
  item_file=$(mktemp "$CONFIRM_DIR/item.XXXXXX")
  python3 -c 'import json,sys; print(json.dumps({"filename":sys.argv[1],"cdn_url":sys.argv[2],"size":int(sys.argv[3]),"checksum":sys.argv[4]}, separators=(",",":")))' "$filename" "$cdn_url" "$fsize" "$checksum" > "$item_file"
}

upload_file_to_cos() {
  local f="$1"
  local fname fsize checksum key cdn_url
  fname=$(basename "$f")
  fsize=$(file_size "$f")
  checksum=$(file_checksum "$f")
  key="releases/$fname"
  cdn_url="${CDN_BASE}/${key}"

  echo "[Release] Uploading $fname (${fsize} bytes)..."
  coscmd upload -f "$f" "$key"
  echo "[Release] OK, CDN: $cdn_url"
  add_confirm_item "$fname" "$cdn_url" "$fsize" "$checksum"
}

uploaded=0
for f in "$@"; do
  [ -f "$f" ] || continue
  upload_file_to_cos "$f"
  uploaded=$((uploaded + 1))
done

if [ "$uploaded" -eq 0 ]; then
  echo "[Release] No matching files found"
  exit 0
fi

python3 -c 'import glob,json,sys; items=[]; [items.append(json.load(open(path, encoding="utf-8"))) for path in sorted(glob.glob(sys.argv[1] + "/item.*"))]; print(json.dumps({"files":items}, separators=(",",":")))' "$CONFIRM_DIR" > /tmp/confirm.json
echo "[Release] Confirming uploads..."
curl -sf "$API_BASE/admin/releases/confirm-upload" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/confirm.json
echo "[Release] Confirmed!"
