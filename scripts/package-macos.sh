#!/bin/bash
# package-macos.sh — Build, sign, notarize, and package SolStream macOS client
#
# Prerequisites:
#   - Xcode 15+ installed
#   - Developer ID Application certificate in keychain
#   - App Store Connect API key (for notarytool)
#
# Usage:
#   ./package-macos.sh [--dev] [--notarize]
#
#   --dev        Development build (ad-hoc signing, no notarization)
#   --notarize   Production build with full notarization

set -euo pipefail
cd "$(dirname "$0")/../macos/SolStreamClient"

PRODUCT_NAME="SolStream"
# What SwiftPM actually builds, which differs from the bundle name.
EXECUTABLE_NAME="SolStreamClient"
BUNDLE_ID="com.solstream.macclient"
BUILD_DIR=".build/release"
DMG_NAME="${PRODUCT_NAME}.dmg"
DMG_DIR=".build/dmg"

# The version, read from the one line that decides it rather than typed here as
# well. It used to be typed in both places and they had drifted: the bundle said
# 0.2.0 while the application it contained logged v0.3 at startup, so the Get
# Info panel and the log a user sends back with a bug report disagreed about
# which build they were looking at — and the log is the one that gets believed,
# because it comes from the running program.
#
# main.swift wins because that string is what reaches a user's log. Reading it
# here is what stops the two drifting again. An empty read is a hard failure
# rather than a default, since a bundle stamped with the wrong version is worth
# less than no bundle at all: fix the line, or fix this, before packaging.
VERSION_SOURCE="Sources/SolStreamClient/main.swift"
VERSION=$(sed -n '/Log\.startSession(version:/ {
    s/.*version: "v\{0,1\}\([0-9][0-9.]*\)".*/\1/p
    q
}' "$VERSION_SOURCE")
if [ -z "$VERSION" ]; then
    echo "ERROR: could not read the version from $VERSION_SOURCE."
    echo "       It is the Log.startSession(version: \"vX.Y\") call in"
    echo "       applicationDidFinishLaunching; if that line has changed shape,"
    echo "       this script has to be taught the new one."
    exit 1
fi

# Parse flags
DEV_BUILD=false
DO_NOTARIZE=false
for arg in "$@"; do
    case "$arg" in
        --dev) DEV_BUILD=true ;;
        --notarize) DO_NOTARIZE=true ;;
    esac
done

echo "=== SolStream macOS Package ==="
echo "Version: $VERSION"
echo "Dev build: $DEV_BUILD"
echo "Notarize: $DO_NOTARIZE"

# Step 1: Build
echo ""
echo "--- Step 1: Building ---"
swift build --configuration release

# Assemble the bundle. SPM puts the executable in .build/release/ directly,
# under the product's name -- which is not the bundle's name, so it is renamed
# on the way in to match CFBundleExecutable below.
APP_PATH="$BUILD_DIR/$PRODUCT_NAME.app"
# Removed first, so what ships is exactly what this run assembled. Everything
# below writes three files — the executable, the icon and Info.plist — and
# overwrites each of them, but it removes nothing, so anything an earlier build
# left in the bundle and this one does not produce simply stayed: a resource
# since deleted from the tree, a helper from a layout that no longer exists.
# codesign --force re-seals whatever it finds rather than deciding what belongs,
# so a leftover is signed, notarised and copied into the DMG exactly as though
# somebody had meant to put it there. Rebuilding the bundle from nothing is the
# only step that can tell the difference.
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
# Unconditionally, not just when the .app is missing: guarding this on the
# directory's existence meant every run after the first packaged the previous
# build's binary.
cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_PATH/Contents/MacOS/$PRODUCT_NAME"

# The icon. Cut by assets/logo/build.sh and committed, rather than generated
# here: an icon that changes because a toolchain updated is an icon nobody
# reviewed. Missing is not fatal — the bundle still runs, it just wears the
# generic application icon — but it is worth saying, because a blank icon in the
# Dock is the first thing anybody notices and the last thing anybody reports.
ICON_SRC="Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_PATH/Contents/Resources/AppIcon.icns"
else
    echo "  WARNING: no $ICON_SRC — run assets/logo/build.sh. The bundle will"
    echo "           show the generic application icon in the Dock and Finder."
fi

