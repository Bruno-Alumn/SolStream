#include "encoder.h"

#include "feed_ledger.h"
#include "log.h"

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <codecapi.h>
#include <icodecapi.h>
#include <d3d11.h>

#include <atomic>
#include <mutex>
#include <vector>

namespace solstream::media {
namespace {

constexpr int kRing = 6;          ///< NV12 textures in flight
constexpr int kMetaRing = 64;     ///< per-picture metadata slots

/// How many output format changes one drain will renegotiate before giving up.
/// A transform that answers every ProcessOutput with MF_E_TRANSFORM_STREAM_CHANGE
/// would otherwise spin a work-queue thread here for ever, and a real encoder
/// changes its output type at most once or twice in a session.
constexpr int kMaxFormatChanges = 4;

template <typename T>
void Release(T*& p) {
    if (p) { p->Release(); p = nullptr; }
}

long long Now() {
    LARGE_INTEGER now{};
    QueryPerformanceCounter(&now);
    return now.QuadPart;
}

/// Ticks per second, for turning a QPC difference into a duration. Read once:
/// the value is fixed for the life of the boot.
long long QpcFrequency() {
    static const long long ticks = [] {
        LARGE_INTEGER frequency{};
        QueryPerformanceFrequency(&frequency);
        return frequency.QuadPart ? frequency.QuadPart : 1;
    }();
    return ticks;
}

/// Does this Annex B buffer already start with a sequence parameter set?
///
/// An IDR without SPS and PPS in front of it is undecodable by a receiver that
/// has just joined, and whether the encoder inlines them is a per-driver choice
/// rather than a guarantee. Checking is three lines; assuming is a black picture
/// on somebody else's machine.
bool StartsWithSps(const unsigned char* data, size_t length) {
    size_t i = 0;
    while (i + 4 <= length) {
        if (data[i] == 0 && data[i + 1] == 0) {
            if (data[i + 2] == 1) {
                return (data[i + 3] & 0x1F) == 7;
            }
            if (data[i + 2] == 0 && i + 5 <= length && data[i + 3] == 1) {
                return (data[i + 4] & 0x1F) == 7;
            }
        }
        ++i;
    }
    return false;
}

}  // namespace

// ── The event pump ───────────────────────────────────────────────────────────
//
// A hardware MFT is event-driven: polling ProcessOutput on one returns
// NEED_MORE_INPUT forever. This uses BeginGetEvent rather than a polling loop
// because a 1 ms poll adds 1 ms to a budget that is 3-8 ms in total, and
// because a blocking GetEvent on an MFT that stops emitting cannot be woken.
struct EncoderCallback : public IMFAsyncCallback {
    struct Encoder::Impl* owner = nullptr;
    std::atomic<ULONG> refs{1};

    /// Held for the whole of Invoke, and taken by Close before it releases a
    /// single one of the interfaces Invoke uses.
    ///
    /// It lives here rather than on Impl because Impl is the thing that goes
    /// away. A callback that had already read `owner` and was about to lock a
    /// mutex inside Impl would be locking storage that Close had finished with
    /// and ~Encoder had destroyed. This object is reference counted and the
    /// work queue holds a reference for the duration of the call, so the mutex
    /// is still there to be taken however late the callback runs.
    std::mutex gate;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (riid == IID_IUnknown || riid == __uuidof(IMFAsyncCallback)) {
            *out = static_cast<IMFAsyncCallback*>(this);
            AddRef();
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG left = --refs;
        if (left == 0) { delete this; }
        return left;
    }
    HRESULT STDMETHODCALLTYPE GetParameters(DWORD*, DWORD*) override {
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE Invoke(IMFAsyncResult* result) override;
};

struct Encoder::Impl {
    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    ID3D11VideoDevice* videoDevice = nullptr;
    ID3D11VideoContext* videoContext = nullptr;
    ID3D11VideoProcessor* processor = nullptr;
    ID3D11VideoProcessorEnumerator* enumerator = nullptr;

    ID3D11Texture2D* nv12[kRing] = {};
    /// Only for the software path: NV12 read back to the CPU, because an
    /// encoder that is not D3D-aware cannot be handed a texture.
    ID3D11Texture2D* staging = nullptr;
    /// Only for the no-video-engine path: the captured BGRA, read back so the
    /// colour conversion can be done on the CPU.
    ID3D11Texture2D* stagingBgra = nullptr;
    UINT stagingBgraWidth = 0, stagingBgraHeight = 0;
    /// True when this D3D11 device has no video interfaces at all -- a virtual
    /// machine, or a basic display adapter. Then there is no VideoProcessor to
    /// convert with and no hardware encoder to feed, and everything happens on
    /// the CPU.
    bool cpuOnly = false;
    ID3D11VideoProcessorOutputView* nv12View[kRing] = {};
    int nextSlot = 0;

    ID3D11Texture2D* sourceTexture = nullptr;   ///< weak, only for cache identity
    ID3D11VideoProcessorInputView* sourceView = nullptr;
    UINT sourceWidth = 0, sourceHeight = 0;

    IMFTransform* mft = nullptr;
    ICodecAPI* codec = nullptr;
    IMFMediaEventGenerator* events = nullptr;
    IMFDXGIDeviceManager* manager = nullptr;
    EncoderCallback* callback = nullptr;

    UINT width = 0, height = 0, fps = 60, bitrate = 20000000;
    LONGLONG ticksPerFrame = 166666;
    /// An asynchronous MFT says when it wants input and when it has output. A
    /// software one does neither: it is fed and drained inline.
    bool async = true;
    std::atomic<bool> running{false};

    std::vector<unsigned char> sequenceHeader;

    /// How many drains have ended on an HRESULT that is not one of the two ways
    /// this transform says "nothing to give", and when that was last said out
    /// loud. Drain-thread only. See the rate limit in Drain for why counting
    /// beats logging: the first version of that line wrote 396 entries during a
    /// session that delivered every picture it captured.
    uint64_t drainFailures = 0;
    long long lastDrainComplaint = 0;
    std::vector<unsigned char> picture;   ///< assembled coded picture

