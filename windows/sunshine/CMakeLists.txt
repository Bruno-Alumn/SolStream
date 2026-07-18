# SolStream Sunshine fork — encoder input + pipe server library

add_library(sunshine_fork STATIC
    solstream_encoder_input.cpp
    sunshine_pipe_server.cpp
)

target_include_directories(sunshine_fork PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../CaptureHelper
)

target_link_libraries(sunshine_fork PUBLIC
    d3d11.lib
    dxgi.lib
)

solstream_setup_target(sunshine_fork)
target_compile_features(sunshine_fork PRIVATE cxx_std_20)

# Include API subdirectory (adds sources to sunshine_fork)
add_subdirectory(api)
