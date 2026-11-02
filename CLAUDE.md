# Working in this repository

## Commits and pull requests

Every commit is the owner's and the owner's alone:

- Author and committer: `Bruno-Alumn <171815746+Bruno-Alumn@users.noreply.github.com>`.
- No `Co-Authored-By` or `Co-authored-by` lines, and no "Generated with" or
  other AI credit, in commit messages or pull request descriptions.
- Dates in UTC: commit with `TZ=UTC`.
- Merge by fast-forwarding `main` to the reviewed commit. GitHub's own squash
  merge writes the account's display name as the author and carries every
  co-author line it finds, so it is not used.

`.claude/settings.json` turns Claude Code's attribution off for every session
here, the `commit-msg` hook in `.githooks` strips any co-author line that gets
through and refuses another author, and CI's "Commit authors" check fails a
pull request or a push to `main` that breaks either rule. Enable the hook per
clone with `git config core.hooksPath .githooks`.
