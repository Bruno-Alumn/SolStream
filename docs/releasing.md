# Releasing

A release is the tag `vX.Y.Z` on a commit of `main` whose `VERSION` says
`X.Y.Z`. Pushing the tag is the whole act: `.github/workflows/release.yml`
builds both programs from that commit, signs the checksums and publishes the
GitHub release that both updaters read. `docs/updates.md` is the contract it
publishes to; this is how to drive it.

## Once: the signing key

The updaters install only what is signed with the key whose public half is
compiled into them (`docs/updates.md`). The private half lives in two places
and never in the repository: the owner's
`~/.config/solstream/update-signing-key.pem` (mode 0600), and the Actions
secret `SOLSTREAM_UPDATE_SIGNING_KEY`. To put the one into the other:

```bash
gh secret set SOLSTREAM_UPDATE_SIGNING_KEY --repo Bruno-Alumn/SolStream \
    < ~/.config/solstream/update-signing-key.pem
```

Never commit a key, not even briefly, not even in a branch. gitleaks runs before
every commit and in CI, and knows what a PEM private key looks like, but a key
that has been pushed has leaked whether or not anything noticed.

### Who can read it

Only the workflow's *Sign* job uses the secret, but that is the workflow's
choice, not a rule GitHub enforces. A repository secret is handed to any
workflow run in the repository that asks for it, so a workflow file pushed to
any branch could print it. Anyone who can push here, or who holds a token
allowed to change workflows, can take the key, and with it sign an update
that every installed copy accepts. While the repository is private on GitHub
Free, that is how it stays: give write access only to people you would give the
key, and review every change under `.github/workflows/` as you would the key.

Once the repository is public, or on GitHub Pro, close that gap:

1. **Settings → Environments → New environment** `release`. Under *Deployment
   branches and tags* choose *Selected branches and tags* and add one tag rule,
   `v*.*.*`. Then put the Sign job in it: in `.github/workflows/release.yml`,
   add `environment: release` to the `sign` job, beside its `permissions: {}`,
   and commit that to `main`. A run uses the workflow as it was tagged, so
   only releases tagged after that commit read the environment. The line is
   left out until now because GitHub Free has no environments in a private
   repository, and a job naming one might not run at all.
2. Move the secret into it, then delete the repository-wide one:

   ```bash
   gh secret set SOLSTREAM_UPDATE_SIGNING_KEY --env release --repo Bruno-Alumn/SolStream \
       < ~/.config/solstream/update-signing-key.pem
   gh secret delete SOLSTREAM_UPDATE_SIGNING_KEY --repo Bruno-Alumn/SolStream
   ```

3. **Settings → Rules → Rulesets → New tag ruleset** targeting `refs/tags/v*`:
   restrict creations, updates and deletions, with only yourself allowed to
   bypass. Without it, anybody who can push could push a new `v` tag on a
   commit carrying a workflow of their own, and the environment would hand that
   workflow the key.

Whatever the plan, turn on **immutable releases** in the repository settings,
where GitHub offers them: a published release's files and tag can then never
be changed. The workflow already never replaces a published release, and it
uploads to a draft and publishes last, which is what immutable releases need.

## Cutting a release

1. Set the version, on its own line and nothing else:

   ```bash
   printf '1.0.1\n' > VERSION
   git add VERSION
   git commit -m "Release 1.0.1"
   git push origin main
   ```

   Wait for CI to pass on that commit. It packages both programs as the
   release does, except that the Mac app is built for Apple silicon only (the
   release adds Intel with `--universal`). It runs the Windows setup's
   `--verify-update-signature` against the test vector, runs the release's
   steps that write, sign and check `SHA256SUMS` with a throwaway key, and
   checks that both programs carry the public key `docs/updates.md` names.
   What it cannot check is the secret itself, or the Intel half: if only that
   fails on the tag, see *A build failed* below.

2. Tag that commit and push the tag. In UTC: an annotated tag records the
   tagger's time zone, and every date in this repository is kept at +0000 so
   none of them says where it was made.

   ```bash
   TZ=UTC git tag -a v1.0.1 -m "SolStream 1.0.1"
   git cat-file tag v1.0.1 | grep '^tagger .* +0000$'
   git push origin v1.0.1
   ```

   The same goes for commits: `TZ=UTC git commit`.

   One tag at a time: let one release publish before pushing the next tag.

3. Watch **Actions → Release**. When it finishes the release is on the
   Releases page, and installed copies find it within a day, or as soon as
   somebody asks: *Check for Updates…* on the Mac, *Check for updates* on the
   PC.

What the six jobs do:

| Job | Does |
| --- | --- |
| **Tag matches VERSION** | Refuses a run that is not on a `vX.Y.Z` tag, a tag that does not match `VERSION`, or a tagged commit that is not on `main`. Refuses a commit whose two programs do not carry the public key in its `docs/updates.md`. Picks the key the signature has to satisfy: the one in `docs/updates.md` at the latest release, since that is what installed copies carry, or this commit's for the first release. |
| **macOS package** | `scripts/package-macos.sh --dev --universal`: one bundle for Apple silicon and Intel, ad-hoc signed, stamped with `VERSION` and the commit count as its build number, then `SolStream-X.Y.Z-macOS.zip` and `.dmg` made from it. |
| **Windows package (MSVC)** | `scripts/package-windows.ps1`: `SolStreamSetup-X.Y.Z.exe`, refused if its version block disagrees with `VERSION`. Then runs it with `--verify-update-signature` on `tests/update-vector`: the test vector must pass, a copy with one byte changed must fail, and the vector must fail under the compiled-in production key. |
| **Sign** | Writes `SHA256SUMS` for exactly the three files. Refuses unless the secret is the private half of the key the first job chose, then signs with OpenSSL. Nothing but OpenSSL and Python's standard library runs beside the key, and the job has no token. |
| **Check the signature** | `scripts/sign-release.py verify` with the key the first job chose, then every file against `SHA256SUMS`: a second implementation of the format, beside the Sign job's own. It installs `cryptography` from PyPI, which is why it is neither the job holding the key nor the one that publishes. |
| **Publish** | Checks everything again with OpenSSL and Python's standard library only, since any job in the run can replace the run's artifacts, the PyPI one included: that `SHA256SUMS` lists exactly this version's three files, that its signature holds under the key the first job chose, and that the files match it. Refuses if the tag already has a release or has moved since the build, then creates the release with all five files: a short header, then GitHub's generated notes. It is marked latest only if it is the highest version released, and stops rather than guess when GitHub cannot say which release is the latest. Only this job can write to the repository, and all it writes is the release. |

## When it goes wrong

Nothing is published until the last job, so every failure before it leaves
nothing to clean up but the tag.

- **The tag does not match `VERSION`, or is not on `main`.** Delete the tag
  (`git push --delete origin v1.0.1 && git tag -d v1.0.1`), fix what it says,
  and tag again.
- **A build failed.** Fix it on `main`, then either move the tag to the fixed
  commit, which is fine while no release exists for it, or release the next
  patch version.
- **"is not the private half of".** The secret holds a key installed copies do
  not trust. Set it again from the owner's file. If that key is lost, see
  *Changing the key*.
- **"already has a release".** A published release is never replaced, because an
  updater may already have read its `SHA256SUMS`: release the next patch
  version instead. If it is a *draft* left by a failed publish, delete it
  (`gh release delete v1.0.1 --yes --repo Bruno-Alumn/SolStream`, which keeps
  the tag) and re-run.
- **"has moved since this run built".** The tag was pointed at another commit
  during the run. Release the next patch version from the commit you mean.
- **Re-running.** `gh workflow run release.yml --repo Bruno-Alumn/SolStream
  --ref v1.0.1`, or **Actions → Release → Run workflow** with the tag chosen
  under *Use workflow from*. A run started on a branch is refused. The re-run
  uses `release.yml` as it was tagged, so a fix to the workflow itself means
  moving the tag (while no release exists) or the next patch version.

## Signing by hand

For when Actions cannot run, and for the one release after a lost key. The
result is identical, so the updaters cannot tell the difference. Everything
below runs from the repository root, checked out at the tag.

1. Put the three files in `dist/release/`. Either take them from a run that
   built them, within 7 days of it, after which its artifacts expire:

   ```bash
   gh run download <run-id> --repo Bruno-Alumn/SolStream -n macos -D dist/release
   gh run download <run-id> --repo Bruno-Alumn/SolStream -n windows -D dist/release
   ```

   Later than that, re-run the workflow on the tag (*Re-running*, above) and
   take them from the new run, whose builds finish even when Sign refuses.
   Only when Actions cannot run at all, build them yourself:
   `scripts/package-macos.sh --dev --universal` on a Mac and
   `scripts\package-windows.ps1` on Windows each write theirs to `dist/`, and
   the three versioned files go into `dist/release/`. Those are not the bytes
   CI built and tested, and the Mac build number counts your checkout's
   commits, so build from a full clone of the tag. They also carry the path
   they were built at: the Mac binary keeps its source files' full paths,
   your user name with them, and a release hands that to everyone who
   downloads it. So clone to a path that names nobody, such as
   `/tmp/SolStream`, and check before publishing; this must print 0:

   ```bash
   unzip -p dist/release/SolStream-*-macOS.zip 'SolStream.app/Contents/MacOS/SolStream' \
       | strings | grep -c "$HOME"
   ```

2. Make sure both programs carry the key in this commit's `docs/updates.md`;
   each line must end in `:1`:

   ```bash
   key=$(awk '/compiled into both programs:/ {found = 1; next} found && NF {print $1; exit}' docs/updates.md)
   grep -cF "\"$key\"" macos/SolStreamClient/Sources/SolStreamClient/UpdateFormats.swift windows/SolStreamAgent/updater.h
   ```

