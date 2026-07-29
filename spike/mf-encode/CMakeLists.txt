# What the hardware encoder costs, and whether it can do long-term reference
# frames -- which decides whether a third of the transport design is buildable.
#
#   cmake -S spike/mf-encode -B build/mf-encode
#   cmake --build build/mf-encode --config Release
cmake_minimum_required(VERSION 3.20)
project(SolStreamMfEncode CXX)
add_executable(mf-encode main.cpp)
set_target_properties(mf-encode PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_compile_definitions(mf-encode PRIVATE UNICODE _UNICODE)
if(MSVC)
    target_compile_options(mf-encode PRIVATE /W4 /permissive- /utf-8 /EHsc)
endif()
target_link_libraries(mf-encode PRIVATE mfplat mfuuid strmiids ole32 propsys)
