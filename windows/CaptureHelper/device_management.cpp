#include "device_management.h"

#include <wrl/client.h>
#include <dxgi1_6.h>

#include <algorithm>
#include <cstdint>
#include <cwchar>
#include <format>
#include <iterator>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

namespace SolStream::Capture {

// ══════════════════════════════════════════════════════════════════════════════
// DeviceException
// ══════════════════════════════════════════════════════════════════════════════

DeviceException::DeviceException(HRESULT hresult, std::string_view message)
    : std::runtime_error(
          std::format("{} [HRESULT=0x{:08X}]", message,
                      static_cast<std::uint32_t>(hresult))),
      m_hresult(hresult) {}

// ══════════════════════════════════════════════════════════════════════════════
// Internal helpers
// ══════════════════════════════════════════════════════════════════════════════

namespace {

/// Create the DXGI factory used by DeviceManager.
/// Creates IDXGIFactory1 (safe on all D3D11 systems, no COM cast issues).
/// Note: SolStream requires Windows 10 2004+, so CreateDXGIFactory2 is
/// always available. The IDXGIFactory1 fallback is for defensive coding only.
Microsoft::WRL::ComPtr<IDXGIFactory1> CreateFactory() {
    Microsoft::WRL::ComPtr<IDXGIFactory1> factory;

    // Create directly as IDXGIFactory1 (always available).
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    if (FAILED(hr))
        throw DeviceException(hr, "SolStream: CreateDXGIFactory1 failed.");

    return factory;
}

constexpr std::uint32_t kWideCharBufSize = 128;

constexpr UINT kDeviceCreationFlags =
    D3D11_CREATE_DEVICE_BGRA_SUPPORT;

// Feature level list without 12.x — 11_0 minimum is sufficient for capture.
constexpr D3D_FEATURE_LEVEL kFeatureLevels[] = {
    D3D_FEATURE_LEVEL_11_1,
    D3D_FEATURE_LEVEL_11_0,
};

} // anonymous namespace

// ══════════════════════════════════════════════════════════════════════════════
// Construction / Destruction
// ══════════════════════════════════════════════════════════════════════════════

DeviceManager::DeviceManager()
    : m_factory(CreateFactory()) {}

DeviceManager::~DeviceManager() { ReleaseDevice(); }

// ══════════════════════════════════════════════════════════════════════════════
// Device creation
// ══════════════════════════════════════════════════════════════════════════════

DeviceManager::DevicePtr DeviceManager::CreateDevice(D3D_DRIVER_TYPE driverType) {
    if (!m_factory)
        throw DeviceException(E_UNEXPECTED,
                              "SolStream: CreateDevice called on moved-from DeviceManager.");

    if (driverType == D3D_DRIVER_TYPE_UNKNOWN)
        throw DeviceException(E_INVALIDARG, "SolStream: CreateDevice does not accept D3D_DRIVER_TYPE_UNKNOWN.");

    Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
    LUID luid{};

    if (driverType == D3D_DRIVER_TYPE_HARDWARE) {
        // DXGI 1.6 fast path: prefer high-performance GPU.
        Microsoft::WRL::ComPtr<IDXGIFactory6> f6;
        if (SUCCEEDED(m_factory.As(&f6))) {
            for (UINT i = 0;; ++i) {
                Microsoft::WRL::ComPtr<IDXGIAdapter1> a;
                HRESULT hr = f6->EnumAdapterByGpuPreference(
                    i, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, IID_PPV_ARGS(&a));
                if (hr == DXGI_ERROR_NOT_FOUND)
                    break;
                if (FAILED(hr))
                    continue;
                DXGI_ADAPTER_DESC1 desc{};
                if (FAILED(a->GetDesc1(&desc)))
                    continue;
                if (!(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) {
                    adapter = a;
                    luid = desc.AdapterLuid;
                    break;
                }
            }
        }

        // Generic fallback across all adapters.
        if (!adapter) {
            for (UINT i = 0;; ++i) {
                Microsoft::WRL::ComPtr<IDXGIAdapter1> a;
                HRESULT hr = m_factory->EnumAdapters1(i, &a);
                if (hr == DXGI_ERROR_NOT_FOUND)
                    break;
                if (FAILED(hr))
                    continue;
                DXGI_ADAPTER_DESC1 desc{};
                if (FAILED(a->GetDesc1(&desc)))
                    continue;
                if (!(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) {
                    adapter = a;
                    luid = desc.AdapterLuid;
                    break;
                }
            }
        }

        if (!adapter)
            throw DeviceException(DXGI_ERROR_NOT_FOUND,
                                  "SolStream: no suitable hardware adapter found.");
    }

    // Release any previous device before creating a new one.
    ReleaseDevice();

    // For non-hardware driver types, query the adapter LUID from the device.
    if (driverType != D3D_DRIVER_TYPE_HARDWARE && !adapter) {
        ReleaseDevice();
        // Create device without a specific adapter. After creation, query
        // the adapter LUID from the device.
        auto [dev, _ctx] = CreateD3D11Device(nullptr, driverType, LUID{});
        // Now get the actual adapter LUID from the device.
        Microsoft::WRL::ComPtr<IDXGIDevice> dxgiDev;
        if (SUCCEEDED(dev.As(&dxgiDev))) {
            Microsoft::WRL::ComPtr<IDXGIAdapter> dxgiAdapter;
            if (SUCCEEDED(dxgiDev->GetAdapter(&dxgiAdapter))) {
                DXGI_ADAPTER_DESC desc{};
                if (SUCCEEDED(dxgiAdapter->GetDesc(&desc)))
                    m_adapterLuid = desc.AdapterLuid;
            }
        }
        return dev;
    }

    auto const [device, _context] = CreateD3D11Device(adapter.Get(), driverType, luid);
    return device;
}

// ══════════════════════════════════════════════════════════════════════════════
// Accessors
// ══════════════════════════════════════════════════════════════════════════════

DXGI_ADAPTER_DESC1 DeviceManager::GetAdapterDesc() const {
    if (!m_device)
        throw DeviceException(E_UNEXPECTED,
                              "SolStream: GetAdapterDesc called with no active device.");
    if (!m_factory)
        throw DeviceException(E_UNEXPECTED,
                              "SolStream: GetAdapterDesc called on moved-from DeviceManager.");

    Microsoft::WRL::ComPtr<IDXGIDevice> dxgiDevice;
    {
        HRESULT hr = m_device.As(&dxgiDevice);
        if (FAILED(hr))
            throw DeviceException(hr, "SolStream: m_device.As(&dxgiDevice) failed.");
    }

    Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
    {
        HRESULT hr = dxgiDevice->GetAdapter(&adapter);
        if (FAILED(hr))
            throw DeviceException(hr, "SolStream: dxgiDevice->GetAdapter(&adapter) failed.");
    }

    Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter1;
    {
        HRESULT hr = adapter.As(&adapter1);
        if (FAILED(hr))
            throw DeviceException(hr, "SolStream: adapter.As(&adapter1) failed.");
    }

    DXGI_ADAPTER_DESC1 desc{};
    {
        HRESULT hr = adapter1->GetDesc1(&desc);
        if (FAILED(hr))
            throw DeviceException(hr, "SolStream: adapter1->GetDesc1(&desc) failed.");
    }
    return desc;
}

HRESULT DeviceManager::CheckDeviceRemoval() const noexcept {
    if (!m_device)
        return S_OK;  // no device to check — not an error
    return m_device->GetDeviceRemovedReason();
}

// ══════════════════════════════════════════════════════════════════════════════
// Internal
// ══════════════════════════════════════════════════════════════════════════════

std::pair<DeviceManager::DevicePtr, DeviceManager::ContextPtr>
DeviceManager::CreateD3D11Device(IDXGIAdapter1* adapter,
                                  D3D_DRIVER_TYPE driverType,
                                  LUID expectedLuid) {
    D3D_FEATURE_LEVEL selectedLevel{};
    UINT flags = kDeviceCreationFlags;

#ifdef _DEBUG
    flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif

    auto doCreate = [&](UINT f) -> HRESULT {
        Microsoft::WRL::ComPtr<ID3D11Device> dev;
        Microsoft::WRL::ComPtr<ID3D11DeviceContext> ctx;
        HRESULT hr = D3D11CreateDevice(
            adapter,
            driverType,
            nullptr,
            f,
            kFeatureLevels,
            static_cast<UINT>(std::size(kFeatureLevels)),
            D3D11_SDK_VERSION,
            &dev,
            &selectedLevel,
            &ctx);
        if (SUCCEEDED(hr)) {
            m_device  = std::move(dev);
            m_context = std::move(ctx);
            m_adapterLuid = expectedLuid;
        }
        return hr;
    };

    HRESULT hr = doCreate(flags);
    if (hr == DXGI_ERROR_SDK_COMPONENT_MISSING) {
        flags &= ~D3D11_CREATE_DEVICE_DEBUG;
        hr = doCreate(flags);
    }
    if (hr == E_INVALIDARG) {
        // 11_1 not supported on this runtime. Retry with only 11_0.
        static constexpr D3D_FEATURE_LEVEL kFallback[] = {
            D3D_FEATURE_LEVEL_11_0,
        };
        flags = kDeviceCreationFlags;
#ifdef _DEBUG
        flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif
        Microsoft::WRL::ComPtr<ID3D11Device> dev;
        Microsoft::WRL::ComPtr<ID3D11DeviceContext> ctx;
        hr = D3D11CreateDevice(adapter, driverType, nullptr, flags,
                               kFallback, static_cast<UINT>(std::size(kFallback)),
                               D3D11_SDK_VERSION, &dev, &selectedLevel, &ctx);
        if (SUCCEEDED(hr)) {
            m_device  = std::move(dev);
            m_context = std::move(ctx);
            m_adapterLuid = expectedLuid;
        }
        if (hr == DXGI_ERROR_SDK_COMPONENT_MISSING) {
            flags &= ~D3D11_CREATE_DEVICE_DEBUG;
            hr = D3D11CreateDevice(adapter, driverType, nullptr, flags,
                                   kFallback, static_cast<UINT>(std::size(kFallback)),
                                   D3D11_SDK_VERSION, &dev, &selectedLevel, &ctx);
            if (SUCCEEDED(hr)) {
                m_device  = std::move(dev);
                m_context = std::move(ctx);
                m_adapterLuid = expectedLuid;
            }
        }
    }
    if (FAILED(hr))
        throw DeviceException(hr, "SolStream: D3D11CreateDevice failed.");

    return {m_device, m_context};
}

void DeviceManager::ReleaseDevice() noexcept {
    if (m_context) {
        m_context->ClearState();
        m_context->Flush();
    }
    m_context.Reset();
    m_device.Reset();
    m_adapterLuid = LUID{};
}

} // namespace SolStream::Capture
