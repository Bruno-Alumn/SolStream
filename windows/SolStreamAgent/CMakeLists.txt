# SolStream Agent — built on Windows with MSVC, or cross-compiled from
# macOS/Linux with mingw-w64 via ./build-cross.sh
cmake_minimum_required(VERSION 3.20)

# Required for the MSVC_RUNTIME_LIBRARY property below to be honoured at all.
# Without it CMake silently ignores the property and keeps the default dynamic
# runtime, which is a failure that only shows up on a machine with no Visual
# Studio on it.
cmake_policy(SET CMP0091 NEW)

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
    installer.cpp
)

set_target_properties(SolStreamAgent PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)

target_link_libraries(SolStreamAgent PRIVATE
    user32 ws2_32 dwmapi shell32 winhttp crypt32 bcrypt gdi32
    setupapi cfgmgr32 comctl32
    # The host window draws with Direct2D and lays out text with DirectWrite.
    # Both are in-box, so this adds nothing to what has to be installed.
    d2d1 dwrite
)

# UNICODE selects the wide-character Win32 entry point (wmain) and the W forms
# of the API, on both toolchains.
target_compile_definitions(SolStreamAgent PRIVATE UNICODE _UNICODE)

if(MSVC)
    # /utf-8 because the sources are UTF-8 and the UI strings contain em dashes.
    # Without it MSVC reads them in the system code page and "token — the" is
    # rendered as "token a€" in the window.
    target_compile_options(SolStreamAgent PRIVATE /W4 /permissive- /utf-8)

    # Static runtime, so the executable is genuinely self-contained.
    #
    # The default /MD build imports MSVCP140.dll and VCRUNTIME140.dll, which are
    # NOT part of Windows -- they arrive with the Visual C++ Redistributable, or
    # with Visual Studio. On a clean Windows 11 none of them exist, so the
    # program cannot start at all: it dies at load with 0xC0000135,
    # STATUS_DLL_NOT_FOUND, before main and therefore before any message it could
    # have shown. Every development machine has them, which is exactly why this
    # survived until the first install onto a machine that was not one.
    #
    # Shipping the redistributable instead would mean a second installer to chain
    # and a reboot prompt to explain, for an application whose whole selling
    # point is that there is one thing to run.
    set_property(TARGET SolStreamAgent PROPERTY
                 MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
else()
    target_compile_options(SolStreamAgent PRIVATE -Wall -Wextra -municode)
    target_link_options(SolStreamAgent PRIVATE -municode -static)
endif()
