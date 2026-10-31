#!/usr/bin/env bash
# Developer ID 公证发布: build -> notarize app -> staple -> dmg -> notarize dmg -> staple
#
# 前置:
#   1. 钥匙串里有 "Developer ID Application: ..." 证书
#   2. 一次性存公证凭据(用团队 ASC API Key, 不需要 app-specific password):
#      xcrun notarytool store-credentials avoxkit \
#        --key ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 \
#        --key-id <KEY_ID> \
#        --issuer <ISSUER_ID>
#
# 用法:
#   ./script/release_macos.sh
#   CODESIGN_IDENTITY="Developer ID Application: <Your Name> (<TEAM_ID>)" ./script/release_macos.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIST=${DIST:-"$ROOT/dist/avoxkit-macos-arm64"}
APP="$DIST/avoxkit.app"
ZIP="$DIST.zip"
PROFILE=${NOTARY_PROFILE:-avoxkit}
VERSION=$(awk -F'[:+ ]+' '/^version:/ {print $2}' "$ROOT/pubspec.yaml")
DMG="$DIST/Avoxkit-${VERSION}-arm64.dmg"
DMG_STAGE="$DIST/.dmg-stage"

die() {
  echo "❌ $*" >&2
  exit 1
}

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  CODESIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null |
    sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
fi
[ -n "$CODESIGN_IDENTITY" ] ||
  die "找不到 Developer ID Application 证书。Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application"

echo "identity: $CODESIGN_IDENTITY"
echo "version:  $VERSION"

CODESIGN_IDENTITY="$CODESIGN_IDENTITY" "$ROOT/script/build_macos.sh"

[ -d "$APP" ] || die "构建产物不存在: $APP"
codesign --verify --deep --strict --verbose=2 "$APP"
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  die "Release 包带了 get-task-allow, 不能分发"
fi

# 先公证 app, 装订后再做 DMG; 这样用户把 app 拖出 DMG 也带票据
echo "== notarize app =="
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "== build dmg =="
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/Avoxkit.app"
ln -s /Applications "$DMG_STAGE/Applications"
cp -f "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/SOURCE-OFFER.md" "$DMG_STAGE/"
rm -f "$DMG"
hdiutil create -volname "Avoxkit" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG"
rm -rf "$DMG_STAGE"
codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"

echo "== notarize dmg =="
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "== gatekeeper =="
spctl -a -vv -t install "$DMG"
spctl -a -vv -t exec "$APP"

( cd "$(dirname "$DMG")" &&
  shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256" )

echo
echo "dmg: $DMG"
echo "zip: $ZIP"
