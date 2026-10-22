# Update signature test vector

Signed with a throwaway key whose private half was discarded; see
`docs/updates.md`. `SHA256SUMS` + `SHA256SUMS.sig` must verify against
`test-key.pub.b64`, and must not verify against the production key or with any
byte of `SHA256SUMS` changed.

    python3 scripts/sign-release.py verify "$(cat tests/update-vector/test-key.pub.b64)" tests/update-vector/SHA256SUMS
