// main.cpp — what the hardware H.264 encoder costs, and what it can do.
//
// Two questions, and the second one decides whether a third of the transport
// design is buildable at all.
//
//   1. HOW LONG FROM SUBMITTING A FRAME TO HOLDING ITS FIRST ENCODED BYTE?
//      docs/transport-smt1.md budgets 3-8 ms for this and calls the figure
//      arithmetic rather than measurement. Nothing in SolStream has ever
//      configured an encoder, so there is no evidence in the tree either way.
//
//   2. DOES IT EXPOSE LONG-TERM REFERENCE FRAMES?
//      The recovery scheme replaces "loss happened, send an IDR" with "loss
//      happened, predict from a frame the client says it still holds". That is
//      the reason the design can drop FEC and its 20-30% bandwidth tax. It
//      requires the encoder to mark a frame as a long-term reference and later
//      to predict from a named one. If it cannot, the whole tier-2 recovery
//      design is fiction and the honest answer is to find that out now rather
//      than after building the feedback channel that feeds it.
//
//      Listed in the design's own open questions as "the largest unknown".
//
// Deliberately no capture and no colour conversion: frames are synthetic NV12.
// Capture latency is already measured (spike/wgc-capture) and BGRA-to-NV12 is a
// second encoder-shaped problem. One new variable at a time.

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
// codecapi.h for the CODECAPI_* GUIDs, icodecapi.h for ICodecAPI itself --
// which is NOT declared by mfidl.h, contrary to the obvious guess.
//
// NOT wmcodecdsp.h. That pulls in strmif.h, which declares CodecAPIEventData a
// second time and fails the build on a struct redefinition with nothing to do
// with this code.
#include <codecapi.h>
#include <icodecapi.h>
#include <d3d11.h>

#include <algorithm>
#include <cstdio>
#include <vector>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")
// The CODECAPI_* GUIDs live here, not in mfuuid.
#pragma comment(lib, "strmiids.lib")
#pragma comment(lib, "d3d11.lib")

namespace {

constexpr UINT32 kWidth = 1920;
constexpr UINT32 kHeight = 1080;
constexpr UINT32 kFps = 60;
constexpr UINT32 kBitrate = 20000000;
constexpr int kFrames = 300;

LARGE_INTEGER g_frequency{};
double MillisSince(long long start) {
    LARGE_INTEGER now{};
    QueryPerformanceCounter(&now);
    return (double) (now.QuadPart - start) * 1000.0 / (double) g_frequency.QuadPart;
}
long long Now() {
    LARGE_INTEGER now{};
    QueryPerformanceCounter(&now);
    return now.QuadPart;
}

template <typename T>
void Release(T*& p) { if (p) { p->Release(); p = nullptr; } }

/// Ask the codec whether it supports a control, and if it does, what range.
/// IsSupported alone is not enough: several controls report supported and then
/// refuse every value, which is a different answer and one worth printing.
void Probe(ICodecAPI* codec, const GUID& api, const char* name) {
    if (!codec) { return; }
    const HRESULT supported = codec->IsSupported(&api);
    if (supported != S_OK) {
        std::printf("  %-34s NO (0x%08lX)\n", name, supported);
        return;
    }
    VARIANT value{};
    VariantInit(&value);
    const HRESULT got = codec->GetValue(&api, &value);
    if (SUCCEEDED(got) && value.vt == VT_UI4) {
        std::printf("  %-34s yes, currently %lu\n", name, value.ulVal);
    } else if (SUCCEEDED(got) && value.vt == VT_BOOL) {
        std::printf("  %-34s yes, currently %s\n", name,
                    value.boolVal ? "true" : "false");
    } else {
        std::printf("  %-34s yes (value unreadable, 0x%08lX)\n", name, got);
    }
    VariantClear(&value);
}

bool TrySet(ICodecAPI* codec, const GUID& api, ULONG value, const char* name) {
    if (!codec) { return false; }
    VARIANT v{};
    VariantInit(&v);
    v.vt = VT_UI4;
    v.ulVal = value;
    const HRESULT hr = codec->SetValue(&api, &v);
    VariantClear(&v);
    std::printf("  set %-30s %lu -> %s (0x%08lX)\n", name, value,
                SUCCEEDED(hr) ? "OK" : "REFUSED", hr);
    return SUCCEEDED(hr);
}

void Report(const char* label, std::vector<double> v) {
    if (v.empty()) { std::printf("  %-30s no samples\n", label); return; }
    std::sort(v.begin(), v.end());
    double sum = 0;
    for (double x : v) { sum += x; }
    auto at = [&](double q) { return v[(size_t) (q * (v.size() - 1))]; };
    std::printf("  %-30s n=%zu  min %.2f  p50 %.2f  p95 %.2f  max %.2f  mean %.2f\n",
                label, v.size(), v.front(), at(0.50), at(0.95), v.back(),
                sum / (double) v.size());
}

/// A moving pattern, so the encoder has real work to do. A static frame encodes
/// to almost nothing and would measure the wrong thing entirely.
void FillNv12(BYTE* data, UINT32 width, UINT32 height, int frame) {
    for (UINT32 y = 0; y < height; ++y) {
        BYTE* row = data + (size_t) y * width;
        for (UINT32 x = 0; x < width; ++x) {
            row[x] = (BYTE) ((x * 3 + y * 5 + frame * 11) & 0xFF);
        }
    }
    BYTE* chroma = data + (size_t) width * height;
    for (UINT32 y = 0; y < height / 2; ++y) {
        BYTE* row = chroma + (size_t) y * width;
        for (UINT32 x = 0; x < width; x += 2) {
            row[x] = (BYTE) (128 + ((x + frame) & 0x1F));
            row[x + 1] = (BYTE) (128 - ((y + frame) & 0x1F));
        }
    }
}

}  // namespace

