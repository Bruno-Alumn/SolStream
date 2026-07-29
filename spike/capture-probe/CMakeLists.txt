# Window capture and display capture, on the same window, one after the other.
#
#   cmake -S spike/capture-probe -B build/spike-capture-probe
#   cmake --build build/spike-capture-probe --config Release
cmake_minimum_required(VERSION 3.20)
project(SolStreamCaptureProbe CXX)

add_executable(capture-probe main.cpp)

set_target_properties(capture-probe PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)

target_compile_definitions(capture-probe PRIVATE UNICODE _UNICODE)
target_link_libraries(capture-probe PRIVATE windowsapp d3d11 dxgi user32)

if(MSVC)
    target_compile_options(capture-probe PRIVATE /W4 /permissive- /utf-8 /EHsc)
    target_link_options(capture-probe PRIVATE /SUBSYSTEM:CONSOLE /ENTRY:wmainCRTStartup)
endif()
