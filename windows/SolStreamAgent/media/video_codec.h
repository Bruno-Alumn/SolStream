// video_codec.h — which video codec a session uses, and how to read its NALs.
//
// H.264 is what every Mac and every host has always spoken. HEVC is offered by
// a Mac in `media open` as `"videoCodecs":"hevc,h264"`, most wanted first, and
// the host answers with the one it chose in `"videoCodec"`. Either end may be
// older than the field: a Mac that sends nothing gets H.264, and a host that
// answers nothing is taken by the Mac to be sending it. See
// docs/transport-smt1.md.
//
// Apart from encoder.cpp, which builds only with MSVC, so the test program can
// check it.

#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace solstream::media {

enum class VideoCodec { H264, Hevc };

/// The name on the wire and in the log.
constexpr const char* VideoCodecName(VideoCodec codec) {
    return codec == VideoCodec::Hevc ? "hevc" : "h264";
}

/// The Mac's `videoCodecs`, most wanted first. Names this host does not know
/// are skipped, and so are repeats. Empty or absent -- every Mac that predates
/// the field -- is H.264 alone, which is what such a Mac decodes.
inline std::vector<VideoCodec> ParseVideoCodecs(const std::string& field) {
    std::vector<VideoCodec> codecs;
    size_t start = 0;
    while (start <= field.size()) {
        size_t end = field.find(',', start);
        if (end == std::string::npos) { end = field.size(); }
        std::string name = field.substr(start, end - start);
        while (!name.empty() && name.front() == ' ') { name.erase(name.begin()); }
        while (!name.empty() && name.back() == ' ') { name.pop_back(); }
        VideoCodec codec = VideoCodec::H264;
        bool known = true;
        if (name == "hevc" || name == "h265") {
            codec = VideoCodec::Hevc;
        } else if (name == "h264") {
            codec = VideoCodec::H264;
        } else {
            known = false;
        }
        if (known) {
            bool repeated = false;
            for (VideoCodec seen : codecs) { repeated = repeated || seen == codec; }
            if (!repeated) { codecs.push_back(codec); }
        }
        start = end + 1;
    }
    if (codecs.empty()) { codecs.push_back(VideoCodec::H264); }
    return codecs;
}

/// The codec to encode with: the Mac's first choice that this PC can encode in
/// hardware. H.264 is always possible -- Windows ships a software encoder for
/// it -- so it is the answer when nothing the Mac offered is, even a Mac that
/// left it out of its list.
inline VideoCodec ChooseVideoCodec(const std::vector<VideoCodec>& offered,
                                   bool hardwareHevc) {
    for (VideoCodec codec : offered) {
        if (codec == VideoCodec::H264) { return codec; }
        if (codec == VideoCodec::Hevc && hardwareHevc) { return codec; }
    }
    return VideoCodec::H264;
}

/// The type of the NAL unit whose header starts at `header`.
inline int NalType(VideoCodec codec, const unsigned char* header) {
    return codec == VideoCodec::Hevc ? (header[0] >> 1) & 0x3F : header[0] & 0x1F;
}

/// The first parameter set a picture that restarts decoding has to carry:
/// H.264's SPS, HEVC's VPS.
inline bool IsLeadingParameterSet(VideoCodec codec, int type) {
    return codec == VideoCodec::Hevc ? type == 32 : type == 7;
}

/// A picture that decoding can start from: H.264's IDR slice, or one of
/// HEVC's IRAP pictures -- BLA, IDR_W_RADL, IDR_N_LP and CRA, types 16-21.
/// Nothing in this stream refers back past any of them, which is what makes
/// each one a keyframe as far as the Mac's hold and reassembly are concerned.
inline bool IsKeyframeNal(VideoCodec codec, int type) {
    return codec == VideoCodec::Hevc ? type >= 16 && type <= 21 : type == 5;
}

/// A unit carrying picture data rather than parameters or side information.
inline bool IsSliceNal(VideoCodec codec, int type) {
    return codec == VideoCodec::Hevc ? type <= 31 : type >= 1 && type <= 5;
}

/// Call `visit(type)` for each NAL unit of an Annex B buffer, in order, until
/// it returns false.
template <typename Visit>
void ForEachNal(VideoCodec codec, const unsigned char* data, size_t length, Visit visit) {
    // HEVC's NAL header is two bytes, H.264's one; a unit shorter than that is
    // not one.
    const size_t header = codec == VideoCodec::Hevc ? 2 : 1;
    size_t i = 0;
    while (i + 3 + header <= length) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
            if (!visit(NalType(codec, data + i + 3))) { return; }
            i += 3 + header;
            continue;
        }
        ++i;
    }
}

/// Does this Annex B buffer start with the parameter sets a joining decoder
/// needs: an SPS for H.264, a VPS for HEVC?
///
/// An IDR without them in front of it is undecodable by a receiver that has
/// just joined, and whether the encoder inlines them is a per-driver choice
/// rather than a guarantee. Checking is three lines; assuming is a black
/// picture on somebody else's machine.
inline bool StartsWithParameterSets(VideoCodec codec, const unsigned char* data,
                                    size_t length) {
    bool starts = false;
    ForEachNal(codec, data, length, [&](int type) {
        starts = IsLeadingParameterSet(codec, type);
        return false;
    });
    return starts;
}

/// Is this Annex B buffer a picture decoding can start from? Decided by its
/// first slice, since every slice of a picture has the same type, so a P-frame
/// is read only as far as its own first slice header.
inline bool ContainsKeyframe(VideoCodec codec, const unsigned char* data, size_t length) {
    bool found = false;
    ForEachNal(codec, data, length, [&](int type) {
        if (!IsSliceNal(codec, type)) { return true; }
        found = IsKeyframeNal(codec, type);
        return false;
    });
    return found;
}

}  // namespace solstream::media
