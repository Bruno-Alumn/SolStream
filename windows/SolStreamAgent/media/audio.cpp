#include "audio.h"
#include "audio_downmix.h"
#include "resampler.h"
#include "audio_tree.h"

#include <mmreg.h>
#include <audioclient.h>
#include <avrt.h>
#include <tlhelp32.h>
#include <mmdeviceapi.h>
#include <objbase.h>
#include <audioclientactivationparams.h>
#include <opus.h>
#include "audio_reopen.h"
#include "audio_source.h"
#include "log.h"

#include <algorithm>
#include <atomic>
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
/// of eight channels. The channels are mixed down to two by their layout
/// (audio_downmix.h) -- taking the first two dropped a film's dialogue, which
/// is in the centre; the rate is dealt with by the resampler below.
void Convert(const WAVEFORMATEX* format, const unsigned char* source, UINT32 frames,
             std::vector<float>& out) {
    const int channels = format->nChannels;
    out.resize((size_t) frames * 2);
    const uint32_t mask = format->wFormatTag == WAVE_FORMAT_EXTENSIBLE
        ? (uint32_t) ((const WAVEFORMATEXTENSIBLE*) format)->dwChannelMask : 0u;
    const StereoWeights weights = DownmixWeights(channels, mask);
    // More than one source channel on a side: a mixdown, which can pass full
    // scale and is brought within it gently (SoftLimit). Plain stereo is left
    // exactly as it came.
    int sources = 0;
    for (int c = 0; c < channels; ++c) {
        sources += weights.left[(size_t) c] != 0.0f ? 1 : 0;
    }
    const bool mixed = sources > 1;

    // The extensible subformat GUID's first word IS the old format tag --
    // {00000003-0000-0010-8000-00aa00389b71} is IEEE float -- so this needs
    // neither ksmedia.h nor a GUID comparison to answer the only question here.
    const bool isFloat =
        format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT
        || (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE
            && ((const WAVEFORMATEXTENSIBLE*) format)->SubFormat.Data1
                   == WAVE_FORMAT_IEEE_FLOAT);

    // Packed 24-bit, 8-bit and 64-bit float come out as zeros below, which the
    // silence check then drops -- the Mac heard nothing and nothing said why.
    // Once per process is enough to say it.
    const bool handled = format->wBitsPerSample == 16 || format->wBitsPerSample == 32;
    if (!handled) {
        static std::atomic<bool> said{false};
        if (!said.exchange(true)) {
            Log("[media] the sound arrives as %u-bit %s, which SolStream cannot "
                "read, so none is sent. Choose a 16-bit format in Windows' sound "
                "settings for this device.",
                (unsigned) format->wBitsPerSample, isFloat ? "float" : "integer");
        }
    }

    for (UINT32 i = 0; i < frames; ++i) {
        float left = 0.0f, right = 0.0f;
        for (int c = 0; c < channels; ++c) {
            const float wl = weights.left[(size_t) c];
            const float wr = weights.right[(size_t) c];
            if (wl == 0.0f && wr == 0.0f) {
                continue;
            }
            const size_t at = (size_t) i * channels + (size_t) c;
            float sample = 0.0f;
            if (isFloat && format->wBitsPerSample == 32) {
                sample = ((const float*) source)[at];
            } else if (format->wBitsPerSample == 16) {
                sample = ((const int16_t*) source)[at] / 32768.0f;
            } else if (format->wBitsPerSample == 32) {
                sample = (float) ((const int32_t*) source)[at] / 2147483648.0f;
            }
            left += sample * wl;
            right += sample * wr;
        }
        out[(size_t) i * 2] = mixed ? SoftLimit(left) : left;
        out[(size_t) i * 2 + 1] = mixed ? SoftLimit(right) : right;
    }
}

