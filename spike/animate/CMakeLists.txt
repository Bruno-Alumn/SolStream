# Moving content, so a throughput figure means something.
#
#   cmake -S spike/animate -B build/spike-animate
#   cmake --build build/spike-animate --config Release
cmake_minimum_required(VERSION 3.20)
project(SolStreamAnimateSpike CXX)

add_executable(animate main.cpp)

set_target_properties(animate PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)

target_compile_definitions(animate PRIVATE UNICODE _UNICODE)
target_link_libraries(animate PRIVATE user32 gdi32)

if(MSVC)
    target_compile_options(animate PRIVATE /W4 /permissive- /utf-8 /EHsc)
    target_link_options(animate PRIVATE /SUBSYSTEM:CONSOLE /ENTRY:wmainCRTStartup)
endif()
