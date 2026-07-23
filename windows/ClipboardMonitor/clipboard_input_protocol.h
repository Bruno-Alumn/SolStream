#pragma once

/// @file clipboard_input_protocol.h
/// Shared protocol definitions for ClipboardMonitor ↔ InputInjector IPC
/// and ClipboardMonitor ↔ macOS client WS/UDP protocols.
///
/// This header is shared by ClipboardMonitor.exe, InputInjector.exe,
/// and cross-referenced by the macOS Swift client.

#include <Windows.h>
#include <cstdint>

namespace solstream::clipboard {

// ══════════════════════════════════════════════════════════════════════════════
// Port assignments
// ══════════════════════════════════════════════════════════════════════════════

constexpr uint16_t kClipboardWSPort     = 47991;  // Clipboard sync (TCP/WS)
constexpr uint16_t kInputUDPPort        = 47990;  ///< Input packets (UDP)

// ══════════════════════════════════════════════════════════════════════════════
// Named pipe (ClipboardMonitor → InputInjector)
// ══════════════════════════════════════════════════════════════════════════════

static constexpr wchar_t kInputInjectorPipe[] =
    L"\\\\.\\pipe\\SolStream_InputInjector";

constexpr uint32_t kInputPipeMaxMsgSize  = 256;   ///< Bounded message per spec
constexpr uint32_t kInputPipeBufferSize  = 4096;

// ══════════════════════════════════════════════════════════════════════════════
// Input packet format (ClipboardMonitor UDP → InputInjector pipe)
// ══════════════════════════════════════════════════════════════════════════════

#pragma pack(push, 1)

enum class InputType : uint8_t {
    KeyDown      = 1,
    KeyUp        = 2,
    MouseMove    = 3,
    MouseDown    = 4,
    MouseUp      = 5,
    MouseWheel   = 6,
    Modifiers    = 7,  ///< Modifier flag set (Shift, Ctrl, Alt, Win)
};

struct InputPacket {
    InputType type;                          ///< 1 byte
    uint8_t  reserved;                       ///< Padding / flags
    uint16_t sequence;                       ///< Per-session monotonic counter
    union {
        // Keyboard (type 1, 2)
        struct {
            uint8_t  vkCode;                 ///< Windows virtual-key code
            uint8_t  scancode;               ///< Hardware scancode
            uint16_t flags;                  ///< KEYEVENTF_EXTENDEDKEY, etc.
        } key;
        // Mouse move (type 3)
        struct {
            uint32_t absoluteX;              ///< 0..65535 (normalised screen)
            uint32_t absoluteY;              ///< 0..65535
            uint16_t flags;                  ///< MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE
        } mouseMove;
        // Mouse button (type 4, 5)
        struct {
            uint8_t  button;                 ///< 0=left, 1=right, 2=middle
            uint8_t  padding[3];
        } mouseButton;
        // Mouse wheel (type 6)
        struct {
            int16_t  delta;                  ///< WHEEL_DELTA units
            uint16_t flags;                  ///< MOUSEEVENTF_WHEEL
        } mouseWheel;
        // Modifier set (type 7)
        struct {
            uint8_t  modifiers;              ///< Bit 0=Shift, 1=Ctrl, 2=Alt, 3=Win
            uint8_t  padding[3];
        } modifiers;
        // Raw storage for serialisation
        uint8_t raw[8];
    };
};
static_assert(sizeof(InputPacket) == 12, "InputPacket must be 12 bytes");

#pragma pack(pop)

// ══════════════════════════════════════════════════════════════════════════════
// Clipboard format allowlist
// ══════════════════════════════════════════════════════════════════════════════

/// Bitmask of allowlisted clipboard formats.
constexpr uint64_t CFMT_TEXT           = 1ULL << 0;   ///< CF_TEXT / CF_UNICODETEXT
constexpr uint64_t CFMT_HDROP          = 1ULL << 1;   ///< CF_HDROP (file list)
constexpr uint64_t CFMT_DIB            = 1ULL << 2;   ///< CF_DIB (bitmap)
constexpr uint64_t CFMT_FILECONTENTS   = 1ULL << 3;   ///< CFSTR_FILECONTENTS
constexpr uint64_t CFMT_ALL_ALLOWED    = CFMT_TEXT | CFMT_HDROP | CFMT_DIB | CFMT_FILECONTENTS;

/// Maximum clipboard sync parameters.
constexpr uint32_t kMaxFormatsPerSync   = 10;
constexpr uint64_t kMaxBytesPerFormat   = 100ULL * 1024 * 1024;  // 100 MB
constexpr uint32_t kMaxOpsPerSecond     = 5;                     // rate limit
constexpr uint32_t kDebounceMs          = 100;                   // coalesce

// ══════════════════════════════════════════════════════════════════════════════
// Clipboard WS protocol frame tags
// ══════════════════════════════════════════════════════════════════════════════

/// Frame types for the clipboard WS binary protocol.
enum class ClipboardFrameType : uint8_t {
    ClipboardUpdate   = 1,  ///< New clipboard data
    ClipboardRequest  = 2,  ///< Request current clipboard snapshot
    Heartbeat         = 4,  ///< Keep-alive ping
    AuthToken         = 5,  ///< Session auth token
};

// ══════════════════════════════════════════════════════════════════════════════
// AES-GCM constants for UDP input encryption
// ══════════════════════════════════════════════════════════════════════════════

constexpr uint32_t kAESGCMKeySize    = 32;    ///< AES-256 key
constexpr uint32_t kAESGCMNonceSize  = 12;    ///< 96-bit nonce
constexpr uint32_t kAESGCMTagSize    = 16;    ///< Authentication tag
constexpr uint32_t kReplayWindowSize = 1024;  ///< Sliding window slots

}  // namespace solstream::clipboard