    std::mutex lock;
    // The one frame waiting to be encoded. Latest wins.
    bool havePending = false;
    int pendingSlot = 0;
    ID3D11Texture2D* pendingBgra = nullptr;   ///< cpuOnly: converted at feed time
    UINT pendingSrcWidth = 0, pendingSrcHeight = 0;
    long long pendingCapturedAt = 0;
    bool pendingIdr = false;
    int needInput = 0;
    /// Frame ids and keyframe requests, spent only on a frame the encoder
    /// takes. See feed_ledger.h.
    FeedLedger ledger;

    struct Meta {
        long long capturedAt = 0;
        bool emitted = false;
    } meta[kMetaRing];

    PictureSink sink;

    std::atomic<uint64_t> submitted{0}, pictures{0}, dropped{0}, extraSamples{0};

    bool MakeProcessor(UINT srcWidth, UINT srcHeight);
    bool ReadBackNv12(int slot, IMFMediaBuffer** out);
    bool ConvertOnCpu(ID3D11Texture2D* bgra, UINT srcWidth, UINT srcHeight,
                      IMFMediaBuffer** out);
    bool Convert(ID3D11Texture2D* bgra, UINT srcWidth, UINT srcHeight, int slot);
    /// True only when the MFT took the frame. The caller owns a need-input
    /// credit and must not spend it on a false.
    bool FeedLocked();
    void Drain();
    void Emit(LONGLONG pictureTime, bool isIdr);
};

HRESULT STDMETHODCALLTYPE EncoderCallback::Invoke(IMFAsyncResult* result) {
    // This runs on an MF work-queue thread while another thread may be inside
    // Encoder::Close. Testing `running` once at the top was not enough to stop
    // it: the test passes, Close then releases the event generator, the MFT and
    // the ICodecAPI and ~Encoder destroys Impl, and this thread carries on into
    // Drain and Emit through pointers to freed objects. That window is open on
    // every media stop and every retarget, and when it lands it presents as a
    // crash during shutdown rather than as a race. Close cannot get past this
    // lock until the body below has finished, and by the time it can, `owner`
    // is null, so a callback arriving late does nothing at all.
    std::lock_guard<std::mutex> gateGuard(gate);
    Encoder::Impl* self = owner;
    if (!self || !self->running.load() || !self->events || !self->mft) {
        return S_OK;
    }
    IMFMediaEvent* event = nullptr;
    if (FAILED(self->events->EndGetEvent(result, &event)) || !event) {
        return S_OK;
    }
    MediaEventType type = 0;
    event->GetType(&type);
    event->Release();

    if (type == METransformNeedInput) {
        std::lock_guard<std::mutex> guard(self->lock);
        // The credit this event carries is only spent if a frame actually went
        // in. FeedLocked can fail to wrap the texture, to make a sample, or to
        // have ProcessInput accept it; before, all three swallowed the credit,
        // nothing ever asked for input again and the encoder stopped for good
        // after one bad frame. Handing it back costs a frame, not the stream.
        if (!self->havePending || !self->FeedLocked()) {
            ++self->needInput;
        }
    } else if (type == METransformHaveOutput) {
        self->Drain();
    }

    if (self->running.load() && self->events) {
        self->events->BeginGetEvent(this, nullptr);
    }
    return S_OK;
}

// ── Colour conversion, on the GPU ────────────────────────────────────────────

bool Encoder::Impl::MakeProcessor(UINT srcWidth, UINT srcHeight) {
    Release(processor);
    // Every output view was created against the OLD enumerator. Keeping them
    // across a resize is a use-after-free that presents as a corrupted picture
    // rather than as a crash.
    for (int i = 0; i < kRing; ++i) {
        Release(nv12View[i]);
    }
    Release(enumerator);

    D3D11_VIDEO_PROCESSOR_CONTENT_DESC desc{};
    desc.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    desc.InputWidth = srcWidth;
    desc.InputHeight = srcHeight;
    desc.OutputWidth = width;
    desc.OutputHeight = height;
    desc.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
    if (FAILED(videoDevice->CreateVideoProcessorEnumerator(&desc, &enumerator))) {
        return false;
    }
    if (FAILED(videoDevice->CreateVideoProcessor(enumerator, 0, &processor))) {
        return false;
    }

    // BT.709, limited range on the way out, full range on the way in. Both ends
    // have to agree or the picture is washed out or crushed rather than broken,
    // which is the kind of wrong that survives a review.
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE in{};
    in.RGB_Range = 0;          // full range RGB, which is what WGC hands over
    in.YCbCr_Matrix = 1;       // BT.709
    in.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_0_255;
    videoContext->VideoProcessorSetStreamColorSpace(processor, 0, &in);

    D3D11_VIDEO_PROCESSOR_COLOR_SPACE out{};
    out.YCbCr_Matrix = 1;      // BT.709
    out.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
    videoContext->VideoProcessorSetOutputColorSpace(processor, &out);

    const RECT full{0, 0, (LONG) width, (LONG) height};
    videoContext->VideoProcessorSetOutputTargetRect(processor, TRUE, &full);
    const RECT source{0, 0, (LONG) srcWidth, (LONG) srcHeight};
    videoContext->VideoProcessorSetStreamSourceRect(processor, 0, TRUE, &source);
    videoContext->VideoProcessorSetStreamDestRect(processor, 0, TRUE, &full);
    return true;
}

bool Encoder::Impl::Convert(ID3D11Texture2D* bgra, UINT srcWidth, UINT srcHeight,
                            int slot) {
    if (!processor || srcWidth != sourceWidth || srcHeight != sourceHeight) {
        if (!MakeProcessor(srcWidth, srcHeight)) {
            return false;
        }
        sourceWidth = srcWidth;
        sourceHeight = srcHeight;
        Release(sourceView);
        sourceTexture = nullptr;
    }
    if (bgra != sourceTexture || !sourceView) {
        Release(sourceView);
        D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC viewDesc{};
        viewDesc.FourCC = 0;
        viewDesc.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
        viewDesc.Texture2D.MipSlice = 0;
        if (FAILED(videoDevice->CreateVideoProcessorInputView(
                bgra, enumerator, &viewDesc, &sourceView))) {
            return false;
        }
        sourceTexture = bgra;
    }
    if (!nv12View[slot]) {
        // The output view needs the enumerator, so it cannot be made in Open --
        // the enumerator does not exist until the first source size is known.
        D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC viewDesc{};
        viewDesc.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
        viewDesc.Texture2D.MipSlice = 0;
        if (FAILED(videoDevice->CreateVideoProcessorOutputView(
                nv12[slot], enumerator, &viewDesc, &nv12View[slot]))) {
            return false;
        }
    }

    D3D11_VIDEO_PROCESSOR_STREAM stream{};
    stream.Enable = TRUE;
    stream.pInputSurface = sourceView;
    const HRESULT hr =
        videoContext->VideoProcessorBlt(processor, nv12View[slot], 0, 1, &stream);
    if (FAILED(hr)) {
        return false;
    }
    // The blt is queued on the immediate context; the encoder reads the texture
    // from its own queue. Flushing here is what makes "the encoder saw the
    // frame" true rather than probable.
    context->Flush();
    return true;
}

/// Copy one NV12 texture into a system-memory media buffer.
///
/// NV12 is a full-resolution Y plane followed by an interleaved half-height UV
/// plane, and the mapped row pitch is almost never the width -- the driver picks
/// its own alignment. Copying `height * pitch` bytes straight through would put
/// the padding in the stream and shear the picture.
/// BGRA on the GPU to NV12 in a media buffer, entirely on the CPU.
///
/// BT.709 limited range, integer coefficients, nearest-neighbour scaling. It is
/// not fast and it is not meant to be: it exists so a machine with no video
/// engine streams slowly instead of not at all.
bool Encoder::Impl::ConvertOnCpu(ID3D11Texture2D* bgra, UINT srcWidth, UINT srcHeight,
                                 IMFMediaBuffer** out) {
    if (!stagingBgra || stagingBgraWidth != srcWidth || stagingBgraHeight != srcHeight) {
        Release(stagingBgra);
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = srcWidth;
        desc.Height = srcHeight;
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_STAGING;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        if (FAILED(device->CreateTexture2D(&desc, nullptr, &stagingBgra))) {
            return false;
        }
        stagingBgraWidth = srcWidth;
        stagingBgraHeight = srcHeight;
    }
    context->CopyResource(stagingBgra, bgra);

    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(context->Map(stagingBgra, 0, D3D11_MAP_READ, 0, &mapped))) {
        return false;
    }
    const DWORD bytes = width * height * 3 / 2;
    IMFMediaBuffer* buffer = nullptr;
    if (FAILED(MFCreateMemoryBuffer(bytes, &buffer))) {
        context->Unmap(stagingBgra, 0);
        return false;
    }
    BYTE* destination = nullptr;
    if (FAILED(buffer->Lock(&destination, nullptr, nullptr))) {
        buffer->Release();
        context->Unmap(stagingBgra, 0);
        return false;
    }

