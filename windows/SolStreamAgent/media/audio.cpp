#include "audio.h"

#include <mmreg.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <objbase.h>
#include <audioclientactivationparams.h>
#include <opus.h>
#include "audio_reopen.h"
#include "audio_source.h"
#include "log.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <string>
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

/// What goes on the wire is always 48 kHz stereo, whatever the endpoint runs at.
constexpr uint32_t kWireRate = 48000;

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

// ── Encoding and sending ────────────────────────────────────────────────────

/// 48 kHz stereo float in, packets out: PCM or Opus, as the Mac asked.
///
/// Shared by both sources below, which differ only in where the samples come
/// from. A packet that is nothing but digital zero is not sent at all, whatever
/// the source: an app capture delivers its silences as zeros rather than with
/// AUDCLNT_BUFFERFLAGS_SILENT, and sending them would cost Lossless 1.6 Mbit/s
/// to transmit nothing. The Mac plays silence when its queue runs dry, which is
/// the same result for no bytes.
class Packetizer {
public:
    Packetizer(const AudioEncoding& encoding, const AudioCapture::Sink& sink,
               std::atomic<uint64_t>& packets, std::atomic<uint64_t>& silent)
        : sink_(sink), packets_(packets), silent_(silent) {
        opus_ = encoding.codec == AudioEncoding::Codec::Opus ? OpenOpus(encoding) : nullptr;
        format_ = opus_ ? 2 : 1;
        // PCM stays at 5 ms whatever was asked: 10 ms of it is 1920 bytes, which
        // no longer fits in a datagram.
        frames_ = (size_t) kWireRate * (opus_ ? encoding.frameMs : kPacketMs) / 1000;
        QueryPerformanceFrequency(&frequency_);
        QueryPerformanceCounter(&started_);
    }
    ~Packetizer() {
        if (opus_) { opus_encoder_destroy(opus_); }
    }
    Packetizer(const Packetizer&) = delete;
    Packetizer& operator=(const Packetizer&) = delete;

    /// Send every whole packet `pending` holds, and keep the remainder.
    void Drain(std::vector<float>& pending) {
        const size_t samples = frames_ * 2;
        size_t at = 0;
        for (; pending.size() - at >= samples; at += samples) {
            const float* chunk = pending.data() + at;
            if (std::all_of(chunk, chunk + samples, [](float v) { return v == 0.0f; })) {
                silent_.fetch_add(1);
                continue;
            }
            LARGE_INTEGER now{};
            QueryPerformanceCounter(&now);
            const uint32_t timestampUs = (uint32_t)
                ((now.QuadPart - started_.QuadPart) * 1000000 / frequency_.QuadPart);
            if (opus_) {
                // Float straight in: Opus would only turn S16 back into float.
                const opus_int32 length = opus_encode_float(
                    opus_, chunk, (int) frames_, encoded_, (opus_int32) sizeof(encoded_));
                if (length > 0) {
                    sink_(encoded_, (size_t) length, seq_++, timestampUs, kWireRate, 2, format_);
                    packets_.fetch_add(1);
                } else if (++encodeFailures_ == 1 || encodeFailures_ % 1000 == 0) {
                    // Losing a packet loses its 10 ms and nothing else, so this
                    // is said, not acted on -- once, then every thousandth.
                    Log("[media] Opus could not encode a packet (%s); %llu so far",
                        opus_strerror((int) length), (unsigned long long) encodeFailures_);
                }
            } else {
                packet_.resize(samples);
                for (size_t i = 0; i < samples; ++i) {
                    packet_[i] = Clamp16(chunk[i]);
                }
                sink_((const unsigned char*) packet_.data(), samples * sizeof(int16_t),
                      seq_++, timestampUs, kWireRate, 2, format_);
                packets_.fetch_add(1);
            }
        }
        pending.erase(pending.begin(), pending.begin() + at);
    }

private:
    const AudioCapture::Sink& sink_;
    std::atomic<uint64_t>& packets_;
    std::atomic<uint64_t>& silent_;
    OpusEncoder* opus_ = nullptr;
    unsigned char format_ = 1;
    size_t frames_ = 0;
    unsigned char encoded_[kMaxOpusPacket];
    std::vector<int16_t> packet_;
    uint64_t encodeFailures_ = 0;
    uint32_t seq_ = 1;
    LARGE_INTEGER frequency_{}, started_{};
};

