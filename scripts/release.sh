#!/usr/bin/env bash
# Builds a self-signed release: Release build, no Finder extension, signed with a local certificate,
# zipped, with a Sparkle appcast for that zip.
#
#   scripts/release.sh
#
# Needs: xcodegen, build/librclone/librclone.dylib (scripts/build-librclone.sh), the code-signing
# identity below in the login Keychain, and Sparkle's tools (bin/ of the Sparkle release tarball,
# SPARKLE_BIN) with the EdDSA private key from generate_keys in the Keychain.
# Output: build/release/dist/Dockyard-<version>.zip and appcast.xml. See docs/app.md, "Releases".
set -euo pipefail

IDENTITY="${SIGN_IDENTITY:-Dockyard Self-Signed}"
REPO="${GITHUB_REPO:-jeremyhaber/Dockyard}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
DIST="$BUILD/dist"
: "${SPARKLE_BIN:?set SPARKLE_BIN to the bin/ folder of the Sparkle release}"

[ -f "$ROOT/build/librclone/librclone.dylib" ] || { echo "librclone missing: run scripts/build-librclone.sh" >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "\"$IDENTITY\"" || { echo "No valid signing identity \"$IDENTITY\"" >&2; exit 1; }

(cd "$ROOT/App" && xcodegen -q)
xcodebuild -project "$ROOT/App/Dockyard.xcodeproj" -scheme Dockyard -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$BUILD" CODE_SIGNING_ALLOWED=NO build -quiet

APP="$BUILD/Build/Products/Release/Dockyard.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")

# The Finder extension needs an App Group, which only an Apple-issued certificate can carry.
rm -rf "$APP/Contents/PlugIns"

# Sign inside out: nested code first, the app last. No entitlements, so nothing needs a provisioning profile.
sign() { codesign --force --sign "$IDENTITY" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
for lib in "$APP"/Contents/Frameworks/*.dylib; do sign "$lib"; done
sign "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$DIST" && mkdir -p "$DIST"
ZIP="$DIST/Dockyard-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# One release per appcast: Sparkle only needs the newest version, and each GitHub release has its own URL.
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" "$DIST"

echo "Built $ZIP and $DIST/appcast.xml (version $VERSION)"
