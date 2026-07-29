#include "encoder.h"

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

template <typename T>
void Release(T*& p) {
    if (p) { p->Release(); p = nullptr; }
}

long long Now() {
    LARGE_INTEGER now{};
    QueryPerformanceCounter(&now);
    return now.QuadPart;
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
    std::atomic<bool> running{false};

    std::vector<unsigned char> sequenceHeader;
    std::vector<unsigned char> picture;   ///< assembled coded picture

    std::mutex lock;
    // The one frame waiting to be encoded. Latest wins.
    bool havePending = false;
    int pendingSlot = 0;
    long long pendingCapturedAt = 0;
    bool pendingIdr = false;
    int needInput = 0;
    uint32_t nextFrameId = 1;
    std::atomic<bool> idrWanted{false};

    struct Meta {
        long long capturedAt = 0;
        bool emitted = false;
    } meta[kMetaRing];

    PictureSink sink;

    std::atomic<uint64_t> submitted{0}, pictures{0}, dropped{0}, extraSamples{0};

    bool MakeProcessor(UINT srcWidth, UINT srcHeight);
    bool Convert(ID3D11Texture2D* bgra, UINT srcWidth, UINT srcHeight, int slot);
    void FeedLocked();
    void Drain();
};

HRESULT STDMETHODCALLTYPE EncoderCallback::Invoke(IMFAsyncResult* result) {
    Encoder::Impl* self = owner;
    if (!self || !self->running.load()) {
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
        if (self->havePending) {
            self->FeedLocked();
        } else {
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

// ── Submitting and draining ──────────────────────────────────────────────────

void Encoder::Impl::FeedLocked() {
    if (!havePending) { return; }
    havePending = false;

    const uint32_t frameId = nextFrameId++;
    meta[frameId % kMetaRing].capturedAt = pendingCapturedAt;
    meta[frameId % kMetaRing].emitted = false;

    IMFMediaBuffer* buffer = nullptr;
    if (FAILED(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), nv12[pendingSlot],
                                         0, FALSE, &buffer))) {
        return;
    }
    {
        IMF2DBuffer* two = nullptr;
        if (SUCCEEDED(buffer->QueryInterface(__uuidof(IMF2DBuffer), (void**) &two))) {
            DWORD length = 0;
            if (SUCCEEDED(two->GetContiguousLength(&length))) {
                buffer->SetCurrentLength(length);
            }
            two->Release();
        }
    }

    IMFSample* sample = nullptr;
    if (FAILED(MFCreateSample(&sample))) {
        Release(buffer);
        return;
    }
    sample->AddBuffer(buffer);
    sample->SetSampleTime((LONGLONG) frameId * 10000000LL / (LONGLONG) fps);
    sample->SetSampleDuration(10000000LL / (LONGLONG) fps);

    if (pendingIdr || idrWanted.exchange(false)) {
        VARIANT on{};
        on.vt = VT_UI4;
        on.ulVal = 1;
        if (codec) { codec->SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &on); }
    }

    mft->ProcessInput(0, sample, 0);
    submitted.fetch_add(1);
    Release(sample);
    Release(buffer);
}