int main() {
    QueryPerformanceFrequency(&g_frequency);
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
        std::printf("MFStartup failed\n");
        return 1;
    }

    std::printf("=== SolStream hardware H.264 encoder spike ===\n\n");

    // ── Find a hardware encoder ──────────────────────────────────────────────
    MFT_REGISTER_TYPE_INFO output{MFMediaType_Video, MFVideoFormat_H264};
    IMFActivate** activates = nullptr;
    UINT32 count = 0;
    HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                           MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                           nullptr, &output, &activates, &count);
    if (FAILED(hr) || count == 0) {
        std::printf("no HARDWARE H.264 encoder (0x%08lX, count %u); "
                    "the design assumes one exists\n", hr, count);
        return 1;
    }
    WCHAR* name = nullptr;
    UINT32 nameLen = 0;
    activates[0]->GetAllocatedString(MFT_FRIENDLY_NAME_Attribute, &name, &nameLen);
    std::printf("[1] encoder: %ls   (%u hardware encoders present)\n\n", name, count);
    CoTaskMemFree(name);

    IMFTransform* encoder = nullptr;
    hr = activates[0]->ActivateObject(IID_PPV_ARGS(&encoder));
    for (UINT32 i = 0; i < count; ++i) { activates[i]->Release(); }
    CoTaskMemFree(activates);
    if (FAILED(hr)) {
        std::printf("could not activate the encoder (0x%08lX)\n", hr);
        return 1;
    }

    // UNLOCK BEFORE ANYTHING ELSE. A hardware MFT is asynchronous and starts
    // locked: SetInputType returns MF_E_TRANSFORM_ASYNC_LOCKED (0xC00D6D77)
    // until MF_TRANSFORM_ASYNC_UNLOCK is set, and the output type is accepted
    // first regardless, so the failure looks like the INPUT type being wrong
    // rather than like a missing unlock. Doing this after configuring types --
    // which is where it reads naturally -- fails exactly that way.
    const bool async = [&] {
        IMFAttributes* attributes = nullptr;
        if (FAILED(encoder->GetAttributes(&attributes)) || !attributes) { return false; }
        UINT32 value = 0;
        attributes->GetUINT32(MF_TRANSFORM_ASYNC, &value);
        if (value) { attributes->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, 1); }
        attributes->Release();
        return value != 0;
    }();
    std::printf("[1] transform is %s\n\n", async ? "ASYNCHRONOUS (unlocked)" : "synchronous");

    // A D3D11 device manager, BEFORE the media types.
    //
    // A hardware MFT advertises MF_SA_D3D11_AWARE, and several of them will
    // accept every call in the setup sequence without one and then never emit a
    // single METransformNeedInput -- which presents as a hang in GetEvent with
    // nothing having failed. Sent before type negotiation because that is where
    // the MFT decides what it can do.
    UINT32 d3dAware = 0;
    {
        IMFAttributes* attributes = nullptr;
        if (SUCCEEDED(encoder->GetAttributes(&attributes)) && attributes) {
            attributes->GetUINT32(MF_SA_D3D11_AWARE, &d3dAware);
            attributes->Release();
        }
    }
    std::printf("[2] MF_SA_D3D11_AWARE %s\n", d3dAware ? "yes" : "no");

    ID3D11Device* d3d = nullptr;
    ID3D11DeviceContext* d3dContext = nullptr;
    IMFDXGIDeviceManager* manager = nullptr;
    if (d3dAware) {
        D3D_FEATURE_LEVEL level{};
        HRESULT made = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                         D3D11_CREATE_DEVICE_VIDEO_SUPPORT
                                             | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                         nullptr, 0, D3D11_SDK_VERSION, &d3d, &level,
                                         &d3dContext);
        if (SUCCEEDED(made)) {
            // Without multithread protection the encoder and this thread share a
            // device context that is not safe to share, which corrupts in ways
            // that look like encoder bugs.
            ID3D10Multithread* threading = nullptr;
            if (SUCCEEDED(d3d->QueryInterface(IID_PPV_ARGS(&threading)))) {
                threading->SetMultithreadProtected(TRUE);
                threading->Release();
            }
            UINT token = 0;
            made = MFCreateDXGIDeviceManager(&token, &manager);
            if (SUCCEEDED(made)) { made = manager->ResetDevice(d3d, token); }
            if (SUCCEEDED(made)) {
                made = encoder->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER,
                                               (ULONG_PTR) manager);
            }
        }
        std::printf("[2] D3D manager       %s (0x%08lX)\n",
                    SUCCEEDED(made) ? "attached" : "FAILED", made);
    }
    std::printf("\n");

    // ── What can it do? ──────────────────────────────────────────────────────
    ICodecAPI* codec = nullptr;
    encoder->QueryInterface(IID_PPV_ARGS(&codec));
    std::printf("[2] capabilities\n");
    Probe(codec, CODECAPI_AVEncVideoLTRBufferControl, "LTR buffer control");
    Probe(codec, CODECAPI_AVEncVideoUseLTRFrame,      "use LTR frame");
    Probe(codec, CODECAPI_AVEncVideoMarkLTRFrame,     "mark LTR frame");
    Probe(codec, CODECAPI_AVEncSliceControlMode,      "slice control mode");
    Probe(codec, CODECAPI_AVEncSliceControlSize,      "slice control size");
    Probe(codec, CODECAPI_AVLowLatencyMode,           "low latency mode");
    Probe(codec, CODECAPI_AVEncCommonRateControlMode, "rate control mode");
    Probe(codec, CODECAPI_AVEncVideoForceKeyFrame,    "force key frame");
    Probe(codec, CODECAPI_AVEncH264CABACEnable,       "CABAC");
    std::printf("\n");

    // ── Configure ────────────────────────────────────────────────────────────
    IMFMediaType* outType = nullptr;
    MFCreateMediaType(&outType);
    outType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    outType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    outType->SetUINT32(MF_MT_AVG_BITRATE, kBitrate);
    MFSetAttributeSize(outType, MF_MT_FRAME_SIZE, kWidth, kHeight);
    MFSetAttributeRatio(outType, MF_MT_FRAME_RATE, kFps, 1);
    MFSetAttributeRatio(outType, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    outType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    outType->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High);
    hr = encoder->SetOutputType(0, outType, 0);
    std::printf("[3] output type  %s (0x%08lX)\n", SUCCEEDED(hr) ? "set" : "REFUSED", hr);
    if (FAILED(hr)) { return 1; }

    IMFMediaType* inType = nullptr;
    MFCreateMediaType(&inType);
    inType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    inType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    MFSetAttributeSize(inType, MF_MT_FRAME_SIZE, kWidth, kHeight);
    MFSetAttributeRatio(inType, MF_MT_FRAME_RATE, kFps, 1);
    MFSetAttributeRatio(inType, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    inType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    hr = encoder->SetInputType(0, inType, 0);
    std::printf("[3] input type   %s (0x%08lX)\n\n", SUCCEEDED(hr) ? "set" : "REFUSED", hr);
    if (FAILED(hr)) { return 1; }

    std::printf("[4] configuring for latency\n");
    TrySet(codec, CODECAPI_AVLowLatencyMode, 1, "AVLowLatencyMode");
    TrySet(codec, CODECAPI_AVEncCommonRateControlMode,
           eAVEncCommonRateControlMode_CBR, "rate control = CBR");
    TrySet(codec, CODECAPI_AVEncH264CABACEnable, 0, "CABAC off");
    // Slices per frame. This is what makes slice-early sending possible: an
    // encoder that only emits whole frames cannot put anything on the wire
    // before the frame is finished, and the design's "send slices as they
    // complete" is then unimplementable whatever the transport does.
    TrySet(codec, CODECAPI_AVEncSliceControlMode, 2, "slice mode = slices/frame");
    TrySet(codec, CODECAPI_AVEncSliceControlSize, 4, "slices per frame = 4");
    std::printf("\n");

    encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

    IMFMediaEventGenerator* events = nullptr;
    if (async) { encoder->QueryInterface(IID_PPV_ARGS(&events)); }

    // ── Encode ───────────────────────────────────────────────────────────────
    const DWORD frameBytes = kWidth * kHeight * 3 / 2;
    std::vector<double> submitToFirstOutput;
    std::vector<long long> submittedAt(kFrames + 1, 0);
    int produced = 0, sliceCount = 0;
    size_t encodedBytes = 0;
    int nextFrame = 1;

    // Eight frames, generated ONCE and cycled. Filling 3 MB of NV12 per frame in
    // a scalar loop costs more than encoding it, so the previous version starved
    // the encoder: 300 frames of 5 seconds' content took over 20 seconds and the
    // run timed out half way. The pipeline has to be saturated for a latency
    // figure to mean anything, because a starved encoder is never queueing.
    constexpr int kVariants = 8;
    std::vector<std::vector<BYTE>> variants(kVariants);
    for (int v = 0; v < kVariants; ++v) {
        variants[v].resize(frameBytes);
        FillNv12(variants[v].data(), kWidth, kHeight, v * 37);
    }

    auto submit = [&](int frame) -> bool {
        IMFMediaBuffer* buffer = nullptr;
        if (FAILED(MFCreateMemoryBuffer(frameBytes, &buffer))) { return false; }
        BYTE* data = nullptr;
        buffer->Lock(&data, nullptr, nullptr);
        memcpy(data, variants[frame % kVariants].data(), frameBytes);
        buffer->Unlock();
        buffer->SetCurrentLength(frameBytes);

        IMFSample* sample = nullptr;
        MFCreateSample(&sample);
        sample->AddBuffer(buffer);
        sample->SetSampleTime((LONGLONG) (frame - 1) * 10000000 / kFps);
        sample->SetSampleDuration(10000000 / kFps);
        submittedAt[frame] = Now();
        const HRESULT sent = encoder->ProcessInput(0, sample, 0);
        Release(sample);
        Release(buffer);
        return SUCCEEDED(sent);
    };

    auto drain = [&]() {
        for (;;) {
            MFT_OUTPUT_STREAM_INFO info{};
            encoder->GetOutputStreamInfo(0, &info);
            IMFSample* outSample = nullptr;
            IMFMediaBuffer* outBuffer = nullptr;
            const bool allocates =
                (info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES
                                 | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
            if (!allocates) {
                MFCreateSample(&outSample);
                MFCreateMemoryBuffer(info.cbSize ? info.cbSize : (1 << 20), &outBuffer);
                outSample->AddBuffer(outBuffer);
            }
            MFT_OUTPUT_DATA_BUFFER out{};
            out.dwStreamID = 0;
            out.pSample = outSample;
            DWORD status = 0;
            const HRESULT got = encoder->ProcessOutput(0, 1, &out, &status);
            if (got == MF_E_TRANSFORM_NEED_MORE_INPUT || got == MF_E_TRANSFORM_STREAM_CHANGE) {
                Release(outSample); Release(outBuffer);
                return;
            }
            if (FAILED(got)) { Release(outSample); Release(outBuffer); return; }

            IMFSample* result = out.pSample;
            LONGLONG time = 0;
            result->GetSampleTime(&time);
            const int frame = (int) (time * kFps / 10000000) + 1;
            DWORD length = 0;
            result->GetTotalLength(&length);
            encodedBytes += length;
            ++sliceCount;
            if (frame >= 1 && frame <= kFrames && submittedAt[frame] != 0) {
                submitToFirstOutput.push_back(MillisSince(submittedAt[frame]));
                submittedAt[frame] = 0;   // first output only
                ++produced;
            }
            Release(result);
            Release(outBuffer);
            if (out.pEvents) { out.pEvents->Release(); }
        }
    };

    const long long runStart = Now();
    if (async && events) {
        // Hardware MFTs are event-driven: they say when they want a frame and
        // when they have one. Polling ProcessOutput on one of these returns
        // NEED_MORE_INPUT forever.
        // POLLED, WITH A DEADLINE. A blocking GetEvent on an MFT that never
        // emits an event hangs forever with nothing having failed, and a spike
        // that hangs is worse than one that reports what it saw: the previous
        // run had to be killed from another machine and produced no diagnosis
        // at all. Counting the events makes "it emitted nothing" and "it
        // emitted the wrong thing" different answers.
        int needInput = 0, haveOutput = 0, otherEvents = 0;
        const long long deadline = Now() + g_frequency.QuadPart * 40;
        long long lastOutput = Now();
        // Done when every frame has been submitted AND the encoder has been
        // quiet for 300 ms. Waiting for N distinct first-outputs was wrong: with
        // slices enabled several samples carry the SAME timestamp, so "unique
        // frames seen" stalls below the frame count and the loop never ends.
        while (Now() < deadline) {
            if (nextFrame > kFrames
                && (Now() - lastOutput) > g_frequency.QuadPart * 3 / 10) {
                break;
            }
            IMFMediaEvent* event = nullptr;
            const HRESULT got = events->GetEvent(MF_EVENT_FLAG_NO_WAIT, &event);
            if (got == MF_E_NO_EVENTS_AVAILABLE || !event) {
                Sleep(1);
                continue;
            }
            if (FAILED(got)) { break; }
            MediaEventType type = 0;
            event->GetType(&type);
            event->Release();
            if (type == METransformNeedInput) {
                ++needInput;
                if (nextFrame <= kFrames) { submit(nextFrame++); }
            } else if (type == METransformHaveOutput) {
                ++haveOutput;
                lastOutput = Now();
                drain();
            } else {
                ++otherEvents;
            }
        }
        std::printf("  events: NeedInput %d, HaveOutput %d, other %d%s\n",
                    needInput, haveOutput, otherEvents,
                    Now() >= deadline ? "   (TIMED OUT after 20s)" : "");
    } else {
        for (int f = 1; f <= kFrames; ++f) {
            submit(f);
            drain();
        }
        encoder->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
        drain();
    }
    const double seconds = MillisSince(runStart) / 1000.0;

    std::printf("\n=== results ===\n");
    std::printf("  frames with output             %d of %d submitted\n", produced, nextFrame - 1);
    std::printf("  output samples (slices)        %d  = %.2f per frame\n",
                sliceCount, produced ? (double) sliceCount / produced : 0);
    std::printf("  encoded size                   %.2f MB, %.1f Mbit/s at %d fps\n",
                (double) encodedBytes / 1e6,
                seconds > 0 ? (double) encodedBytes * 8 / seconds / 1e6 : 0, kFps);
    Report("submit -> first output, ms", submitToFirstOutput);

    Release(codec);
    Release(events);
    Release(inType);
    Release(outType);
    Release(encoder);
    MFShutdown();
    return 0;
}
