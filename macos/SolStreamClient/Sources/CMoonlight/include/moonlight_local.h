/// @file moonlight_local.h
/// Bridge header for moonlight-common-c library integration.
///
/// moonlight-common-c provides:
///   - SRTP encryption/decryption (AES-GCM)
///   - RTP depacketization (H.264, H.265, Opus)
///   - RTSP handshake protocol
///   - Moonlight pairing (certificate exchange, PIN)
///
/// In Phase 2, this is a placeholder that declares the subset of
/// moonlight-common-c APIs that the Swift client uses. In a production
/// build, these would be provided by the actual moonlight-common-c
/// library (either via SPM submodule or XCFramework).

#ifndef MOONLIGHT_LOCAL_H
#define MOONLIGHT_LOCAL_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── RTSP Handshake ──────────────────────────────────────────────────────────

/// Opaque RTSP context handle.
typedef struct RTSP_CTX RTSP_CTX;

/// Create an RTSP context.
RTSP_CTX* rtsp_create(const char* host, int port);

/// Destroy an RTSP context.
void rtsp_destroy(RTSP_CTX* ctx);

/// Perform the full RTSP handshake (OPTIONS → DESCRIBE → SETUP → PLAY).
/// Returns 0 on success, -1 on failure.
int rtsp_handshake(RTSP_CTX* ctx, const char* app_name);

// ── SRTP Decryption ─────────────────────────────────────────────────────────

/// Opaque SRTP context handle.
typedef struct SRTP_CTX SRTP_CTX;

/// Create an SRTP decryption context with the given key and salt.
SRTP_CTX* srtp_create_decoder(const uint8_t* key, size_t key_len,
                               const uint8_t* salt, size_t salt_len);

/// Destroy an SRTP context.
void srtp_destroy(SRTP_CTX* ctx);

/// Decrypt an SRTP packet. The decrypted payload is written back into
/// the same buffer (in-place). Returns the payload length on success,
/// or -1 on authentication failure.
int srtp_decrypt(SRTP_CTX* ctx, uint8_t* data, size_t len);

// ── RTP Depacketization ─────────────────────────────────────────────────────

/// Depacketize an H.264 NAL unit from an RTP payload.
/// Returns the number of bytes written to `out_data`, or -1 on error.
int rtp_depacketize_h264(const uint8_t* rtp_payload, size_t payload_len,
                         uint8_t* out_data, size_t out_capacity);

/// Depacketize an H.265 (HEVC) NAL unit from an RTP payload.
int rtp_depacketize_h265(const uint8_t* rtp_payload, size_t payload_len,
                         uint8_t* out_data, size_t out_capacity);

/// Depacketize Opus audio from an RTP payload.
int rtp_depacketize_opus(const uint8_t* rtp_payload, size_t payload_len,
                         int16_t* out_pcm, size_t out_capacity);

// ── Pairing ─────────────────────────────────────────────────────────────────

/// Generate a Moonlight-style certificate (X.509 self-signed).
/// Stores paths to the generated cert and key files.
int pairing_generate_certificate(const char* cert_path, const char* key_path);

/// Perform PIN-based pairing with the server.
/// Returns 0 on success, -1 on failure. On success, the session key
/// is stored in `session_key` (32 bytes).
int pairing_exchange(const char* host, int port, const char* pin,
                     uint8_t* session_key, size_t* key_len);

#ifdef __cplusplus
}
#endif

#endif // MOONLIGHT_LOCAL_H
