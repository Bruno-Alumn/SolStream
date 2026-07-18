#include "texture_ring.h"

#include <array>
#include <atomic>
#include <cstdint>

namespace SolStream::Capture {

// ══════════════════════════════════════════════════════════════════════════════
// Construction / Destruction
// ══════════════════════════════════════════════════════════════════════════════

TextureRing::TextureRing() = default;
TextureRing::~TextureRing() { Reset(); }

TextureRing::TextureRing(TextureRing&& other) noexcept
    : m_device(std::move(other.m_device)),
      m_createFn(std::move(other.m_createFn))
{
    for (std::size_t i = 0; i < kRingSlotCount; ++i) {
        m_slots[i] = std::move(other.m_slots[i]);
        m_status[i].store(
            other.m_status[i].exchange(
                static_cast<std::uint8_t>(SlotStatus::Free),
                std::memory_order_relaxed),
            std::memory_order_relaxed);
    }
    m_initialized.store(other.m_initialized.exchange(false, std::memory_order_release),
                        std::memory_order_relaxed);
    m_deviceRemoved.store(other.m_deviceRemoved.exchange(false, std::memory_order_relaxed),
                          std::memory_order_relaxed);
    m_claimedProducerSlot = std::exchange(other.m_claimedProducerSlot, kRingSlotCount);
    m_claimedConsumerSlot = std::exchange(other.m_claimedConsumerSlot, kRingSlotCount);
    m_nextProducerIndex = std::exchange(other.m_nextProducerIndex, 0);
    m_nextConsumerIndex = std::exchange(other.m_nextConsumerIndex, 0);
    m_stats = std::exchange(other.m_stats, RingStats{});
}

TextureRing& TextureRing::operator=(TextureRing&& other) noexcept {
    if (this != &other) {
        Reset();
        for (std::size_t i = 0; i < kRingSlotCount; ++i) {
            m_slots[i] = std::move(other.m_slots[i]);
            m_status[i].store(
                other.m_status[i].exchange(
                    static_cast<std::uint8_t>(SlotStatus::Free),
                    std::memory_order_relaxed),
                std::memory_order_relaxed);
        }
        m_initialized.store(other.m_initialized.exchange(false, std::memory_order_release),
                            std::memory_order_relaxed);
        m_deviceRemoved.store(other.m_deviceRemoved.exchange(false, std::memory_order_relaxed),
                              std::memory_order_relaxed);
        m_claimedProducerSlot   = std::exchange(other.m_claimedProducerSlot, kRingSlotCount);
        m_claimedConsumerSlot   = std::exchange(other.m_claimedConsumerSlot, kRingSlotCount);
        m_nextProducerIndex = std::exchange(other.m_nextProducerIndex, 0);
        m_nextConsumerIndex = std::exchange(other.m_nextConsumerIndex, 0);
        m_device  = std::move(other.m_device);
        m_createFn = std::move(other.m_createFn);
        m_stats = std::exchange(other.m_stats, RingStats{});
    }
    return *this;
}

// ══════════════════════════════════════════════════════════════════════════════
// Initialize / Reset
// ══════════════════════════════════════════════════════════════════════════════

void TextureRing::Initialize(ID3D11Device* device, CreateTextureFn createFn) {
    if (!device)
        throw TextureRingException("TextureRing::Initialize: device is null.");
    if (!createFn)
        throw TextureRingException("TextureRing::Initialize: createFn is empty.");

    if (m_initialized.load(std::memory_order_acquire))
        throw TextureRingException("TextureRing::Initialize: already initialized.");

    Slot tempSlots[kRingSlotCount]{};
    for (std::size_t i = 0; i < kRingSlotCount; ++i) {
        auto tex = createFn(i, device);
        if (!tex)
            throw TextureRingException("TextureRing::Initialize: createFn returned null slot "
                                       + std::to_string(i) + ".");
        Microsoft::WRL::ComPtr<IDXGIKeyedMutex> mutex;
        HRESULT hr = tex.As(&mutex);
        if (FAILED(hr))
            throw TextureRingException(
                "TextureRing::Initialize: texture missing IDXGIKeyedMutex.", hr);
        tempSlots[i].texture = std::move(tex);
        tempSlots[i].mutex   = std::move(mutex);
    }

    for (std::size_t i = 0; i < kRingSlotCount; ++i) {
        m_slots[i]  = std::move(tempSlots[i]);
        m_status[i].store(static_cast<std::uint8_t>(SlotStatus::Free),
                          std::memory_order_relaxed);
    }

    m_device          = device;
    m_createFn        = std::move(createFn);
    m_nextProducerIndex  = 0;
    m_nextConsumerIndex  = 0;
    m_claimedProducerSlot = kRingSlotCount;
    m_claimedConsumerSlot = kRingSlotCount;
    m_stats = RingStats{};
    m_deviceRemoved.store(false, std::memory_order_relaxed);

    m_initialized.store(true, std::memory_order_release);
}

void TextureRing::Reset() noexcept {
    m_initialized.store(false, std::memory_order_release);
    m_deviceRemoved.store(false, std::memory_order_relaxed);
    m_claimedProducerSlot = kRingSlotCount;
    m_claimedConsumerSlot = kRingSlotCount;
    m_nextProducerIndex = 0;
    m_nextConsumerIndex  = 0;

    for (auto& s : m_status)
        s.store(static_cast<std::uint8_t>(SlotStatus::Free), std::memory_order_relaxed);
    for (auto& slot : m_slots) {
        slot.texture.Reset();
        slot.mutex.Reset();
    }
    m_device.Reset();
    m_createFn = nullptr;
    m_stats = RingStats{};
}

// ══════════════════════════════════════════════════════════════════════════════
// Producer
// ══════════════════════════════════════════════════════════════════════════════

TextureRing::ProduceResult TextureRing::BeginProduce() noexcept {
    if (!m_initialized.load(std::memory_order_acquire))
        return {nullptr, RingResult::InvalidState};
    if (m_deviceRemoved.load(std::memory_order_relaxed))
        return {nullptr, RingResult::DeviceRemoved};
    if (m_claimedProducerSlot < kRingSlotCount)
        return {nullptr, RingResult::NoSlotAvailable};

    const std::size_t start = m_nextProducerIndex;
    for (std::size_t i = 0; i < kRingSlotCount; ++i) {
        const std::size_t idx = (start + i) % kRingSlotCount;
        Slot& slot = m_slots[idx];

        if (m_status[idx].load(std::memory_order_relaxed) !=
            static_cast<std::uint8_t>(SlotStatus::Free))
            continue;

        HRESULT hr = slot.mutex->AcquireSync(kMutexKeyProduce, kMutexAcquireTimeoutMs);
        if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
            ++m_stats.producerTimeouts;
            return {nullptr, RingResult::AcquireTimeout};
        }
        if (hr != S_OK) {
            HandleDeviceRemoved();
            m_claimedProducerSlot = kRingSlotCount;
            return {nullptr, RingResult::DeviceRemoved};
        }

        // We hold the mutex. CAS Free→Pending with acq_rel (synchronizes
        // with consumer's release-store of Free from EndConsume).
        auto expected = static_cast<std::uint8_t>(SlotStatus::Free);
        if (!m_status[idx].compare_exchange_strong(
                expected,
                static_cast<std::uint8_t>(SlotStatus::Pending),
                std::memory_order_acq_rel,
                std::memory_order_relaxed)) {
            // AcquireSync succeeded but CAS failed (slot was taken between
            // our relaxed load and CAS). Release the mutex properly.
            HRESULT releaseHr = slot.mutex->ReleaseSync(kMutexKeyConsume);
            if (releaseHr != S_OK) {
                HandleDeviceRemoved();
                m_claimedProducerSlot = kRingSlotCount;
                return {nullptr, RingResult::DeviceRemoved};
            }
            continue;
        }

        m_claimedProducerSlot = idx;
        m_nextProducerIndex = (idx + 1) % kRingSlotCount;
        ++m_stats.totalFramesCaptured;
        return {slot.texture.Get(), RingResult::Success};
    }

