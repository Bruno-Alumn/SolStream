# ClipboardMonitor — clipboard listener, WS server, UDP input receiver, dedup
# Port 47991 (WS clipboard sync), Port 47990 (UDP input receive)

add_executable(ClipboardMonitor
    main.cpp
    clipboard_listener.cpp
    dedup.cpp
    ws_server.cpp
    udp_input.cpp
    ../CaptureHelper/pipe_transport.cpp
)

target_link_libraries(ClipboardMonitor PRIVATE
    SolStream::cppwinrt
    bcrypt.lib
    crypt32.lib
    secur32.lib
)

solstream_setup_target(ClipboardMonitor)
target_compile_features(ClipboardMonitor PRIVATE cxx_std_20)

# Console subsystem for debugging (change to WIN32_EXECUTABLE for release)
set_target_properties(ClipboardMonitor PROPERTIES
    WIN32_EXECUTABLE FALSE
)

# Include path for shared IPC headers
target_include_directories(ClipboardMonitor PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../CaptureHelper
)
