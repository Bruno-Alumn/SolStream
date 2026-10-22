#include "audio.h"

#include <mmreg.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <objbase.h>
#include <opus.h>
#include "log.h"

#include <algorithm>
#include <cstring>
#include <vector>


namespace solstream::media {
namespace {

/// How often the endpoint is polled, and the length of a PCM packet: 960
/// bytes of stereo S16, one datagram. An Opus packet is as long as the Mac
/// asked for.
constexpr int kPacketMs = 5;

/// The most libopus will put in one packet whatever it is asked for, and well
/// inside one datagram.
constexpr int kMaxOpusPacket = 1275;

template <typename T>
void Release(T*& p) {
    if (p) { p->Release(); p = nullptr; }
}

int16_t Clamp16(float value) {
    const float scaled = value * 32767.0f;
    if (scaled > 32767.0f) { return 32767; }
    if (scaled < -32768.0f) { return -32768; }
    return (int16_t) scaled;
}

/// Convert whatever the endpoint's mix format is into interleaved stereo float.
///
/// The mix format is float32 on every machine this has been run on, but it is
/// not guaranteed to be, and a host that assumes it produces white noise rather
/// than an error -- which is the worst possible way to be wrong about audio.
///
/// It is also not guaranteed to be 48 kHz stereo. The dev box's endpoint reports
/// **96 kHz, 8 channels, 32 bits**, and a host that shipped those samples
/// untouched would have the Mac play them at half speed through the first two
/// of eight channels. Front left and right are always the first two channels in
/// a WAVEFORMATEXTENSIBLE layout, so taking them is a correct downmix rather
/// than an arbitrary one; the rate is dealt with by the resampler below.
void Convert(const WAVEFORMATEX* format, const unsigned char* source, UINT32 frames,
             std::vector<float>& out) {
    const int channels = format->nChannels;
    out.resize((size_t) frames * 2);

    // The extensible subformat GUID's first word IS the old format tag --
    // {00000003-0000-0010-8000-00aa00389b71} is IEEE float -- so this needs
    // neither ksmedia.h nor a GUID comparison to answer the only question here.
    const bool isFloat =
        format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT
        || (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE
            && ((const WAVEFORMATEXTENSIBLE*) format)->SubFormat.Data1
                   == WAVE_FORMAT_IEEE_FLOAT);

    for (UINT32 i = 0; i < frames; ++i) {
        float left = 0.0f, right = 0.0f;
        if (isFloat && format->wBitsPerSample == 32) {
            const float* samples = (const float*) source + (size_t) i * channels;
            left = samples[0];
            right = channels > 1 ? samples[1] : samples[0];
        } else if (format->wBitsPerSample == 16) {
            const int16_t* samples = (const int16_t*) source + (size_t) i * channels;
            left = samples[0] / 32768.0f;
            right = channels > 1 ? samples[1] / 32768.0f : left;
        } else if (format->wBitsPerSample == 32) {
            const int32_t* samples = (const int32_t*) source + (size_t) i * channels;
            left = (float) samples[0] / 2147483648.0f;
            right = channels > 1 ? (float) samples[1] / 2147483648.0f : left;
        }
        out[(size_t) i * 2] = left;
        out[(size_t) i * 2 + 1] = right;
    }
}

/// Resampling to 48 kHz by area averaging, with the part-finished output sample
/// carried across calls.
///
/// Every output sample covers `ratio` input frames and is their mean: at 96 kHz
/// the mean of two, at 192 kHz the mean of four, and at 48 kHz the ratio is 1 so
/// each input frame passes through unchanged. Where a boundary falls inside an
/// input frame -- 44.1 kHz, or any rate that is not a whole multiple of 48 kHz --
/// that frame is split between the two output samples it straddles in
/// proportion, so no input is dropped and none is counted twice.
///
/// This was linear interpolation, with a comment saying that at ratio 2 it took
/// the mean of two inputs and so acted as a two-tap decimation filter. It did
/// not. The read position advanced by exactly 2.0 each time, so the
/// interpolation fraction was always zero and every second input frame was
/// handed out untouched: nearest-sample decimation, with nothing at all between
/// a 96 kHz mix and a 24 kHz Nyquist to keep content above it from folding back
/// into the audible band. Nobody noticed because a desktop mix has almost no
/// energy up there, which is exactly the sort of wrong that survives.
///
/// A boxcar mean of N is a poor anti-alias filter. It is a real one, which is
/// the difference that matters here. Anything better would mean the Media
/// Foundation resampler MFT and a second pipeline to keep alive for a case that
/// has not been observed.
struct Resampler {
    /// The output sample being built: the input it has covered so far, each
    /// frame weighted by how much of it belongs to this sample, and how wide
    /// that coverage has become. Both are carried between calls because a WASAPI
    /// buffer boundary falls wherever it likes, and an output sample that
    /// straddles one must not be emitted twice or cut short.
    double sumLeft = 0.0, sumRight = 0.0;
    double filled = 0.0;

