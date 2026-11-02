#!/bin/sh
# Point the package managers' copies at a release -- the latest, or the tag
# given -- using the SHA256SUMS published with it: the Homebrew cask
# (packaging/solstream.rb) and the Chocolatey package (packaging/chocolatey).
# With --push the cask is also copied into the tap repository,
# Bruno-Alumn/homebrew-solstream; the Chocolatey package is published by
# .github/workflows/chocolatey.yml. Needs gh, signed in.
#
#   scripts/update-packages.sh [vX.Y.Z] [--push]
set -eu

repo=Bruno-Alumn/SolStream
tap=Bruno-Alumn/homebrew-solstream
root="$(cd "$(dirname "$0")/.." && pwd)"
cask="$root/packaging/solstream.rb"
nuspec="$root/packaging/chocolatey/solstream.nuspec"
choco_install="$root/packaging/chocolatey/tools/chocolateyinstall.ps1"

tag=""
push=false
for arg in "$@"; do
    case "$arg" in
        --push) push=true ;;
        v*) tag="$arg" ;;
        *) echo "usage: $0 [vX.Y.Z] [--push]" >&2; exit 2 ;;
    esac
done
[ -n "$tag" ] || tag=$(gh release view --repo "$repo" --json tagName -q .tagName)
version=${tag#v}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh release download "$tag" --repo "$repo" --pattern SHA256SUMS --dir "$work"
sum() {
    s=$(awk -v f="$1" '$2 == f { print $1 }' "$work/SHA256SUMS")
    [ -n "$s" ] || { echo "no $1 in $tag's SHA256SUMS" >&2; exit 1; }
    echo "$s"
}
sha=$(sum "SolStream-$version-macOS.zip")
setup_sha=$(sum "SolStreamSetup-$version.exe")

sed -i.bak -E \
    -e "s/^  version \"[^\"]*\"/  version \"$version\"/" \
    -e "s/^  sha256 \"[^\"]*\"/  sha256 \"$sha\"/" \
    "$cask"
rm -f "$cask.bak"
grep -q "^  version \"$version\"\$" "$cask" && grep -q "^  sha256 \"$sha\"\$" "$cask" ||
    { echo "packaging/solstream.rb has no version or sha256 line to set" >&2; exit 1; }
echo "packaging/solstream.rb: $version $sha"

sed -i.bak -E "s|<version>[^<]*</version>|<version>$version</version>|" "$nuspec"
sed -i.bak -E \
    -e "s|^( *url64bit *= *)'[^']*'|\\1'https://github.com/$repo/releases/download/$tag/SolStreamSetup-$version.exe'|" \
    -e "s|^( *checksum64 *= *)'[^']*'|\\1'$setup_sha'|" \
    "$choco_install"
rm -f "$nuspec.bak" "$choco_install.bak"
grep -q "<version>$version</version>" "$nuspec" &&
    grep -q "/$tag/SolStreamSetup-$version.exe'\$" "$choco_install" &&
    grep -q "^ *checksum64 *= *'$setup_sha'\$" "$choco_install" ||
    { echo "packaging/chocolatey has no version, url64bit or checksum64 to set" >&2; exit 1; }
echo "packaging/chocolatey: $version $setup_sha"

if $push; then
    path=Casks/solstream.rb
    # On a 404 gh still prints the error body, so only trust a successful call.
    current=$(gh api "repos/$tap/contents/$path" -q .sha 2>/dev/null) || current=""
    gh api -X PUT "repos/$tap/contents/$path" \
        -f message="Update SolStream to $version" \
        -f content="$(base64 < "$cask" | tr -d '\n')" \
        -f "committer[name]=Bruno-Alumn" \
        -f "committer[email]=171815746+Bruno-Alumn@users.noreply.github.com" \
        ${current:+-f sha="$current"} >/dev/null
    echo "pushed to $tap"
fi
