#!/bin/sh
# Cross-compile the agent to a Windows .exe from macOS/Linux.
#   brew install mingw-w64
# Produces SolStreamAgent.exe next to this script. Building here does not
# replace building on Windows — it catches compile and link errors early,
# which matters because the agent is developed on a Mac.
set -e
CXX=${CXX:-x86_64-w64-mingw32-g++}
cd "$(dirname "$0")"
# The version from the repository's VERSION file, as CMakeLists.txt reads it,
# so this build compares against the same number the real one does.
VERSION=$(tr -d ' \t\r\n' < ../../VERSION)
if ! printf '%s\n' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
    echo "VERSION must hold X.Y.Z and nothing else, not '$VERSION'" >&2
    exit 1
fi
"$CXX" -std=c++20 -municode -O2 -Wall -Wextra -static \
    "-DSOLSTREAM_VERSION_STRING=\"$VERSION\"" \
    -o SolStreamAgent.exe \
    main.cpp util.cpp vdd.cpp display_setup.cpp driver_install.cpp tailscale.cpp \
    host_window.cpp \
    installer.cpp updater.cpp media/log.cpp \
    -luser32 -lws2_32 -ldwmapi -lshcore -lshell32 -lwinhttp -lcrypt32 -lbcrypt -lgdi32 \
    -lsetupapi -lcfgmgr32 -lcomctl32 -lnewdev -liphlpapi -lole32 -loleaut32 -luuid \
    -ld2d1 -ldwrite -lwtsapi32
echo "built: $(pwd)/SolStreamAgent.exe ($VERSION)"
# The updater's tests, compiled so this check covers them too. Run them on
# Windows (or under Wine) with the test vector:
#   SolStreamUpdaterTests.exe ..\..\tests\update-vector
"$CXX" -std=c++20 -municode -O2 -Wall -Wextra -static \
    "-DSOLSTREAM_VERSION_STRING=\"$VERSION\"" \
    -o SolStreamUpdaterTests.exe \
    updater_tests.cpp util.cpp installer.cpp media/log.cpp \
    driver_install.cpp display_setup.cpp vdd.cpp tailscale.cpp \
    -luser32 -ladvapi32 -lshell32 -lwinhttp -lcrypt32 -lbcrypt -lole32 -loleaut32 -luuid \
    -lsetupapi -lcfgmgr32 -lnewdev -liphlpapi -lws2_32 -lwtsapi32
echo "built: $(pwd)/SolStreamUpdaterTests.exe"
