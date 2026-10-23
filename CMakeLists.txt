cmake_minimum_required(VERSION 3.25)

# ---- Policy ----
cmake_policy(SET CMP0091 NEW)  # MSVC runtime library selection via target properties

project(
    SolStream
    VERSION 0.1.0
    DESCRIPTION "SolStream — Remote App Streaming"
    LANGUAGES CXX
)

# ---- C++ Standard ----
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ---- Output directories per config ----
foreach(config DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_${config} "${CMAKE_BINARY_DIR}/bin/$<LOWER_CASE:${config}>")
    set(CMAKE_LIBRARY_OUTPUT_DIRECTORY_${config} "${CMAKE_BINARY_DIR}/lib/$<LOWER_CASE:${config}>")
    set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY_${config} "${CMAKE_BINARY_DIR}/lib/$<LOWER_CASE:${config}>")
endforeach()

# ---- Testing ----
include(CTest)

# ---- Subdirectories ----
add_subdirectory(windows/SolStreamAgent)

if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
