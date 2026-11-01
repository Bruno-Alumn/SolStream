#!/bin/sh
# Cut every icon both applications ship from the logo image, source.png.
#
# Run on a Mac: the generator draws with CoreGraphics and the .icns is packed by
# iconutil, both of which are already here. The Windows .ico is assembled by the
# generator itself, so nothing has to be installed on either side and the
# Windows build just compiles a file that is already in the tree.
#
#   assets/logo/build.sh
#
# The outputs are COMMITTED. Regenerating is a deliberate act with a visible
# diff, rather than something a build does silently.
set -e
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"

rm -rf out
swiftc -O -o /tmp/solstream-make-icons make-icons.swift
/tmp/solstream-make-icons source.png out

iconutil --convert icns --output out/AppIcon.icns out/AppIcon.iconset

cp out/AppIcon.icns "$ROOT/macos/SolStreamClient/Resources/AppIcon.icns"
cp out/SolStream.ico "$ROOT/windows/SolStreamAgent/SolStream.ico"
cp out/icon.png "$ROOT/docs/media/icon.png"

echo ""
echo "  macos/SolStreamClient/Resources/AppIcon.icns  $(wc -c < out/AppIcon.icns | tr -d ' ') bytes"
echo "  windows/SolStreamAgent/SolStream.ico          $(wc -c < out/SolStream.ico | tr -d ' ') bytes"
echo "  docs/media/icon.png                           $(wc -c < out/icon.png | tr -d ' ') bytes"
echo "  assets/logo/out/preview-*.png                 for looking at"
