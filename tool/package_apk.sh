#!/usr/bin/env bash
# Build the Gundam POS release APK and package it for testing.
#
#   ./tool/package_apk.sh [API_BASE] [OUT_ZIP]
#   ./tool/package_apk.sh http://10.80.88.20:3100
#
# The API base is compiled in (dart-define) because the app has no runtime
# server setting yet — see tool/BUILD-README.md.
set -euo pipefail

API_BASE="${1:-http://10.80.88.20:3100}"
POS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ZIP="${2:-/tmp/gundam-pos-test-$(date +%Y%m%d-%H%M).zip}"

export PATH="$HOME/.local/bin:$HOME/flutter/bin:$PATH"
cd "$POS_DIR"

echo "== flutter test"
flutter test

echo "== flutter build apk --release (POS_API_BASE=$API_BASE)"
flutter build apk --release --dart-define="POS_API_BASE=$API_BASE"

APK="build/app/outputs/flutter-apk/app-release.apk"
[ -f "$APK" ] || { echo "APK missing: $APK" >&2; exit 1; }

STAGE="$(mktemp -d)"
cp "$APK" "$STAGE/gundam-pos-release.apk"
cp tool/BUILD-README.md "$STAGE/BUILD-README.md"
cp tool/README-icons.md "$STAGE/README-icons.md"

( cd "$STAGE" && zip -q -r "$OUT_ZIP" . )
rm -rf "$STAGE"

echo "== packaged: $OUT_ZIP"
unzip -l "$OUT_ZIP"
