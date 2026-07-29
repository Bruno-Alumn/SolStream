# Step 3: the packet layer on a socket, and nothing else. See pong.cpp.
#
#   cmake -S spike/smt-ping -B build/smt-ping
#   cmake --build build/smt-ping --config Release
cmake_minimum_required(VERSION 3.20)
project(SolStreamSmtPing CXX)
add_executable(smt-pong pong.cpp)
set_target_properties(smt-pong PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_compile_definitions(smt-pong PRIVATE UNICODE _UNICODE)
if(MSVC)
    target_compile_options(smt-pong PRIVATE /W4 /permissive- /utf-8)
endif()
target_link_libraries(smt-pong PRIVATE bcrypt ws2_32)