// ── One app's sound ──────────────────────────────────────────────────────────
//
// PROCESS LOOPBACK, which Windows has had since build 20348 -- every Windows 11:
// the sound of one process and everything it started, and nothing else. A
// browser's audio comes from a child process of the browser, so the tree is
// what is wanted rather than the one process.
//
// Measured on the dev box before this was written, because the design hangs on
// it: a tap delivers continuously, 100 buffers a second, whether its app is
// playing or not, and a silent app's buffers are zeros WITHOUT the silent flag.
// So the taps of several apps run in step and can simply be added together,
// and the packetizer's zero check is what keeps a quiet app off the wire. The
// endpoint's mix format does not apply -- GetMixFormat answers E_NOTIMPL -- so
// the tap is asked for the wire format itself and needs no resampling.

/// The completion handler ActivateAudioInterfaceAsync calls back on a thread of
/// its own. It has to be agile, which answering for IAgileObject declares.
class Activation final : public IActivateAudioInterfaceCompletionHandler, public IAgileObject {
public:
    Activation() : done(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}

    HANDLE done;
    HRESULT result = E_FAIL;

    /// The activated client, once `done` is set, for the caller to own.
    IAudioClient* Take() {
        IAudioClient* taken = client_;
        client_ = nullptr;
        return taken;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG) InterlockedIncrement(&refs_); }
    ULONG STDMETHODCALLTYPE Release() override {
        const LONG left = InterlockedDecrement(&refs_);
        if (left == 0) { delete this; }
        return (ULONG) left;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IActivateAudioInterfaceCompletionHandler)) {
            *out = static_cast<IActivateAudioInterfaceCompletionHandler*>(this);
        } else if (iid == __uuidof(IAgileObject)) {
            *out = static_cast<IAgileObject*>(this);
        } else {
            *out = nullptr;
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE ActivateCompleted(IActivateAudioInterfaceAsyncOperation* op) override {
        HRESULT activated = E_FAIL;
        IUnknown* unknown = nullptr;
        HRESULT hr = op->GetActivateResult(&activated, &unknown);
        if (SUCCEEDED(hr)) { hr = activated; }
        if (SUCCEEDED(hr) && unknown) {
            hr = unknown->QueryInterface(__uuidof(IAudioClient), (void**) &client_);
        }
        if (unknown) { unknown->Release(); }
        result = hr;
        SetEvent(done);
        return S_OK;
    }

private:
    // A handler whose caller gave up waiting is released by the operation
    // when it finally completes, and takes the client with it.
    ~Activation() {
        if (client_) { client_->Release(); }
        if (done) { CloseHandle(done); }
    }
    LONG refs_ = 1;
    IAudioClient* client_ = nullptr;
};

/// One wanted app's capture. Kept while the app is wanted even when the tap
/// stops working -- the audio service restarted, say -- with `client` null
/// until it opens again; see RunApps.
struct ProcessTap {
    DWORD pid = 0;
    IAudioClient* client = nullptr;
    IAudioCaptureClient* capture = nullptr;
    HANDLE ready = nullptr;
    /// Stereo frames read and not yet mixed.
    std::vector<float> queued;
    ReadTrouble trouble;
    Reopener reopen;
};

void CloseTap(ProcessTap& tap) {
    if (tap.client) { tap.client->Stop(); }
    Release(tap.capture);
    Release(tap.client);
    if (tap.ready) { CloseHandle(tap.ready); tap.ready = nullptr; }
    tap.queued.clear();
}

