# There are no C++ tests, and this directory no longer pretends there are.
#
# It used to fetch GoogleTest — a 30 MB archive downloaded and built at configure
# time — and define an add_solstream_test() helper on top of it. Nothing ever
# called the helper, no test executable was ever declared, and so the dependency
# was fetched and compiled for a suite of exactly zero tests. An unused
# dependency that nothing links is worse than no scaffolding at all: it costs
# every configure, it has to be kept in step with the toolchain, and it makes the
# tree look as though a C++ suite exists to be run.
#
# The tests that do exist are the Swift ones in
# macos/SolStreamClient/Tests/SolStreamClientTests, run with `swift test`. The
# Windows side is verified by running it, which docs/architecture.md is honest
# about under "What is measured, and what is not".
#
# This file stays behind as a comment rather than being deleted because the
# top-level CMakeLists.txt still does add_subdirectory(tests) inside
# if(BUILD_TESTING), and CMake fails outright on a directory with no
# CMakeLists.txt in it. BUILD_TESTING becomes ON by default the moment
# include(CTest) runs, so deleting this file would break a plain
# `cmake -S . -B build` on a fresh clone.
#
# If C++ tests are written, fetch the framework here at that point, for the
# targets that will actually link it.
