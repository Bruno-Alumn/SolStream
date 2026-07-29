# Step 5: the video packetizer, measured without an encoder. See send.cpp.
#
#   cmake -S spike/smt-video -B build/smt-video
#   cmake --build build/smt-video --config Release
cmake_minimum_required(VERSION 3.20)
project(SolStreamSmtVideo CXX)
add_executable(smt-video-send send.cpp)
set_target_properties(smt-video-send PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_compile_definitions(smt-video-send PRIVATE UNICODE _UNICODE)
if(MSVC)
    target_compile_options(smt-video-send PRIVATE /W4 /permissive- /utf-8)
endif()
target_link_libraries(smt-video-send PRIVATE bcrypt ws2_32 winmm)
