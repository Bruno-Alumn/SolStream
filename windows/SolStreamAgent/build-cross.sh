#!/bin/sh
# Cross-compile the agent to a Windows .exe from macOS/Linux.
#   brew install mingw-w64 cmake
# Produces SolStreamAgent.exe next to this script. Building here does not
# replace building on Windows — it catches compile and link errors early,
# which matters because the agent is developed on a Mac.
#
# CMakeLists.txt is the one list of sources, flags and libraries, and the one
# check of VERSION; this only points it at mingw. The build tree is
# build/cross at the repository root (BUILD_DIR to change it), so a second run
# compiles only what changed.
#
# The updater's tests, with the clipboard's and the sound capture's reopening
# (media/audio_reopen.h) beside them since it is the one C++ test program, are
# built too, so this check covers them. Run them on Windows (or under Wine)
# with the test vector:
#   SolStreamUpdaterTests.exe ..\..\tests\update-vector
set -e
CXX=${CXX:-x86_64-w64-mingw32-g++}
RC=${RC:-x86_64-w64-mingw32-windres}
cd "$(dirname "$0")"
BUILD_DIR=${BUILD_DIR:-../../build/cross}
# -O2 and no NDEBUG, as this script compiled before it went through CMake.
# ~/.local/bin/cc can be a wrapper rather than a compiler, so nothing here is
# left for CMake to find on its own.
cmake -S ../.. -B "$BUILD_DIR" \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_RC_COMPILER="$RC" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS_RELEASE=-O2 \
    -DBUILD_TESTING=ON > /dev/null
cmake --build "$BUILD_DIR" --target SolStreamAgent SolStreamUpdaterTests \
    --parallel "${JOBS:-4}"
for exe in SolStreamAgent SolStreamUpdaterTests; do
    cp "$BUILD_DIR/bin/release/$exe.exe" .
    echo "built: $(pwd)/$exe.exe"
done