    const BYTE* source = (const BYTE*) mapped.pData;
    BYTE* chroma = destination + (size_t) width * height;
    for (UINT y = 0; y < height; ++y) {
        const UINT sy = srcHeight == height ? y : y * srcHeight / height;
        const BYTE* row = source + (size_t) sy * mapped.RowPitch;
        BYTE* luma = destination + (size_t) y * width;
        for (UINT x = 0; x < width; ++x) {
            const UINT sx = srcWidth == width ? x : x * srcWidth / width;
            const BYTE b = row[sx * 4 + 0];
            const BYTE g = row[sx * 4 + 1];
            const BYTE r = row[sx * 4 + 2];
            luma[x] = (BYTE) (((47 * r + 157 * g + 16 * b) >> 8) + 16);
            if ((y & 1) == 0 && (x & 1) == 0) {
                BYTE* uv = chroma + (size_t) (y / 2) * width + x;
                uv[0] = (BYTE) (((-26 * r - 87 * g + 113 * b) >> 8) + 128);
                uv[1] = (BYTE) (((113 * r - 102 * g - 11 * b) >> 8) + 128);
            }
        }
    }

    buffer->Unlock();
    buffer->SetCurrentLength(bytes);
    context->Unmap(stagingBgra, 0);
    *out = buffer;
    return true;
}

bool Encoder::Impl::ReadBackNv12(int slot, IMFMediaBuffer** out) {
    if (!staging) {
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = width;
        desc.Height = height;
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_NV12;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_STAGING;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        if (FAILED(device->CreateTexture2D(&desc, nullptr, &staging))) {
            return false;
        }
    }
    context->CopyResource(staging, nv12[slot]);

    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped))) {
        return false;
    }
    const DWORD bytes = width * height * 3 / 2;
    IMFMediaBuffer* buffer = nullptr;
    if (FAILED(MFCreateMemoryBuffer(bytes, &buffer))) {
        context->Unmap(staging, 0);
        return false;
    }
    BYTE* destination = nullptr;
    if (FAILED(buffer->Lock(&destination, nullptr, nullptr))) {
        buffer->Release();
        context->Unmap(staging, 0);
        return false;
    }
    const BYTE* source = (const BYTE*) mapped.pData;
    for (UINT row = 0; row < height; ++row) {
        memcpy(destination + (size_t) row * width, source + (size_t) row * mapped.RowPitch,
               width);
    }
    const BYTE* chroma = source + (size_t) height * mapped.RowPitch;
    BYTE* chromaOut = destination + (size_t) width * height;
    for (UINT row = 0; row < height / 2; ++row) {
        memcpy(chromaOut + (size_t) row * width,
               chroma + (size_t) row * mapped.RowPitch, width);
    }
    buffer->Unlock();
    buffer->SetCurrentLength(bytes);
    context->Unmap(staging, 0);
    *out = buffer;
    return true;
}

