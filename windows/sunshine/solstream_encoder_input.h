#pragma once

/// @file solstream_encoder_input.h
/// Encoder input abstraction for SolStream's shared-texture capture pipeline.
///
/// This replaces Sunshine's built-in capture (DXGI duplicator) with SolStream's
/// shared D3D11 textures arriving via named-pipe IPC from CaptureHelper.
///
/// Thread safety: NOT thread-safe. All calls must be serialized externally.

#include <Windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>

namespace solstream {

// ── Constants ───────────────────────────────────────────────────────────────

constexpr std::size_t kRingSlotCount = 3;
constexpr std::uint32_t kMutexAcquireTimeoutMs = 16;
constexpr std::uint64_t kMutexKeyProducer = 0;
constexpr std::uint64_t kMutexKeyConsumer = 1;

// ══════════════════════════════════════════════════════════════════════════════
// Ring buffer state (shared with CaptureHelper via keyed mutex)
// ══════════════════════════════════════════════════════════════════════════════

/// Per-slot status (transitions must be atomic with acquire/release ordering).
enum class SlotStatus : std::uint8_t {
    Free,     ///< Available for producer (CaptureHelper) to write.
    Pending,  ///< Written by producer, ready for consumer (encoder) to read.
    InUse,    ///< Currently being read by the encoder.
};

/// A single slot in the shared ring buffer.
struct SharedSlot {
    HANDLE          sharedHandle{};  ///< NT handle for ID3D11Device::OpenSharedResource
    IDXGIKeyedMutex* mutex{};        ///< Keyed mutex for cross-process synchronisation
    SlotStatus      status{SlotStatus::Free};
};

// ══════════════════════════════════════════════════════════════════════════════
// Encoder input — reads from the shared ring
// ══════════════════════════════════════════════════════════════════════════════

/// Receives shared-texture handles from CaptureHelper via the named pipe,
/// opens them on Sunshine's D3D11 device, and delivers frames to the encoder.
///
/// Lifecycle:
///   1. SetDevice() with Sunshine's D3D11 device.
///   2. ImportSlot() for each shared handle received from CaptureHelper.
///   3. AcquireFrame() returns the next available texture.
///   4. ReleaseFrame() when the encoder is done with it.
///   5. On device loss, call Reset() and re-import handles after recreation.
class EncoderInput {
public:
    EncoderInput();
    ~EncoderInput();

    EncoderInput(const EncoderInput&) = delete;
    EncoderInput& operator=(const EncoderInput&) = delete;

    /// Set the D3D11 device used to open shared resources.
    /// Must be called before importing any handles.
    void SetDevice(ID3D11Device* device);

    /// Import a shared handle and store it in the next available slot.
    /// Returns the slot index, or -1 if all slots are occupied.
    /// The handle must have been created with D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX.
    [[nodiscard]] int ImportHandle(HANDLE sharedHandle);

    /// Attempt to acquire the next frame from the ring.
    /// On success, returns the texture and its slot index.
    /// Returns nullptr with result = NoFrame if no pending frame.
    struct AcquireResult {
        ID3D11Texture2D* texture{};
        int slotIndex{-1};
        enum Result { Success, NoFrame, DeviceLost, Timeout } result{NoFrame};
    };
    [[nodiscard]] AcquireResult AcquireFrame();

    /// Release a previously acquired frame back to the producer.
    /// Must be called for every successful AcquireFrame().
    bool ReleaseFrame(int slotIndex);

    /// Reset all imported handles and slot state.
    void Reset();

private:
    Microsoft::WRL::ComPtr<ID3D11Device> m_device;

    SharedSlot m_slots[kRingSlotCount]{};
    int m_slotCount{};

    int m_nextConsumerIndex{};
};

} // namespace solstream
