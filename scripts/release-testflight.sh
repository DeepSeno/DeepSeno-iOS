#!/usr/bin/env bash
# Release DeepSeno to App Store Connect / TestFlight.
#
# What it does (in order):
#   1. Bumps CURRENT_PROJECT_VERSION in project.yml by +1 (unless --no-bump).
#   2. Regenerates the Xcode project, restores Info.plist version values.
#   3. Cleans + archives Release configuration for generic iOS device.
#   4. Exports a signed App Store IPA using cloud-managed signing.
#   5. Uploads to App Store Connect via App Store Connect API key.
#
# Requirements (one-time setup):
#   - Apple Developer Program membership.
#   - App Store Connect API key with Admin role saved at:
#       ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#   - ./.env file in repo root with KEY_ID, ISSUER_ID, and TEAM_ID, e.g.:
#       Key ID=<APP_STORE_CONNECT_KEY_ID>
#       Issuer ID=<APP_STORE_CONNECT_ISSUER_ID>
#       Team ID=<APPLE_TEAM_ID>
#       Bundle ID=<APP_BUNDLE_ID>
#       Relay Server Base URL=<RELAY_SERVER_BASE_URL, optional>
#       Private Key Base64=<base64 encoded .p8, optional if .p8 already exists>
#     (.env is gitignored.)
#   - ExportOptions.plist at repo root with method=app-store-connect.
#
# Usage:
#   ./scripts/release-testflight.sh                    # bump build, archive, upload
#   ./scripts/release-testflight.sh --no-bump          # reuse current build number
#   ./scripts/release-testflight.sh --no-upload        # build + export only, skip upload
#   ./scripts/release-testflight.sh --validate         # validate IPA without uploading

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# ─── Parse args ───────────────────────────────────────────────────────────
BUMP=1
UPLOAD=1
VALIDATE_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --no-bump)      BUMP=0 ;;
        --no-upload)    UPLOAD=0 ;;
        --validate)     VALIDATE_ONLY=1 ;;
        -h|--help)
            sed -n '/^# /,/^$/p' "$0" | head -30
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 1 ;;
    esac
done

# ─── Load .env ────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
    echo "❌ Missing .env at $REPO_ROOT/.env. See script header for required format." >&2
    exit 1
fi
KEY_ID=$(grep -E '^Key ID=' .env | head -1 | cut -d= -f2- | tr -d '[:space:]')
ISSUER_ID=$(grep -E '^Issuer ID=' .env | head -1 | cut -d= -f2- | tr -d '[:space:]')
TEAM_ID=$(grep -E '^Team ID=' .env | head -1 | cut -d= -f2- | tr -d '[:space:]')
BUNDLE_ID=$(grep -E '^Bundle ID=' .env | head -1 | cut -d= -f2- | tr -d '[:space:]')
RELAY_SERVER_BASE_URL=$(grep -E '^Relay Server Base URL=' .env | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)
PRIVATE_KEY_BASE64=$(grep -E '^Private Key Base64=' .env | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)
if [[ -z "$KEY_ID" || -z "$ISSUER_ID" || -z "$TEAM_ID" || -z "$BUNDLE_ID" ]]; then
    echo "❌ .env must contain 'Key ID=...', 'Issuer ID=...', 'Team ID=...', and 'Bundle ID=...' lines." >&2
    exit 1
fi
P8="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
if [[ ! -f "$P8" && -n "$PRIVATE_KEY_BASE64" ]]; then
    echo "🔐 Decoding App Store Connect private key from .env"
    mkdir -p "$(dirname "$P8")"
    if ! printf '%s' "$PRIVATE_KEY_BASE64" | base64 -D > "$P8" 2>/dev/null; then
        printf '%s' "$PRIVATE_KEY_BASE64" | base64 --decode > "$P8"
    fi
    chmod 600 "$P8"
fi
if [[ ! -f "$P8" ]]; then
    echo "❌ Missing API key at $P8" >&2
    echo "   Copy the downloaded .p8 there. File name must be AuthKey_<KEY_ID>.p8." >&2
    echo "   Or put 'Private Key Base64=...' in .env." >&2
    exit 1
fi