HRESULT OpenTap(DWORD pid, ProcessTap& tap) {
    AUDIOCLIENT_ACTIVATION_PARAMS params{};
    params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    params.ProcessLoopbackParams.TargetProcessId = pid;
    params.ProcessLoopbackParams.ProcessLoopbackMode =
        PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
    PROPVARIANT variant{};
    variant.vt = VT_BLOB;
    variant.blob.cbSize = sizeof(params);
    variant.blob.pBlobData = (BYTE*) &params;

    Activation* handler = new Activation();
    IActivateAudioInterfaceAsyncOperation* operation = nullptr;
    HRESULT hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
                                             __uuidof(IAudioClient), &variant, handler,
                                             &operation);
    if (SUCCEEDED(hr)) {
        // Measured at well under a millisecond. The bound is for a wedged
        // audio service, which must not take the audio thread down with it.
        hr = WaitForSingleObject(handler->done, 2000) == WAIT_OBJECT_0
                 ? handler->result : HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    }
    tap.pid = pid;
    tap.client = SUCCEEDED(hr) ? handler->Take() : nullptr;
    if (operation) { operation->Release(); }
    handler->Release();
    if (SUCCEEDED(hr) && !tap.client) { hr = E_NOINTERFACE; }

    if (SUCCEEDED(hr)) {
        WAVEFORMATEX format{};
        format.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
        format.nChannels = 2;
        format.nSamplesPerSec = kWireRate;
        format.wBitsPerSample = 32;
        format.nBlockAlign = 8;
        format.nAvgBytesPerSec = kWireRate * 8;
        // Event-driven, as a process tap has to be, with 20 ms of buffer:
        // twice the engine's period, drained every period.
        hr = tap.client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                    AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK
                                        | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
                                        | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                                    200000, 0, &format, nullptr);
    }
    if (SUCCEEDED(hr)) {
        tap.ready = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        hr = tap.ready ? tap.client->SetEventHandle(tap.ready) : HRESULT_FROM_WIN32(GetLastError());
    }
    if (SUCCEEDED(hr)) {
        hr = tap.client->GetService(__uuidof(IAudioCaptureClient), (void**) &tap.capture);
    }
    if (SUCCEEDED(hr)) {
        hr = tap.client->Start();
    }
    if (FAILED(hr)) { CloseTap(tap); }
    return hr;
}

/// Everything a tap has delivered, onto the end of its queue. A buffer
/// flagged silent still holds its place in time, as zeros, so the apps
/// being mixed stay in step. Returns the failure that stopped the reading, if
/// one did: a tap whose reads fail has stopped delivering, and treating that
/// as nothing yet kept the app silent until the set of windows changed.
HRESULT ReadTap(ProcessTap& tap) {
    UINT32 available = 0;
    HRESULT hr = tap.capture->GetNextPacketSize(&available);
    while (SUCCEEDED(hr) && available > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        hr = tap.capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
        if (FAILED(hr)) {
            break;
        }
        const size_t at = tap.queued.size();
        tap.queued.resize(at + (size_t) frames * 2, 0.0f);
        if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT) && frames > 0) {
            memcpy(tap.queued.data() + at, data, (size_t) frames * 2 * sizeof(float));
        }
        tap.capture->ReleaseBuffer(frames);
        hr = tap.capture->GetNextPacketSize(&available);
    }
    return hr;
}

/// How many of the wanted apps are being heard, for the five-second line.
int OpenTaps(const std::vector<ProcessTap>& taps) {
    return (int) std::count_if(taps.begin(), taps.end(),
                               [](const ProcessTap& tap) { return tap.client != nullptr; });
}

/// How far one tap may run ahead of another before the one behind is counted
/// as silent for the difference: three engine periods. Taps deliver in step,
/// so this is reached only by an app that has stalled or is going away, and it
/// must not hold up the others' sound while it does.
constexpr size_t kMixSlackFrames = kWireRate * 30 / 1000;

