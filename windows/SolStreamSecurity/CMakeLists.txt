# SolStream Security — pairing, TLS certs, pipe ACLs, helper signing
# Static library linked by Sunshine and other components

add_library(solstream_security STATIC
    pairing.cpp
    tls_cert.cpp
    pipe_acl.cpp
    helper_signing.cpp
)

target_include_directories(solstream_security PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(solstream_security PUBLIC
    bcrypt.lib
    ncrypt.lib
    crypt32.lib
    advapi32.lib
)

solstream_setup_target(solstream_security)
target_compile_features(solstream_security PRIVATE cxx_std_20)
