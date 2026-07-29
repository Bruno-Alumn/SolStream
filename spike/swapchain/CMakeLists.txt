# Content drawn on the GPU, so a throughput figure is the pipeline's and not the
# test's — and so the capture is asked the swap-chain question directly.
#
#   cmake -S spike/swapchain -B build/spike-swapchain
#   cmake --build build/spike-swapchain --config Release
cmake_minimum_required(VERSION 3.20)
project(SolStreamSwapChainSpike CXX)

add_executable(swapchain main.cpp)

set_target_properties(swapchain PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)

target_compile_definitions(swapchain PRIVATE UNICODE _UNICODE)
target_link_libraries(swapchain PRIVATE user32 d3d11 dxgi d3dcompiler)

if(MSVC)
    target_compile_options(swapchain PRIVATE /W4 /permissive- /utf-8 /EHsc)
    target_link_options(swapchain PRIVATE /SUBSYSTEM:CONSOLE /ENTRY:wmainCRTStartup)
endif()