/// Every tap's sound added together, as far as all of them have reached. A
/// tap waiting to open again has nothing queued and is left out of the reckoning,
/// or it would hold the others back by the whole of kMixSlackFrames.
void Mix(std::vector<ProcessTap>& taps, std::vector<float>& out) {
    size_t least = SIZE_MAX, most = 0;
    for (const ProcessTap& tap : taps) {
        if (!tap.client) { continue; }
        const size_t frames = tap.queued.size() / 2;
        least = frames < least ? frames : least;
        most = frames > most ? frames : most;
    }
    if (least == SIZE_MAX) { return; }
    size_t frames = least;
    if (most > least + kMixSlackFrames) { frames = most - kMixSlackFrames; }
    if (frames == 0) { return; }
    const size_t base = out.size();
    out.resize(base + frames * 2, 0.0f);
    for (ProcessTap& tap : taps) {
        const size_t take = frames * 2 < tap.queued.size() ? frames * 2 : tap.queued.size();
        for (size_t i = 0; i < take; ++i) {
            out[base + i] += tap.queued[i];
        }
        tap.queued.erase(tap.queued.begin(), tap.queued.begin() + take);
    }
}

/// The name of a process's executable, for the log.
std::string ProcessName(DWORD pid) {
    std::string name = "pid " + std::to_string(pid);
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) { return name; }
    wchar_t path[MAX_PATH];
    DWORD length = MAX_PATH;
    if (QueryFullProcessImageNameW(process, 0, path, &length)) {
        const wchar_t* base = wcsrchr(path, L'\\');
        char narrow[MAX_PATH];
        if (WideCharToMultiByte(CP_UTF8, 0, base ? base + 1 : path, -1, narrow, sizeof(narrow),
                                nullptr, nullptr) > 0) {
            name = std::string(narrow) + " (" + std::to_string(pid) + ")";
        }
    }
    CloseHandle(process);
    return name;
}

/// Whether this Windows can capture one process's sound: build 20348 or
/// later. Asked of ntdll, because GetVersionEx lies to an executable whose
/// manifest does not name the version it is running on.
bool HasProcessLoopback() {
    using RtlGetVersionFn = LONG(WINAPI*)(OSVERSIONINFOW*);
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    auto rtlGetVersion = ntdll
        ? reinterpret_cast<RtlGetVersionFn>(
              reinterpret_cast<void*>(GetProcAddress(ntdll, "RtlGetVersion")))
        : nullptr;
    OSVERSIONINFOW version{};
    version.dwOSVersionInfoSize = sizeof(version);
    return rtlGetVersion && rtlGetVersion(&version) == 0
        && VersionHasAppSound(version.dwMajorVersion, version.dwBuildNumber);
}