// ── Submitting and draining ──────────────────────────────────────────────────

bool Encoder::Impl::FeedLocked() {
    if (!havePending) { return false; }
    havePending = false;

    // Not spent until ProcessInput has taken the frame: see feed_ledger.h.
    const uint32_t frameId = ledger.NextFrameId();
    meta[frameId % kMetaRing].capturedAt = pendingCapturedAt;
    meta[frameId % kMetaRing].emitted = false;

    IMFMediaBuffer* buffer = nullptr;
    if (async) {
        // THE POINT OF THE WHOLE PATH: the encoder is handed the texture, and
        // the frame never touches the CPU.
        if (FAILED(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), nv12[pendingSlot],
                                             0, FALSE, &buffer))) {
            return false;
        }
        IMF2DBuffer* two = nullptr;
        if (SUCCEEDED(buffer->QueryInterface(__uuidof(IMF2DBuffer), (void**) &two))) {
            DWORD length = 0;
            if (SUCCEEDED(two->GetContiguousLength(&length))) {
                buffer->SetCurrentLength(length);
            }
            two->Release();
        }
    } else if (cpuOnly) {
        // No video engine at all: the captured BGRA comes back to the CPU and
        // the colour conversion happens here.
        if (!ConvertOnCpu(pendingBgra, pendingSrcWidth, pendingSrcHeight, &buffer)) {
            return false;
        }
    } else {
        // The software encoder is not D3D-aware, so the NV12 has to come back
        // across the bus. This is exactly the copy the hardware path exists to
        // avoid, and it is why this mode is a fallback rather than an option.
        if (!ReadBackNv12(pendingSlot, &buffer)) {
            return false;
        }
    }

    IMFSample* sample = nullptr;
    if (FAILED(MFCreateSample(&sample))) {
        Release(buffer);
        return false;
    }
    // Unchecked, a failed AddBuffer left an empty sample: the frame's pixels are
    // in `buffer` and nothing else refers to it, so what went into ProcessInput
    // below would have been a timestamp with no picture attached to it.
    if (FAILED(sample->AddBuffer(buffer))) {
        Release(sample);
        Release(buffer);
        return false;
    }
    // ONE INTEGER TICK PER FRAME, so the timestamp divides back exactly.
    //
    // The obvious form -- frameId * 10^7 / fps -- does not round-trip. At 60 fps
    // it truncates to 166666 ticks a frame, and recovering the frame id as
    // time * fps / 10^7 then loses one in three: frame 3 comes back as frame 2.
    // The dev box reported "extra samples 116" out of 349 pictures, which is
    // exactly a third, and every one of those was a picture attributed to the
    // wrong capture time.
    sample->SetSampleTime((LONGLONG) frameId * ticksPerFrame);
    sample->SetSampleDuration(ticksPerFrame);

    const bool idr = ledger.TakeIdr(pendingIdr);
    if (idr) {
        VARIANT on{};
        on.vt = VT_UI4;
        on.ulVal = 1;
        if (codec) { codec->SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &on); }
    }

    // ProcessInput can refuse -- MF_E_NOTACCEPTING when the credit was stale,
    // or an outright failure. Its HRESULT was dropped and the frame counted as
    // submitted either way, so the pictures/submitted pair in the five-second
    // log counted frames the MFT never took and the ratio looked like dropped
    // output rather than input that never went in.
    const HRESULT fed = mft->ProcessInput(0, sample, 0);
    Release(sample);
    Release(buffer);
    if (FAILED(fed)) {
        ledger.Refused(idr);
        return false;
    }
    ledger.Accepted();
    submitted.fetch_add(1);
    return true;
}

