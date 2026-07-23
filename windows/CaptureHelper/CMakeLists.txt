# CaptureHelper — per-window WinRT capture with D3D11 shared texture
add_executable(CaptureHelper
    main.cpp
    capture.cpp
    texture_ring.cpp
    device_management.cpp
    pipe_transport.cpp
)

target_link_libraries(CaptureHelper PRIVATE
    SolStream::cppwinrt
    d3d11
    dxgi
)

solstream_setup_target(CaptureHelper)

target_compile_features(CaptureHelper PRIVATE cxx_std_20)

# GUI subsystem (no console window)
set_target_properties(CaptureHelper PROPERTIES
    WIN32_EXECUTABLE FALSE
)
