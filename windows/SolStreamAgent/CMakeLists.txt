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
#
# The version is the repository's VERSION file and nothing else: the Mac
# bundle, this executable's version block and the release tag all read it, and
# the updater compares against what lands here (docs/updates.md). Checked to be
# exactly X.Y.Z, because the updater refuses any other shape -- a build that
# could not parse its own version would never see an update. Changing the file
# re-runs the configure.
set(SOLSTREAM_VERSION_FILE "${CMAKE_CURRENT_SOURCE_DIR}/../../VERSION")
file(READ "${SOLSTREAM_VERSION_FILE}" SOLSTREAM_VERSION)
string(STRIP "${SOLSTREAM_VERSION}" SOLSTREAM_VERSION)
if(NOT SOLSTREAM_VERSION MATCHES "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")
    message(FATAL_ERROR "VERSION must hold X.Y.Z and nothing else, not '${SOLSTREAM_VERSION}'")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${SOLSTREAM_VERSION_FILE}")
string(REPLACE "." "," SOLSTREAM_VERSION_COMMA "${SOLSTREAM_VERSION}")
set(SOLSTREAM_VERSION_COMMA "${SOLSTREAM_VERSION_COMMA},0")

# RC treats a backslash as an escape, so every path has to arrive doubled.
string(REPLACE "\\" "\\\\" SOLSTREAM_ICON_RC "${CMAKE_CURRENT_SOURCE_DIR}/SolStream.ico")

# libopus, which compresses the sound: the one component in what ships that
# SolStream did not write. third_party/opus/SOLSTREAM.md says what it is, why
# it is here and exactly what was taken from the release. Its licence travels
# inside the executable, which is the only thing that ships.
get_filename_component(SOLSTREAM_OPUS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/opus" ABSOLUTE)
string(REPLACE "\\" "\\\\" SOLSTREAM_OPUS_COPYING_RC "${SOLSTREAM_OPUS_DIR}/COPYING")

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
        media/keys.cpp
        media/session.cpp
    )
else()
    set(SOLSTREAM_MEDIA_SOURCES "")
endif()

