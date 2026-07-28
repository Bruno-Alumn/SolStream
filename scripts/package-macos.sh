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
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
# Unconditionally, not just when the .app is missing: guarding this on the
# directory's existence meant every run after the first packaged the previous
# build's binary.
cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_PATH/Contents/MacOS/$PRODUCT_NAME"

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
    <key>CFBundleVersion</key>
    <string>0.2.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>SolStream needs microphone access for audio streaming.</string>
    <!--
      App Transport Security has to allow cleartext, and this is not a corner
      being cut.

      GameStream pairing is plain HTTP by protocol design: /pair on the base
      port is the unauthenticated half of the handshake, and it exists to
      establish the client certificate that everything afterwards is
      authenticated with. There is no TLS to require there, because the point of
      the exchange is to agree on the identity TLS would have checked.

      Everything that carries anything then runs over mTLS on the https port
      with the host's public key pinned by SolStream itself (ServerTrust) --
      which is a stronger check than ATS performs, since it is pinned per host
      and port rather than trusted from a CA list.

      Without this the packaged application cannot pair at all. It fails only on
      a FIRST connection to a host, so a build with the pin already stored looks
      perfectly healthy and every new user hits it: "The resource could not be
      loaded because the App Transport Security policy requires the use of a
      secure connection".
    -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
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
    -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>SolStream connects to your Windows PC on your local network or VPN to stream applications from it.</string>
    <!--
      And the service the host advertises itself with, so the connect window can
      find PCs without anybody typing an address. Bonjour browsing is denied
      unless the service type is declared here — silently, again: the browser
      simply reports nothing and the list stays empty.
    -->
    <key>NSBonjourServices</key>
    <array>
        <string>_nvstream._tcp</string>
    </array>
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
