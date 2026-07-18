# SolStream API — HTTP route handlers for Sunshine web server

target_sources(sunshine_fork PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/api/solstream_api.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/api/solstream_api.h
)

target_include_directories(sunshine_fork PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/api
)

# Link psapi for EnumProcessModules / QueryFullProcessImageName
target_link_libraries(sunshine_fork PUBLIC
    psapi.lib
)
