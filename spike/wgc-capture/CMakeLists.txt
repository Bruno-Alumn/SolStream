# A throwaway that answers one question before anything is built on the answer.
#
# Deliberately its own project rather than a target in the agent's build: it is a
# measurement, it will be deleted, and it must not end up linked into anything by
# somebody adding a source file to the wrong list.
#
#   cmake -S spike/wgc-capture -B build/spike-wgc
#   cmake --build build/spike-wgc --config Release
cmake_minimum_required(VERSION 3.20)
project(SolStreamCaptureSpike CXX)

add_executable(wgc-capture main.cpp)

set_target_properties(wgc-capture PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)

target_compile_definitions(wgc-capture PRIVATE UNICODE _UNICODE)

if(MSVC)
    # /await is not needed -- the one async call is resolved with .get() -- but
    # C++/WinRT wants permissive- off and utf-8 on, like the rest of this project.
    target_compile_options(wgc-capture PRIVATE /W4 /permissive- /utf-8 /EHsc)
    target_link_options(wgc-capture PRIVATE /SUBSYSTEM:CONSOLE /ENTRY:wmainCRTStartup)
endif()

# windowsapp.lib is the WinRT surface a desktop application links; d3d11 and dxgi
# are for the device the frame pool hands its textures to.
target_link_libraries(wgc-capture PRIVATE windowsapp d3d11 dxgi user32 gdi32)
