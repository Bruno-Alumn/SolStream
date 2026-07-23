#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <Windows.h>
#include <d3d11.h>
#include <dxgi1_6.h>           // includes dxgi1_2.h transitively
#include <wrl/client.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace SolStream::Capture {

/// Exception wrapping an HRESULT failure from D3D11/DXGI operations.
class DeviceException final : public std::runtime_error {
public:
    DeviceException(HRESULT hresult, std::string_view message);
    [[nodiscard]] HRESULT HResult() const noexcept { return m_hresult; }

private:
    HRESULT m_hresult;
};

/// Manages a D3D11 device, immediate context, and parent DXGI factory.
///
/// Thread safety: NOT thread-safe. All calls must be serialized externally.
/// ID3D11Device is safe for concurrent usage, but the immediate context
/// (returned by GetImmediateContext()) is NOT thread-safe and must be
/// protected by the caller if accessed from multiple threads.
///
/// COM must be initialized (COINIT_MULTITHREADED or COINIT_APARTMENTTHREADED)
/// on the calling thread before using this class.
///
/// Device removal: call CheckDeviceRemoval() periodically (e.g. every frame).
/// Returns S_OK if the device is healthy, or a failure HRESULT
/// (e.g. DXGI_ERROR_DEVICE_REMOVED) if the device was lost.
/// device must be recreated via CreateDevice() or CreateDeviceOnAdapter().
/// Recreation releases the old device first; no partial state is left behind.
class DeviceManager {
public:
    using DevicePtr = Microsoft::WRL::ComPtr<ID3D11Device>;
    using ContextPtr = Microsoft::WRL::ComPtr<ID3D11DeviceContext>;
    using FactoryPtr = Microsoft::WRL::ComPtr<IDXGIFactory1>;

    DeviceManager();
    ~DeviceManager();

    DeviceManager(const DeviceManager&) = delete;
    DeviceManager& operator=(const DeviceManager&) = delete;

    /// Create a D3D11 device using the specified driver type.
    /// For D3D_DRIVER_TYPE_HARDWARE the first suitable adapter is selected.
    [[nodiscard]] DevicePtr CreateDevice(D3D_DRIVER_TYPE driverType = D3D_DRIVER_TYPE_HARDWARE);

    /// LUID of the adapter backing the current device.
    /// Returns {0,0} if no device has been created yet. Check HasDevice() first.
    [[nodiscard]] LUID GetAdapterLUID() const noexcept { return m_adapterLuid; }

    /// Adapter descriptor for the current device.
    /// Throws DeviceException if no device has been created.
    [[nodiscard]] DXGI_ADAPTER_DESC1 GetAdapterDesc() const;

    /// Returns true if a D3D11 device has been successfully created.
    [[nodiscard]] bool HasDevice() const noexcept { return m_device != nullptr; }

    /// Poll the device removal status.
    /// Returns S_OK if the device is healthy, or a failure HRESULT
    /// (e.g. DXGI_ERROR_DEVICE_REMOVED) if the device was lost.
    [[nodiscard]] HRESULT CheckDeviceRemoval() const noexcept;

    /// Access the owning DXGI factory. (raw pointer, no AddRef)
    [[nodiscard]] IDXGIFactory1* GetDXGIFactory() const noexcept { return m_factory.Get(); }

    /// Access the D3D11 device. (raw pointer, no AddRef)
    [[nodiscard]] ID3D11Device* GetD3D11Device() const noexcept { return m_device.Get(); }

    /// Access the D3D11 immediate context. (raw pointer, no AddRef)
    /// NOT thread-safe — caller must serialize access.
    [[nodiscard]] ID3D11DeviceContext* GetImmediateContext() const noexcept { return m_context.Get(); }

private:
    void ReleaseDevice() noexcept;
    [[nodiscard]] std::pair<DevicePtr, ContextPtr>
        CreateD3D11Device(IDXGIAdapter1* adapter, D3D_DRIVER_TYPE driverType, LUID expectedLuid);

    FactoryPtr m_factory;
    DevicePtr m_device;
    ContextPtr m_context;
    LUID m_adapterLuid{};
};

} // namespace SolStream::Capture