# ─── Bump build number ────────────────────────────────────────────────────
CURRENT_BUILD=$(grep -E '^\s*CURRENT_PROJECT_VERSION:' project.yml | head -1 | awk '{print $2}')
MARKETING=$(grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | awk '{print $2}' | tr -d '"')
if [[ $BUMP -eq 1 ]]; then
    NEW_BUILD=$((CURRENT_BUILD + 1))
    echo "🔼 Bumping CURRENT_PROJECT_VERSION: $CURRENT_BUILD → $NEW_BUILD"
    # macOS sed needs '' after -i
    sed -i '' "s/CURRENT_PROJECT_VERSION: $CURRENT_BUILD/CURRENT_PROJECT_VERSION: $NEW_BUILD/" project.yml
    CURRENT_BUILD=$NEW_BUILD
else
    echo "↪ Reusing build $CURRENT_BUILD (--no-bump)"
fi
echo "📦 Version: $MARKETING ($CURRENT_BUILD)"

# ─── Regen Xcode project + fix Info.plist ─────────────────────────────────
echo "🔧 xcodegen generate"
xcodegen generate >/dev/null
# xcodegen regenerates Info.plist with placeholders (1.0/1). Force the real
# strings — pbxproj override means actual build picks them up anyway, but the
# file looks right in the diff.
plutil -replace CFBundleShortVersionString -string "$MARKETING" DeepSeno/Info.plist
plutil -replace CFBundleVersion -string "$CURRENT_BUILD" DeepSeno/Info.plist
if [[ -f DeepSenoShareExtension/Info.plist ]]; then
    plutil -replace CFBundleShortVersionString -string "$MARKETING" DeepSenoShareExtension/Info.plist
    plutil -replace CFBundleVersion -string "$CURRENT_BUILD" DeepSenoShareExtension/Info.plist
fi

# ─── Archive ──────────────────────────────────────────────────────────────
ARCHIVE_PATH="$REPO_ROOT/build/DeepSeno.xcarchive"
IPA_DIR="$REPO_ROOT/build/ipa"
EXPORT_OPTIONS="$REPO_ROOT/build/ExportOptions.generated.plist"
rm -rf "$ARCHIVE_PATH" "$IPA_DIR"
mkdir -p "$REPO_ROOT/build"
cp ExportOptions.plist "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM_ID" "$EXPORT_OPTIONS" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS"

echo "🛠  Archiving (may take 1–2 min)…"
xcodebuild -scheme DeepSeno \
    -destination 'generic/platform=iOS' \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$P8" \
    -authenticationKeyID "$KEY_ID" \
    -authenticationKeyIssuerID "$ISSUER_ID" \
    DEEPSENO_DEVELOPMENT_TEAM="$TEAM_ID" \
    DEEPSENO_BUNDLE_ID="$BUNDLE_ID" \
    DEEPSENO_RELAY_SERVER_BASE_URL="$RELAY_SERVER_BASE_URL" \
    clean archive 2>&1 | grep -E 'ARCHIVE|error:|^\*\*' | tail -5

if [[ ! -d "$ARCHIVE_PATH" ]]; then
    echo "❌ Archive failed — see Xcode logs above." >&2
    exit 1
fi
echo "✅ Archive at $ARCHIVE_PATH"

# ─── Export IPA ───────────────────────────────────────────────────────────
echo "📤 Exporting signed IPA…"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$IPA_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$P8" \
    -authenticationKeyID "$KEY_ID" \
    -authenticationKeyIssuerID "$ISSUER_ID" 2>&1 | tail -5

IPA="$IPA_DIR/DeepSeno.ipa"
if [[ ! -f "$IPA" ]]; then
    echo "❌ Export failed — no IPA produced." >&2
    exit 1
fi
echo "✅ IPA: $IPA ($(du -h "$IPA" | awk '{print $1}'))"

# ─── Validate or Upload ───────────────────────────────────────────────────
if [[ $VALIDATE_ONLY -eq 1 ]]; then
    echo "🧪 Validating (not uploading)…"
    xcrun altool --validate-app -f "$IPA" -t ios \
        --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID"
    exit 0
fi

if [[ $UPLOAD -eq 0 ]]; then
    echo "⏭  Skipping upload (--no-upload). IPA ready at $IPA"
    exit 0
fi

echo "🚀 Uploading to App Store Connect…"
xcrun altool --upload-app -f "$IPA" -t ios \
    --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID"

echo ""
echo "🎉 Done. Build $MARKETING ($CURRENT_BUILD) uploaded."
echo "   Processing takes 10–30 min. Track at:"
echo "   https://appstoreconnect.apple.com/apps"
