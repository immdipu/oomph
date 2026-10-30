#!/bin/sh
# Builds build/release/Oomph-<version>.dmg: the app and its bundled engine signed with a
# Developer ID, both the app and the disk image notarized and stapled. Run by the release
# workflow; without NOTARY_KEY it skips notarization, so a dry run works with any identity:
#   SIGN_IDENTITY="Apple Development" Scripts/release.sh 1.1.0
set -eu
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Scripts/release.sh <version>}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
OUT=build/release
APP="$OUT/Build/Products/Release/Oomph.app"
DMG="$OUT/Oomph-$VERSION.dmg"

# Submits $1 with the App Store Connect API key at NOTARY_KEY, then staples the ticket to $2.
notarize() {
	if [ -z "${NOTARY_KEY:-}" ]; then
		echo "NOTARY_KEY isn't set; not notarizing $1"
		return
	fi
	xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
	xcrun stapler staple "$2"
}

rm -rf "$OUT"
# Unsigned, so the build script leaves the engine to the signing below.
xcodebuild -project Oomph.xcodeproj -scheme Oomph -configuration Release \
	-destination 'platform=macOS,arch=arm64' -derivedDataPath "$OUT" \
	CODE_SIGNING_ALLOWED=NO MARKETING_VERSION="$VERSION" build

# Inside out, engine first. Notarization needs Hardened Runtime and a secure timestamp on both.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Helpers/eqtune"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

# Stapling the app too lets it pass Gatekeeper offline once it's copied out of the disk image.
ditto -c -k --keepParent "$APP" "$OUT/Oomph.zip"
notarize "$OUT/Oomph.zip" "$APP"

mkdir "$OUT/dmg"
ditto "$APP" "$OUT/dmg/Oomph.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname Oomph -srcfolder "$OUT/dmg" -format UDZO "$DMG"
codesign --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG" "$DMG"