/// The streamed apps' sound, and nothing else, until `running` says stop.
void RunApps(const AudioCapture::Processes& processes, Packetizer& packetizer,
             const std::function<bool()>& running, std::atomic<int>& appSources) {
    std::vector<ProcessTap> taps;
    std::vector<DWORD> current;
    std::vector<HANDLE> events;
    std::vector<float> pending;
    ULONGLONG nextCheck = 0;
    Log("[media] audio from the streamed apps only");

    while (running()) {
        // The streamed windows come and go during a session -- the Mac places
        // them after the session opens, and closes and adds them as it likes --
        // so which apps to hear is asked again four times a second.
        const ULONGLONG now = GetTickCount64();
        if (now >= nextCheck) {
            nextCheck = now + 250;
            std::vector<DWORD> wanted;
            for (unsigned long pid : processes()) {
                if (pid != 0 && pid != GetCurrentProcessId()) { wanted.push_back((DWORD) pid); }
            }
            std::sort(wanted.begin(), wanted.end());
            wanted.erase(std::unique(wanted.begin(), wanted.end()), wanted.end());
            if (wanted != current) {
                // Kept where still wanted, so an app that stays does not lose a
                // beat when another joins it.
                const auto unwanted = [&wanted](const ProcessTap& tap) {
                    return !std::binary_search(wanted.begin(), wanted.end(), tap.pid);
                };
                for (ProcessTap& tap : taps) {
                    if (unwanted(tap)) {
                        Log("[media] no longer hearing %s", ProcessName(tap.pid).c_str());
                        CloseTap(tap);
                    }
                }
                taps.erase(std::remove_if(taps.begin(), taps.end(), unwanted), taps.end());
                for (DWORD pid : wanted) {
                    const bool have = std::any_of(taps.begin(), taps.end(),
                                                  [pid](const ProcessTap& tap) { return tap.pid == pid; });
                    if (have) { continue; }
                    ProcessTap tap;
                    const HRESULT hr = OpenTap(pid, tap);
                    if (SUCCEEDED(hr)) {
                        Log("[media] hearing %s", ProcessName(pid).c_str());
                        tap.reopen.Opened(GetTickCount64());
                        taps.push_back(std::move(tap));
                    } else {
                        Log("[media] could not hear %s (0x%08lX)", ProcessName(pid).c_str(), hr);
                    }
                }
                // A failed open is not retried until the set changes; asking a
                // process that refused once, four times a second, would only
                // fill the log.
                current = wanted;
            }
            // Unlike a tap that would not open, one that opened and then
            // stopped working is opened again, every half second until it
            // does: it worked, so what stopped it -- the audio service
            // restarting, most likely -- passes. The time is taken after each
            // open rather than before: one that times out takes two seconds,
            // and counted from before it, it would be due again at once.
            for (ProcessTap& tap : taps) {
                if (!running()) { break; }
                if (tap.client || !tap.reopen.Due(GetTickCount64())) { continue; }
                const HRESULT hr = OpenTap(tap.pid, tap);
                const ULONGLONG opened = GetTickCount64();
                if (SUCCEEDED(hr)) {
                    if (tap.reopen.Opened(opened)) {
                        Log("[media] hearing %s again", ProcessName(tap.pid).c_str());
                    }
                } else if (tap.reopen.OpenFailed(hr, opened)) {
                    Log("[media] could not hear %s again yet (0x%08lX); trying again",
                        ProcessName(tap.pid).c_str(), hr);
                }
            }
            appSources.store(OpenTaps(taps));
        }
        events.clear();
        for (const ProcessTap& tap : taps) {
            if (tap.client) { events.push_back(tap.ready); }
        }
        if (events.empty()) {
            Sleep(kPacketMs);
            continue;
        }
        // WaitForMultipleObjects refuses more than MAXIMUM_WAIT_OBJECTS handles
        // and returns at once, which would spin this loop. Waiting on the first
        // 64 is enough: every tap is read below however the wait ends.
        WaitForMultipleObjects((DWORD) std::min<size_t>(events.size(), MAXIMUM_WAIT_OBJECTS),
                               events.data(), FALSE, 20);
        const ULONGLONG readAt = GetTickCount64();
        for (ProcessTap& tap : taps) {
            if (!tap.client) { continue; }
            const HRESULT hr = ReadTap(tap);
            if (SUCCEEDED(hr)) {
                tap.trouble.Worked();
            } else if (tap.trouble.GiveUp(hr, readAt)) {
                // Closed but kept, and opened again by the check above.
                if (tap.reopen.Lost(hr, readAt)) {
                    Log("[media] lost the sound of %s (0x%08lX); opening it again",
                        ProcessName(tap.pid).c_str(), hr);
                }
                CloseTap(tap);
                appSources.store(OpenTaps(taps));
            }
        }
        Mix(taps, pending);
        packetizer.Drain(pending);
    }

    for (ProcessTap& tap : taps) { CloseTap(tap); }
}

// ── The whole PC's sound ────────────────────────────────────────────────────