// Resampling to 48 kHz: see SincResampler (resampler.h).

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
    /// A short silence after a sound, for a source that says "silent" with
    /// a flag rather than with zeros: Drain sends it, finishing what Opus
    /// held of the sound (see there).
    void EndSound(std::vector<float>& pending) const {
        pending.insert(pending.end(), frames_ * 2 * 2, 0.0f);
    }

    void Drain(std::vector<float>& pending) {
        const size_t samples = frames_ * 2;
        size_t at = 0;
        for (; pending.size() - at >= samples; at += samples) {
            float* chunk = pending.data() + at;
            // Within full scale before either encoder, which Opus is not built
            // to take past: a plain clamp, which changes nothing in range. A
            // surround mixdown was already brought in gently (Convert).
            for (size_t i = 0; i < samples; ++i) {
                chunk[i] = std::clamp(chunk[i], -1.0f, 1.0f);
            }
            const bool quiet =
                std::all_of(chunk, chunk + samples, [](float v) { return v == 0.0f; });
            // Two packets of the silence after a sound are sent, not dropped:
            // Opus holds the last few milliseconds of what it was given until
            // the next packet, and with nothing after a sound that stopped
            // short -- a video paused mid-word -- it came out at the start of
            // the next sound, seconds later, as a click.
            if (quiet && trailing_ == 0) {
                silent_.fetch_add(1);
                continue;
            }
            trailing_ = quiet ? trailing_ - 1 : 2;
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
    int trailing_ = 0;   ///< silent packets still to send after a sound; see Drain
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
    /// Read since it opened: Windows flags the first buffer after a start as
    /// a discontinuity, which is not sound lost.
    bool readOnce = false;
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
        // Event-driven, as a process tap has to be, with 100 ms of buffer --
        // drained every period, so it adds no delay; it is room for the thread
        // being held off (a busy PC, a new app's capture opening) without
        // Windows dropping the sound.
        hr = tap.client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                    AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK
                                        | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
                                        | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                                    1000000, 0, &format, nullptr);
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
void NoteDiscontinuity(const char* whose);

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
        if ((flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) && tap.readOnce) {
            NoteDiscontinuity("an app's");
        }
        tap.readOnce = true;
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

/// Windows dropped sound before this thread read it -- the thread was held
/// off too long. Said at most every 30 s, with how often, rather than not at
/// all: a dropout otherwise left nothing in the log.
///
/// Per thread, and so per session: each has a sound thread of its own.
void NoteDiscontinuity(const char* whose) {
    thread_local ULONGLONG saidAt = 0;
    thread_local unsigned long count = 0;
    ++count;
    const ULONGLONG now = GetTickCount64();
    if (saidAt == 0 || now - saidAt >= 30000) {
        Log("[media] Windows dropped some of %s sound before it could be read (%lu time%s): "
            "the PC was too busy for the sound thread", whose, count, count == 1 ? "" : "s");
        saidAt = now;
        count = 0;
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

/// Every process's parent and start time, for WithoutDescendants. Empty if
/// the snapshot could not be taken, which keeps every wanted app.
std::map<uint32_t, ProcessEntry> ProcessTree() {
    std::map<uint32_t, ProcessEntry> all;
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) { return all; }
    PROCESSENTRY32W entry{sizeof(entry)};
    for (BOOL more = Process32FirstW(snapshot, &entry); more;
         more = Process32NextW(snapshot, &entry)) {
        ProcessEntry process;
        process.parent = entry.th32ParentProcessID;
        if (HANDLE handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                        entry.th32ProcessID)) {
            FILETIME created{}, exited{}, kernel{}, user{};
            if (GetProcessTimes(handle, &created, &exited, &kernel, &user)) {
                process.started = ((uint64_t) created.dwHighDateTime << 32) | created.dwLowDateTime;
            }
            CloseHandle(handle);
        }
        all[entry.th32ProcessID] = process;
    }
    CloseHandle(snapshot);
    return all;
}

/// Whether `pid` is File Explorer. Its capture would be the whole desktop's
/// -- nearly everything is started by it, and Windows captures an app with
/// all it started -- so an Explorer window streamed is not heard.
bool IsExplorer(DWORD pid) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) { return false; }
    wchar_t path[MAX_PATH];
    DWORD length = MAX_PATH;
    bool explorer = false;
    if (QueryFullProcessImageNameW(process, 0, path, &length)) {
        const wchar_t* base = wcsrchr(path, L'\\');
        explorer = _wcsicmp(base ? base + 1 : path, L"explorer.exe") == 0;
    }
    CloseHandle(process);
    return explorer;
}

