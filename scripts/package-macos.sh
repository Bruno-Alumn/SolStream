#!/bin/bash
# package-macos.sh — Build, sign, notarize, and package SolStream macOS client
#
# Prerequisites:
#   - Xcode 15+ installed
#   - Developer ID Application certificate in keychain (not for --dev)
#   - App Store Connect API key (for notarytool)
#
# Usage:
#   ./package-macos.sh [--dev] [--universal] [--notarize]
#
#   --dev        Ad-hoc signing, no notarization. The release workflow packages
#                with it too: until there is a Developer ID certificate, ad hoc
#                is the only identity a release can carry.
#   --universal  Apple silicon and Intel in one executable, as a release ships.
#                Without it, only this Mac's own architecture is built.
#   --notarize   Production build with full notarization
#
# Produces:
#   macos/SolStreamClient/.build/release/SolStream.app
#   dist/SolStream-X.Y.Z-macOS.zip   what the Mac updater downloads
#   dist/SolStream-X.Y.Z-macOS.dmg   what a person downloads
# Both from the same signed bundle, so the two cannot be different builds.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT/macos/SolStreamClient"

PRODUCT_NAME="SolStream"
# What SwiftPM actually builds, which differs from the bundle name.
EXECUTABLE_NAME="SolStreamClient"
BUNDLE_ID="com.solstream.macclient"
BUILD_DIR=".build/release"
DMG_DIR=".build/dmg"
DIST_DIR="$REPO_ROOT/dist"

# The version comes from VERSION at the repository root, the one place it is
# written (docs/updates.md): the release tag, this bundle and the Windows
# executable all read it. It used to be read out of main.swift's log line, and
# before that typed here as well, and the copies drifted -- the bundle said
# 0.2.0 while the program inside it logged v0.3. The application now reads its
# own version from this bundle, and the updater refuses a download whose bundle
# is not exactly the release's version, so a wrong stamp here is a release
# that cannot install. An unreadable file is therefore a hard failure, never a
# default. tr drops the CR a Windows checkout gives the line.
VERSION=$(head -n 1 "$REPO_ROOT/VERSION" 2>/dev/null | tr -d '\r' || true)
if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "ERROR: $REPO_ROOT/VERSION must hold one line, X.Y.Z (found \"$VERSION\")."
    exit 1
fi

# CFBundleVersion is the build number, and it has to keep rising: it is what
# Launch Services uses to choose between two copies of the bundle id, and what a
# crash report carries. The commit count only ever grows on main. A shallow
# clone counts 1, which is why the release workflow fetches the whole history;
# outside a git checkout there is nothing to count, and 1 is honest.
BUILD_NUMBER=$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || true)
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    BUILD_NUMBER=1
fi

ZIP_PATH="$DIST_DIR/$PRODUCT_NAME-$VERSION-macOS.zip"
DMG_PATH="$DIST_DIR/$PRODUCT_NAME-$VERSION-macOS.dmg"

# Parse flags
DEV_BUILD=false
DO_NOTARIZE=false
UNIVERSAL=false
for arg in "$@"; do
    case "$arg" in
        --dev) DEV_BUILD=true ;;
        --notarize) DO_NOTARIZE=true ;;
        --universal) UNIVERSAL=true ;;
    esac
done

echo "=== SolStream macOS Package ==="
echo "Version: $VERSION (build $BUILD_NUMBER)"
echo "Dev build: $DEV_BUILD"
echo "Universal: $UNIVERSAL"
echo "Notarize: $DO_NOTARIZE"

# Step 1: Build
echo ""
echo "--- Step 1: Building ---"
if [ "$UNIVERSAL" = true ]; then
    # One architecture at a time, then lipo. Asking SwiftPM for both at once
    # switches it to a different build system that puts its products somewhere
    # else entirely. This Mac's own architecture is built last because each
    # build repoints .build/release at its own triple, and that is where a plain
    # `swift build -c release` would have left it.
    NATIVE_ARCH=$(uname -m)
    SLICES=()
    for arch in x86_64 arm64; do
        [ "$arch" = "$NATIVE_ARCH" ] || SLICES+=("$arch")
    done
    SLICES+=("$NATIVE_ARCH")
    SLICE_BINARIES=()
    for arch in "${SLICES[@]}"; do
        swift build --configuration release --arch "$arch"
        SLICE_BINARIES+=("$(swift build --configuration release --arch "$arch" --show-bin-path)/$EXECUTABLE_NAME")
    done
else
    swift build --configuration release
fi

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
if [ "$UNIVERSAL" = true ]; then
    # Straight into the bundle, not over either slice's own build product,
    # which the next incremental build would then mistake for its own.
    lipo -create -output "$APP_PATH/Contents/MacOS/$PRODUCT_NAME" "${SLICE_BINARIES[@]}"
    lipo -info "$APP_PATH/Contents/MacOS/$PRODUCT_NAME"
else
    cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_PATH/Contents/MacOS/$PRODUCT_NAME"
