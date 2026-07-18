include(FetchContent)

if(CMAKE_SOURCE_DIR STREQUAL PROJECT_SOURCE_DIR)
    set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
    set(BUILD_GMOCK ON CACHE BOOL "" FORCE)
    set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
endif()

FetchContent_Declare(
    googletest
    URL https://github.com/google/googletest/archive/refs/tags/v1.15.2.zip
    URL_HASH SHA256=f179ec217f9b3b3f3c6e8b02d3e7eda997b49e4ce26d6b235c9053bec9c0bf9f
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)

FetchContent_MakeAvailable(googletest)

include(GoogleTest)

# Helper: register a test executable with project defaults
function(add_solstream_test name)
    add_executable(${name} ${ARGN})
    target_link_libraries(${name} PRIVATE GTest::gtest_main GTest::gmock)
    target_compile_features(${name} PRIVATE cxx_std_20)
    solstream_setup_target(${name})
    gtest_discover_tests(${name}
        DISCOVERY_TIMEOUT 60
        WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/bin/$<LOWER_CASE:$<CONFIG>>"
        PROPERTIES TIMEOUT 60
    )
endfunction()
