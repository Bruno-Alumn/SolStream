# SolStream Agent — built on Windows with MSVC, or cross-compiled from
# macOS/Linux with mingw-w64 via ./build-cross.sh
cmake_minimum_required(VERSION 3.20)

# A console application: it is a background service that logs to stderr.
add_executable(SolStreamAgent main.cpp)

set_target_properties(SolStreamAgent PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)

target_link_libraries(SolStreamAgent PRIVATE user32 ws2_32 dwmapi)

# UNICODE selects the wide-character Win32 entry point (wmain) and the W forms
# of the API, on both toolchains.
target_compile_definitions(SolStreamAgent PRIVATE UNICODE _UNICODE)

if(MSVC)
    target_compile_options(SolStreamAgent PRIVATE /W4 /permissive-)
else()
    target_compile_options(SolStreamAgent PRIVATE -Wall -Wextra -municode)
    target_link_options(SolStreamAgent PRIVATE -municode -static)
endif()
