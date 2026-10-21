# SolStream Agent — built on Windows with MSVC, or cross-compiled from
# macOS/Linux with mingw-w64 via ./build-cross.sh
cmake_minimum_required(VERSION 3.20)

# Required for the MSVC_RUNTIME_LIBRARY property below to be honoured at all.
# Without it CMake silently ignores the property and keeps the default dynamic
# runtime, which is a failure that only shows up on a machine with no Visual
# Studio on it.
cmake_policy(SET CMP0091 NEW)

# The host application. It captures, encodes and sends the picture itself
# (media/), checks for the virtual display it streams (vdd.cpp), sets that
# display up (display_setup.cpp), installs itself (installer.cpp) and serves
# the Mac.
#
# Deliberately still a console subsystem target. The stray console window the
# agent used to leave on the desktop is dealt with at runtime instead
# (ReleaseUnwantedConsole in main.cpp), because /SUBSYSTEM:WINDOWS would fix the
# window by breaking every command line: a shell does not wait for a GUI
# program, so `SolStream.exe --print-token` would return before printing.
# The resource script is built ALWAYS. It used to be conditional on Sunshine
# being embedded, which meant every ordinary build produced an executable with
# no icon and no version block -- and the only builds that had them were the
# packaged ones nobody looks at until they are on somebody else's machine.
set(SOLSTREAM_VERSION "1.0.0")
string(REPLACE "." "," SOLSTREAM_VERSION_COMMA "${SOLSTREAM_VERSION}")
set(SOLSTREAM_VERSION_COMMA "${SOLSTREAM_VERSION_COMMA},0")

# RC treats a backslash as an escape, so every path has to arrive doubled.
string(REPLACE "\\" "\\\\" SOLSTREAM_ICON_RC "${CMAKE_CURRENT_SOURCE_DIR}/SolStream.ico")

configure_file(resources.rc.in "${CMAKE_CURRENT_BINARY_DIR}/resources.rc" @ONLY)
set(SOLSTREAM_RESOURCES "${CMAKE_CURRENT_BINARY_DIR}/resources.rc")

# SMT/1's media path -- capture, encode, packetize, send, and the input coming
# back. MSVC only: Windows.Graphics.Capture arrives through C++/WinRT and Media
# Foundation through the Windows SDK, and mingw-w64 has neither. The cross build
# is a development convenience; what ships is built on Windows, so the media
# path is present in every binary anybody installs.
if(MSVC)
    set(SOLSTREAM_MEDIA_SOURCES
        media/smt.cpp
        media/channel.cpp
        media/capture.cpp
        media/encoder.cpp
        media/audio.cpp
        media/input.cpp
        media/session.cpp
    )
else()
    set(SOLSTREAM_MEDIA_SOURCES "")
endif()

add_executable(SolStreamAgent
    main.cpp
    util.cpp
    # Not media-only: the host window logs through it too, and it has no
    # dependency beyond stdio.
    media/log.cpp
    vdd.cpp
    display_setup.cpp
    host_window.cpp
    installer.cpp
    ${SOLSTREAM_MEDIA_SOURCES}
    ${SOLSTREAM_RESOURCES}
    # Merged into the linker's manifest: no console window when started from
    # the logon task or a shortcut. See the file.
    SolStream.manifest
)

set_target_properties(SolStreamAgent PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)

target_link_libraries(SolStreamAgent PRIVATE
    user32 ws2_32 dwmapi shell32 winhttp crypt32 bcrypt gdi32
    setupapi cfgmgr32 comctl32
    # GetDpiForMonitor, for the size a window will be on the capture display.
    shcore
    # The host window draws with Direct2D and lays out text with DirectWrite.
    # Both are in-box, so this adds nothing to what has to be installed.
    d2d1 dwrite
    # Shortcuts are IShellLink, which is COM (ole32) and needs its class and
    # interface ids (uuid) -- mingw's import libraries do not carry those unless
    # the library is named.
    ole32 uuid
    # The logon task is registered through ITaskService, whose strings are BSTRs.
    oleaut32
)

# UNICODE selects the wide-character Win32 entry point (wmain) and the W forms
# of the API, on both toolchains.
target_compile_definitions(SolStreamAgent PRIVATE UNICODE _UNICODE
    # One version number for the code and for the resource block, so what
    # Add/Remove Programs lists and what the file's Properties dialog says
    # cannot disagree.
    SOLSTREAM_VERSION_STRING="${SOLSTREAM_VERSION}")

if(MSVC)
    target_compile_definitions(SolStreamAgent PRIVATE SOLSTREAM_MEDIA)
    target_link_libraries(SolStreamAgent PRIVATE
        # Capture, conversion and encode.
        windowsapp d3d11 dxgi
        mfplat mfuuid mf
        # CODECAPI's property GUIDs live in strmiids, not in any mf library --
        # leaving it out fails at link with unresolved CODECAPI_* symbols and
        # says nothing about which header they came from.
        strmiids
        # timeBeginPeriod. Windows' default timer is 15.6 ms, so a pacer that
        # sleeps without this runs at a third of the rate it thinks it does.
        winmm
    )

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