/// The default output device, opened for loopback.
struct Loopback {
    IMMDeviceEnumerator* enumerator = nullptr;
    IMMDevice* device = nullptr;
    IAudioClient* client = nullptr;
    IAudioCaptureClient* capture = nullptr;
    WAVEFORMATEX* format = nullptr;
    /// The device's id, to tell when another one has become the default.
    std::wstring id;
};

void CloseLoopback(Loopback& loopback) {
    if (loopback.client) { loopback.client->Stop(); }
    Release(loopback.capture);
    Release(loopback.client);
    Release(loopback.device);
    Release(loopback.enumerator);
    if (loopback.format) {
        CoTaskMemFree(loopback.format);
        loopback.format = nullptr;
    }
    loopback.id.clear();
}

/// Open whatever is the default output device now. Everything is asked for
/// afresh, the enumerator included, because what is being replaced may have
/// gone with the audio service that handed it out.
HRESULT OpenLoopback(Loopback& loopback) {
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                  __uuidof(IMMDeviceEnumerator), (void**) &loopback.enumerator);
    if (SUCCEEDED(hr)) {
        hr = loopback.enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &loopback.device);
    }
    if (SUCCEEDED(hr)) {
        LPWSTR id = nullptr;
        if (SUCCEEDED(loopback.device->GetId(&id)) && id) {
            loopback.id = id;
            CoTaskMemFree(id);
        }
        hr = loopback.device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                       (void**) &loopback.client);
    }
    if (SUCCEEDED(hr)) {
        hr = loopback.client->GetMixFormat(&loopback.format);
    }
    if (SUCCEEDED(hr)) {
        // LOOPBACK, so what is captured is what the speakers are being sent --
        // including the audio of the application being streamed, which is the
        // whole point. A 200 ms buffer is far more than the 5 ms packets need
        // and costs nothing, because it is drained every poll.
        hr = loopback.client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
                                         2000000, 0, loopback.format, nullptr);
    }
    if (SUCCEEDED(hr)) {
        hr = loopback.client->GetService(__uuidof(IAudioCaptureClient),
                                         (void**) &loopback.capture);
    }
    if (SUCCEEDED(hr)) {
        hr = loopback.client->Start();
    }
    if (FAILED(hr)) { CloseLoopback(loopback); }
    return hr;
}

/// The id of the default output device, or nothing when there is none or the
/// question fails.
std::wstring DefaultDeviceId(IMMDeviceEnumerator* enumerator) {
    std::wstring id;
    IMMDevice* device = nullptr;
    if (enumerator && SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device))) {
        LPWSTR text = nullptr;
        if (SUCCEEDED(device->GetId(&text)) && text) {
            id = text;
            CoTaskMemFree(text);
        }
        device->Release();
    }
    return id;
}

