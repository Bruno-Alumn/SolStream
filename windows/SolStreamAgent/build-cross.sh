#!/bin/sh
# Cross-compile the agent to a Windows .exe from macOS/Linux.
#   brew install mingw-w64
# Produces SolStreamAgent.exe next to this script. Building here does not
# replace building on Windows — it catches compile and link errors early,
# which matters because the agent is developed on a Mac.
set -e
CXX=${CXX:-x86_64-w64-mingw32-g++}
cd "$(dirname "$0")"
"$CXX" -std=c++20 -municode -O2 -Wall -Wextra -static \
    -o SolStreamAgent.exe main.cpp \
    -luser32 -lws2_32 -ldwmapi -lshcore -lshell32 -lwinhttp -lcrypt32
echo "built: $(pwd)/SolStreamAgent.exe"
