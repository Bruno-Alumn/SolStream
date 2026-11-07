#!/usr/bin/env bash
# check-public-key.sh - the production update key, as docs/updates.md writes
# it down, and that both programs carry the same one.
#
#   bash scripts/check-public-key.sh
#       Reads the key from docs/updates.md, checks both programs' copies of it
#       and prints it. Fails with an annotation saying which file is wrong.
#   bash scripts/check-public-key.sh --read < updates.md
#       Prints the key that copy of docs/updates.md holds, and fails silently
#       when it holds none: the caller says which copy it was.
#
# The key is written three times. Each copy installed from a release checks
# every later release with the key compiled into it, so a program whose copy
# differs from the document could never update again, and nothing would show
# it until the next release. CI runs this on every commit that could change
# it, and release.yml before it signs.
set -euo pipefail
cd "$(dirname "$0")/.."

read_key() {
    awk '/compiled into both programs:/ {found = 1; next} found && NF {print $1; exit}'
}

# 87 base64 characters and one '=': a P-256 point, uncompressed. Never the
# test vector's key, which anybody can sign with.
valid_key() {
    [[ "$1" =~ ^[A-Za-z0-9+/]{87}=$ ]] && [ "$1" != "$(cat tests/update-vector/test-key.pub.b64)" ]
}

if [ "${1:-}" = --read ]; then
    key=$(read_key)
    valid_key "$key" || exit 1
    echo "$key"
    exit 0
fi

key=$(read_key < docs/updates.md)
if ! valid_key "$key"; then
    echo "::error file=docs/updates.md::Could not read the production public key from docs/updates.md." >&2
    exit 1
fi
for source in macos/SolStreamClient/Sources/SolStreamClient/UpdateFormats.swift windows/SolStreamAgent/updater.h; do
    if ! grep -qF "\"$key\"" "$source"; then
        echo "::error file=$source::does not carry the production public key in docs/updates.md. Copies installed with it would refuse every release after the one they came in." >&2
        exit 1
    fi
done
echo "$key"