add_executable(SolStreamAgent
    main.cpp
    util.cpp
    # What the clipboard's text needs between the Mac and Windows.
    clipboard.cpp
    # Not media-only: the host window logs through it too, and it has no
    # dependency beyond stdio.
    media/log.cpp
    vdd.cpp
    display_setup.cpp
    # Fetches and installs the virtual display for a PC that has none.
    driver_install.cpp
    # Whether this PC is on Tailscale, for the window's away-from-home advice.
    tailscale.cpp
    # Whether a Mac knocking on a busy host may take back the session it left.
    session_takeover.cpp
    # Putting a streamed window back as it was, and remembering what is owed.
    window_restore.cpp
    host_window.cpp
    installer.cpp
    # Finds, verifies and installs updates from GitHub releases.
    updater.cpp
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
    # UpdateDriverForPlugAndPlayDevices, which binds the virtual display's
    # driver to the device driver_install.cpp creates; and the adapter list,
    # for whether this PC is on Tailscale.
    newdev iphlpapi
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
    # WTSQuerySessionInformationW: who is signed in at this desktop, which the
    # install asks when it was elevated to somebody else's account.
    wtsapi32
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
        # ActivateAudioInterfaceAsync, which opens a capture of one app's sound.
        mmdevapi
    )

    # The sound's encoder. Static, and nothing of libopus's own build beyond the
    # library: no tests, no programs, nothing to install.
    set(OPUS_BUILD_SHARED_LIBRARY OFF CACHE BOOL "" FORCE)
    set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
    set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
    set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
    set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
    # libopus also builds its tests whenever BUILD_TESTING is on, whatever
    # OPUS_BUILD_TESTING says, and its tests are not vendored: a configure with
    # SolStream's tests on would fail on missing files. Off for libopus alone.
    set(SOLSTREAM_BUILD_TESTING "${BUILD_TESTING}")
    set(BUILD_TESTING OFF)
    add_subdirectory("${SOLSTREAM_OPUS_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/opus")
    set(BUILD_TESTING "${SOLSTREAM_BUILD_TESTING}")
    # The agent's static runtime, below, for the library too. libopus's own
    # default is the DLL one, and a /MD library in a /MT program links with
    # LNK4098 and then carries two C runtimes, each with its own heap.
    set_property(TARGET opus PROPERTY
                 MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    target_link_libraries(SolStreamAgent PRIVATE opus)

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

    # Every DLL this program imports comes from System32, never from beside the
    # executable. The updater runs it elevated from %LOCALAPPDATA%\SolStream\
    # Updates, setup runs it elevated from Downloads, and uninstall from %TEMP%
    # -- all three writable by the user's own programs, and Windows looks in
    # the program's own folder first for any import that is not a KnownDLL
    # (dwmapi, winhttp, d2d1, dxgi, mfplat...). A planted one would run elevated
    # before wmain, where nothing in the code can stop it. 0x800 is
    # LOAD_LIBRARY_SEARCH_SYSTEM32, honoured for static imports from Windows 10
    # 1607; side-by-side and API-set DLLs resolve as before. Loads after wmain
    # are main.cpp's SetDefaultDllDirectories. Check: `dumpbin /loadconfig`
    # shows DependentLoadFlags 0x800 -- not yet seen on a real MSVC link, so
    # look on the first one rather than remove it. The mingw build cannot set
    # it: its linker has no such option, and it is not what ships.
    target_link_options(SolStreamAgent PRIVATE /DEPENDENTLOADFLAG:0x800)
else()
    target_compile_options(SolStreamAgent PRIVATE -Wall -Wextra -municode)
    target_link_options(SolStreamAgent PRIVATE -municode -static)
endif()

# The updater's own tests: version, JSON, SHA256SUMS and base64 parsing, the
# signature against tests/update-vector, the host allow-list, the anti-rollback
# name check, the download's hold, and the note an install leaves; and beside
# them what uninstall takes of the virtual display's settings and records, which
# adapter is Tailscale's, how a key the Mac sends by position is pressed here,
# the clipboard's line endings and privacy markers, when the sound capture
# opens its device again (media/audio_reopen.h, a header of its own because
# audio.cpp builds only with MSVC), and when a Mac may take back the session
# it left behind, this being the one C++ test program. No
# network, and nothing outside a temporary folder and a volatile registry key
# of its own under HKCU: it never sees the real %LOCALAPPDATA%, nor SolStream's
# records in HKLM. updater_tests.cpp includes updater.cpp to reach its
# internals, so that is not listed again here. Not built by
# package-windows.ps1, which configures with BUILD_TESTING off.
if(BUILD_TESTING)
    add_executable(SolStreamUpdaterTests updater_tests.cpp util.cpp clipboard.cpp
        installer.cpp media/log.cpp driver_install.cpp display_setup.cpp vdd.cpp tailscale.cpp
        session_takeover.cpp media/keys.cpp window_restore.cpp)
    set_target_properties(SolStreamUpdaterTests PROPERTIES
        CXX_STANDARD 20
        CXX_STANDARD_REQUIRED ON
    )
    target_compile_definitions(SolStreamUpdaterTests PRIVATE UNICODE _UNICODE
        SOLSTREAM_VERSION_STRING="${SOLSTREAM_VERSION}")
    target_link_libraries(SolStreamUpdaterTests PRIVATE
        user32 advapi32 shell32 winhttp crypt32 bcrypt ole32 oleaut32 uuid
        setupapi cfgmgr32 newdev iphlpapi ws2_32 wtsapi32)
    if(MSVC)
        target_compile_options(SolStreamUpdaterTests PRIVATE /W4 /permissive- /utf-8)
    else()
        target_compile_options(SolStreamUpdaterTests PRIVATE -Wall -Wextra -municode)
        target_link_options(SolStreamUpdaterTests PRIVATE -municode -static)
    endif()
    add_test(NAME updater
             COMMAND SolStreamUpdaterTests
                     "${CMAKE_CURRENT_SOURCE_DIR}/../../tests/update-vector")
endif()