# Step 2: Create Info.plist if missing
echo ""
echo "--- Step 2: Info.plist ---"
# Unconditionally, not "if missing". The first version of this guarded on the
# file's existence, which meant every run after the first shipped the previous
# build's plist -- exactly the bug that made this script never produce a working
# bundle at all.
if true; then
    cat > "$APP_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$PRODUCT_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$PRODUCT_NAME</string>
    <!-- Both keys, and neither is redundant. CFBundleIconFile is what the Dock,
         Finder and the Cmd-Tab switcher read out of a bundle that was not built
         by Xcode; CFBundleIconName is what Sonoma and later prefer, and its
         absence is why an icns can sit in Resources being ignored. -->
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <!-- Both come from the Log.startSession(version:) line in main.swift, read
         by this script, so the version in Get Info and the version in the log
         cannot disagree about which build somebody is running. -->
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>SolStream needs microphone access for audio streaming.</string>
    <!--
      Local Network access, which macOS gates per application.

      Everything SolStream does is a local network connection: the host is a PC
      on the same LAN or the same VPN. Without this key the system denies those
      connections, and it denies them by TIMING OUT rather than refusing, so the
      failure reads as "the PC is not answering" and points the user at their
      firewall, their host, and their network — anywhere but here.

      This did not show up for a long time because a bare binary run from a
      terminal inherits the terminal's own grant. Only the packaged application
      has an identity of its own to be denied.

      It is the only networking key here, and the two that used to sit beside it
      have gone because nothing in the application reaches the code they govern.
      NSAppTransportSecurity applied to URLSession and WebKit, and existed for
      GameStream's plain-HTTP /pair step; there is no HTTP request left anywhere
      in the client, and the sockets that remain are NWConnection and BSD
      sockets, which ATS does not police in either direction. NSBonjourServices
      declared _nvstream._tcp for an NWBrowser that has been deleted: discovery
      is now one UDP datagram broadcast to port 47629 and a host answering it,
      with no mDNS responder on either side (AgentChannel/HostBrowser.swift).
      Declaring a service type nothing browses for, and relaxing a policy nothing
      is subject to, both read as "this application talks plain HTTP to a
      Bonjour service" to anybody auditing the bundle, which it does not.
    -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>SolStream connects to your Windows PC on your local network or VPN to stream applications from it.</string>
</dict>
</plist>
EOF
fi

# Step 3: Sign
echo ""
echo "--- Step 3: Signing ---"
if [ "$DEV_BUILD" = true ]; then
    codesign --deep --force --verify --verbose \
        --sign "-" "$APP_PATH"
else
    IDENTITY=$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" | head -1 \
        | awk '{print $2}')
    if [ -z "$IDENTITY" ]; then
        echo "ERROR: No Developer ID Application certificate found."
        echo "Run: security find-identity -v -p codesigning"
        exit 1
    fi
    echo "Signing with identity: $IDENTITY"
    codesign --deep --force --verify --verbose \
        --options runtime \
        --sign "$IDENTITY" "$APP_PATH"
fi

# Verify signing
codesign --verify --verbose "$APP_PATH"

# Step 4: Create DMG
echo ""
echo "--- Step 4: Creating DMG ---"
rm -rf "$DMG_DIR" "$DMG_NAME"
mkdir -p "$DMG_DIR"
cp -R "$APP_PATH" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

hdiutil create -volname "$PRODUCT_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_NAME"

rm -rf "$DMG_DIR"

echo ""
echo "DMG created: $DMG_NAME"

# Step 5: Notarize (optional)
if [ "$DO_NOTARIZE" = true ]; then
    echo ""
    echo "--- Step 5: Notarizing ---"

    # Requires App Store Connect API key or Apple ID
    # Option A: API key
    if [ -f "$HOME/.appstoreconnect/private_key.p8" ]; then
        xcrun notarytool submit "$DMG_NAME" \
            --key "$HOME/.appstoreconnect/private_key.p8" \
            --key-id "$(cat $HOME/.appstoreconnect/key-id.txt)" \
            --issuer "$(cat $HOME/.appstoreconnect/issuer-id.txt)" \
            --wait
    else
        # Option B: Apple ID (interactive)
        echo "No API key found. Using Apple ID..."

        # The Team ID is the 10 characters in brackets at the end of the
        # certificate's common name -- "Developer ID Application: Name (AB12CD34EF)".
        # This used to reuse the awk '{print $2}' pipeline from the signing step,
        # which yields the certificate's SHA-1 fingerprint instead: notarytool
        # would reject it, after asking for a password.
        TEAM_ID=$(security find-identity -v -p codesigning \
            | grep "Developer ID Application" | head -1 \
            | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')
        if [ -z "$TEAM_ID" ]; then
            echo "ERROR: Could not read a Team ID from the Developer ID certificate."
            echo "Run: security find-identity -v -p codesigning"
            exit 1
        fi
        echo "Team ID: $TEAM_ID"

        read -rp "Apple ID: " APPLE_ID
        read -rsp "App-specific password: " APP_PASSWORD
        echo ""
        xcrun notarytool submit "$DMG_NAME" \
            --apple-id "$APPLE_ID" \
            --password "$APP_PASSWORD" \
            --team-id "$TEAM_ID" \
            --wait
    fi

    # Staple the ticket
    xcrun stapler staple "$DMG_NAME"

    echo ""
    echo "Notarization complete."
fi

echo ""
echo "=== Done ==="
echo "Package: $DMG_NAME"
ls -lh "$DMG_NAME"