/// Everything the PC plays, as the default output device is sent it.
///
/// Whichever device that is at the moment. It used to be opened once, and
/// a failed read taken for nothing yet: so when the device changed under a
/// session -- a headset plugged in, a Bluetooth one taking over, the HDMI
/// monitor carrying the sound switched off -- the capture failed, or went on
/// capturing a device nothing played to, and the Mac heard nothing for the
/// rest of the session without a line in the log to say why. Now the capture
/// is opened again, at most twice a second, when its reads fail (see
/// ReadTrouble) and when another device becomes the default. The Mac takes
/// the pause in between as it takes any silence: it plays from its cushion,
/// then waits for the next sound and cushions again.
void RunWholePc(Packetizer& packetizer, const std::function<bool()>& running,
                std::atomic<uint64_t>& silent) {
    Loopback loopback;
    Reopener reopen;
    ReadTrouble trouble;
    Resampler resampler;
    double ratio = 1.0;
    ULONGLONG nextDeviceCheck = 0;
    std::vector<float> converted, pending;

    while (running()) {
        const ULONGLONG now = GetTickCount64();
        if (!loopback.capture) {
            if (!reopen.Due(now)) {
                Sleep(kPacketMs);
                continue;
            }
            const HRESULT hr = OpenLoopback(loopback);
            if (FAILED(hr)) {
                if (reopen.OpenFailed(hr, now)) {
                    Log("[media] audio loopback unavailable (0x%08lX); trying again every half second",
                        hr);
                }
                Sleep(kPacketMs);
                continue;
            }
            if (reopen.Opened(now)) {
                Log("[media] audio loopback at %lu Hz, %u channels, %u bits",
                    loopback.format->nSamplesPerSec, loopback.format->nChannels,
                    loopback.format->wBitsPerSample);
            }
            // To 48 kHz, whatever the endpoint is running at. The Mac's renderer
            // is fixed at 48 kHz, and a rate field it ignores would be a silent
            // half-speed bug rather than a loud one. It is also the rate Opus
            // works at internally. Worked out again for every device opened,
            // since the next one need not run at the same rate, and nothing
            // part-built by the last device's resampling is carried over.
            ratio = (double) loopback.format->nSamplesPerSec / (double) kWireRate;
            resampler = Resampler{};
            nextDeviceCheck = now + kDefaultDeviceCheckMs;
        }

        if (now >= nextDeviceCheck) {
            nextDeviceCheck = now + kDefaultDeviceCheckMs;
            if (DefaultDeviceMoved(loopback.id, DefaultDeviceId(loopback.enumerator))) {
                if (reopen.Lost(S_OK, now)) {
                    Log("[media] another output device is now the default; capturing that one");
                }
                CloseLoopback(loopback);
                continue;
            }
        }

        UINT32 available = 0;
        HRESULT hr = loopback.capture->GetNextPacketSize(&available);
        if (SUCCEEDED(hr) && available == 0) {
            trouble.Worked();
            Sleep(kPacketMs);
            continue;
        }
        while (SUCCEEDED(hr) && available > 0) {
            BYTE* data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            hr = loopback.capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
            if (FAILED(hr)) {
                break;
            }
            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
                // Nothing is playing; see Packetizer on why nothing is sent.
                silent.fetch_add(1);
            } else if (frames > 0) {
                Convert(loopback.format, data, frames, converted);
                resampler.Run(converted, ratio, pending);
            }
            loopback.capture->ReleaseBuffer(frames);
            hr = loopback.capture->GetNextPacketSize(&available);
        }
        packetizer.Drain(pending);
        if (SUCCEEDED(hr)) {
            trouble.Worked();
        } else if (trouble.GiveUp(hr, now)) {
            if (reopen.Lost(hr, now)) {
                Log("[media] the output device stopped answering (0x%08lX); opening the default one again",
                    hr);
            }
            CloseLoopback(loopback);
        } else {
            Sleep(kPacketMs);
        }
    }

    CloseLoopback(loopback);
}

}  // namespace

bool AppSoundSupported() { return HasProcessLoopback(); }

void AudioCapture::Stop() { stop_.store(true); }

void AudioCapture::Run(const AudioEncoding& encoding, const Processes& processes, Sink sink,
                       std::function<bool()> keepGoing) {
    stop_.store(false);
    appSources_.store(-1);
    // This session's, for the five-second line: the capture outlives a
    // session, and the counts went on from the last one's.
    packets_.store(0);
    silent_.store(0);
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool ownsCom = SUCCEEDED(com);
    Packetizer packetizer(encoding, sink, packets_, silent_);
    const auto running = [&] { return !stop_.load() && keepGoing(); };

    if (processes && HasProcessLoopback()) {
        RunApps(processes, packetizer, running, appSources_);
    } else {
        if (processes) {
            Log("[media] only the streamed apps' sound needs Windows 10 build 20348 or "
                "later; sending the whole PC's");
        }
        RunWholePc(packetizer, running, silent_);
    }
    appSources_.store(-1);
    if (ownsCom) { CoUninitialize(); }
}

}  // namespace solstream::media