    ++m_stats.missedFrames;
    return {nullptr, RingResult::NoSlotAvailable};
}

RingResult TextureRing::EndProduce() noexcept {
    if (m_claimedProducerSlot >= kRingSlotCount)
        return RingResult::InvalidState;

    const std::size_t idx = m_claimedProducerSlot;
    m_claimedProducerSlot = kRingSlotCount;

    HRESULT hr = m_slots[idx].mutex->ReleaseSync(kMutexKeyConsume);
    if (hr != S_OK) {
        HandleDeviceRemoved();
        return RingResult::DeviceRemoved;
    }
    return RingResult::Success;
}

// ══════════════════════════════════════════════════════════════════════════════
// Consumer
// ══════════════════════════════════════════════════════════════════════════════

TextureRing::ConsumeResult TextureRing::BeginConsume() noexcept {
    if (!m_initialized.load(std::memory_order_acquire))
        return {nullptr, RingResult::InvalidState};
    if (m_deviceRemoved.load(std::memory_order_relaxed))
        return {nullptr, RingResult::DeviceRemoved};
    if (m_claimedConsumerSlot < kRingSlotCount)
        return {nullptr, RingResult::NoSlotAvailable};

    const std::size_t start = m_nextConsumerIndex;
    for (std::size_t i = 0; i < kRingSlotCount; ++i) {
        const std::size_t idx = (start + i) % kRingSlotCount;
        Slot& slot = m_slots[idx];

        auto expected = static_cast<std::uint8_t>(SlotStatus::Pending);
        if (!m_status[idx].compare_exchange_strong(
                expected,
                static_cast<std::uint8_t>(SlotStatus::InUse),
                std::memory_order_acquire,
                std::memory_order_relaxed))
            continue;

        HRESULT hr = slot.mutex->AcquireSync(kMutexKeyConsume, kMutexAcquireTimeoutMs);
        if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
            m_status[idx].store(static_cast<std::uint8_t>(SlotStatus::Pending),
                                std::memory_order_release);
            ++m_stats.consumerTimeouts;
            return {nullptr, RingResult::AcquireTimeout};
        }
        if (hr != S_OK) {
            m_status[idx].store(static_cast<std::uint8_t>(SlotStatus::Pending),
                                std::memory_order_release);
            HandleDeviceRemoved();
            m_claimedConsumerSlot = kRingSlotCount;
            return {nullptr, RingResult::DeviceRemoved};
        }

        m_claimedConsumerSlot = idx;
        m_nextConsumerIndex = (idx + 1) % kRingSlotCount;
        ++m_stats.totalFramesDelivered;
        return {slot.texture.Get(), RingResult::Success};
    }

    return {nullptr, RingResult::NoSlotAvailable};
}

