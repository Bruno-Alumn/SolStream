#!/bin/sh
# Set packaging/solstream.rb to a release -- the latest, or the tag given --
# from the SHA256SUMS published with it, and with --push copy it into the tap
# repository, Bruno-Alumn/homebrew-solstream. Needs gh, signed in.
#
#   scripts/update-cask.sh [vX.Y.Z] [--push]
set -eu

repo=Bruno-Alumn/SolStream
tap=Bruno-Alumn/homebrew-solstream
cask="$(cd "$(dirname "$0")/.." && pwd)/packaging/solstream.rb"

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
sha=$(awk -v f="SolStream-$version-macOS.zip" '$2 == f { print $1 }' "$work/SHA256SUMS")
[ -n "$sha" ] || { echo "no SolStream-$version-macOS.zip in $tag's SHA256SUMS" >&2; exit 1; }

sed -i.bak -E \
    -e "s/^  version \"[^\"]*\"/  version \"$version\"/" \
    -e "s/^  sha256 \"[^\"]*\"/  sha256 \"$sha\"/" \
    "$cask"
rm -f "$cask.bak"
grep -q "^  version \"$version\"\$" "$cask" && grep -q "^  sha256 \"$sha\"\$" "$cask" ||
    { echo "packaging/solstream.rb has no version or sha256 line to set" >&2; exit 1; }
echo "packaging/solstream.rb: $version $sha"

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
