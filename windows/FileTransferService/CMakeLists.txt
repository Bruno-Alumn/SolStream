# FileTransferService — HTTP file upload/download, IDataObject clipboard, cleanup
# Port 47992

add_executable(FileTransferService
    main.cpp
    path_validator.cpp
    cleanup.cpp
    clipboard_object.cpp
    http_server.cpp
)

target_link_libraries(FileTransferService PRIVATE
    rpcrt4.lib
    shell32.lib
    ole32.lib
    uuid.lib
)

solstream_setup_target(FileTransferService)
target_compile_features(FileTransferService PRIVATE cxx_std_20)

# Console subsystem for debugging (change to WIN32_EXECUTABLE for release)
set_target_properties(FileTransferService PROPERTIES
    WIN32_EXECUTABLE FALSE
)

# Include path for ClipboardMonitor protocol header
target_include_directories(FileTransferService PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../ClipboardMonitor
)
