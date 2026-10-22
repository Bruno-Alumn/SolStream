# Security

SolStream lets a Mac drive applications on a Windows PC, so its security
model matters more than most small projects'.

## What protects a host

- **A pairing token.** Every agent connection proves knowledge of the PC's
  token (shown in SolStream's window on the PC) with an HMAC challenge-response;
  the token itself never crosses the network.
- **An encrypted, forward-secret channel.** After authentication the agent
  channel switches to AES-256-GCM with keys from an ephemeral P-256 exchange
  mixed with the token. Media travels over SMT/1 (`docs/transport-smt1.md`),
  AES-256-GCM per datagram with a replay window.
- **A launch allow-list.** The Mac can only launch what the PC's own Start
  menu lists.

Keep the PC on a trusted network or reach it over a VPN such as Tailscale; the
agent port should not be exposed to the internet.

## Reporting a vulnerability

Please report security issues privately to the repository owner through
GitHub's private vulnerability reporting (Security → Report a vulnerability),
not in a public issue. Include what you found, how to reproduce it, and the
impact you expect.

## Hygiene in this repository

- No secrets, tokens, keys, host names, addresses or personal paths are
  committed. CI runs gitleaks over every push (`.gitleaks.toml`), and
  `.githooks/pre-commit` refuses a commit that would add one -- enable it in
  a clone with `git config core.hooksPath .githooks`.
- Pairing tokens live on the Mac in
  `~/Library/Application Support/SolStream/pairing-tokens.json` (the folder and
  the file readable only by your user, the file excluded from backups) and on the PC
  in `%LOCALAPPDATA%\SolStream\agent.token`, never in the repository. Anyone who
  can read either file can pair with that PC, so treat them like a password.
- The Mac's token is not in the Keychain. SolStream is signed ad hoc, so macOS
  sees every update as a different program, and a Keychain item tied to the old
  one asked for your password again after each update. A Mac that kept its
  tokens in the Keychain moves across the ones macOS hands over without
  asking; for any other you type the token once more.
