# InputInjector — named pipe receiver, SendInput, client validation, key tracking
# Runs as scheduled task: High Integrity Admin, interactive session, NO network

add_executable(InputInjector
    main.cpp
    input_injector.cpp
    key_state_tracker.cpp
    pipe_client_validator.cpp
)

target_link_libraries(InputInjector PRIVATE
    wintrust.lib
    wtsapi32.lib
)

solstream_setup_target(InputInjector)
target_compile_features(InputInjector PRIVATE cxx_std_20)

# GUI subsystem (no console window)
set_target_properties(InputInjector PROPERTIES
    WIN32_EXECUTABLE FALSE
)