3. Find the key the signature has to satisfy, which is the one installed copies
   carry: the key in `docs/updates.md` at the latest release. For the first
   release, or after a lost key, it is `$key` above.

   ```bash
   latest=$(gh release view --repo Bruno-Alumn/SolStream --json tagName --jq .tagName)
   gh api "repos/Bruno-Alumn/SolStream/contents/docs/updates.md?ref=$latest" \
       -H 'Accept: application/vnd.github.raw' | grep -A2 'compiled into both programs:'
   ```

4. Write, sign and check `SHA256SUMS`. `sign-release.py` needs the
   `cryptography` package, which a venv of its own keeps out of the system
   Python; the script then runs with that venv's interpreter, as below, since
   a bare `python3` would not find the package:

   ```bash
   python3 -m venv ~/.venvs/solstream-sign
   ~/.venvs/solstream-sign/bin/pip install cryptography
   cd dist/release
   shasum -a 256 SolStream-1.0.1-macOS.dmg SolStream-1.0.1-macOS.zip SolStreamSetup-1.0.1.exe > SHA256SUMS
   ~/.venvs/solstream-sign/bin/python3 ../../scripts/sign-release.py sign ~/.config/solstream/update-signing-key.pem SHA256SUMS
   ~/.venvs/solstream-sign/bin/python3 ../../scripts/sign-release.py verify "<the key from step 3>" SHA256SUMS
   ```

   The names are in the order the workflow writes them, sorted by name.

5. On Windows, the setup can check it too, in PowerShell, in the folder holding
   the five files. `0` means the signature is good for that key:

   ```powershell
   .\SolStreamSetup-1.0.1.exe --verify-update-signature SHA256SUMS SHA256SUMS.sig "<the key from step 3>"; $LASTEXITCODE
   ```

6. Publish all five files, still in `dist/release`. Add `--latest=false` if a
   higher version has already been released, or it would hide that one from
   every updater:

   ```bash
   gh release create v1.0.1 --repo Bruno-Alumn/SolStream --verify-tag --title "SolStream 1.0.1" --generate-notes \
       SolStream-1.0.1-macOS.zip SolStream-1.0.1-macOS.dmg SolStreamSetup-1.0.1.exe SHA256SUMS SHA256SUMS.sig
   ```

## Changing the key

The programs trust one key each, so a new key reaches them the way any other
change does: in a release they accept, which means one signed with the old key.

1. Make the new key and its public half:

   ```bash
   umask 077
   openssl ecparam -name prime256v1 -genkey -noout \
       | openssl pkcs8 -topk8 -nocrypt -out ~/.config/solstream/update-signing-key.new.pem
   openssl pkey -in ~/.config/solstream/update-signing-key.new.pem -pubout -outform DER \
       | tail -c 65 | base64 | tr -d '\n'; echo
   ```

2. Put the public half in `docs/updates.md` and in both programs (CI fails
   until all three agree), and release that as usual, *with the old key still
   in the secret*. The check job sees the key change and has the signature
   checked against the old key, which is what the copies being updated still
   carry.
3. Once it is published, replace the old key with the new one, in your file and
   in the secret. Every release after this is signed with the new key.

Copies that never install the release in step 2 still hold only the old key and
will refuse everything after it; they have to be reinstalled by hand. So leave
some weeks between a key change and the release after it.

**If the key leaks**, do the same at once: anyone holding it can sign an update
that installed copies accept, until they have taken the release that drops it.

**If only your file is lost**, the secret still signs, though GitHub never shows
it back: change the key at leisure as above, which gives you a file again.

**If the key is lost altogether**, nothing can be signed for the copies already
installed. Make a new key, put its public half in `docs/updates.md` and both
programs, put it in the secret, and push the tag. The Sign job refuses,
because the latest release says installed copies trust the old key, but by
then both packages are built. Publish that one release by hand (*Signing by
hand*), taking the files from that run within 7 days, signing with the new key
and checking against the new public key. From then on the
latest release carries the new key and the workflow signs as usual. Every copy
already installed refuses that release and everything after it: tell everybody
to reinstall from the Releases page.

## While the repository is private

The workflow works the same, but the releases are visible only to people with
access to the repository. The updaters, asking without credentials, get a 404,
which they take to mean "nothing published", so they stay quiet. To try an
update meanwhile, give one program a fine-grained personal access token limited
to this repository, with *Contents: Read-only* and an expiry date, through
`SOLSTREAM_GITHUB_TOKEN` (`docs/updates.md`). The updater sends it only to
api.github.com, never to the download hosts a release asset redirects to, but
it should still be able to do nothing else. *While this repository is private*
in `README.md` says how to hand it to each program. The release notes carry a
line saying the same for as long as the repository is private. Nothing needs changing on the
day the repository goes public, except that the token can then be deleted.

GitHub bills a private repository's macOS runner minutes at ten times the
Linux rate and Windows at twice, and every CI run and release uses both.