fi

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
    <!-- The version from VERSION, which the application reads back from here
         for its log and its updater, so Get Info, the log and the release
         cannot disagree about which build somebody is running. The build
         number is the commit count; see the top of this script. -->
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
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

# Verify signing, as strictly as the updater will before it installs this
# bundle (docs/updates.md): failing here costs a rebuild, failing there costs
# every installed copy its update.
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Step 4: Zip, for the updater
echo ""
echo "--- Step 4: Creating zip ---"
mkdir -p "$DIST_DIR"
# Earlier versions' packages go too, as package-windows.ps1 removes its older
# setups: beside the new ones they are downloads that look current and are not,
# and signing by hand (docs/releasing.md) picks files out of here.
find "$DIST_DIR" -maxdepth 1 \
    \( -name "$PRODUCT_NAME-*-macOS.zip" -o -name "$PRODUCT_NAME-*-macOS.dmg" \) \
    ! -name "$PRODUCT_NAME-$VERSION-macOS.*" -delete
rm -f "$ZIP_PATH"
# ditto rather than zip: it is what the updater unpacks with, and it keeps the
# bundle's symlinks and signature exactly as they are. Without extended
# attributes, resource forks or ACLs, though: ditto stores those as AppleDouble
# "._" files, which every file here has (com.apple.provenance, at least). ditto
# folds them back in on the way out, but any other unzip leaves them in the
# bundle as files the signature does not cover, and codesign then rejects it.
# They would also carry this machine's attributes onto every Mac that installs
# the release.
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP_PATH" "$ZIP_PATH"
if zipinfo -1 "$ZIP_PATH" | grep -q '\._'; then
    echo "ERROR: $ZIP_PATH carries AppleDouble (._) entries."
    exit 1
fi

# Unpacked again and checked the way the updater checks it, because the zip,
# not the bundle above, is what installed copies receive.
ZIP_CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$ZIP_CHECK_DIR"' EXIT
ditto -x -k "$ZIP_PATH" "$ZIP_CHECK_DIR"
UNZIPPED="$ZIP_CHECK_DIR/$PRODUCT_NAME.app"
UNZIPPED_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$UNZIPPED/Contents/Info.plist")
UNZIPPED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$UNZIPPED/Contents/Info.plist")
if [ "$UNZIPPED_ID" != "$BUNDLE_ID" ] || [ "$UNZIPPED_VERSION" != "$VERSION" ]; then
    echo "ERROR: the zip holds $UNZIPPED_ID $UNZIPPED_VERSION, not $BUNDLE_ID $VERSION."
    exit 1
fi
codesign --verify --deep --strict "$UNZIPPED"
echo "Zip created: $ZIP_PATH"

# Step 5: Create DMG
echo ""
echo "--- Step 5: Creating DMG ---"
rm -rf "$DMG_DIR" "$DMG_PATH"
# An earlier version of this script wrote the DMG beside Package.swift. Left
# there, it is a download that looks current and is not.
rm -f "$REPO_ROOT/macos/SolStreamClient/$PRODUCT_NAME.dmg"
mkdir -p "$DMG_DIR"
cp -R "$APP_PATH" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

# Retried because hdiutil fails now and then with "Resource busy" when the
# disk-image service is still busy with something else, which on a CI runner
# would otherwise fail a release that has nothing wrong with it.
for attempt in 1 2 3; do
    if hdiutil create -volname "$PRODUCT_NAME" \
        -srcfolder "$DMG_DIR" \
        -ov -format UDZO \
        "$DMG_PATH"; then
        break
    fi
    if [ "$attempt" = 3 ]; then
        echo "ERROR: hdiutil could not create $DMG_PATH."
        exit 1
    fi
    echo "  hdiutil failed; trying again in 5 seconds."
    sleep 5
done

rm -rf "$DMG_DIR"

echo ""
echo "DMG created: $DMG_PATH"

# Step 6: Notarize (optional)
# The DMG is what is submitted. Notarizing it also records the bundle inside,
# which is byte for byte the one in the zip, so the updater's copy passes
# Gatekeeper's online check too; only the DMG gets a stapled ticket.
if [ "$DO_NOTARIZE" = true ]; then
    echo ""
    echo "--- Step 6: Notarizing ---"

    # Requires App Store Connect API key or Apple ID
    # Option A: API key
    if [ -f "$HOME/.appstoreconnect/private_key.p8" ]; then
        xcrun notarytool submit "$DMG_PATH" \
            --key "$HOME/.appstoreconnect/private_key.p8" \
            --key-id "$(cat "$HOME/.appstoreconnect/key-id.txt")" \
            --issuer "$(cat "$HOME/.appstoreconnect/issuer-id.txt")" \
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
        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$APPLE_ID" \
            --password "$APP_PASSWORD" \
            --team-id "$TEAM_ID" \
            --wait
    fi

    # Staple the ticket
    xcrun stapler staple "$DMG_PATH"

    echo ""
    echo "Notarization complete."
fi

echo ""
echo "=== Done ==="
echo "App: $APP_PATH"
ls -lh "$ZIP_PATH" "$DMG_PATH"
