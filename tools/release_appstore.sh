#!/usr/bin/env bash
set -euo pipefail

# Free MIDI Player — App Store Connect Build, Archive, Export & Upload Script
# Supports:
#   ./tools/release_appstore.sh --register-bundle-id
#   ./tools/release_appstore.sh --archive
#   ./tools/release_appstore.sh --export
#   ./tools/release_appstore.sh --validate
#   ./tools/release_appstore.sh --upload
#   ./tools/release_appstore.sh --configure-metadata
#   ./tools/release_appstore.sh --all

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUNDLE_ID="${BUNDLE_ID:-com.lukeknoble.freemidiplayer}"
APP_NAME="${APP_NAME:-Free MIDI Player}"
TEAM_ID="${DEVELOPMENT_TEAM:-QKZ4JTYUVM}"
SCHEME="PianoWait"
PROJECT="PianoWait.xcodeproj"
ARCHIVE_PATH="${ARCHIVE_PATH:-$REPO_ROOT/build/FreeMIDIPlayer.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$REPO_ROOT/build/Export}"
EXPORT_OPTIONS="${EXPORT_OPTIONS:-$REPO_ROOT/AppStore/ExportOptions.plist}"

ASC_KEY_ID="${ASC_KEY_ID:-362BK739MY}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-cd0c881b-f57b-4030-9d14-73f868ececb6}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.private_keys/AuthKey_${ASC_KEY_ID}.p8}"

AUTH_FLAGS=()
if [[ -f "$ASC_KEY_PATH" ]]; then
  AUTH_FLAGS=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

