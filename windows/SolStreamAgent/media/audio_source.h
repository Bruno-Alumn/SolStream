// audio_source.h — whose sound the host says it will send.
//
// Capturing one process's sound takes Windows' process loopback, which came
// with build 20348; every consumer Windows 10 is older. There the host sends
// the whole PC's sound whatever it was asked, and it used to answer a request
// for the streamed apps' with "apps" all the same. The Mac then said in its
// settings that notifications and music stayed on the PC while it played them,
// and its own check for a host that sends everything could never fire. The
// answer is now what will be sent.
//
// Apart from audio.cpp, which builds only with MSVC, so the test program can
// check it.

#pragma once

namespace solstream::media {

/// Whether a Windows of this version captures one process's sound.
constexpr bool VersionHasAppSound(unsigned long major, unsigned long build) {
    return major > 10 || (major == 10 && build >= 20348);
}

/// The `audioSource` a `media open` reply carries: "apps" only when the
/// streamed apps' sound was asked for and this Windows can capture it.
constexpr const char* AudioSourceReply(bool askedForApps, bool appSoundSupported) {
    return askedForApps && appSoundSupported ? "apps" : "system";
}

}  // namespace solstream::media