RingResult TextureRing::EndConsume() noexcept {
    if (m_claimedConsumerSlot >= kRingSlotCount)
        return RingResult::InvalidState;

    const std::size_t idx = m_claimedConsumerSlot;
    m_claimedConsumerSlot = kRingSlotCount;

    HRESULT hr = m_slots[idx].mutex->ReleaseSync(kMutexKeyProduce);
    if (hr != S_OK) {
        HandleDeviceRemoved();
        return RingResult::DeviceRemoved;
    }

    m_status[idx].store(static_cast<std::uint8_t>(SlotStatus::Free),
                        std::memory_order_release);
    return RingResult::Success;
}

// ══════════════════════════════════════════════════════════════════════════════
// Internal helpers
// ══════════════════════════════════════════════════════════════════════════════

void TextureRing::HandleDeviceRemoved() noexcept {
    m_deviceRemoved.store(true, std::memory_order_relaxed);
}

// ══════════════════════════════════════════════════════════════════════════════
// Cross-process handle export
// ══════════════════════════════════════════════════════════════════════════════

std::size_t TextureRing::ExportSharedHandleCount() const noexcept {
    if (!m_initialized.load(std::memory_order_acquire))
        return 0;
    return kRingSlotCount;
}

HANDLE TextureRing::ExportSlotHandle(
    std::size_t slotIndex, HANDLE targetProcessHandle) const noexcept
{
    if (slotIndex >= kRingSlotCount || !targetProcessHandle ||
        targetProcessHandle == INVALID_HANDLE_VALUE)
        return nullptr;
    if (!m_slots[slotIndex].texture)
        return nullptr;

    // Get the IDXGIResource for this slot.
    Microsoft::WRL::ComPtr<IDXGIResource> dxgiResource;
    HRESULT hr = m_slots[slotIndex].texture.As(&dxgiResource);
    if (FAILED(hr))
        return nullptr;

    // Get the local shared handle.
    HANDLE localHandle = nullptr;
    hr = dxgiResource->GetSharedHandle(&localHandle);
    if (FAILED(hr) || !localHandle)
        return nullptr;

    // Duplicate into the target process.
    HANDLE remoteHandle = nullptr;
    BOOL ok = DuplicateHandle(
        GetCurrentProcess(),
        localHandle,
        targetProcessHandle,
        &remoteHandle,
        0, FALSE, DUPLICATE_SAME_ACCESS);

    if (!ok)
        return nullptr;

    return remoteHandle;
}

void TextureRing::ResetSlotStates() noexcept {
    for (auto& s : m_status)
        s.store(static_cast<std::uint8_t>(SlotStatus::Free),
                std::memory_order_release);
    m_nextProducerIndex = 0;
    m_nextConsumerIndex = 0;
    m_claimedProducerSlot = kRingSlotCount;
    m_claimedConsumerSlot = kRingSlotCount;
}

} // namespace SolStream::Capture
