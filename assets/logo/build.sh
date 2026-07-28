#!/bin/sh
# Cut every icon both applications ship, from one description of the mark.
#
# Run on a Mac: the generator draws with CoreGraphics and the .icns is packed by
# iconutil, both of which are already here. The Windows .ico is assembled by the
# generator itself, so nothing has to be installed on either side and the
# Windows build just compiles a file that is already in the tree.
#
#   assets/logo/build.sh
#
# The outputs are COMMITTED. Regenerating is a deliberate act with a visible
# diff, rather than something a build does silently — an icon that changes
# because a toolchain updated is an icon nobody reviewed.
set -e
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"

rm -rf out
swiftc -O -o /tmp/solstream-make-logo make-logo.swift
/tmp/solstream-make-logo out

iconutil --convert icns --output out/AppIcon.icns out/AppIcon.iconset

mkdir -p "$ROOT/macos/SolStreamClient/Resources"
cp out/AppIcon.icns "$ROOT/macos/SolStreamClient/Resources/AppIcon.icns"
cp out/SolStream.ico "$ROOT/windows/SolStreamAgent/SolStream.ico"

echo ""
echo "  windows/SolStreamAgent/SolStream.ico              $(wc -c < out/SolStream.ico | tr -d ' ') bytes"
echo "  macos/SolStreamClient/Resources/AppIcon.icns      $(wc -c < out/AppIcon.icns | tr -d ' ') bytes"
echo "  assets/logo/out/preview-512.png                   for looking at"
