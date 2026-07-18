#include "solstream_encoder_input.h"

#include <atomic>
#include <cstring>
#include <format>
#include <string>

namespace solstream {

// ══════════════════════════════════════════════════════════════════════════════
// Construction / Destruction
// ══════════════════════════════════════════════════════════════════════════════

EncoderInput::EncoderInput() = default;
EncoderInput::~EncoderInput() { Reset(); }

EncoderInput::EncoderInput(EncoderInput&& other) noexcept
    : m_device(std::move(other.m_device)),
      m_context(std::move(other.m_context)),
      m_slotCount(std::exchange(other.m_slotCount, 0)),
      m_nextConsumerIndex(std::exchange(other.m_nextConsumerIndex, 0))
{
    for (int i = 0; i < kRingSlotCount; ++i) {
        m_slots[i] = other.m_slots[i];
        other.m_slots[i] = {};
    }
}

EncoderInput& EncoderInput::operator=(EncoderInput&& other) noexcept {
    if (this != &other) {
        Reset();
        m_device  = std::move(other.m_device);
        m_context = std::move(other.m_context);
        m_slotCount = std::exchange(other.m_slotCount, 0);
        m_nextConsumerIndex = std::exchange(other.m_nextConsumerIndex, 0);
        for (int i = 0; i < kRingSlotCount; ++i) {
            m_slots[i] = other.m_slots[i];
            other.m_slots[i] = {};
        }
    }
    return *this;
}

// ══════════════════════════════════════════════════════════════════════════════
// Device
// ══════════════════════════════════════════════════════════════════════════════

void EncoderInput::SetDevice(ID3D11Device* device) {
    if (!device)
        throw std::invalid_argument("EncoderInput::SetDevice: device is null.");
    m_device = device;
    device->GetImmediateContext(&m_context);
}

// ══════════════════════════════════════════════════════════════════════════════
// Slot management
// ══════════════════════════════════════════════════════════════════════════════

int EncoderInput::ImportHandle(HANDLE sharedHandle) {
    if (!sharedHandle || sharedHandle == INVALID_HANDLE_VALUE)
        return -1;
    if (!m_device || m_slotCount >= kRingSlotCount)
        return -1;

    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
    HRESULT hr = m_device->OpenSharedResource(sharedHandle, IID_PPV_ARGS(&texture));
    if (FAILED(hr))
        return -1;

    Microsoft::WRL::ComPtr<IDXGIKeyedMutex> mutex;
    hr = texture.As(&mutex);
    if (FAILED(hr))
        return -1;

    int idx = m_slotCount++;
    m_slots[idx].sharedHandle = sharedHandle;
    m_slots[idx].mutex        = mutex.Detach();
    return idx;
}

void EncoderInput::RemoveHandle(int slotIndex) {
    if (slotIndex < 0 || slotIndex >= m_slotCount)
        return;
    auto& slot = m_slots[slotIndex];
    if (slot.mutex)  { slot.mutex->Release();  slot.mutex = nullptr; }
    if (slot.sharedHandle) { CloseHandle(slot.sharedHandle); slot.sharedHandle = nullptr; }
    if (slotIndex < m_slotCount - 1) {
        m_slots[slotIndex] = m_slots[m_slotCount - 1];
        m_slots[m_slotCount - 1] = {};
    }
    --m_slotCount;
}

// ══════════════════════════════════════════════════════════════════════════════
// Frame acquisition (consumer side, synchronised via keyed mutex)
// ══════════════════════════════════════════════════════════════════════════════

EncoderInput::AcquireResult EncoderInput::AcquireFrame() {
    if (m_slotCount == 0)
        return {nullptr, -1, AcquireResult::NoFrame};

    // Probe each slot starting from the last consumed index.  The keyed mutex
    // IS the synchronisation primitive: if AcquireSync(key=1) succeeds then a
    // frame has been produced and released by CaptureHelper.
    for (int i = 0; i < m_slotCount; ++i) {
        int idx = (m_nextConsumerIndex + i) % m_slotCount;

        HRESULT hr = m_slots[idx].mutex->AcquireSync(
            kMutexKeyConsumer, kMutexAcquireTimeoutMs);

        if (hr == S_OK) {
            // Frame available.
            m_nextConsumerIndex = (idx + 1) % m_slotCount;

            Microsoft::WRL::ComPtr<ID3D11Texture2D> tex;
            hr = m_device->OpenSharedResource(
                m_slots[idx].sharedHandle, IID_PPV_ARGS(&tex));
            if (FAILED(hr)) {
                // Release the mutex so the producer can retry.
                m_slots[idx].mutex->ReleaseSync(kMutexKeyProducer);
                return {nullptr, -1, AcquireResult::DeviceLost};
            }
            return {tex.Detach(), idx, AcquireResult::Success};
        }

        if (hr == DXGI_ERROR_WAIT_TIMEOUT)
            continue;  // try next slot

        // Any other failure indicates device loss.
        return {nullptr, -1, AcquireResult::DeviceLost};
    }

    return {nullptr, -1, AcquireResult::NoFrame};
}

bool EncoderInput::ReleaseFrame(int slotIndex) {
    if (slotIndex < 0 || slotIndex >= m_slotCount)
        return false;
    if (!m_slots[slotIndex].mutex)
        return false;

    // Release the keyed mutex back to the producer (key = 0).
    HRESULT hr = m_slots[slotIndex].mutex->ReleaseSync(kMutexKeyProducer);
    return SUCCEEDED(hr);
}

// ══════════════════════════════════════════════════════════════════════════════
// Reset
// ══════════════════════════════════════════════════════════════════════════════

void EncoderInput::Reset() {
    for (int i = 0; i < m_slotCount; ++i) {
        if (m_slots[i].mutex) {
            m_slots[i].mutex->Release();
            m_slots[i].mutex = nullptr;
        }
        if (m_slots[i].sharedHandle) {
            CloseHandle(m_slots[i].sharedHandle);
            m_slots[i].sharedHandle = nullptr;
        }
    }
    m_slotCount = 0;
    m_nextConsumerIndex = 0;
    m_context.Reset();
    m_device.Reset();
}

} // namespace solstream