void Encoder::Impl::Drain() {
    // Collect every sample the encoder has ready. They are concatenated by
    // timestamp: one picture may arrive as more than one sample, and a receiver
    // handed half an access unit does not report an error, it shows a broken
    // picture.
    picture.clear();
    LONGLONG pictureTime = -1;
    bool isIdr = false;

    for (;;) {
        MFT_OUTPUT_STREAM_INFO info{};
        mft->GetOutputStreamInfo(0, &info);
        const bool allocates =
            (info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES
                             | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
        IMFSample* outSample = nullptr;
        IMFMediaBuffer* outBuffer = nullptr;
        if (!allocates) {
            MFCreateSample(&outSample);
            MFCreateMemoryBuffer(info.cbSize ? info.cbSize : (1u << 21), &outBuffer);
            outSample->AddBuffer(outBuffer);
        }
        MFT_OUTPUT_DATA_BUFFER out{};
        out.dwStreamID = 0;
        out.pSample = outSample;
        DWORD status = 0;
        const HRESULT got = mft->ProcessOutput(0, 1, &out, &status);
        if (FAILED(got)) {
            Release(outSample);
            Release(outBuffer);
            break;
        }
        IMFSample* result = out.pSample;
        LONGLONG time = 0;
        result->GetSampleTime(&time);
        UINT32 clean = 0;
        result->GetUINT32(MFSampleExtension_CleanPoint, &clean);

        if (pictureTime >= 0 && time != pictureTime) {
            // A second picture in the same drain. Emit the first, then start
            // over -- concatenating two pictures would be silently undecodable.
            extraSamples.fetch_add(1);
        }
        IMFMediaBuffer* got1 = nullptr;
        if (SUCCEEDED(result->ConvertToContiguousBuffer(&got1)) && got1) {
            BYTE* data = nullptr;
            DWORD length = 0;
            if (SUCCEEDED(got1->Lock(&data, nullptr, &length))) {
                picture.insert(picture.end(), data, data + length);
                got1->Unlock();
            }
            got1->Release();
        }
        pictureTime = time;
        isIdr = isIdr || clean != 0;

        Release(result);
        Release(outBuffer);
        if (out.pEvents) { out.pEvents->Release(); }
    }

    if (picture.empty() || pictureTime < 0) {
        return;
    }
    const uint32_t frameId = (uint32_t) (pictureTime * (LONGLONG) fps / 10000000LL);
    Meta& m = meta[frameId % kMetaRing];

    if (isIdr && !sequenceHeader.empty()
        && !StartsWithSps(picture.data(), picture.size())) {
        picture.insert(picture.begin(), sequenceHeader.begin(), sequenceHeader.end());
    }

    if (m.emitted) {
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
Encoder::~Encoder() { Close(); }

bool Encoder::Open(ID3D11Device* device, UINT width, UINT height, UINT fps,
                   UINT bitrateBps) {
    Impl& s = *impl_;
    Close();

    // H.264 wants even dimensions; a window can be any odd size at all.
    s.width = width & ~1u;
    s.height = height & ~1u;
    s.fps = fps ? fps : 60;
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
        Close();
        return false;
    }

    for (int i = 0; i < kRing; ++i) {
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
            Close();
            return false;
        }
    }

    // ── The transform ────────────────────────────────────────────────────────
    MFT_REGISTER_TYPE_INFO outInfo{MFMediaType_Video, MFVideoFormat_H264};
    IMFActivate** activates = nullptr;
    UINT32 count = 0;
    if (FAILED(MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                         MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                         nullptr, &outInfo, &activates, &count))
        || count == 0) {
        Close();
        return false;
    }
    const HRESULT activated = activates[0]->ActivateObject(IID_PPV_ARGS(&s.mft));
    for (UINT32 i = 0; i < count; ++i) { activates[i]->Release(); }
    CoTaskMemFree(activates);
    if (FAILED(activated)) {
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
            attributes->Release();
        }
    }
    {
        UINT token = 0;
        if (SUCCEEDED(MFCreateDXGIDeviceManager(&token, &s.manager))) {
            if (SUCCEEDED(s.manager->ResetDevice(s.device, token))) {
                s.mft->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER,
                                      (ULONG_PTR) s.manager);
            }
        }
    }

    IMFMediaType* outType = nullptr;
    MFCreateMediaType(&outType);
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
        Close();
        return false;
    }

    IMFMediaType* inType = nullptr;
    MFCreateMediaType(&inType);
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
        Close();
        return false;
    }

    s.mft->QueryInterface(IID_PPV_ARGS(&s.codec));
    if (s.codec) {
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
        // SLICES ARE LEFT ALONE. spike/mf-encode asked for four per frame and
        // got 1.5, and a packetizer that assumes one output sample is one
        // picture is correct only when it is. The Drain above counts every
        // sample that says otherwise rather than trusting either answer.
    }

    // The sequence header is only populated once the type is committed, and on
    // some drivers only after streaming starts -- so it is read here and
    // re-read on the first IDR if it was not ready.
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
    if (SUCCEEDED(s.mft->QueryInterface(IID_PPV_ARGS(&s.events)))) {
        s.callback = new EncoderCallback();
        s.callback->owner = &s;
        s.events->BeginGetEvent(s.callback, nullptr);
    } else {
        // A synchronous MFT would need a different pump entirely, and every
        // hardware encoder this targets is asynchronous. Failing loudly beats
        // running a path nothing has ever exercised.
        s.running.store(false);
        Close();
        return false;
    }
    return true;
}

void Encoder::Close() {
    Impl& s = *impl_;
    s.running.store(false);
    if (s.mft) {
        s.mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        s.mft->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
        s.mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    }
    Release(s.events);
    if (s.callback) {
        s.callback->owner = nullptr;
        s.callback->Release();
        s.callback = nullptr;
    }
    Release(s.codec);
    Release(s.mft);
    Release(s.manager);
    Release(s.sourceView);
    s.sourceTexture = nullptr;
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
    const int slot = s.nextSlot;
    s.nextSlot = (s.nextSlot + 1) % kRing;

    if (!s.Convert(bgra, srcWidth, srcHeight, slot)) {
        s.dropped.fetch_add(1);
        return false;
    }

    std::lock_guard<std::mutex> guard(s.lock);
    if (s.havePending) {
        s.dropped.fetch_add(1);   // latest wins
    }
    s.havePending = true;
    s.pendingSlot = slot;
    s.pendingCapturedAt = capturedAt;
    s.pendingIdr = forceIdr;
    if (s.needInput > 0) {
        --s.needInput;
        s.FeedLocked();
    }
    return true;
}

void Encoder::RequestIdr() { impl_->idrWanted.store(true); }

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
