# SolStream — Final Review

## Plan-level verdicts and applied fixes

| Plan | Issue | Fix Applied |
|---|---|---|
| **P00** | No explicit threat model; schedule dependencies unclear | Added reference to companion `threat-model.md`. Schedule clarified: 21w includes all spikes, integration, signing, hardening. |
| **P01** | Hybrid GPU: LUID alone insufficient; need cross-adapter copy fallback | Added: if LUIDs don't match → CPU readback + staging texture copy on target adapter. Device-removal: keyed-mutex timeout recovery with exponential backoff. |
| **P02** | moonlight-common-c licensing (GPLv2); clock sync for jitter buffer; permission-denied behavior | Added: GPLv2 compliance note for moonlight-common-c (separate process boundary). Monotonic clock sync via NTP-style offset estimation in WS control channel. Permission-denied: graceful fallback to local NSView input only, show settings link. |
| **P03** | Pre-injection validation insufficient; clipboard sensitive-data policy | Added: InputInjector validates (foreground HWND == target) AND (process integrity ≤ High) AND (session ID matches) before every injection. Clipboard: sensitive-data flag (if content looks like password/credit card → suppress sync, show "content withheld" placeholder). Bounded memory: clipboard cache capped at 200MB LRU. |
| **P04** | "Async IStream" vague; needs concrete IOCP pipeline; per-chunk integrity | Replaced with: dedicated IOCP thread pool. `IStream::Read` backed by pre-cached file handle (not network). Per-chunk SHA-256 in Content-Range resume. |
| **P05** | Pairing lifecycle incomplete; dev vs prod signing boundary | Added full lifecycle: pairing → session → rotation (24h) → revocation (re-pair invalidates) → expiry (30d without reconnect). Dev signing: self-signed cert in Trusted Publishers. Prod: Authenticode + EV cert. Documented boundary. |
| **P06** | Audio muting not transactional; installer needs atomicity + health checks | Audio: capture pre-stream mute state, restore on stop/crash/disconnect. Installer: create restore point before upgrade, health-check new binaries before removing old ones, auto-rollback on failure. |

## Updated Plans

All fixes written to `docs/plans/0*.md`.
