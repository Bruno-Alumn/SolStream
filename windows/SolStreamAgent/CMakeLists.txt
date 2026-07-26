# SolStream Agent — built on Windows with MSVC, or cross-compiled from
# macOS/Linux with mingw-w64 via ./build-cross.sh
cmake_minimum_required(VERSION 3.20)

add_executable(SolStreamAgent WIN32 main.cpp)

set_target_properties(SolStreamAgent PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)

# A console app, not a windowed one: it is a background service that logs to
# stderr. WIN32 above only selects the subsystem for MSVC's linker, so undo it.
set_target_properties(SolStreamAgent PROPERTIES WIN32_EXECUTABLE OFF)

target_link_libraries(SolStreamAgent PRIVATE user32 ws2_32 dwmapi)

if(MSVC)
    target_compile_options(SolStreamAgent PRIVATE /W4 /permissive-)
    # wmain, matching the cross build.
    target_compile_definitions(SolStreamAgent PRIVATE UNICODE _UNICODE)
else()
    target_compile_options(SolStreamAgent PRIVATE -Wall -Wextra -municode)
    target_link_options(SolStreamAgent PRIVATE -municode -static)
endif()