void Encoder::Impl::Drain() {
    // Drain until the encoder has nothing left, emitting a picture every time
    // the sample timestamp changes.
    //
    // One picture can arrive as more than one sample, and MORE THAN ONE PICTURE
    // can arrive in a single drain -- 35 of the first 106 pictures on the dev
    // box did. Concatenating those into one buffer glues two access units
    // together, which a decoder does not report as an error: it shows a broken
    // picture, or a right one and a missing one. So the timestamp is the
    // boundary, and it is acted on rather than merely counted.
    picture.clear();
    LONGLONG pictureTime = -1;
    bool isIdr = false;
    int changes = 0;

    for (;;) {
        MFT_OUTPUT_STREAM_INFO info{};
        if (FAILED(mft->GetOutputStreamInfo(0, &info))) {
            // Without this the flags stayed zero, which reads as "the transform
            // does not allocate", and the sample below was made and fed to a
            // transform that had just said it could not describe its own output.
            break;
        }
        const bool allocates =
            (info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES
                             | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
        IMFSample* outSample = nullptr;
        IMFMediaBuffer* outBuffer = nullptr;
        if (!allocates) {
            // All three were unchecked. MFCreateSample fails under memory
            // pressure like anything else, and AddBuffer was then called on a
            // null pointer -- a crash on an MF work-queue thread, with the last
            // line in the log being an ordinary frame.
            if (FAILED(MFCreateSample(&outSample))
                || FAILED(MFCreateMemoryBuffer(info.cbSize ? info.cbSize : (1u << 21),
                                               &outBuffer))
                || FAILED(outSample->AddBuffer(outBuffer))) {
                Release(outSample);
                Release(outBuffer);
                break;
            }
        }
        MFT_OUTPUT_DATA_BUFFER out{};
        out.dwStreamID = 0;
        out.pSample = outSample;
        DWORD status = 0;
        const HRESULT got = mft->ProcessOutput(0, 1, &out, &status);
        if (FAILED(got)) {
            Release(outSample);
            Release(outBuffer);
            if (out.pEvents) { out.pEvents->Release(); }
            // Every failure used to end the drain silently, which is right for
            // most of them and wrong for the one that matters. STREAM_CHANGE is
            // not a failure at all -- the transform is telling us its output type
            // has changed and it will produce nothing further until the new type
            // is set, so treating it as "nothing more to drain" left the encoder
            // silent for the rest of the session with no error anywhere.
            //
            // NEED_MORE_INPUT is the ordinary end: the encoder has given up
            // everything it has. E_UNEXPECTED is the same thing said badly, and
            // it is BY FAR the common case here rather than an edge: measured on
            // the dev box's NVIDIA MFT, a 20-second session that delivered 314
            // of 316 pictures with nothing damaged answered E_UNEXPECTED 396
            // times. The asynchronous transform raises a NEED_INPUT/HAVE_OUTPUT
            // event and then has nothing by the time the drain arrives, and this
            // is what it says about that. Logging it cost 396 lines and rolled
            // the megabyte log in minutes, which is how a diagnostic becomes the
            // thing that destroys the evidence.
            if (got == MF_E_TRANSFORM_NEED_MORE_INPUT || got == E_UNEXPECTED) {
                break;
            }
            if (got == MF_E_TRANSFORM_STREAM_CHANGE) {
                if (++changes > kMaxFormatChanges) {
                    Log("[media] the encoder keeps changing its output format; "
                        "abandoning this drain");
                    break;
                }
                IMFMediaType* changed = nullptr;
                HRESULT renegotiated = mft->GetOutputAvailableType(0, 0, &changed);
                if (SUCCEEDED(renegotiated) && changed) {
                    renegotiated = mft->SetOutputType(0, changed, 0);
                    changed->Release();
                }
                if (FAILED(renegotiated)) {
                    Log("[media] the encoder changed its output format and would "
                        "not accept the new type (0x%08lX)", renegotiated);
                    break;
                }
                // The parameter sets described the old format. Dropping the
                // cached copy is what makes Emit ask the transform again on the
                // next IDR that arrives without them inlined, rather than
                // prefixing a stale SPS that no longer describes the stream.
                sequenceHeader.clear();
                continue;
            }
            // Rate-limited, for the reason above: a per-frame failure logged per
            // frame is a log that holds nothing but that failure. Once every five
            // seconds, carrying how many were swallowed, keeps a persistent
            // problem visible without letting it push everything else out.
            ++drainFailures;
            const long long complainedAt = Now();
            if (lastDrainComplaint == 0
                || (complainedAt - lastDrainComplaint) > QpcFrequency() * 5) {
                Log("[media] the encoder would not produce output (0x%08lX), "
                    "%llu time%s so far", got,
                    (unsigned long long) drainFailures,
                    drainFailures == 1 ? "" : "s");
                lastDrainComplaint = complainedAt;
            }
            break;
        }
        IMFSample* result = out.pSample;
        if (!result) {
            // Success with nothing handed over. Dereferencing that is the same
            // crash as the null sample above, one branch further on.
            Release(outSample);
            Release(outBuffer);
            if (out.pEvents) { out.pEvents->Release(); }
            break;
        }
        LONGLONG time = 0;
        result->GetSampleTime(&time);
        UINT32 clean = 0;
        result->GetUINT32(MFSampleExtension_CleanPoint, &clean);

        if (pictureTime >= 0 && time != pictureTime) {
            Emit(pictureTime, isIdr);
            picture.clear();
            isIdr = false;
        }

        IMFMediaBuffer* contiguous = nullptr;
        if (SUCCEEDED(result->ConvertToContiguousBuffer(&contiguous)) && contiguous) {
            BYTE* data = nullptr;
            DWORD length = 0;
            if (SUCCEEDED(contiguous->Lock(&data, nullptr, &length))) {
                picture.insert(picture.end(), data, data + length);
                contiguous->Unlock();
            }
            contiguous->Release();
        }
        pictureTime = time;
        isIdr = isIdr || clean != 0;

        Release(result);
        Release(outBuffer);
        if (out.pEvents) { out.pEvents->Release(); }
    }

    Emit(pictureTime, isIdr);
}

void Encoder::Impl::Emit(LONGLONG pictureTime, bool isIdr) {
    if (picture.empty() || pictureTime < 0) {
        return;
    }
    const uint32_t frameId = (uint32_t) (pictureTime / ticksPerFrame);
    Meta& m = meta[frameId % kMetaRing];

    if (isIdr && !StartsWithSps(picture.data(), picture.size())) {
        if (sequenceHeader.empty() && mft) {
            // Open read MF_MT_MPEG_SEQUENCE_HEADER before NOTIFY_BEGIN_STREAMING,
            // and some drivers do not fill it in until they have encoded
            // something. When that happened the header stayed empty for the
            // whole session and every IDR went out with no SPS and no PPS in
            // front of it -- which nothing here reports, because the encoder is
            // happy and it is the receiver that cannot decode. Ask again now
            // that a picture exists. Only on an IDR the encoder did not inline
            // the parameter sets into, so this is a handful of calls in a
            // session rather than one per frame, and it stops asking the moment
            // an answer arrives.
            IMFMediaType* current = nullptr;
            if (SUCCEEDED(mft->GetOutputCurrentType(0, &current)) && current) {
                UINT32 length = 0;
                if (SUCCEEDED(current->GetBlobSize(MF_MT_MPEG_SEQUENCE_HEADER, &length))
                    && length > 0) {
                    sequenceHeader.resize(length);
                    current->GetBlob(MF_MT_MPEG_SEQUENCE_HEADER, sequenceHeader.data(),
                                     length, &length);
                }
                current->Release();
            }
        }
        if (!sequenceHeader.empty()) {
            picture.insert(picture.begin(), sequenceHeader.begin(), sequenceHeader.end());
        }
    }

    if (m.emitted) {
        // The same picture twice means one output sample is NOT one picture and
        // the timestamp boundary above did not catch it. Counted rather than
        // hidden: it changes what the packetizer is allowed to assume.
        extraSamples.fetch_add(1);
    }
    m.emitted = true;
    pictures.fetch_add(1);

    if (sink) {
        CodedPicture coded;
        coded.data = picture.data();
        coded.length = picture.size();
        coded.frameId = frameId;
        coded.isIdr = isIdr;
        coded.capturedAt = m.capturedAt;
        coded.encodedAt = Now();
        sink(coded);
    }
}

// ── Lifetime ─────────────────────────────────────────────────────────────────

Encoder::Encoder() : impl_(std::make_unique<Impl>()) {}
Encoder::~Encoder() {
    Close();
    // Drop the sink while there is still a live object to drop it from. Close
    // has just made sure no callback is inside Emit, so this is the point at
    // which whatever the caller captured -- a session, a queue, a lock -- can be
    // destroyed without something being part-way through calling it. It is not
    // done in Close because Open calls Close, and clearing it there would throw
    // away a sink attached before Open.
    impl_->sink = nullptr;
}

/// The encoder's tuning, applied through ICodecAPI.
///
/// Keyframes on request only: the GOP is an hour long, so the only IDRs are
/// the first, the ones the client asks for when it detects loss, and the ones
/// a new pass starts with. The client detects every loss -- a damaged picture,
/// and since 10-21 a picture lost whole -- and freezes on the last good one
/// until the IDR it asked for arrives, so a periodic refresh buys nothing and
/// costs a burst the size of six ordinary frames every second.
void ApplyCodecSettings(Encoder::Impl& s) {
    VARIANT v{};
    v.vt = VT_BOOL;
    v.boolVal = VARIANT_TRUE;
    s.codec->SetValue(&CODECAPI_AVLowLatencyMode, &v);
    VARIANT mode{};
    mode.vt = VT_UI4;
    mode.ulVal = eAVEncCommonRateControlMode_CBR;
    s.codec->SetValue(&CODECAPI_AVEncCommonRateControlMode, &mode);
    VARIANT rate{};
    rate.vt = VT_UI4;
    rate.ulVal = s.bitrate;
    s.codec->SetValue(&CODECAPI_AVEncCommonMeanBitRate, &rate);
    VARIANT gop{};
    gop.vt = VT_UI4;
    gop.ulVal = (s.fps ? s.fps : 60) * 3600;
    s.codec->SetValue(&CODECAPI_AVEncMPVGOPSize, &gop);
}

bool Encoder::Open(ID3D11Device* device, UINT width, UINT height, UINT fps,
                   UINT bitrateBps) {
    Impl& s = *impl_;
    Close();

    // H.264 wants even dimensions; a window can be any odd size at all.
    s.width = width & ~1u;
    s.height = height & ~1u;
    s.fps = fps ? fps : 60;
    s.ticksPerFrame = 10000000LL / (LONGLONG) s.fps;
    s.bitrate = bitrateBps;
    if (s.width < 16 || s.height < 16) {
        return false;
    }

    s.device = device;
    s.device->AddRef();
    s.device->GetImmediateContext(&s.context);
    if (FAILED(s.device->QueryInterface(__uuidof(ID3D11VideoDevice),
                                        (void**) &s.videoDevice))
        || FAILED(s.context->QueryInterface(__uuidof(ID3D11VideoContext),
                                            (void**) &s.videoContext))) {
        // A Hyper-V guest reports exactly this. There is no VideoProcessor to
        // convert BGRA to NV12 with, so the conversion moves to the CPU and the
        // NV12 ring is never allocated.
        Log("[media] this D3D11 device has no video engine; converting on the CPU");
        Release(s.videoDevice);
        Release(s.videoContext);
        s.cpuOnly = true;
    }

    for (int i = 0; i < kRing && !s.cpuOnly; ++i) {
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = s.width;
        desc.Height = s.height;
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_NV12;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_RENDER_TARGET;
        if (FAILED(s.device->CreateTexture2D(&desc, nullptr, &s.nv12[i]))) {
            Log("[media] could not allocate an NV12 %ux%u texture", s.width, s.height);
            Close();
            return false;
        }
    }

    // ── The transform ────────────────────────────────────────────────────────
    // HARDWARE FIRST, THEN ANYTHING.
    //
    // Asking only for hardware means SolStream cannot stream at all on a machine
    // without an H.264 encoder in its GPU -- a virtual machine, a thin client, an
    // old laptop. Windows ships a software H.264 MFT for exactly that case. It is
    // far slower and it is synchronous rather than event-driven, so the pump
    // below has two shapes; degrading to it beats refusing to run.
    MFT_REGISTER_TYPE_INFO outInfo{MFMediaType_Video, MFVideoFormat_H264};
    IMFActivate** activates = nullptr;
    UINT32 count = 0;
    HRESULT enumerated = S_OK;
    bool hardware = false;
    if (!s.cpuOnly) {
        enumerated = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                               MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                               nullptr, &outInfo, &activates, &count);
        hardware = SUCCEEDED(enumerated) && count > 0;
    }
    if (!hardware) {
        if (activates) { CoTaskMemFree(activates); activates = nullptr; }
        count = 0;
        enumerated = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                               MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT
                                   | MFT_ENUM_FLAG_SORTANDFILTER,
                               nullptr, &outInfo, &activates, &count);
    }
    if (FAILED(enumerated) || count == 0) {
        Log("[media] this PC has no H.264 encoder at all, hardware or software");
        Close();
        return false;
    }
    if (!hardware) {
        Log("[media] no hardware H.264 encoder; falling back to software, which "
            "will not keep up at a high resolution");
    }
    const HRESULT activated = activates[0]->ActivateObject(IID_PPV_ARGS(&s.mft));
    for (UINT32 i = 0; i < count; ++i) { activates[i]->Release(); }
    CoTaskMemFree(activates);
    if (FAILED(activated)) {
        Log("[media] the encoder would not activate (0x%08lX)", activated);
        Close();
        return false;
    }

    // Unlock and attach the device manager BEFORE type negotiation. Both fail
    // by pointing somewhere else if they are done in the order that reads
    // naturally; see the header.
    {
        IMFAttributes* attributes = nullptr;
        if (SUCCEEDED(s.mft->GetAttributes(&attributes)) && attributes) {
            UINT32 async = 0;
            attributes->GetUINT32(MF_TRANSFORM_ASYNC, &async);
            if (async) { attributes->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, 1); }
            s.async = async != 0;
            attributes->Release();
        }
    }
    if (hardware) {
        UINT token = 0;
        if (SUCCEEDED(MFCreateDXGIDeviceManager(&token, &s.manager))) {
            if (SUCCEEDED(s.manager->ResetDevice(s.device, token))) {
                s.mft->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER,
                                      (ULONG_PTR) s.manager);
            }
        }
    }

    // Before type negotiation. Set only afterwards, as this used to be, the
    // NVIDIA MFT accepted every property and kept its defaults: low latency
    // read back OFF, and a keyframe every 60 frames that nobody asked for --
    // ~120 KB bursts once a second, the frames most likely to lose a fragment
    // on Wi-Fi, each costing ~25 ms of pacing.
    s.mft->QueryInterface(IID_PPV_ARGS(&s.codec));
    if (s.codec) {
        ApplyCodecSettings(s);
    }

    IMFMediaType* outType = nullptr;
    // Checked because the next line dereferences it. MFStartup belongs to the
    // session that owns this encoder rather than to this class, so an Open on a
    // thread where Media Foundation is not running answers MF_E_SHUTDOWN here --
    // and unchecked that was a null dereference one line later rather than the
    // log line below.
    if (FAILED(MFCreateMediaType(&outType)) || !outType) {
        Log("[media] could not create the H.264 output media type");
        Close();
        return false;
    }
    outType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    outType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    outType->SetUINT32(MF_MT_AVG_BITRATE, s.bitrate);
    MFSetAttributeSize(outType, MF_MT_FRAME_SIZE, s.width, s.height);
    MFSetAttributeRatio(outType, MF_MT_FRAME_RATE, s.fps, 1);
    MFSetAttributeRatio(outType, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    outType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    outType->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High);
    HRESULT hr = s.mft->SetOutputType(0, outType, 0);
    Release(outType);
    if (FAILED(hr)) {
        Log("[media] the encoder refused H.264 %ux%u at %u kbit/s (0x%08lX)",
            s.width, s.height, s.bitrate / 1000, hr);
        Close();
        return false;
    }

    IMFMediaType* inType = nullptr;
    if (FAILED(MFCreateMediaType(&inType)) || !inType) {
        Log("[media] could not create the NV12 input media type");
        Close();
        return false;
    }
    inType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    inType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    MFSetAttributeSize(inType, MF_MT_FRAME_SIZE, s.width, s.height);
    MFSetAttributeRatio(inType, MF_MT_FRAME_RATE, s.fps, 1);
    MFSetAttributeRatio(inType, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    inType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    inType->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
    inType->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
    hr = s.mft->SetInputType(0, inType, 0);
    Release(inType);
    if (FAILED(hr)) {
        Log("[media] the encoder refused NV12 %ux%u (0x%08lX)", s.width, s.height, hr);
        Close();
        return false;
    }

    if (s.codec) {
        // And again now the types are set: some MFTs only take these after
        // negotiation, others only before (see above), and asking twice is
        // harmless where both are accepted.
        ApplyCodecSettings(s);
        // What the encoder actually settled on, said once per pass. Several
        // hardware MFTs accept a property and ignore it, and every tuning
        // decision about keyframe size and frequency starts from these.
        auto setting = [&](const GUID& key) -> long long {
            VARIANT value{};
            if (FAILED(s.codec->GetValue(&key, &value))) { return -1; }
            switch (value.vt) {
                case VT_UI4: return (long long) value.ulVal;
                case VT_UI8: return (long long) value.ullVal;
                case VT_BOOL: return value.boolVal ? 1 : 0;
                default: return -2;
            }
        };
        Log("[media] encoder settings: low latency %lld, rate mode %lld, gop %lld,"
            " b-frames %lld, vbv %lld bits",
            setting(CODECAPI_AVLowLatencyMode),
            setting(CODECAPI_AVEncCommonRateControlMode),
            setting(CODECAPI_AVEncMPVGOPSize),
            setting(CODECAPI_AVEncMPVDefaultBPictureCount),
            setting(CODECAPI_AVEncCommonBufferSize));
        // SLICES ARE LEFT ALONE. spike/mf-encode asked for four per frame and
        // got 1.5, and a packetizer that assumes one output sample is one
        // picture is correct only when it is. The Drain above counts every
        // sample that says otherwise rather than trusting either answer.
    }

    // The sequence header is only populated once the type is committed, and on
    // some drivers only after streaming starts -- so it is read here, and Emit
    // reads it again on the first IDR that arrives without one if this comes
    // back empty.
    {
        IMFMediaType* current = nullptr;
        if (SUCCEEDED(s.mft->GetOutputCurrentType(0, &current)) && current) {
            UINT32 length = 0;
            if (SUCCEEDED(current->GetBlobSize(MF_MT_MPEG_SEQUENCE_HEADER, &length))
                && length > 0) {
                s.sequenceHeader.resize(length);
                current->GetBlob(MF_MT_MPEG_SEQUENCE_HEADER, s.sequenceHeader.data(),
                                 length, &length);
            }
            current->Release();
        }
    }

    s.mft->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    s.mft->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

    s.running.store(true);
    if (s.async && SUCCEEDED(s.mft->QueryInterface(IID_PPV_ARGS(&s.events)))) {
        s.callback = new EncoderCallback();
        s.callback->owner = &s;
        s.events->BeginGetEvent(s.callback, nullptr);
    } else {
        // Synchronous: nothing will ask for input, so Submit feeds and drains
        // on the caller's thread.
        s.async = false;
    }
    return true;
}