/// The streamed apps' sound, and nothing else, until `running` says stop.
void RunApps(const AudioCapture::Processes& processes, Packetizer& packetizer,
             const std::function<bool()>& running, std::atomic<int>& appSources) {
    std::vector<ProcessTap> taps;
    std::vector<DWORD> current;
    std::vector<HANDLE> events;
    std::vector<float> pending;
    ULONGLONG nextCheck = 0;
    // The pids asked for last time, before the tree was looked at: the
    // snapshot is taken only when they change.
    std::vector<DWORD> lastAsked;
    std::vector<DWORD> toldExplorer;   // said once each
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
            if (wanted != lastAsked) {
                lastAsked = wanted;
                // Explorer's capture would be the desktop's; and an app another
                // wanted app started is in that one's capture already.
                std::vector<uint32_t> asked;
                for (DWORD pid : wanted) {
                    if (IsExplorer(pid)) {
                        if (std::find(toldExplorer.begin(), toldExplorer.end(), pid)
                            == toldExplorer.end()) {
                            toldExplorer.push_back(pid);
                            Log("[media] not hearing File Explorer: Windows would include every "
                                "app it started, which is most of the desktop");
                        }
                        continue;
                    }
                    asked.push_back((uint32_t) pid);
                }
                std::vector<uint32_t> kept = asked;
                if (asked.size() > 1) {
                    const auto tree = ProcessTree();
                    // No snapshot: every app kept, and asked again next time
                    // rather than latched until the streamed set changes.
                    if (tree.empty()) {
                        lastAsked.clear();
                    } else {
                        kept = WithoutDescendants(asked, tree);
                    }
                }
                if (kept.size() < asked.size()) {
                    Log("[media] %zu streamed app(s) already heard through the app that "
                        "started them", asked.size() - kept.size());
                }
                wanted.assign(kept.begin(), kept.end());
            } else {
                wanted = current;
            }
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
                    if (!running()) { break; }
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
                        // Kept, closed, so the retry below opens it once what
                        // stopped it passes. It used to be dropped until the set
                        // of streamed windows changed: an app opened while the
                        // audio service was still starting -- just after logon
                        // or wake -- stayed silent for the whole session. The
                        // Reopener keeps the retries out of the log.
                        tap.pid = pid;
                        if (tap.reopen.OpenFailed(hr, GetTickCount64())) {
                            Log("[media] could not hear %s (0x%08lX); trying again",
                                ProcessName(pid).c_str(), hr);
                        }
                        taps.push_back(std::move(tap));
                    }
                }
                current = wanted;
            }
            // A tap that is not open -- one that never opened, or one that
            // opened and then stopped working -- is opened again, every half
            // second until it does: what stopped it -- the audio service
            // starting or restarting, most likely -- passes. The time is taken after each
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
    SincResampler resampler;
    ULONGLONG nextDeviceCheck = 0;
    std::vector<float> converted, pending;
    // Read since the device opened (see ProcessTap::readOnce), and whether
    // sound was playing at the last buffer (see Packetizer::EndSound).
    bool readOnce = false;
    bool sounding = false;

    while (running()) {
        const ULONGLONG now = GetTickCount64();
        if (!loopback.capture) {
            readOnce = false;
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
            resampler.Reset((double) loopback.format->nSamplesPerSec / (double) kWireRate);
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
            if ((flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) && readOnce) {
                NoteDiscontinuity("the PC's");
            }
            readOnce = true;
            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
                // Nothing is playing; see Packetizer on why nothing is sent --
                // after a short silence to end what was playing on (Packetizer::
                // EndSound), which arrives as this flag here, not as zeros.
                if (sounding) {
                    packetizer.EndSound(pending);
                    sounding = false;
                }
                silent.fetch_add(1);
            } else if (frames > 0) {
                sounding = true;
                Convert(loopback.format, data, frames, converted);
                resampler.Run(converted, pending);
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
    // Scheduled as audio, as Windows' own audio threads are: at normal
    // priority a game loading every core held this thread off long enough
    // to lose sound.
    DWORD mmcssTask = 0;
    const HANDLE mmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &mmcssTask);
    if (!mmcss) {
        Log("[media] the sound thread could not be scheduled as audio (%lu)",
            (unsigned long) GetLastError());
    }
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
    if (mmcss) { AvRevertMmThreadCharacteristics(mmcss); }
    if (ownsCom) { CoUninitialize(); }
}

}  // namespace solstream::media
