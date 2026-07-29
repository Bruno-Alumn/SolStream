#include "log.h"

#include <cstdarg>
#include <cstdio>

namespace solstream::media {
namespace {

LogFn g_logger = nullptr;

}  // namespace

void SetLogger(LogFn logger) { g_logger = logger; }

void Log(const char* format, ...) {
    char line[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(line, sizeof(line), format, args);
    va_end(args);
    if (g_logger) {
        g_logger(line);
    } else {
        std::fprintf(stderr, "%s\n", line);
    }
}

}  // namespace solstream::media
