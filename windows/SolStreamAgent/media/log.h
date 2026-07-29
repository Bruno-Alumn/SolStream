// log.h — the media path's line into the agent's log file.
//
// The agent's own Log() has internal linkage, and reaching across a translation
// unit boundary into an anonymous namespace is not something to arrange with a
// declaration that happens to match. A function pointer set once at startup
// says what is actually happening: the media path does not know where its lines
// go, and the agent decides.

#pragma once

namespace solstream::media {

using LogFn = void (*)(const char* line);

/// Called once by the agent. Until then, lines go to stderr, which is what a
/// development build has and an installed one does not.
void SetLogger(LogFn logger);

void Log(const char* format, ...);

}  // namespace solstream::media
