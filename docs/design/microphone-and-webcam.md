# Microphone and webcam to the PC (design, not built)

The goal: in a call in a streamed Windows app (Teams, Discord, Zoom), the
Mac's microphone and camera are what the PC uses.

## Capture on the Mac: straightforward

- **Microphone:** `AVAudioEngine` input, Opus-encoded with the libopus the
  host already ships, sent over SMT/1 the other way.
- **Camera:** `AVCaptureSession`, H.264-encoded with VideoToolbox. A
  permission prompt for each.

## Playing them on the PC: needs drivers

| | Microphone | Camera |
|---|---|---|
| **No driver** | Not possible: Windows has no API to create an audio input device. | **Windows 11 22H2+**: `MFCreateVirtualCamera` registers a camera backed by a COM media source we'd ship. No driver, but a registered DLL. Windows 10 has nothing. |
| **Third-party driver** | VB-Audio Virtual Cable (donationware, can't be redistributed without a licence), Scream (open source, signing status varies). | OBS Virtual Camera (GPL, installed with OBS). |
| **Our own driver** | A SysVAD-based virtual microphone: KMDF, EV signing plus Microsoft attestation. | Not needed on Windows 11. |

## Recommendation

1. **Camera first, Windows 11 only,** via `MFCreateVirtualCamera`. No driver,
   but a media source DLL is real work: frame pacing and format negotiation.
2. **Microphone** only with a signed driver of our own, once there is a code
   signing setup. Shipping someone else's audio driver has licence and
   support problems.

## Decision needed

Whether a Windows-11-only camera is worth building before the microphone,
and whether to invest in driver signing at all. That signing would also
unlock game controllers.