void Encoder::Close() {
    Impl& s = *impl_;
    s.running.store(false);
    // Detach the callback FIRST, and block here until any Invoke that got past
    // its `running` test has left. Everything below this point releases
    // something that Invoke dereferences, so it cannot start until the callback
    // is provably out.
    //
    // The gate is taken and dropped before the drain rather than held across
    // it. MFT_MESSAGE_COMMAND_DRAIN makes the MFT emit more events, and holding
    // the lock the callback needs while deliberately provoking the callback is
    // the one arrangement here that could deadlock. Ordered this way the drain
    // runs with no callback in flight and no callback able to start: `owner` is
    // already null, so whatever it provokes returns immediately. The tail of
    // the encode is thrown away, which is what a stop is.
    if (s.callback) {
        {
            std::lock_guard<std::mutex> guard(s.callback->gate);
            s.callback->owner = nullptr;
        }
        s.callback->Release();
        s.callback = nullptr;
    }
    if (s.mft) {
        s.mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        s.mft->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
        s.mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    }
    Release(s.events);
    Release(s.codec);
    Release(s.mft);
    Release(s.manager);
    Release(s.sourceView);
    s.sourceTexture = nullptr;
    Release(s.staging);
    Release(s.stagingBgra);
    s.stagingBgraWidth = s.stagingBgraHeight = 0;
    for (int i = 0; i < kRing; ++i) {
        Release(s.nv12View[i]);
        Release(s.nv12[i]);
    }
    Release(s.processor);
    Release(s.enumerator);
    Release(s.videoContext);
    Release(s.videoDevice);
    Release(s.context);
    Release(s.device);
    s.sequenceHeader.clear();
    s.sourceWidth = s.sourceHeight = 0;
    // The need-input credits belonged to the transform that has just gone, and
    // the pending frame points at a texture released above. Carrying either
    // into a later Open on the same Encoder would feed a transform that never
    // asked -- and now that a refused ProcessInput hands the credit back
    // instead of swallowing it, that stale credit would be retried for ever.
    s.needInput = 0;
    s.havePending = false;
    // And the reference Submit took on the last captured texture, which is this
    // object's to drop rather than the capture's.
    Release(s.pendingBgra);
}

