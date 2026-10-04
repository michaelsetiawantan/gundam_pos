#!/usr/bin/env bash
# Build the Gundam POS release APK, stamp it with its version + build identity, and package it with
# the release metadata the server needs (sha256 + changelog).
#
#   ./tool/package_apk.sh [API_BASE] [OUT_ZIP] [VERSION_NAME] [VERSION_CODE]
#   ./tool/package_apk.sh http://10.80.88.20:3100 /tmp/gundam-pos.zip 0.2.0 2
#
# The API base is only the build-time DEFAULT now — the tablet can change its server address on the
# Activation/Login screen (see tool/BUILD-README.md).
set -euo pipefail

API_BASE="${1:-http://10.80.88.20:3100}"
POS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$POS_DIR/.." && pwd)"

# Version identity: CLI args win, else the pubspec `version:` line (name+build).
PUBSPEC_VERSION="$(sed -n 's/^version: *\([^+ ]*\)\(+\([0-9]*\)\)\?.*/\1 \3/p' "$POS_DIR/pubspec.yaml" | head -1)"
VERSION_NAME="${3:-${PUBSPEC_VERSION%% *}}"
VERSION_CODE="${4:-${PUBSPEC_VERSION##* }}"
[ -n "$VERSION_CODE" ] || VERSION_CODE=1
OUT_ZIP="${2:-/tmp/gundam-pos-${VERSION_NAME}-$(date +%Y%m%d-%H%M).zip}"

BUILD_SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_TIME="$(date -Iseconds)"

export PATH="$HOME/.local/bin:$HOME/flutter/bin:$PATH"
cd "$POS_DIR"

echo "== version $VERSION_NAME (code $VERSION_CODE) · sha $BUILD_SHA"
echo "== flutter test"
flutter test

echo "== flutter build apk --release (POS_API_BASE=$API_BASE)"
flutter build apk --release \
  --build-name="$VERSION_NAME" \
  --build-number="$VERSION_CODE" \
  --dart-define="POS_API_BASE=$API_BASE" \
  --dart-define="BUILD_VERSION=$VERSION_NAME" \
  --dart-define="BUILD_NUMBER=$VERSION_CODE" \
  --dart-define="BUILD_SHA=$BUILD_SHA" \
  --dart-define="BUILD_TIME=$BUILD_TIME"

APK="build/app/outputs/flutter-apk/app-release.apk"
[ -f "$APK" ] || { echo "APK missing: $APK" >&2; exit 1; }

# GUARD (learned the hard way): Flutter injects android.permission.INTERNET only
# into the DEBUG/PROFILE manifests. A release APK without it in the MAIN manifest
# cannot make a single HTTP request, and on the tablet it looks like "this device
# has no internet" while Chrome on the same tablet reaches the server fine.
# Assert it on the BUILT apk, so no future manifest edit can ship that state.
AAPT2="$(ls -d "$HOME"/android-sdk/build-tools/*/aapt2 2>/dev/null | tail -1)"
if [ -n "$AAPT2" ]; then
  # No pipe into `grep -q`: grep exits on the first match, which SIGPIPEs aapt2 and
  # (under `set -o pipefail`) reports a failure even when the permission IS there.
  BADGING="$("$AAPT2" dump badging "$APK" 2>/dev/null || true)"
  # Every capability the tablet needs in the field. A missing INTERNET shipped once
  # (activation looked like "no internet"); the rest are declared in the MAIN
  # manifest for the same reason, so the WHOLE set is asserted here.
  REQUIRED_PERMS="
    android.permission.INTERNET
    android.permission.ACCESS_NETWORK_STATE
    android.permission.ACCESS_WIFI_STATE
    android.permission.WAKE_LOCK
    android.permission.FOREGROUND_SERVICE
    android.permission.FOREGROUND_SERVICE_DATA_SYNC
    android.permission.DOWNLOAD_WITHOUT_NOTIFICATION
    android.permission.READ_EXTERNAL_STORAGE
    android.permission.WRITE_EXTERNAL_STORAGE
    android.permission.REQUEST_INSTALL_PACKAGES
    android.permission.BLUETOOTH_CONNECT
    android.permission.CAMERA
    android.permission.REORDER_TASKS
    com.google.android.c2dm.permission.RECEIVE
    android.permission.POST_NOTIFICATIONS
    android.permission.READ_SYNC_SETTINGS
    android.permission.WRITE_SYNC_SETTINGS"
  MISSING=""
  for P in $REQUIRED_PERMS; do
    case "$BADGING" in
      *"uses-permission: name='$P'"*) ;;
      *) MISSING="$MISSING $P" ;;
    esac
  done
  # The app-scoped C2D_MESSAGE permission is stamped with the applicationId, so it
  # is matched by suffix rather than by a name we cannot know at build time.
  case "$BADGING" in
    *".permission.C2D_MESSAGE'"*) ;;
    *) MISSING="$MISSING <applicationId>.permission.C2D_MESSAGE" ;;
  esac
  if [ -n "$MISSING" ]; then
    echo "FATAL: the release APK is missing required permission(s):$MISSING" >&2
    echo "       Add them to android/app/src/main/AndroidManifest.xml — a release" >&2
    echo "       build does NOT inherit the debug manifest, and the tablet cannot" >&2
    echo "       reach the network or keep a job alive without them." >&2
    exit 1
  fi
  echo "== guard: all required permissions present in the release APK"
else
  echo "== guard SKIPPED: aapt2 not found under ~/android-sdk/build-tools" >&2
fi

SHA256="$(sha256sum "$APK" | awk '{print $1}')"
SIZE="$(stat -c %s "$APK")"
APK_NAME="gundam-pos-${VERSION_NAME}.apk"

STAGE="$(mktemp -d)"
cp "$APK" "$STAGE/$APK_NAME"
cp tool/BUILD-README.md "$STAGE/BUILD-README.md"
cp tool/README-icons.md "$STAGE/README-icons.md"
cp CHANGELOG.md "$STAGE/CHANGELOG.md"

# Release metadata for /app/pos-releases (paste the sha256 + the changelog section for this version).
python3 - "$STAGE" "$VERSION_NAME" "$VERSION_CODE" "$SHA256" "$SIZE" "$APK_NAME" "$BUILD_TIME" <<'PY'
import json, os, sys
stage, version, code, sha, size, apk_name, build_time = sys.argv[1:8]
meta = {
    "version": version,
    "versionCode": int(code),
    "apk_asset": apk_name,
    "sha256": sha,
    "sizeBytes": int(size),
    "apk_url": f"<URL publik ke {apk_name}>",
    "min_supported_config": None,
    "mandatory": False,
    "released_at": build_time,
    "note": "Upload the APK where apk_url points, then create + publish a release in /app/pos-releases with this sha256 and the changelog section for this version.",
}
with open(os.path.join(stage, "version.json"), "w") as fh:
    json.dump(meta, fh, indent=2)
with open(os.path.join(stage, "sha256.txt"), "w") as fh:
    fh.write(f"{sha}  {apk_name}\n")
print("sha256:", sha)
print("size:", size, "bytes")
PY

( cd "$STAGE" && python3 - "$OUT_ZIP" <<'PY'
import os, sys, zipfile
out = sys.argv[1]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for name in sorted(os.listdir(".")):
        z.write(name, name)
PY
)
rm -rf "$STAGE"

echo "== packaged: $OUT_ZIP  (version $VERSION_NAME / code $VERSION_CODE)"
python3 -c "import sys,zipfile;z=zipfile.ZipFile(sys.argv[1]);[print(f'{i.file_size:>10}  {i.filename}') for i in z.infolist()]" "$OUT_ZIP"
