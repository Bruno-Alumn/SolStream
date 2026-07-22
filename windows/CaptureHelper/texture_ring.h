#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <Windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>

namespace SolStream::Capture {

// ── Keyed-mutex protocol keys ──────────────────────────────────────────────
constexpr std::uint64_t kMutexKeyProduce = 0;
constexpr std::uint64_t kMutexKeyConsume = 1;

// ── Constants ───────────────────────────────────────────────────────────────
constexpr std::size_t kRingSlotCount = 3;
constexpr std::uint32_t kMutexAcquireTimeoutMs = 16;

// ── Slot state machine ──────────────────────────────────────────────────────
enum class SlotStatus : std::uint8_t {
    Free,
    Pending,
    InUse,
};

// ── Operation result ────────────────────────────────────────────────────────
enum class RingResult {
    Success,
    NoSlotAvailable,
    AcquireTimeout,
    InvalidState,
    DeviceRemoved,
    InternalError,
};

// ── Statistics ──────────────────────────────────────────────────────────────
struct RingStats {
    std::uint64_t totalFramesCaptured{};
    std::uint64_t totalFramesDelivered{};
    std::uint64_t missedFrames{};
    std::uint64_t producerTimeouts{};
    std::uint64_t consumerTimeouts{};
};

// ── Exception ───────────────────────────────────────────────────────────────
class TextureRingException final : public std::runtime_error {
public:
    TextureRingException(std::string msg, HRESULT hr)
        : std::runtime_error(std::move(msg)), m_hresult(hr) {}
    explicit TextureRingException(std::string msg)
        : std::runtime_error(std::move(msg)), m_hresult(E_FAIL) {}
    [[nodiscard]] HRESULT HResult() const noexcept { return m_hresult; }
private:
    HRESULT m_hresult;
};

// ── Forward declarations ────────────────────────────────────────────────────
class TextureRing;
class RingSlotGuard;

// ── Texture Ring ────────────────────────────────────────────────────────────
//
// THREAD SAFETY: Exactly one producer and one consumer thread operating
// concurrently is safe. Slot-status handoff uses C++ atomics for CPU-side
// coordination only (which thread owns which slot). GPU-side visibility of
// texture writes is guaranteed by the keyed-mutex AcquireSync/ReleaseSync
// pairing — not by the atomic status transitions.
//
// Status transition ordering:
//   Producer: relaxed load of status → finds Free → AcquireSync(key=0) →
//             release-store to Pending (publishes slot to consumer)
//   Consumer: acquire-load of status → finds Pending → AcquireSync(key=1) →
//             relaxed store to InUse → processes → ReleaseSync(key=0) →
//             release-store to Free (returns slot to producer)
//   (Producer's next relaxed load of Free may miss; next poll catches it.)
//
// Initialize(), Reset(), GetStats(), ResetStats() must be serialized
// externally with both producer and consumer stopped. All RingSlotGuard
// instances must be released/destroyed BEFORE the TextureRing is destroyed
// or moved — otherwise Release() will use a dangling pointer.
//
// KEYED-MUTEX PROTOCOL:
//   Producer: AcquireSync(kMutexKeyProduce, ms) → write → ReleaseSync(kMutexKeyConsume)
//   Consumer: AcquireSync(kMutexKeyConsume, ∞)  → read  → ReleaseSync(kMutexKeyProduce)
//
class TextureRing {
public:
    using CreateTextureFn = std::function<Microsoft::WRL::ComPtr<ID3D11Texture2D>(
        std::size_t slotIndex, ID3D11Device* device)>;

    struct ProduceResult {
        ID3D11Texture2D* texture{};
        RingResult result{RingResult::InternalError};
    };

    struct ConsumeResult {
        ID3D11Texture2D* texture{};
        RingResult result{RingResult::InternalError};
    };

    TextureRing();
    ~TextureRing();

    TextureRing(const TextureRing&) = delete;
    TextureRing& operator=(const TextureRing&) = delete;
    TextureRing(TextureRing&& other) noexcept;
    TextureRing& operator=(TextureRing&& other) noexcept;

    void Initialize(ID3D11Device* device, CreateTextureFn createFn);
    void Reset() noexcept;

    [[nodiscard]] bool IsInitialized() const noexcept { return m_initialized.load(std::memory_order_acquire); }
    [[nodiscard]] std::size_t SlotCount() const noexcept { return kRingSlotCount; }

    // Producer
    [[nodiscard]] ProduceResult BeginProduce() noexcept;
    RingResult EndProduce() noexcept;

    // Consumer
    [[nodiscard]] ConsumeResult BeginConsume() noexcept;
    RingResult EndConsume() noexcept;

    // RAII convenience
    [[nodiscard]] RingSlotGuard ScopedProduce(ID3D11Texture2D*& outTexture, RingResult& outResult);
    [[nodiscard]] RingSlotGuard ScopedConsume(ID3D11Texture2D*& outTexture, RingResult& outResult);

