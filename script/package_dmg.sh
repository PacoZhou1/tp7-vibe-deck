#!/usr/bin/env bash
set -euo pipefail

APP_NAME="TP7VibeInput"
PRODUCT_NAME="TP7 Vibe Deck"
VOLUME_NAME="TP7 Vibe Deck"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$PRODUCT_NAME.app"
OUTPUT_DMG="${1:-$ROOT_DIR/../TP7VibeDeck.dmg}"

mkdir -p "$(dirname "$OUTPUT_DMG")" "$DIST_DIR"

CONFIGURATION=release "$ROOT_DIR/script/build_and_run.sh" bundle

/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

STAGE_DIR="$(/usr/bin/mktemp -d "$DIST_DIR/dmg-stage.XXXXXX")"
cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

cp -R "$APP_BUNDLE" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$OUTPUT_DMG"
/usr/bin/hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$OUTPUT_DMG"

/usr/bin/hdiutil verify "$OUTPUT_DMG"

echo "$OUTPUT_DMG"