    void Run(const std::vector<float>& in, double ratio, std::vector<float>& out) {
        const size_t frames = in.size() / 2;
        // The ratio comes from the endpoint's declared sample rate. Written as
        // `!(ratio > 0.0)` so a rate of zero, or a NaN out of a broken driver,
        // leaves rather than spins in the loop below asking for a bucket that
        // can never fill.
        if (frames == 0 || !(ratio > 0.0)) { return; }
        for (size_t i = 0; i < frames; ++i) {
            const double left = in[i * 2];
            const double right = in[i * 2 + 1];
            // One whole input frame, given out in pieces to however many output
            // samples it spans: one, two where a boundary falls inside it, and
            // more than that only when the endpoint runs below 48 kHz.
            double remaining = 1.0;
            while (remaining > 0.0) {
                const double wanted = ratio - filled;
                const double take = wanted < remaining ? wanted : remaining;
                sumLeft += left * take;
                sumRight += right * take;
                filled += take;
                remaining -= take;
                // Finished to within rounding counts as finished. Without the
                // epsilon a bucket that lands a hair short of `ratio` would drag
                // a sliver of the next input frame in behind it, for no audible
                // gain and one more trip round this loop every time.
                if (filled + 1e-12 >= ratio) {
                    out.push_back((float) (sumLeft / filled));
                    out.push_back((float) (sumRight / filled));
                    sumLeft = sumRight = 0.0;
                    filled = 0.0;
                }
            }
        }
    }
};

/// libopus, set up the way the stream wants it, or null with the reason
/// logged -- in which case the session sends PCM, which every Mac plays.
OpusEncoder* OpenOpus(const AudioEncoding& encoding) {
    int error = OPUS_OK;
    // RESTRICTED_LOWDELAY is CELT only, with the shortest lookahead Opus has:
    // 2.5 ms. AUDIO would add SILK's 4 ms on top for the speech modes, which
    // at these bitrates and with a game or a film playing it would never pick.
    OpusEncoder* encoder =
        opus_encoder_create(48000, 2, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &error);
    if (!encoder || error != OPUS_OK) {
        Log("[media] the Opus encoder would not open (%s); sending PCM", opus_strerror(error));
        if (encoder) { opus_encoder_destroy(encoder); }
        return nullptr;
    }
    opus_encoder_ctl(encoder, OPUS_SET_BITRATE((opus_int32) encoding.bitrate));
    // Constrained, so a loud passage cannot burst past the rate the Mac chose
    // -- the reason it chose one -- while a quiet one still costs less.
    opus_encoder_ctl(encoder, OPUS_SET_VBR_CONSTRAINT(1));
    opus_encoder_ctl(encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC));
    opus_int32 lookahead = 0;
    opus_encoder_ctl(encoder, OPUS_GET_LOOKAHEAD(&lookahead));
    Log("[media] audio as Opus %u kbit/s in %u ms packets, %d samples of lookahead (%s)",
        encoding.bitrate / 1000, encoding.frameMs, (int) lookahead, opus_get_version_string());
    return encoder;
}

}  // namespace

void AudioCapture::Stop() { stop_.store(true); }

