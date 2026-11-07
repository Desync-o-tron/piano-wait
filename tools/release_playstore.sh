#!/usr/bin/env bash
set -euo pipefail

# free MIDI player (FOSS) — Android Build, Test, Sign & Play Store AAB Script
# Package ID: com.lukeknoble.freemidiplayer
# Supports:
#   ./tools/release_playstore.sh --test
#   ./tools/release_playstore.sh --apk
#   ./tools/release_playstore.sh --bundle
#   ./tools/release_playstore.sh --all

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$REPO_ROOT/android"
EXPORT_DIR="$REPO_ROOT/build/android"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_KEYSTORE_PATH="${ANDROID_KEYSTORE_PATH:-$HOME/.private_keys/freemidiplayer-upload.jks}"
export ANDROID_KEYSTORE_PASSWORD="${ANDROID_KEYSTORE_PASSWORD:-freemidiplayer2026}"
export ANDROID_KEY_ALIAS="${ANDROID_KEY_ALIAS:-upload}"
export ANDROID_KEY_PASSWORD="${ANDROID_KEY_PASSWORD:-freemidiplayer2026}"

ensure_keystore() {
  mkdir -p "$(dirname "$ANDROID_KEYSTORE_PATH")"
  if [[ ! -f "$ANDROID_KEYSTORE_PATH" ]]; then
    echo "==> Generating release upload keystore at $ANDROID_KEYSTORE_PATH..."
    keytool -genkeypair -v \
      -keystore "$ANDROID_KEYSTORE_PATH" \
      -alias "$ANDROID_KEY_ALIAS" \
      -keyalg RSA \
      -keysize 2048 \
      -validity 10000 \
      -storepass "$ANDROID_KEYSTORE_PASSWORD" \
      -keypass "$ANDROID_KEY_PASSWORD" \
      -dname "CN=Luke Knoble, OU=Mobile, O=Luke Knoble, L=Boston, ST=MA, C=US"
  fi
}

run_tests() {
  echo "==> Running Android unit tests..."
  (cd "$ANDROID_DIR" && nice -n 19 ./gradlew testDebugUnitTest --no-daemon)
}

build_apk() {
  ensure_keystore
  echo "==> Building signed Release APK (com.lukeknoble.freemidiplayer)..."
  (cd "$ANDROID_DIR" && nice -n 19 ./gradlew assembleRelease --no-daemon)
  mkdir -p "$EXPORT_DIR"
  cp "$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk" \
     "$EXPORT_DIR/free-midi-player-foss-v1.0-release.apk"
  echo "==> Verifying APK signature..."
  "$ANDROID_HOME/build-tools/35.0.0/apksigner" verify --verbose \
    "$EXPORT_DIR/free-midi-player-foss-v1.0-release.apk" | head -n 10
  ls -lh "$EXPORT_DIR/free-midi-player-foss-v1.0-release.apk"
}

build_bundle() {
  ensure_keystore
  echo "==> Building signed Play Store Release AAB (bundleRelease)..."
  (cd "$ANDROID_DIR" && nice -n 19 ./gradlew bundleRelease --no-daemon)
  mkdir -p "$EXPORT_DIR"
  cp "$ANDROID_DIR/app/build/outputs/bundle/release/app-release.aab" \
     "$EXPORT_DIR/free-midi-player-foss-v1.0-release.aab"
  echo "==> Verifying AAB jar signature..."
  jarsigner -verify "$EXPORT_DIR/free-midi-player-foss-v1.0-release.aab" | tail -n 5
  ls -lh "$EXPORT_DIR/free-midi-player-foss-v1.0-release.aab"
}

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 [--test] [--apk] [--bundle] [--all]"
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    --test)   run_tests ;;
    --apk)    build_apk ;;
    --bundle) build_bundle ;;
    --all)
      run_tests
      build_apk
      build_bundle
      ;;
    *)
      echo "Unknown option: $arg"
      exit 1
      ;;
  esac
done
