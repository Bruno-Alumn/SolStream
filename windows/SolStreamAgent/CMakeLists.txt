# SolStream Agent — built on Windows with MSVC, or cross-compiled from
# macOS/Linux with mingw-w64 via ./build-cross.sh
cmake_minimum_required(VERSION 3.20)

# The host application. It supervises its own Sunshine (sunshine_host.cpp),
# checks for the virtual display it streams (vdd.cpp), and serves the Mac.
#
# Still a console subsystem target: the window is created explicitly, so the same
# binary can be run headless from a terminal for diagnosis — which is how every
# verification in this project's history has been done.
add_executable(SolStreamAgent
    main.cpp
    sunshine_host.cpp
    vdd.cpp
    host_window.cpp
)

set_target_properties(SolStreamAgent PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)

target_link_libraries(SolStreamAgent PRIVATE
    user32 ws2_32 dwmapi shell32 winhttp crypt32 bcrypt gdi32
    setupapi cfgmgr32 comctl32
)

# UNICODE selects the wide-character Win32 entry point (wmain) and the W forms
# of the API, on both toolchains.
target_compile_definitions(SolStreamAgent PRIVATE UNICODE _UNICODE)

if(MSVC)
    target_compile_options(SolStreamAgent PRIVATE /W4 /permissive-)
else()
    target_compile_options(SolStreamAgent PRIVATE -Wall -Wextra -municode)
    target_link_options(SolStreamAgent PRIVATE -municode -static)
endif()
