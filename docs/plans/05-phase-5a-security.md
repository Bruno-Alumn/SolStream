# Phase 5a: Security Hardening (2 Weeks)

## Goal
Harden every channel with proper authentication, encryption, and validation. Implement pairing flow, TLS certificates, pipe ACLs, helper signature verification, and firewall rules.

## Key Changes from Previous Review
1. **Security runs alongside Phase 1-2** — not deferred to end. Named pipe ACLs, helper signing setup, and dev TLS are implemented during Phase 1-2, not after all features are done.
2. **PID recycling prevention**: `GetNamedPipeClientProcessId` → immediately `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_DUP_HANDLE)` → check process creation time via `GetProcessTimes` → **hold handle open for entire session lifetime** (not just during validation). If process exits, handle becomes invalid → disconnect automatically. Bounded validation timeout: 3 seconds max. On timeout → reject.
3. **Config storage split**: `%ProgramData%\SolStream\config\` for security-sensitive data (client cert fingerprints, PIN hashes, session tokens, trusted client list) — DACL write only to SYSTEM and Administrators, read to authenticated users. `%APPDATA%\SolStream\prefs\` for user preferences (resolution, frame rate, audio device, accessibility opt-in) — writable by the user. No DACL mixing.
4. **Test-signing for Phase 5a dev builds**: Self-signed certificate is created during build and installed to `Trusted Publishers` store on dev machines. `WinVerifyTrust` is configured to accept test certificates during development. This breaks the dependency on Phase 5b Authenticode signing.
5. **TLS cipher suite flexibility**: `TLS_AES_256_GCM_SHA384` preferred but `TLS_CHACHA20_POLY1305_SHA256` allowed as fallback for platforms without AES-GCM hardware acceleration.

## Task Breakdown

### Week 1, Day 1-2: Pairing Flow
- [ ] Sunshine generates self-signed TLS cert + key on first launch
- [ ] Server displays a 4-digit PIN in Sunshine Web UI
- [ ] macOS client connects to Sunshine via TLS, receives cert public key
- [ ] Client prompts user to enter the PIN
- [ ] PIN is hashed with server's public key → shared secret
- [ ] Both sides derive session key from shared secret
- [ ] Server stores client's cert fingerprint as "paired"
- [ ] **Verify:** First connect requires PIN, subsequent connects skip PIN (cert fingerprint matches)

### Week 1, Day 3-4: Per-Client Session Tokens
- [ ] After pairing, server generates 64-byte random session token
- [ ] Token sent to macOS client over paired TLS channel
- [ ] All subsequent WS connections (clipboard, control): client presents token in HTTP headers
- [ ] FileTransferService: token required in `Authorization: Bearer <token>` header
- [ ] UDP input: AES-GCM key derived from session token + nonce
- [ ] Token rotation: on reconnect, new token issued. On re-pair, all old tokens invalidated.
- [ ] Unpaired clients: rejected at WS/HTTP level with 401 before any data exchange
- [ ] **Verify:** Unpaired client gets 401 on all channels. Paired client works. Re-pair invalidates old token.

### Week 1, Day 5: TLS Certificate Management
- [ ] Self-signed cert generated at first Sunshine launch (2048-bit RSA, SHA-256)
- [ ] Cert stored in `%APPDATA%\SolStream\cert.pem` + key
- [ ] If cert exists, reuse it (stable fingerprint)
- [ ] TLS 1.3 only (no TLS 1.2 fallback)
- [ ] Cipher suites: TLS_AES_256_GCM_SHA384 only
- [ ] macOS client: verify server cert fingerprint against stored pairing fingerprint
- [ ] **Verify:** TLS handshake succeeds, invalid cert rejected

### Week 2, Day 1: Helper Signature Verification
- [ ] Sign all helper EXEs (CaptureHelper, ClipboardMonitor, InputInjector, FileTransferService) during build
- [ ] Sunshine calls `WinVerifyTrust` before spawning any helper
- [ ] Additionally: call `GetPublisherCertificate` to verify publisher matches SolStream's certificate
- [ ] On signature mismatch: log error, do NOT spawn, show error in Web UI
- [ ] **Verify:** Replacing CaptureHelper.exe with unsigned binary → spawn fails

### Week 2, Day 2: Named Pipe ACL Hardening
- [ ] All named pipes: `PIPE_REJECT_REMOTE_CLIENTS` flag
- [ ] `SECURITY_ATTRIBUTES` with explicit DACL:
  - Allow: only the paired process's token SID
  - Deny: Everyone, Network, Anonymous Logon
- [ ] `NullDACL` explicitly forbidden (static assert in code)
- [ ] **Verify:** Process running as different user cannot connect to pipe

### Week 2, Day 3: Firewall Rule Installer
- [ ] Installer creates inbound firewall rules for ports 47989-47992, 47998-48010
- [ ] Rules scoped to private network profiles only
- [ ] Dev mode: bind all ports to 127.0.0.1, no firewall rules needed
- [ ] **Verify:** First launch on clean Windows → firewall prompt → rule installed → works

### Week 2, Day 4-5: Security Integration Testing
- [ ] Test: replay old UDP capture → rejected by sliding window
- [ ] Test: MITM with fake cert → rejected by fingerprint mismatch
- [ ] Test: connect unpaired client → 401 on all channels
- [ ] Test: replace helper binary → spawn rejected
- [ ] Test: connect to named pipe from different user → access denied
- [ ] Test: UDP packet with wrong nonce → decryption fails → packet dropped
- [ ] Test: token reuse after re-pair → old token rejected
- [ ] **Verify:** All tests pass

## Acceptance Criteria (Phase 5a Gate)
1. Pairing PIN flow works: first connect → enter PIN → paired. Reconnect → automatic.
2. Unpaired clients are rejected on all channels
3. Session tokens authenticate all WS/HTTP/UDP channels
4. Helper signature verification prevents binary replacement
5. Named pipes reject remote connections and unauthorized processes
6. Firewall rules installed for private network only
7. Dev mode binds to 127.0.0.1
8. All security tests pass