void AudioCapture::Run(const AudioEncoding& encoding, Sink sink,
                       std::function<bool()> keepGoing) {
    stop_.store(false);
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool ownsCom = SUCCEEDED(com);

    IMMDeviceEnumerator* enumerator = nullptr;
    IMMDevice* device = nullptr;
    IAudioClient* client = nullptr;
    IAudioCaptureClient* capture = nullptr;
    WAVEFORMATEX* format = nullptr;

    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                  __uuidof(IMMDeviceEnumerator), (void**) &enumerator);
    if (SUCCEEDED(hr)) {
        hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    }
    if (SUCCEEDED(hr)) {
        hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**) &client);
    }
    if (SUCCEEDED(hr)) {
        hr = client->GetMixFormat(&format);
    }
    if (SUCCEEDED(hr)) {
        // LOOPBACK, so what is captured is what the speakers are being sent --
        // including the audio of the application being streamed, which is the
        // whole point. A 200 ms buffer is far more than the 5 ms packets need
        // and costs nothing, because it is drained every poll.
        hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
                                2000000, 0, format, nullptr);
    }
    if (SUCCEEDED(hr)) {
        hr = client->GetService(__uuidof(IAudioCaptureClient), (void**) &capture);
    }
    if (SUCCEEDED(hr)) {
        hr = client->Start();
    }
    if (FAILED(hr)) {
        Log("[media] audio loopback unavailable (0x%08lX); streaming video only", hr);
        Release(capture);
        Release(client);
        Release(device);
        Release(enumerator);
        if (format) { CoTaskMemFree(format); }
        if (ownsCom) { CoUninitialize(); }
        return;
    }

    started_.store(true);
    Log("[media] audio loopback at %lu Hz, %u channels, %u bits",
        format->nSamplesPerSec, format->nChannels, format->wBitsPerSample);

    // What goes on the wire is always 48 kHz stereo, whatever the endpoint is
    // running at. The Mac's renderer is fixed at 48 kHz, and a rate field it
    // ignores would be a silent half-speed bug rather than a loud one. It is
    // also the rate Opus works at internally, so it resamples nothing.
    constexpr uint32_t kWireRate = 48000;
    const double ratio = (double) format->nSamplesPerSec / (double) kWireRate;
    Resampler resampler;

    OpusEncoder* opus =
        encoding.codec == AudioEncoding::Codec::Opus ? OpenOpus(encoding) : nullptr;
    const unsigned char wireFormat = opus ? 2 : 1;
    // PCM stays at 5 ms whatever was asked: 10 ms of it is 1920 bytes, which no
    // longer fits in a datagram.
    const size_t framesPerPacket =
        (size_t) kWireRate * (opus ? encoding.frameMs : kPacketMs) / 1000;
    unsigned char encoded[kMaxOpusPacket];
    uint64_t encodeFailures = 0;

    LARGE_INTEGER frequency{}, started{};
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&started);

    std::vector<float> converted, pending;
    std::vector<int16_t> packet;
    uint32_t seq = 1;

    while (!stop_.load() && keepGoing()) {
        UINT32 available = 0;
        if (FAILED(capture->GetNextPacketSize(&available)) || available == 0) {
            Sleep(kPacketMs);
            continue;
        }
        while (available > 0) {
            BYTE* data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) {
                break;
            }
            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
                // Nothing is playing. Sending digital silence would cost 1.5
                // Mbit/s to transmit nothing; the Mac plays silence when its
                // queue runs dry, which is the same result for no bytes.
                silent_.fetch_add(1);
            } else if (frames > 0) {
                Convert(format, data, frames, converted);
                resampler.Run(converted, ratio, pending);
            }
            capture->ReleaseBuffer(frames);
            if (FAILED(capture->GetNextPacketSize(&available))) {
                break;
            }
        }

        while (pending.size() >= framesPerPacket * 2) {
            LARGE_INTEGER now{};
            QueryPerformanceCounter(&now);
            const uint32_t timestampUs = (uint32_t)
                ((now.QuadPart - started.QuadPart) * 1000000 / frequency.QuadPart);
            if (opus) {
                // Float straight in: Opus would only turn S16 back into float.
                const opus_int32 length = opus_encode_float(
                    opus, pending.data(), (int) framesPerPacket, encoded,
                    (opus_int32) sizeof(encoded));
                if (length > 0) {
                    sink(encoded, (size_t) length, seq++, timestampUs, kWireRate, 2, wireFormat);
                    packets_.fetch_add(1);
                } else if (++encodeFailures == 1 || encodeFailures % 1000 == 0) {
                    // Losing a packet loses its 10 ms and nothing else, so this
                    // is said, not acted on -- once, then every thousandth.
                    Log("[media] Opus could not encode a packet (%s); %llu so far",
                        opus_strerror((int) length), (unsigned long long) encodeFailures);
                }
            } else {
                packet.resize(framesPerPacket * 2);
                for (size_t i = 0; i < packet.size(); ++i) {
                    packet[i] = Clamp16(pending[i]);
                }
                sink((const unsigned char*) packet.data(), packet.size() * sizeof(int16_t),
                     seq++, timestampUs, kWireRate, 2, wireFormat);
                packets_.fetch_add(1);
            }
            pending.erase(pending.begin(), pending.begin() + framesPerPacket * 2);
        }
    }

    client->Stop();
    started_.store(false);
    if (opus) { opus_encoder_destroy(opus); }
    Release(capture);
    Release(client);
    Release(device);
    Release(enumerator);
    if (format) { CoTaskMemFree(format); }
    if (ownsCom) { CoUninitialize(); }
}

}  // namespace solstream::media