bool Encoder::Running() const { return impl_->running.load(); }
UINT Encoder::Width() const { return impl_->width; }
UINT Encoder::Height() const { return impl_->height; }

void Encoder::OnPicture(PictureSink sink) { impl_->sink = std::move(sink); }

bool Encoder::Submit(ID3D11Texture2D* bgra, UINT srcWidth, UINT srcHeight,
                     long long capturedAt, bool forceIdr) {
    Impl& s = *impl_;
    if (!s.running.load() || !bgra) {
        return false;
    }
    int slot = 0;
    if (!s.cpuOnly) {
        slot = s.nextSlot;
        s.nextSlot = (s.nextSlot + 1) % kRing;
        if (!s.Convert(bgra, srcWidth, srcHeight, slot)) {
            s.dropped.fetch_add(1);
            return false;
        }
    }

    std::lock_guard<std::mutex> guard(s.lock);
    // A reference of its own, not the caller's. On the cpuOnly path this texture
    // is read in FeedLocked, and on an asynchronous transform FeedLocked runs
    // from the event callback -- another thread, after Submit has returned and
    // after the capture frame the caller was holding has gone out of scope. The
    // reference is held until the next frame replaces it or Close drops it.
    if (bgra != s.pendingBgra) {
        bgra->AddRef();
        Release(s.pendingBgra);
        s.pendingBgra = bgra;
    }
    s.pendingSrcWidth = srcWidth;
    s.pendingSrcHeight = srcHeight;
    if (s.havePending) {
        s.dropped.fetch_add(1);   // latest wins
    }
    s.havePending = true;
    s.pendingSlot = slot;
    s.pendingCapturedAt = capturedAt;
    s.pendingIdr = forceIdr;
    if (!s.async) {
        // No events are coming. Feed it and take whatever comes out, here.
        s.FeedLocked();
        s.Drain();
        return true;
    }
    if (s.needInput > 0 && s.FeedLocked()) {
        // Spent only on a frame the MFT took. Decrementing first and feeding
        // afterwards threw the credit away whenever the feed failed, and the
        // encoder then waited for a METransformNeedInput that had already been
        // delivered and consumed.
        --s.needInput;
    }
    return true;
}

void Encoder::RequestIdr() { impl_->ledger.RequestIdr(); }

bool Encoder::IdrPending() const { return impl_->ledger.IdrPending(); }

void Encoder::SetBitrate(UINT bitrateBps) {
    Impl& s = *impl_;
    s.bitrate = bitrateBps;
    if (s.codec) {
        VARIANT rate{};
        rate.vt = VT_UI4;
        rate.ulVal = bitrateBps;
        s.codec->SetValue(&CODECAPI_AVEncCommonMeanBitRate, &rate);
    }
}

uint64_t Encoder::Submitted() const { return impl_->submitted.load(); }
uint64_t Encoder::Pictures() const { return impl_->pictures.load(); }
uint64_t Encoder::Dropped() const { return impl_->dropped.load(); }
uint64_t Encoder::ExtraSamples() const { return impl_->extraSamples.load(); }

}  // namespace solstream::media
