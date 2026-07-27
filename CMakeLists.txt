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

# ---- MSVC runtime ----
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")

# ---- Output directories per config ----
foreach(config DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_${config} "${CMAKE_BINARY_DIR}/bin/$<LOWER_CASE:${config}>")
    set(CMAKE_LIBRARY_OUTPUT_DIRECTORY_${config} "${CMAKE_BINARY_DIR}/lib/$<LOWER_CASE:${config}>")
    set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY_${config} "${CMAKE_BINARY_DIR}/lib/$<LOWER_CASE:${config}>")
endforeach()

# ---- C++/WinRT ----
# Prefer CMake config mode; fall back to NuGet path search
find_package(Microsoft.Windows.CppWinRT CONFIG QUIET)

if(Microsoft.Windows.CppWinRT_FOUND)
    # Alias the package's target so CaptureHelper can use SolStream::cppwinrt
    if(TARGET Microsoft.Windows.CppWinRT::CppWinRT)
        add_library(SolStream::cppwinrt ALIAS Microsoft.Windows.CppWinRT::CppWinRT)
    elseif(TARGET Microsoft::CppWinRT)
        add_library(SolStream::cppwinrt ALIAS Microsoft::CppWinRT)
    elseif(TARGET cppwinrt::cppwinrt)
        add_library(SolStream::cppwinrt ALIAS cppwinrt::cppwinrt)
    else()
        message(WARNING "Microsoft.Windows.CppWinRT found but no expected target defined. "
                        "Falling back to manual header search.")
        # Fall through to manual discovery below
    endif()
endif()

if(NOT TARGET SolStream::cppwinrt)
    # Fall back to NuGet path search
    set(CPPWINRT_SEARCH_ROOTS)

    if(DEFINED ENV{NUGET_PACKAGES})
        list(APPEND CPPWINRT_SEARCH_ROOTS
            "$ENV{NUGET_PACKAGES}/microsoft.windows.cppwinrt")
    endif()

    if(DEFINED ENV{USERPROFILE})
        list(APPEND CPPWINRT_SEARCH_ROOTS
            "$ENV{USERPROFILE}/.nuget/packages/microsoft.windows.cppwinrt")
    endif()

    if(DEFINED ENV{CPPWINRT_ROOT})
        list(APPEND CPPWINRT_SEARCH_ROOTS "$ENV{CPPWINRT_ROOT}")
    endif()

    # Find C++/WinRT headers by searching versioned package dirs
    set(CPPWINRT_INCLUDE_DIR)
    foreach(root ${CPPWINRT_SEARCH_ROOTS})
        # Direct path: root points to a package version dir containing include/
        if(EXISTS "${root}/include/winrt/base.h")
            set(CPPWINRT_INCLUDE_DIR "${root}/include")
            message(STATUS "C++/WinRT found at ${root}/include")
            break()
        elseif(EXISTS "${root}/winrt/base.h")
            set(CPPWINRT_INCLUDE_DIR "${root}")
            message(STATUS "C++/WinRT found at ${root}")
            break()
        endif()
        # Versioned NuGet layout: root contains version subdirs
        file(GLOB version_dirs RELATIVE "${root}" "${root}/*")
        list(SORT version_dirs COMPARE NATURAL ORDER DESCENDING)
        foreach(vdir ${version_dirs})
            foreach(suffix "include" "build/native/include")
                set(candidate "${root}/${vdir}/${suffix}")
                if(EXISTS "${candidate}/winrt/base.h")
                    set(CPPWINRT_INCLUDE_DIR "${candidate}")
                    message(STATUS "C++/WinRT found at ${candidate}")
                    break()
                endif()
            endforeach()
            if(CPPWINRT_INCLUDE_DIR)
                break()
            endif()
        endforeach()
        if(CPPWINRT_INCLUDE_DIR)
            break()
        endif()
    endforeach()

    # Last resort: Windows SDK bundled C++/WinRT — find newest SDK with cppwinrt
    if(NOT CPPWINRT_INCLUDE_DIR)
        set(WIN_KITS_DIR "C:/Program Files (x86)/Windows Kits/10/Include")
        if(DEFINED ENV{WindowsSdkDir})
            set(WIN_KITS_DIR "$ENV{WindowsSdkDir}/Include")
        endif()
        if(EXISTS "${WIN_KITS_DIR}")
            file(GLOB sdk_versions RELATIVE "${WIN_KITS_DIR}" "${WIN_KITS_DIR}/*")
            list(SORT sdk_versions COMPARE NATURAL ORDER DESCENDING)
            foreach(sdk ${sdk_versions})
                set(candidate "${WIN_KITS_DIR}/${sdk}/cppwinrt")
                if(EXISTS "${candidate}/winrt/base.h")
                    set(CPPWINRT_INCLUDE_DIR "${candidate}")
                    message(STATUS "C++/WinRT found in Windows SDK ${sdk}")
                    break()
                endif()
            endforeach()
        endif()
    endif()

    if(CPPWINRT_INCLUDE_DIR)
        add_library(SolStream::cppwinrt INTERFACE IMPORTED)
        target_include_directories(SolStream::cppwinrt INTERFACE "${CPPWINRT_INCLUDE_DIR}")
        target_link_libraries(SolStream::cppwinrt INTERFACE windowsapp.lib)
    else()
        message(FATAL_ERROR
            "C++/WinRT not found. Install Microsoft.Windows.CppWinRT NuGet package, "
            "or set CPPWINRT_ROOT env var. Searched: ${CPPWINRT_SEARCH_ROOTS}")
    endif()
endif()

# ---- MSVC target-specific options ----
function(solstream_setup_target target)
    if(MSVC)
        target_compile_options(${target} PRIVATE
            /EHsc
            /permissive-
            /utf-8
            /W4
            /Zc:__cplusplus
            /Zc:preprocessor
            /Zc:inline
            /bigobj
        )
    endif()
    if(WIN32)
        target_compile_definitions(${target} PRIVATE
            WIN32_LEAN_AND_MEAN
            NOMINMAX
            _WIN32_WINNT=0x0A00
            WINVER=0x0A00
            SECURITY_WIN32
        )
    endif()
endfunction()

# ---- Testing ----
include(CTest)

# ---- Subdirectories ----
add_subdirectory(windows/SolStreamAgent)
add_subdirectory(windows/CaptureHelper)
# windows/sunshine is deliberately NOT built — see its README. It builds a
# sunshine_fork static library that nothing links, left over from an approach
# that was abandoned once it turned out Sunshine only needs configuring.
add_subdirectory(windows/ClipboardMonitor)
add_subdirectory(windows/InputInjector)
add_subdirectory(windows/FileTransferService)

if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
