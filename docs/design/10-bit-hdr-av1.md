# 10-bit, HDR and AV1 video (design, not built)

The goal: better pictures on GPUs that can make them. 10-bit HEVC removes the
banding in gradients that 8-bit shows. HDR shows HDR games and video as they
are. AV1 gives the same picture at less bandwidth, which helps over
Tailscale.

## Where things stand

HEVC is negotiated per stream (PR #46). The Mac offers the codecs it decodes
in hardware, and the host picks one its encoder has. Everything below fits
that negotiation: a new codec name, or a profile beside one.

## 10-bit HEVC (Main10), SDR

- **Host:**
  - Capture stays BGRA8. The colour converter makes P010 instead of NV12.
  - The HEVC encoder opens with `eAVEncH265VProfile_Main_420_10`.
  - NVENC, AMF and QuickSync all take P010.
- **Mac:**
  - VideoToolbox decodes Main10 in hardware on every Apple Silicon Mac.
  - The decoder asks for `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`.
  - `MetalView` samples it as 16-bit textures. That is a second shader path beside the NV12 one.
- **Gain:** smoother gradients. **Cost:** about 20% more bits for the same picture, and more GPU work on both ends.
- **Live check needed:** encode time on the dev PC. HEVC already measured slower than H.264 there.

## HDR

Everything in 10-bit, plus:

- **Host:**
  - Capture an HDR display in FP16 (`DXGI_FORMAT_R16G16B16A16_FLOAT`).
  - Convert from scRGB to PQ BT.2020 in the shader.
  - Send the mastering metadata.
  - The virtual display has to be in HDR mode. That is the VDD HDR trap in our notes: content goes black when the driver's colour settings disagree.
- **Mac:** an EDR `CAMetalLayer` (`wantsExtendedDynamicRangeContent`), PQ colour space, and tone-mapping on SDR displays.
- **Decision:** worth it only if HDR games are a target. It is a lot of colour work to get right, and it can only be judged by eye on an HDR Mac.

## AV1

- **Host:**
  - The Media Foundation AV1 encoder MFT exists on NVIDIA RTX 40, Intel Arc and AMD RDNA3.
  - Output is OBUs, not NAL units. Packetizing is simpler: one temporal unit per frame.
- **Mac:**
  - VideoToolbox decodes AV1 in hardware only on **M3 and later**.
  - The format description needs the `av1C` box built from the sequence header OBU.
  - Offer AV1 only where `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)`.
- **Gain:** about 30% less bandwidth than HEVC at the same quality.
- **Blocker:** needs both an AV1 GPU in the PC and an M3 or later Mac to test. Which ones do we have?

## Recommendation, in order

1. **10-bit HEVC, opt-in** in Settings (Codec → "HEVC 10-bit"), after measuring encode time on the PC.
2. **AV1, automatic** where both ends have hardware, once there is hardware to test on.
3. **HDR** last, and only if HDR games matter.

## Decision needed

Which GPU is in the PC and which chip is in the Mac (for AV1). And whether
HDR is a goal.