register_bundle_id() {
  echo "==> Checking / Registering Bundle ID '$BUNDLE_ID' ($APP_NAME) on App Store Connect..."
  if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "ERROR: App Store Connect key not found at $ASC_KEY_PATH"
    exit 1
  fi

  SSL_CERT_FILE=/etc/ssl/cert.pem python3 - "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$ASC_KEY_PATH" "$BUNDLE_ID" "$APP_NAME" <<'PY'
import sys, time, json, urllib.request, urllib.error
import jwt

key_id, issuer_id, key_path, bundle_id, app_name = sys.argv[1:6]
with open(key_path, "r") as f:
    private_key = f.read()

token = jwt.encode(
    {"iss": issuer_id, "iat": int(time.time()), "exp": int(time.time()) + 900, "aud": "appstoreconnect-v1"},
    private_key,
    algorithm="ES256",
    headers={"kid": key_id, "typ": "JWT"},
)

headers = {
    "Authorization": f"Bearer {token}",
    "Content-Type": "application/json",
}

req = urllib.request.Request(
    f"https://api.appstoreconnect.apple.com/v1/bundleIds?filter%5Bidentifier%5D={bundle_id}",
    headers=headers,
)
with urllib.request.urlopen(req, timeout=20) as resp:
    data = json.loads(resp.read().decode())
    existing = [b for b in data.get("data", []) if b["attributes"]["identifier"] == bundle_id]
    if existing:
        print(f"Bundle ID already registered: {existing[0]['id']} ({bundle_id})")
        sys.exit(0)

payload = {
    "data": {
        "type": "bundleIds",
        "attributes": {
            "identifier": bundle_id,
            "name": app_name,
            "platform": "UNIVERSAL",
        },
    }
}
req = urllib.request.Request(
    "https://api.appstoreconnect.apple.com/v1/bundleIds",
    data=json.dumps(payload).encode("utf-8"),
    headers=headers,
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        created = json.loads(resp.read().decode())
        print(f"Registered Bundle ID: {created['data']['id']} ({bundle_id})")
except urllib.error.HTTPError as e:
    print(f"Failed to register Bundle ID ({e.code}): {e.read().decode()}")
    sys.exit(1)
PY
}

build_archive() {
  echo "==> Archiving $SCHEME ($BUNDLE_ID) for generic iOS device..."
  mkdir -p "$(dirname "$ARCHIVE_PATH")"
  rm -rf "$ARCHIVE_PATH"
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    -allowProvisioningUpdates \
    "${AUTH_FLAGS[@]}"
  echo "==> Archive created at: $ARCHIVE_PATH"
}

export_ipa() {
  echo "==> Exporting IPA from $ARCHIVE_PATH..."
  rm -rf "$EXPORT_PATH"
  mkdir -p "$EXPORT_PATH"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_PATH" \
    -allowProvisioningUpdates \
    "${AUTH_FLAGS[@]}"
  echo "==> Exported IPA contents:"
  ls -la "$EXPORT_PATH"
}

find_ipa() {
  local ipa
  ipa="$(find "$EXPORT_PATH" -maxdepth 1 -name "*.ipa" | head -n 1)"
  if [[ -z "$ipa" ]]; then
    echo "ERROR: No .ipa found in $EXPORT_PATH" >&2
    exit 1
  fi
  echo "$ipa"
}

check_asc_app_record() {
  if [[ ! -f "$ASC_KEY_PATH" ]]; then
    return 0
  fi
  SSL_CERT_FILE=/etc/ssl/cert.pem python3 - "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$ASC_KEY_PATH" "$BUNDLE_ID" "$APP_NAME" <<'PY'
import sys, time, json, urllib.request
import jwt

key_id, issuer_id, key_path, bundle_id, app_name = sys.argv[1:6]
with open(key_path, "r") as f:
    private_key = f.read()

token = jwt.encode(
    {"iss": issuer_id, "iat": int(time.time()), "exp": int(time.time()) + 900, "aud": "appstoreconnect-v1"},
    private_key,
    algorithm="ES256",
    headers={"kid": key_id, "typ": "JWT"},
)
req = urllib.request.Request(
    f"https://api.appstoreconnect.apple.com/v1/apps?filter%5BbundleId%5D={bundle_id}",
    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=20) as resp:
    data = json.loads(resp.read().decode()).get("data", [])
    if data:
        print(f"==> Found App Store Connect App ID: {data[0]['id']} ({bundle_id})")
    else:
        print(f"==> NOTE: Bundle ID '{bundle_id}' is registered on App Store Connect,")
        print("    but the App Store Connect App record has not been created in the web UI yet.")
        print("    (Apple blocks POST /v1/apps via API key with 403 FORBIDDEN_ERROR.)")
        print("    Create it once at https://appstoreconnect.apple.com/apps -> (+) New App:")
        print(f"      - Platform: iOS")
        print(f"      - Name: {app_name}")
        print(f"      - Primary Language: English (U.S.)")
        print(f"      - Bundle ID: {bundle_id}")
        print(f"      - SKU: freemidiplayer-ios-001")
PY
}

validate_ipa() {
  local ipa
  ipa="$(find_ipa)"
  check_asc_app_record
  echo "==> Validating $ipa with App Store Connect..."
  xcrun altool --validate-app \
    -f "$ipa" \
    -t ios \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID"
}

upload_ipa() {
  local ipa
  ipa="$(find_ipa)"
  check_asc_app_record
  echo "==> Uploading $ipa to App Store Connect / TestFlight..."
  xcrun altool --upload-app \
    -f "$ipa" \
    -t ios \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID"
}

configure_metadata() {
  echo "==> Configuring App Store Connect metadata via REST API..."
  SSL_CERT_FILE=/etc/ssl/cert.pem python3 "$REPO_ROOT/tools/configure_asc_metadata.py"
}

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 [--register-bundle-id] [--archive] [--export] [--validate] [--upload] [--configure-metadata] [--all]"
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    --register-bundle-id)  register_bundle_id ;;
    --archive)             build_archive ;;
    --export)              export_ipa ;;
    --validate)            validate_ipa ;;
    --upload)              upload_ipa ;;
    --configure-metadata)  configure_metadata ;;
    --all)
      register_bundle_id
      build_archive
      export_ipa
      validate_ipa
      upload_ipa
      configure_metadata
      ;;
    *)
      echo "Unknown option: $arg"
      exit 1
      ;;
  esac
done
