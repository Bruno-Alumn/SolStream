# Updates and releases

Both programs update themselves from this repository's GitHub releases. This
document is the contract between the release pipeline and the two updaters;
change it, and all three, together.

## Versions

- `VERSION` at the repository root is the only place the version is written:
  `X.Y.Z`, nothing else on the line. The Mac bundle's
  `CFBundleShortVersionString`, the Windows executable's version block and the
  release tag all come from it.
- A release is the tag `vX.Y.Z` on a commit whose `VERSION` says `X.Y.Z`.
- Versions compare numerically, part by part. An updater only ever moves to a
  strictly newer version: never sideways, never down.

## What a release carries

| Asset | For |
| --- | --- |
| `SolStream-X.Y.Z-macOS.zip` | the Mac updater: `SolStream.app`, made with `ditto -c -k --norsrc --noextattr --noacl --keepParent` (no extended attributes or `._` entries) |
| `SolStream-X.Y.Z-macOS.dmg` | people installing by hand |
| `SolStreamSetup-X.Y.Z.exe` | the Windows updater and people installing by hand |
| `SHA256SUMS` | one line per asset above, sorted by name: 64 lowercase hex digits, two spaces, the file name, `\n` |
| `SHA256SUMS.sig` | the signature over `SHA256SUMS`, below |

## The signature

ECDSA P-256 over SHA-256 of `SHA256SUMS`'s exact bytes. `SHA256SUMS.sig` is
base64 of the raw 64-byte `r || s` pair, then `\n`. `scripts/sign-release.py`
makes and checks it.

The **public** key, base64 of the 65-byte uncompressed X9.63 point, is
compiled into both programs:

    BAqYL3Fb9yQB0RbUnR8Bat8WVYHsUOM7oNvuiUmmYMxBtiB/g7HGlIBIPXaN+X4LdYuN+xyCt92Vhq9itHoNBOE=

The private key is never in this repository. It lives in the repository's
Actions secret `SOLSTREAM_UPDATE_SIGNING_KEY` (PEM) for the release workflow,
and in the owner's `~/.config/solstream/update-signing-key.pem` (0600). Losing
it means shipping a build with a new public key by hand; leaking it means
anyone can sign an update, so rotate it the same way.

### Test vector

A throwaway key, for unit tests on both sides. Nothing real is signed with it.

    public key  BHEGr5w8p3a2JdZmAKyJVj4ZPCeHcfB3PW3b2LhNliZ8x/KWp+N8YY6ywrVXg2k2PF4KWIaDmqwC1WdRCryoA8c=
    SHA256SUMS  (base64 of the exact bytes)
                M2YxYzRjYWI1YjJmMmQ4ZjlhM2Y2MWUwZDRjM2IyYTE5MDhmN2U2ZDVjNGIzYTI5MTgwN2Y2ZTVkNGMzYjJhMSAgU29sU3RyZWFtLTkuOS45LW1hY09TLnppcAphMGIxYzJkM2U0ZjUwNjE3MjgzOTRhNWI2YzdkOGU5ZmEwYjFjMmQzZTRmNTA2MTcyODM5NGE1YjZjN2Q4ZTlmICBTb2xTdHJlYW1TZXR1cC05LjkuOS5leGUK
    signature   u6TGySE4KPr4p3L/F77C5xIWVNlDs+dR20OkwOnVwyN3rNd1UJu3UsOTN5FXonztlbV7YsHYaaXP3HUn7d7Irg==

It must verify; the same signature with any byte of `SHA256SUMS` changed, and
the same files under the production key, must not.

## How an updater checks

1. `GET https://api.github.com/repos/Bruno-Alumn/SolStream/releases/latest`
   with `Accept: application/vnd.github+json`, `X-GitHub-Api-Version:
   2022-11-28` and `User-Agent: SolStream/<version> (<macOS|Windows>)`. The
   owner and repository are one constant in each program.
2. **404 means "nothing published that this client can see"** -- which is what
   a private repository answers without credentials. Not an error: no update,
   nothing shown, check again later.
3. Ignore drafts and prereleases. Take `tag_name`, strip the `v`, compare.
4. If newer: fetch `SHA256SUMS` and `SHA256SUMS.sig`, verify the signature
   with the compiled-in key, find this platform's asset in the verified sums,
   download it, and require its SHA-256 to match. Anything that fails is
   discarded and logged, never installed.
5. HTTPS only, redirects only to `github.com`, `api.github.com`,
   `objects.githubusercontent.com` and `release-assets.githubusercontent.com`.
   Asset size capped at 200 MB.

### When the repository is private

`SOLSTREAM_GITHUB_TOKEN`, if set in the environment, is sent as
`Authorization: Bearer …` to api.github.com only -- never to the hosts a
download redirects to, whose pre-signed URLs reject a second credential and
must not see the token. Assets are then fetched through their API `url` with
`Accept: application/octet-stream`, because `browser_download_url` does not
take a token. It is read from the environment
only: never stored, never logged, never shown. Unset, the updaters behave as
the public repository will.

### For testing

`SOLSTREAM_PRETEND_VERSION=X.Y.Z` makes an updater believe it is that version
when it checks. It never offers or installs anything not strictly newer than
the version the program was really built as.

On Windows, `SolStream.exe --check-updates` runs one check and prints the
result; with `--download` it also fetches and verifies the installer, and never
runs it. Both obey the two variables above and exit 0 when the check completed,
1 when it failed.

`SolStream.exe --verify-update-signature <SHA256SUMS> <SHA256SUMS.sig>
[<public key base64, or a file holding it>]` checks a signature with no UI and
touches nothing else: exit 0 when it verifies, 1 when it does not, 2 on wrong
usage. Without the third argument it uses the compiled-in production key. CI
and the release workflow run it on `tests/update-vector`.

## When

On launch, after a minute, then every 24 hours; and when the person asks
("Check for Updates…"). At most one check in flight. Unauthenticated, the
GitHub API allows 60 requests an hour per address, which this never comes near.

## Installing

Never on its own, and never in the middle of a stream: an update found is
announced, and installed only when the person says so.

- **Mac.** Unzip into a temporary directory with `ditto -x -k`; check the
  bundle is `com.solstream.macclient` at exactly the release's version and that
  `codesign --verify --deep --strict` accepts it; move the running bundle aside,
  move the new one into its place (same volume, so a rename), relaunch, and
  delete the old one only once the new one has started. If the bundle's folder
  is not writable, say so rather than asking for an administrator password.
- **Windows.** Download into `%LOCALAPPDATA%\SolStream\Updates`, keep the file
  open without write or delete sharing from the hash check until the installer
  has started -- so nothing can swap it between being verified and being run
  elevated -- then run it with `--install` from the path that held handle resolves to
(GetFinalPathNameByHandle), so no junction or link can be re-pointed in
between. The installer asks for elevation
  once, stops the running host, replaces it and starts the new one.