    // Stats (call only when producer and consumer are stopped)
    [[nodiscard]] RingStats GetStats() const noexcept { return m_stats; }
    void ResetStats() noexcept { m_stats = {}; }

    // ── Cross-process handle export ──────────────────────────────────────
    //
    // When the ring is used cross-process (CaptureHelper → Sunshine), the
    // consumer-side CPU state machine lives in a different process.  These
    // helpers export the actual ring-texture handles for IPC transfer and
    // reset CPU slot status between connections.

    /// Return the number of shared handles exported (always kRingSlotCount
    /// when initialized, 0 otherwise).
    [[nodiscard]] std::size_t ExportSharedHandleCount() const noexcept;

    /// Get the shared handle for a given slot, duplicated into the target
    /// process.  Returns nullptr on failure.
    [[nodiscard]] HANDLE ExportSlotHandle(std::size_t slotIndex,
                                           HANDLE targetProcessHandle) const noexcept;

    /// Reset all CPU-side slot statuses back to Free.  Call this after the
    /// consumer process has acknowledged handle receipt and is ready to
    /// participate in the keyed-mutex protocol.
    void ResetSlotStates() noexcept;

private:
    friend class RingSlotGuard;

    struct Slot {
        Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
        Microsoft::WRL::ComPtr<IDXGIKeyedMutex> mutex;
    };

    std::size_t NextFreeIndex() const noexcept;
    std::size_t NextPendingIndex() const noexcept;

    void HandleDeviceRemoved() noexcept;

    // Atomic status for producer-consumer handoff
    // Free→(relaxed)→Pending(release)→InUse(relaxed)→Free(release)
    std::atomic<std::uint8_t> m_status[kRingSlotCount]{};
    // Track outstanding Begin operations (by slot index, kRingSlotCount = none)
    // Atomic because HandleDeviceRemoved() may reset from any thread.
    std::atomic<std::size_t> m_claimedProducerSlot{kRingSlotCount};
    std::atomic<std::size_t> m_claimedConsumerSlot{kRingSlotCount};

    std::size_t m_nextProducerIndex{};
    std::size_t m_nextConsumerIndex{};
    Slot m_slots[kRingSlotCount]{};
    RingStats m_stats{};

    std::atomic<bool> m_initialized{false};
    std::atomic<bool> m_deviceRemoved{false};

    Microsoft::WRL::ComPtr<ID3D11Device> m_device;
    CreateTextureFn m_createFn;
};

// ── RAII Guard ──────────────────────────────────────────────────────────────
// Defined after TextureRing so it can call its methods.
class RingSlotGuard {
public:
    RingSlotGuard() noexcept = default;

    ~RingSlotGuard() noexcept { Release(); }

    RingSlotGuard(const RingSlotGuard&) = delete;
    RingSlotGuard& operator=(const RingSlotGuard&) = delete;

    RingSlotGuard(RingSlotGuard&& other) noexcept
        : m_ring(std::exchange(other.m_ring, nullptr)),
          m_isProducer(other.m_isProducer),
          m_lastResult(other.m_lastResult) {}

    RingSlotGuard& operator=(RingSlotGuard&& other) noexcept {
        if (this != &other) {
            Release();
            m_ring = std::exchange(other.m_ring, nullptr);
            m_isProducer = other.m_isProducer;
            m_lastResult = other.m_lastResult;
        }
        return *this;
    }

    explicit operator bool() const noexcept { return m_ring != nullptr; }

    [[nodiscard]] RingResult LastResult() const noexcept { return m_lastResult; }

    void Release() noexcept {
        if (m_ring) {
            m_lastResult = m_isProducer
                ? m_ring->EndProduce()
                : m_ring->EndConsume();
            m_ring = nullptr;
        }
    }

private:
    friend class TextureRing;

    RingSlotGuard(TextureRing* ring, bool isProducer) noexcept
        : m_ring(ring), m_isProducer(isProducer) {}

    TextureRing* m_ring{};
    bool m_isProducer{};
    RingResult m_lastResult{RingResult::InvalidState};
};

// ── Inline convenience helpers ──────────────────────────────────────────────
inline RingSlotGuard TextureRing::ScopedProduce(ID3D11Texture2D*& outTexture,
                                                  RingResult& outResult) {
    auto [tex, res] = BeginProduce();
    outTexture = tex;
    outResult = res;
    return (res == RingResult::Success)
        ? RingSlotGuard(this, true)
        : RingSlotGuard{};
}

inline RingSlotGuard TextureRing::ScopedConsume(ID3D11Texture2D*& outTexture,
                                                  RingResult& outResult) {
    auto [tex, res] = BeginConsume();
    outTexture = tex;
    outResult = res;
    return (res == RingResult::Success)
        ? RingSlotGuard(this, false)
        : RingSlotGuard{};
}

} // namespace SolStream::Capture
