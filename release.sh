#!/bin/bash
set -euo pipefail

# Canopy release script
# Usage: ./release.sh 3.0.1
# Bumps MARKETING_VERSION, archives, exports, notarizes, staples, zips, and
# generates the Sparkle appcasts — ready to upload to GitHub Releases.
#
# Canopy is one app (it took over Transcriber's bundle id and update feed), so there is nothing to embed.
# One appcast comes out, in build/appcast/, for the iamanthonyterry/canopy-app repo (formerly "transcriber").
# Installed copies still ask github.com/iamanthonyterry/transcriber/releases/latest/download/appcast.xml,
# which GitHub redirects to canopy-app. Never create a new repo called "transcriber": it would break that redirect.
# The old Canopy repo is archived, so its feed is gone. Its zip no longer gets built.
# CURRENT_PROJECT_VERSION is the date, so it is always newer than any earlier Transcriber or Canopy build.
# Builds arm64 only: Remote Host's libiroh_ffi.a has no x86_64 slice, so a universal link fails.
# STOP_BEFORE_NOTARIZE=1 builds and signs everything but doesn't submit it, for checking the bundle.

# One-time setup before first use:
#   xcrun notarytool store-credentials AC_PASSWORD \
#     --apple-id you@example.com --team-id GAYT638PXY --password <app-specific-password>

if [ $# -ne 1 ]; then
  echo "Usage: ./release.sh <marketing-version, e.g. 1.2>"
  exit 1
fi

VERSION="$1"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
SCHEME="Canopy"
PBXPROJ="Canopy.xcodeproj/project.pbxproj"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/Canopy.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/Canopy.app"
ZIP_PATH="$BUILD_DIR/Canopy-$VERSION.zip"
KEYCHAIN_PROFILE="AC_PASSWORD"
SPARKLE_BIN="${SPARKLE_BIN:-$(find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle/Sparkle/bin' -maxdepth 6 2>/dev/null | head -n 1)}"

if [ -z "$SPARKLE_BIN" ]; then
  echo "Could not find Sparkle's generate_appcast tool. Build the project at least once after adding the Sparkle package, then re-run this script."
  exit 1
fi

echo "==> Cleaning previous build output"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Bumping version to $VERSION ($BUILD_NUMBER)"
sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/g" "$PBXPROJ"

# Planning Center OAuth credentials (what Transcriber's build_app.sh did): without them the Planning Center
# schedule would silently stop working for everyone who updates. The file isn't committed.
PCO_ENV="${PCO_ENV:-Support/pco.env}"
PCO_ARGS=()
if [ -f "$PCO_ENV" ]; then
  set -a; . "$PCO_ENV"; set +a
  PCO_ARGS=("PCO_CLIENT_ID=${PCO_CLIENT_ID:-}" "PCO_CLIENT_SECRET=${PCO_CLIENT_SECRET:-}")
else
  echo "warning: $PCO_ENV not found, so this build has no Planning Center credentials" >&2
fi

echo "==> Archiving"
xcodebuild archive \
  -scheme "$SCHEME" \
  -archivePath "$ARCHIVE_PATH" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -skipMacroValidation \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM=GAYT638PXY \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_STYLE=Manual \
  ${PCO_ARGS[@]+"${PCO_ARGS[@]}"} \
  -allowProvisioningUpdates

echo "==> Exporting (Developer ID)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist exportOptions.plist \
  -allowProvisioningUpdates

SIGN_IDENTITY="${SIGN_IDENTITY:-CD882049F8DD5836221DBE167F30CAE12EBB5694}"  # Developer ID Application: Roses as Humans LLC (two certs share the name, so use the hash)
codesign --verify --deep --strict "$APP_PATH"

if [ "${STOP_BEFORE_NOTARIZE:-}" = "1" ]; then
  echo "Stopped before notarizing: $APP_PATH"
  exit 0
fi

echo "==> Notarizing"
ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/Canopy-notarize.zip"
xcrun notarytool submit "$BUILD_DIR/Canopy-notarize.zip" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"

echo "==> Zipping stapled app for distribution"
rm -f "$BUILD_DIR/Canopy-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Generating signed Sparkle appcast"
# Sparkle finds the new app inside an update zip by the host's file name, or by the host's bundle id. Installs that
# began as Transcriber are called Transcriber.app, and some still have Transcriber's earlier bundle id, which only the
# file name can match. So the zip holds the app named Transcriber.app. After updating, the app renames itself to
# Canopy.app (SelfRename), and later updates match it by bundle id.
# Renaming the bundle folder doesn't touch its signature or its stapled notarization ticket.
DIR="$BUILD_DIR/appcast"
STAGE="$BUILD_DIR/stage"
rm -rf "$DIR" "$STAGE"; mkdir -p "$DIR" "$STAGE"
ditto "$APP_PATH" "$STAGE/Transcriber.app"
codesign --verify --deep --strict "$STAGE/Transcriber.app"
ditto -c -k --keepParent "$STAGE/Transcriber.app" "$DIR/Canopy-$VERSION.zip"
rm -rf "$STAGE"
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://github.com/iamanthonyterry/canopy-app/releases/download/v$VERSION/" "$DIR"

echo ""
echo "Done. Create the GitHub release (tag v$VERSION):"
echo "  gh release create v$VERSION $DIR/Canopy-$VERSION.zip $DIR/appcast.xml --repo iamanthonyterry/canopy-app --title \"$VERSION\""
