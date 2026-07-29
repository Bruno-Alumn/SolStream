# The two halves of SMT/1's key schedule have to agree byte for byte before a
# socket exists, because the way they disagree is silent. See vectors.cpp.
#
#   cmake -S spike/smt-vectors -B build/smt-vectors
#   cmake --build build/smt-vectors --config Release
cmake_minimum_required(VERSION 3.20)
project(SolStreamSmtVectors CXX)

add_executable(smt-vectors vectors.cpp)
set_target_properties(smt-vectors PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_compile_definitions(smt-vectors PRIVATE UNICODE _UNICODE)
if(MSVC)
    target_compile_options(smt-vectors PRIVATE /W4 /permissive- /utf-8)
endif()
target_link_libraries(smt-vectors PRIVATE bcrypt)
