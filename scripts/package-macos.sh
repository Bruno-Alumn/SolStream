#!/bin/bash
# package-macos.sh — Build, sign, notarize, and package SolStream macOS client
#
# Prerequisites:
#   - Xcode 15+ installed
#   - Developer ID Application certificate in keychain (not for --dev)
#   - For --notarize, notarytool credentials: a keychain profile made with
#     `xcrun notarytool store-credentials`, or an App Store Connect API key
#
# Usage:
#   ./package-macos.sh [--dev] [--universal] [--notarize]
#
#   --dev        Ad-hoc signing, no notarization. The release workflow packages
#                with it: the Developer ID certificate is on the owner's Mac,
#                not on the runners, so a CI release carries an ad hoc identity.
#   --universal  Apple silicon and Intel in one executable, as a release ships.
#                Without it, only this Mac's own architecture is built.
#   --notarize   Developer ID signing, then notarization of the application and
#                of the DMG, each stapled
#
# Environment:
#   SIGN_IDENTITY    the codesign identity; the first "Developer ID Application"
#                    in the keychain when unset
#   NOTARY_PROFILE   the notarytool keychain profile. When it is unset and an
#                    App Store Connect API key is in ~/.appstoreconnect
#                    (private_key.p8, key-id.txt, issuer-id.txt), the key is
#                    used; otherwise the profile "tuckaway-notary", which this
#                    Mac keeps for the owner's team
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

if [ "$DEV_BUILD" = true ] && [ "$DO_NOTARIZE" = true ]; then
    echo "ERROR: --dev is ad hoc, and Apple notarizes only a Developer ID signature."
    exit 1
fi

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
# How notarytool is told who is asking, as arguments, when notarizing.
notary_auth() {
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    elif [ -f "$HOME/.appstoreconnect/private_key.p8" ]; then
        NOTARY_ARGS=(--key "$HOME/.appstoreconnect/private_key.p8"
                     --key-id "$(cat "$HOME/.appstoreconnect/key-id.txt")"
                     --issuer "$(cat "$HOME/.appstoreconnect/issuer-id.txt")")
    else
        NOTARY_ARGS=(--keychain-profile "tuckaway-notary")
    fi
}

# Submit one file and wait for Apple's answer. A rejection prints Apple's own
# log of why, which is the only place the reason is written down.
notarize() {
    local file="$1" out id
    out=$(xcrun notarytool submit "$file" "${NOTARY_ARGS[@]}" --wait 2>&1) || true
    echo "$out"
    if ! grep -q "status: Accepted" <<<"$out"; then
        id=$(sed -n 's/^ *id: \([0-9a-f-]\{36\}\).*/\1/p' <<<"$out" | head -1)
        if [ -n "$id" ]; then
            xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" || true
        fi
        echo "ERROR: Apple did not accept $file."
        exit 1
    fi
}

if [ "$DEV_BUILD" = true ]; then
    codesign --deep --force --verify --verbose \
        --sign "-" "$APP_PATH"
else
    IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" | head -1 \
        | sed -n 's/.*"\(Developer ID Application: .*\)".*/\1/p')}"
    if [ -z "$IDENTITY" ]; then
        echo "ERROR: No Developer ID Application certificate found."
        echo "Run: security find-identity -v -p codesigning"
        exit 1
    fi
    echo "Signing with identity: $IDENTITY"
    # From the inside out, never --deep: every nested piece of code -- a
    # framework, a dylib, a helper -- is signed on its own first, deepest
    # first, and the bundle last, so each seal covers signatures that are
    # already final. --deep signs them all with the outer bundle's options and
    # is what Apple says not to ship with. Today the bundle holds one
    # executable and nothing nested; this is here for when it does not.
    while IFS= read -r nested; do
        [ -n "$nested" ] || continue
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
    done < <(find "$APP_PATH/Contents" -mindepth 2 \
                 \( -name "*.framework" -o -name "*.dylib" -o -name "*.app" \
                    -o -name "*.xpc" -o -name "*.appex" -o -name "*.bundle" \
                    -o \( -type f -perm -u+x ! -path "$APP_PATH/Contents/MacOS/$PRODUCT_NAME" \) \) \
                 -print | awk '{ print gsub("/", "/"), $0 }' | sort -rn | cut -d' ' -f2-)
    # The hardened runtime and a secure timestamp, both of which notarization
    # requires, and no entitlements at all: SolStream asks for nothing the
    # runtime withholds -- no JIT, no unsigned libraries, no debugger -- so
    # there is no get-task-allow to leave in by mistake.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP_PATH"
    if codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -q "get-task-allow"; then
        echo "ERROR: $APP_PATH carries get-task-allow, which notarization refuses."
        exit 1
    fi
    codesign -d --verbose=2 "$APP_PATH" 2>&1 | grep -E "^(Authority|TeamIdentifier|Timestamp|flags)" || true
fi

# Verify signing, as strictly as the updater will before it installs this
# bundle (docs/updates.md): failing here costs a rebuild, failing there costs
# every installed copy its update.
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Step 3b: Notarize the application itself, so its ticket can be stapled into
# the bundle before the zip and the DMG are made of it. The updater installs
# from the zip, which nothing else could staple: an application stapled here
# opens without asking Apple, on a Mac that is offline or behind a proxy.
if [ "$DO_NOTARIZE" = true ]; then
    echo ""
    echo "--- Step 3b: Notarizing the application ---"
    notary_auth
    APP_SUBMIT_DIR=$(mktemp -d)
    ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP_PATH" \
        "$APP_SUBMIT_DIR/$PRODUCT_NAME.zip"
    notarize "$APP_SUBMIT_DIR/$PRODUCT_NAME.zip"
    rm -rf "$APP_SUBMIT_DIR"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

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

# The image signed too, with the same identity: notarization and Gatekeeper's
# check of a downloaded DMG both want a signed one.
if [ "$DEV_BUILD" != true ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
fi

echo ""
echo "DMG created: $DMG_PATH"

# Step 6: Notarize the DMG (optional)
# The application inside is the one notarized and stapled above; the image is
# submitted on its own so that it can carry a ticket of its own, which is what
# Gatekeeper looks for when somebody opens it from Downloads.
if [ "$DO_NOTARIZE" = true ]; then
    echo ""
    echo "--- Step 6: Notarizing the DMG ---"
    notarize "$DMG_PATH"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
    echo ""
    echo "Notarization complete."
fi

echo ""
echo "=== Done ==="
echo "App: $APP_PATH"
ls -lh "$ZIP_PATH" "$DMG_PATH"
