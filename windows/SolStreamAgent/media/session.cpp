#include "session.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include "capture.h"
#include "encoder.h"
#include "input.h"
#include "smt.h"
#include "audio.h"
#include "log.h"
#include "overflow_gate.h"

#include <mfapi.h>
#include <timeapi.h>
#include <winrt/Windows.Foundation.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "strmiids.lib")
#pragma comment(lib, "windowsapp.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")


namespace solstream::media {
namespace {

constexpr int kVideoHeader = 16;
constexpr int kVideoPayload = smt::kMaxPlaintext - kVideoHeader;   // 1432
constexpr size_t kSendQueueDepth = 24;
/// Silence from the client for this long ends the session. Without it a Mac
/// that goes away leaves an encoder running and a window being captured, with
/// nothing on the host to say so.
constexpr int kSilenceTimeoutMs = 15000;

LARGE_INTEGER g_frequency{};

long long Now() {
    LARGE_INTEGER now{};
    QueryPerformanceCounter(&now);
    return now.QuadPart;
}

double MillisBetween(long long from, long long to) {
    return (double) (to - from) * 1000.0 / (double) g_frequency.QuadPart;
}

/// "the whole pc", or "1 app" and so on, for the five-second line.
std::string AudioFromLabel(int apps) {
    if (apps < 0) { return "from the whole pc"; }
    return "from " + std::to_string(apps) + (apps == 1 ? " app" : " apps");
}

struct Picture {
    std::vector<unsigned char> bytes;
    uint32_t frameId = 0;
    bool isIdr = false;
    long long capturedAt = 0;
    long long encodedAt = 0;
};

}  // namespace

struct MediaSession::Impl {
    SOCKET socket = INVALID_SOCKET;
    sockaddr_in peer{};
    bool havePeer = false;
    std::mutex peerLock;

    smt::Direction toClient, fromClient;
    smt::ReplayWindow replay;
    unsigned char sessTag = 0;
    std::mutex sealLock;    ///< video, audio and stats all seal on this direction

    MediaConfig config;
    // Built fresh for every capture pass and destroyed at the end of it.
    //
    // They used to be members that outlived a session, and the second session
    // on the same agent failed with "the hardware encoder would not open": the
    // first pass's D3D11 device was still alive inside the capture, holding the
    // resources the encoder wanted. A clean slate per pass is one line and
    // removes the whole class.
    //
    // Shared rather than unique, and never dereferenced from another thread
    // without taking a copy under `mediaLock` first. The capture thread destroys
    // both at the end of a pass while the sender thread's five-second report,
    // the receive thread's keyframe request and StatsJson on the agent's command
    // thread are all asking them for counters -- and a null check on a pointer
    // another thread is in the middle of clearing proves nothing.
    //
    // A reader's copy keeps the object alive while it is being read. The
    // encoder's resources still go at the end of the pass, because the pass
    // calls Close() itself; the capture's D3D11 device does not, since Capture
    // frees that in its destructor rather than in Stop(), so a reader that is
    // slow to let go of its copy delays it. Every reader here lets go within one
    // snprintf or one log line, and the next pass has to capture a frame before
    // it opens an encoder. That is a different situation from the paragraph
    // above, which is about a device that outlived an entire session.
    mutable std::mutex mediaLock;
    std::shared_ptr<Capture> capture;
    std::shared_ptr<Encoder> encoder;
    AudioCapture audio;
    InputInjector input;

    std::atomic<bool> running{false};
    std::thread captureThread, senderThread, receiveThread, audioThread;
    /// Held for the whole of Stop. The client thread stops the session when its
    /// Mac goes away and the host stops it on the way out, and those can
    /// coincide; two threads joining one std::thread is std::terminate. The
    /// second caller now waits, then finds nothing left to stop.
    std::mutex stopLock;

    std::mutex queueLock;
    std::condition_variable queueReady;
    std::deque<Picture> queue;
    /// Under `queueLock`, and new for each pass, whose frame ids start again.
    OverflowGate overflowGate;

    long long startedAt = 0;
    /// Written by the receive thread on every datagram that authenticates and
    /// read by the sender thread on every pass of its loop, so it is atomic
    /// rather than a plain long long. The two threads disagreeing by one
    /// datagram about when the client was last heard from costs nothing; a
    /// non-atomic 64-bit value written and read at once is undefined behaviour
    /// whatever the hardware happens to do with it.
    std::atomic<long long> lastHeardAt{0};
    /// When the encoder was last asked for a keyframe, which the client's
    /// requests are limited against. The receive thread reads and writes it,
    /// and a send-queue overflow writes it from an encoder work-queue thread,
    /// so it is atomic for the reason lastHeardAt is.
    std::atomic<long long> lastIdrAt{0};
    long long nextSlot = 0;
    double ticksPerByte = 0;

    std::atomic<uint64_t> datagramsSent{0}, bytesSent{0};
    std::atomic<uint64_t> picturesSent{0}, picturesDropped{0};
    /// Keyframes sent and their bytes, for the stats line: the size of an IDR
    /// is what decides how long it occupies the link and how likely it is to
    /// lose a fragment on Wi-Fi.
    std::atomic<uint64_t> idrsSent{0}, idrBytes{0};
    /// The sound's sealed datagrams, apart from the total, so the five-second
    /// line can show what a sound quality costs: at Data saver it is a twentieth
    /// of Lossless, and inside a 20 Mbit/s total that is noise.
    std::atomic<uint64_t> audioBytesSent{0};
    HANDLE pacingTimer = nullptr;
    std::atomic<uint64_t> datagramsReceived{0}, rejected{0};
    std::atomic<uint64_t> idrRequests{0};
    std::atomic<uint32_t> clientLastFrame{0};
    std::atomic<uint32_t> clientDamaged{0};
    std::atomic<double> lastRttMs{0.0};
    // Capture -> last byte on the wire, which is the figure the whole design is
    // budgeted against and the one nothing has measured until now. Kept as a
    // minimum and a running mean rather than a sample list, because the sender
    // thread must not allocate.
    std::atomic<double> lastGlassToWireMs{0.0};
    std::atomic<double> minGlassToWireMs{1e9};
    std::atomic<double> sumGlassToWireMs{0.0};

    std::atomic<bool> retargetWanted{false};
    std::mutex configLock;

    // How the capture thread tells Start whether the session really opened.
    //
    // Everything that can go wrong with the PICTURE goes wrong on that thread --
    // the window vanishing between the pick and the capture, WGC refusing the
    // item, no hardware encoder on the machine -- and all of it used to happen
    // after Start had returned true, so it reached the log and nothing else.
    // Start waits for this, with a bound, and the agent answers
    // "streaming: false" with a reason instead of "streaming: true" followed by
    // silence and a black window on the Mac.
    //
    // Only the FIRST pass reports. A later pass exists because the client
    // retargeted, by which time Start returned long ago and a failure ends the
    // session rather than answers a question.
    std::mutex openLock;
    std::condition_variable openReported;
    bool opened = false;
    std::string openError;   ///< empty means the capture and the encoder are up

    void ReportOpened(std::string error);
    void CaptureLoop();
    void RunCapture();
    void SenderLoop();
    void ReceiveLoop();
    void SendPicture(const Picture& picture);
    size_t SendSealed(const unsigned char* plaintext, size_t length);
    void WaitUntil(long long deadline);
    void HandlePlaintext(const unsigned char* plaintext, size_t length);
};

// ── Sealing and sending ──────────────────────────────────────────────────────

/// Returns the datagram's size, or 0 when nothing was sent.
size_t MediaSession::Impl::SendSealed(const unsigned char* plaintext, size_t length) {
    unsigned char datagram[smt::kMaxPlaintext + smt::kOverhead];
    size_t total = 0;
    sockaddr_in to{};
    {
        std::lock_guard<std::mutex> guard(peerLock);
        if (!havePeer) { return 0; }
        to = peer;
    }
    {
        std::lock_guard<std::mutex> guard(sealLock);
        total = smt::Seal(toClient, sessTag, plaintext, length, datagram, sizeof(datagram));
    }
    if (total == 0) { return 0; }
    sendto(socket, (const char*) datagram, (int) total, 0, (sockaddr*) &to, sizeof(to));
    datagramsSent.fetch_add(1);
    bytesSent.fetch_add(total);
    return total;
}

void MediaSession::Impl::WaitUntil(long long deadline) {
    // Slept on a high-resolution waitable timer, never spun. The pacing slot is
    // about 300 us per datagram, so the old last-two-milliseconds spin ran for
    // the whole time a frame was being sent -- roughly half of wall time on a
    // core of the host. The timer can wake a little late; the schedule is
    // absolute (nextSlot advances by each datagram's cost, not from "now"), so
    // a late wake sends the next one or two at once and the average rate is
    // unchanged. Anything under 200 us is sent now rather than slept for.
    for (;;) {
        const long long now = Now();
        if (now >= deadline) { return; }
        const long long remainingUs =
            (deadline - now) * 1000000 / g_frequency.QuadPart;
        if (remainingUs < 200) { return; }
        if (pacingTimer) {
            LARGE_INTEGER due{};
            due.QuadPart = -(remainingUs * 10);   // relative, in 100 ns units
            if (SetWaitableTimerEx(pacingTimer, &due, 0, nullptr, nullptr, nullptr, 0)) {
                WaitForSingleObject(pacingTimer, 50);
                continue;
            }
        }
        Sleep(1);
    }
}

void MediaSession::Impl::SendPicture(const Picture& picture) {
    const size_t size = picture.bytes.size();
    if (size == 0) { return; }

    const uint32_t captureUs = (uint32_t)
        ((picture.capturedAt - startedAt) * 1000000 / g_frequency.QuadPart);

    // METER TO A RATE, WITH NO FRAME-PERIOD CAP.
    //
    // spike/smt-video measured this: spreading a frame across its own period
    // loses 3.4% of every keyframe, always the keyframe and never a P-frame,
    // because a 240 KB IDR given 16.7 ms bursts at six times the average rate
    // whatever the schedule claims. A frame may not start before it exists; it
    // may finish after its period.
    const long long now = Now();
    if (nextSlot < now) { nextSlot = now; }

    unsigned char plaintext[smt::kMaxPlaintext];
    for (size_t offset = 0; offset < size; offset += kVideoPayload) {
        const size_t chunk = size - offset < (size_t) kVideoPayload
                                 ? size - offset : (size_t) kVideoPayload;
        plaintext[0] = smt::kTypeVideo;
        unsigned char flags = 0;
        if (offset == 0) { flags |= smt::kFlagFrameStart; }
        if (offset + chunk >= size) { flags |= smt::kFlagFrameEnd; }
        if (picture.isIdr) { flags |= smt::kFlagIdr; }
        plaintext[1] = flags;
        plaintext[2] = 0xF0;                 // ltr: unmarked, previous reference
        plaintext[3] = 0;                    // sliceId
        smt::PutBE(plaintext + 4, picture.frameId, 4);
        smt::PutBE(plaintext + 8, offset, 3);
        plaintext[11] = 0;                   // parameter-set generation
        smt::PutBE(plaintext + 12, captureUs, 4);
        memcpy(plaintext + kVideoHeader, picture.bytes.data() + offset, chunk);

        WaitUntil(nextSlot);
        SendSealed(plaintext, kVideoHeader + chunk);
        // The wire cost of this datagram INCLUDING the IPv4 and UDP headers the
        // path also has to carry.
        nextSlot += (long long)
            ((double) (kVideoHeader + chunk + smt::kOverhead + 28) * ticksPerByte);
    }
    picturesSent.fetch_add(1);
    if (picture.isIdr) {
        idrsSent.fetch_add(1);
        idrBytes.fetch_add(size);
    }

    // A picture whose capture time is zero is one the encoder emitted for a
    // frame id nothing recorded. Counting it would put the whole time since
    // boot into the mean, which is exactly what the first run reported:
    // "glass->wire mean 511786.4 ms".
    if (picture.capturedAt == 0) { return; }
    const double elapsed = MillisBetween(picture.capturedAt, Now());
    lastGlassToWireMs.store(elapsed);
    if (elapsed < minGlassToWireMs.load()) { minGlassToWireMs.store(elapsed); }
    sumGlassToWireMs.store(sumGlassToWireMs.load() + elapsed);
}

// ── Threads ──────────────────────────────────────────────────────────────────

void MediaSession::Impl::ReportOpened(std::string error) {
    {
        std::lock_guard<std::mutex> guard(openLock);
        if (opened) { return; }
        opened = true;
        openError = std::move(error);
    }
    openReported.notify_all();
}

void MediaSession::Impl::CaptureLoop() {
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
    } catch (winrt::hresult_error const&) {
        // Already initialised in another mode, which is survivable: the frame
        // pool is created free-threaded and needs no apartment of its own.
    }
    // One pass per target. Re-pointing the capture at another window is a new
    // capture item, a new size and a new parameter set -- which is a new
    // encoder -- so it is done by going round again rather than by pretending
    // an encoder can change its mind.
    while (running.load()) {
        retargetWanted.store(false);
        RunCapture();
        if (!retargetWanted.load()) {
            break;
        }
    }
    running.store(false);
    // Whatever happened, Start is not left waiting for its bounded timeout. The
    // only way to reach here without a pass having reported is Stop arriving
    // while the first one was still opening.
    ReportOpened("the session was stopped before the capture opened");
}

void MediaSession::Impl::RunCapture() {
    // One copy of the target, taken once, used for the whole pass. Retarget
    // rewrites `config` from the agent's command thread, and this thread was
    // reading its fields one at a time without the lock that Retarget takes --
    // a data race in the language's terms, and in practice a pass that could
    // open a capture on the old window and then size the encoder for the new
    // one. A pass cannot change its source halfway through in any case: the
    // capture item, the encode size and the frame period are all settled when it
    // opens, and a retarget is served by ending the pass and going round again.
    MediaConfig active;
    {
        std::lock_guard<std::mutex> guard(configLock);
        active = config;
    }
    {
        std::lock_guard<std::mutex> guard(mediaLock);
        capture = std::make_shared<Capture>();
        encoder = std::make_shared<Encoder>();
    }
    struct Teardown {
        Impl* self;
        ~Teardown() {
            // Take the two pointers away under the lock, then close them with
            // the lock released. Closing under it would deadlock: Encoder::Close
            // waits for a picture callback that is already running, and that
            // callback wants `mediaLock` to ask for a keyframe.
            std::shared_ptr<Encoder> encoderPtr;
            std::shared_ptr<Capture> capturePtr;
            {
                std::lock_guard<std::mutex> guard(self->mediaLock);
                encoderPtr = std::move(self->encoder);
                capturePtr = std::move(self->capture);
            }
            if (encoderPtr) { encoderPtr->Close(); }
            if (capturePtr) { capturePtr->Stop(); }
        }
    } teardown{this};

    if (active.window) {
        if (!capture->StartWindow(active.window)) {
            Log("[media] capture of window %p failed", (void*) active.window);
            ReportOpened("the window could not be captured");
            return;
        }
    } else if (!capture->StartMonitor(active.monitor)) {
        Log("[media] capture of monitor %p failed", (void*) active.monitor);
        ReportOpened("the display could not be captured");
        return;
    }

    // The first frame decides the encode size, because a window's size is not
    // known until something has been captured from it.
    Frame frame{};
    for (int tries = 0; tries < 100 && running.load(); ++tries) {
        if (capture->Acquire(frame, 0, 50) && frame.width > 0) { break; }
    }
    if (!frame.width || !running.load()) {
        Log("[media] nothing was ever captured");
        ReportOpened("nothing was ever captured from that source");
        return;
    }

    const UINT encodeWidth = active.width ? active.width : frame.width;
    const UINT encodeHeight = active.height ? active.height : frame.height;
    if (!encoder->Open(capture->Device(), encodeWidth, encodeHeight, active.fps,
                      active.bitrate)) {
        Log("[media] the hardware encoder would not open at %ux%u",
            encodeWidth, encodeHeight);
        ReportOpened("the hardware encoder would not open at "
                     + std::to_string(encodeWidth) + "x"
                     + std::to_string(encodeHeight));
        return;
    }
    Log("[media] capturing %ux%u, encoding %ux%u at %u fps, %u kbit/s",
        frame.width, frame.height, encoder->Width(), encoder->Height(),
        active.fps, active.bitrate / 1000);
    // The source and the encoder are up, which is the point Start has been
    // waiting for. Everything above this line can fail, and until this call
    // existed all of it failed into the log and nowhere else: Start had already
    // returned true and the agent had already told the Mac it was streaming.
    ReportOpened(std::string());

    {
        std::lock_guard<std::mutex> guard(queueLock);
        overflowGate = OverflowGate();
    }
    encoder->OnPicture([this](const CodedPicture& coded) {
        Picture picture;
        picture.bytes.assign(coded.data, coded.data + coded.length);
        picture.frameId = coded.frameId;
        picture.isIdr = coded.isIdr;
        picture.capturedAt = coded.capturedAt;
        picture.encodedAt = coded.encodedAt;
        // A full queue means the sender cannot keep up: the backlog is thrown
        // away, and so is every P-frame until the keyframe asked for comes
        // out. See overflow_gate.h.
        OverflowGate::Decision decision;
        {
            std::lock_guard<std::mutex> guard(queueLock);
            decision = overflowGate.Picture(picture.isIdr,
                                            queue.size() >= kSendQueueDepth,
                                            MillisBetween(startedAt, Now()));
            if (decision.clear) {
                queue.clear();
                picturesDropped.fetch_add(1);
            }
            if (decision.send) { queue.push_back(std::move(picture)); }
        }
        if (decision.send) { queueReady.notify_one(); }
        // Through a copy of the pointer, and outside the queue lock so that the
        // two are never held at once: this runs on an encoder work-queue thread,
        // and the pass it belongs to is one the capture thread can be tearing
        // down at the same moment -- `encoder` is exactly what it clears.
        if (decision.askIdr) {
            std::shared_ptr<Encoder> encoderPtr;
            {
                std::lock_guard<std::mutex> guard(mediaLock);
                encoderPtr = encoder;
            }
            if (encoderPtr) {
                // Counted against the client's request limit, as the
                // first-contact keyframe is. The client has no reason to ask
                // while the P-frames are dropped, but one that does anyway,
                // over a loss of its own just before, is then not sent a
                // second keyframe within the limit.
                lastIdrAt.store(Now());
                encoderPtr->RequestIdr();
            }
        }
    });

    uint64_t lastSerial = 0;
    // The heartbeat that makes a still window streamable. WGC delivers nothing
    // while nothing changes, so without this the last frame's damage is never
    // repaired and a client joining a static screen waits forever.
    const int idleMs = 1000 / (int) (active.fps ? active.fps : 60);
    long long lastEncodedAt = Now();
    // capture->Running() as well, because Acquire never says the source has
    // gone: once a frame exists it hands back the retained one for ever. A
    // window that closed mid-session was re-encoded from its last frame every
    // 250 ms for as long as the session lasted. Capture now notices the item
    // closing, and the pass -- and with no retarget pending, the session --
    // ends.
    while (running.load() && !retargetWanted.load() && capture->Running()) {
        Frame current{};
        if (!capture->Acquire(current, lastSerial, idleMs)) {
            if (!capture->Running()) { break; }
            continue;
        }
        // A keyframe the client is waiting for counts as stale too. The request
        // only sets a flag the next Submit consumes, and on a still window the
        // next Submit was the 250 ms refresh -- a quarter of a second of frozen
        // picture on the Mac for every lost datagram, on exactly the content
        // that changes least. The retained frame is re-encoded now instead.
        const bool stale = MillisBetween(lastEncodedAt, Now()) > 250.0
                        || encoder->IdrPending();
        if (!current.isNew && !stale) {
            continue;
        }
        lastSerial = current.serial;
        lastEncodedAt = Now();
        encoder->Submit(current.texture, current.width, current.height,
                       current.isNew ? current.capturedAt : Now(), false);
    }
    if (running.load() && !retargetWanted.load() && !capture->Running()) {
        Log("[media] the captured source has closed; ending the session");
    }
}

void MediaSession::Impl::SenderLoop() {
    timeBeginPeriod(1);
    // High resolution, or it rounds to the 1 ms tick and pacing degrades to
    // bursts. Windows 10 1803 and later; on anything older this is null and
    // WaitUntil falls back to Sleep(1).
    pacingTimer = CreateWaitableTimerExW(nullptr, nullptr,
                                         CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                                         TIMER_ALL_ACCESS);
    long long lastStat = 0;
    long long lastReport = Now();
    uint64_t lastReportPictures = 0, lastReportBytes = 0, lastReportAudioBytes = 0;
    // What the sound is sent as, for the report: "opus 128k/10ms" or "pcm".
    char audioLabel[32];
    if (config.audioEncoding.codec == AudioEncoding::Codec::Opus) {
        snprintf(audioLabel, sizeof(audioLabel), "opus %uk/%ums",
                 config.audioEncoding.bitrate / 1000, config.audioEncoding.frameMs);
    } else {
        snprintf(audioLabel, sizeof(audioLabel), "pcm");
    }
    while (running.load()) {
        Picture picture;
        bool have = false;
        {
            std::unique_lock<std::mutex> guard(queueLock);
            queueReady.wait_for(guard, std::chrono::milliseconds(20),
                                [&] { return !queue.empty() || !running.load(); });
            if (!queue.empty()) {
                picture = std::move(queue.front());
                queue.pop_front();
                have = true;
            }
        }
        if (have) {
            SendPicture(picture);
        }

        // The host's own report, ten times a second: what input it has applied,
        // and its clock. Both are what the client needs to stop repeating
        // events and to turn its echo into a round trip.
        const long long now = Now();
        if (MillisBetween(lastStat, now) > 100.0) {
            lastStat = now;
            unsigned char stat[16];
            stat[0] = smt::kTypeHostStat;
            stat[1] = 0;
            stat[2] = stat[3] = 0;
            smt::PutBE(stat + 4, input.Acknowledged(), 4);
            const uint64_t hostUs =
                (uint64_t) ((now - startedAt) * 1000000 / g_frequency.QuadPart);
            smt::PutBE(stat + 8, hostUs, 8);
            SendSealed(stat, sizeof(stat));
        }

        // Once every five seconds, what the path is actually doing. Written to
        // the same log as everything else because the alternative -- asking for
        // it over the agent channel -- means a session that went wrong at 3am
        // left no evidence at all.
        if (MillisBetween(lastReport, now) > 5000.0) {
            const uint64_t pictures = picturesSent.load();
            const double elapsed = MillisBetween(lastReport, now) / 1000.0;
            // Copies of the two pointers, taken under the lock and held for as
            // long as the counters are being read out of them. The capture
            // thread ends a pass every time the client retargets, and five
            // seconds is long enough that it lands in the middle of a report
            // sooner or later. The lock is not held across the Log itself --
            // that writes to a file, and the capture thread would be waiting.
            std::shared_ptr<Capture> capturePtr;
            std::shared_ptr<Encoder> encoderPtr;
            {
                std::lock_guard<std::mutex> guard(mediaLock);
                capturePtr = capture;
                encoderPtr = encoder;
            }
            Log("[media] %.1f fps, %.1f Mbit/s | capture %llu, encoder %llu/%llu"
                " (dropped %llu, extra samples %llu) | glass->wire last %.1f min %.1f"
                " mean %.1f ms | client frame %u, damaged %u, idr asks %llu"
                " | audio %s %s, %llu sent, %llu silent, %.0f kbit/s | input %llu applied, %llu dup,"
                " %llu failed, ack %u | rx %llu, rejected %llu | idr %llu, mean %llu KB",
                elapsed > 0 ? (double) (pictures - lastReportPictures) / elapsed : 0.0,
                elapsed > 0
                    ? (double) (bytesSent.load() - lastReportBytes) * 8.0 / elapsed / 1e6
                    : 0.0,
                (unsigned long long) (capturePtr ? capturePtr->Delivered() : 0),
                (unsigned long long) (encoderPtr ? encoderPtr->Pictures() : 0),
                (unsigned long long) (encoderPtr ? encoderPtr->Submitted() : 0),
                (unsigned long long) (encoderPtr ? encoderPtr->Dropped() : 0),
                (unsigned long long) (encoderPtr ? encoderPtr->ExtraSamples() : 0),
                lastGlassToWireMs.load(),
                minGlassToWireMs.load() > 1e8 ? 0.0 : minGlassToWireMs.load(),
                pictures ? sumGlassToWireMs.load() / (double) pictures : 0.0,
                clientLastFrame.load(), clientDamaged.load(),
                (unsigned long long) idrRequests.load(),
                audioLabel,
                // Where it came from: the whole PC, or how many streamed apps.
                AudioFromLabel(audio.AppSources()).c_str(),
                (unsigned long long) audio.Packets(),
                (unsigned long long) audio.Silent(),
                // Sealed datagrams, so headers and tag included: what the
                // sound costs the link, less IP and UDP.
                elapsed > 0
                    ? (double) (audioBytesSent.load() - lastReportAudioBytes) * 8.0 / elapsed / 1e3
                    : 0.0,
                // Whether input ARRIVED, which nothing here said before. When
                // clicks stop landing there are only two possibilities -- the
                // Mac is not sending them, or the host is not applying them --
                // and without these three numbers the log is equally consistent
                // with both. It cost an afternoon to find that out.
                (unsigned long long) input.Applied(),
                (unsigned long long) input.Duplicates(),
                (unsigned long long) input.Failed(),
                input.Acknowledged(),
                (unsigned long long) datagramsReceived.load(),
                (unsigned long long) rejected.load(),
                (unsigned long long) idrsSent.load(),
                (unsigned long long) (idrsSent.load()
                                          ? idrBytes.load() / idrsSent.load() / 1024
                                          : 0));
            lastReport = now;
            lastReportPictures = pictures;
            lastReportBytes = bytesSent.load();
            lastReportAudioBytes = audioBytesSent.load();
        }

        // Measured from the session's own start until the client has said
        // anything at all. The `heardAt != 0` guard used to skip the check
        // entirely in that state, so a Mac that agreed a session and then never
        // sent a datagram -- it died, its network went, its UDP was filtered --
        // left the capture, the encoder, the sender and the receive threads
        // running with a bound socket for the life of the agent. The one client
        // slot stayed taken with it. The silence is the same silence whether or
        // not a first packet ever arrived.
        const long long heardAt = lastHeardAt.load();
        const long long since = heardAt != 0 ? heardAt : startedAt;
        if (MillisBetween(since, now) > kSilenceTimeoutMs) {
            Log("[media] %s for %d ms; ending the session",
                heardAt != 0 ? "the client has been silent"
                             : "the client never sent a packet",
                kSilenceTimeoutMs);
            running.store(false);
            break;
        }
    }
    if (pacingTimer) {
        CloseHandle(pacingTimer);
        pacingTimer = nullptr;
    }
    timeEndPeriod(1);
}

void MediaSession::Impl::HandlePlaintext(const unsigned char* plaintext, size_t length) {
    if (length < 1) { return; }
    switch (plaintext[0]) {
        case smt::kTypePing: {
            unsigned char pong[17] = {};
            pong[0] = smt::kTypePong;
            if (length >= 9) { memcpy(pong + 1, plaintext + 1, 8); }
            const uint64_t hostUs =
                (uint64_t) ((Now() - startedAt) * 1000000 / g_frequency.QuadPart);
            smt::PutBE(pong + 9, hostUs, 8);
            SendSealed(pong, sizeof(pong));
            break;
        }
        case smt::kTypeInput:
            input.Apply(plaintext, length);
            break;
        case smt::kTypeFeedback: {
            if (length < 20) { break; }
            clientLastFrame.store((uint32_t) smt::ReadBE(plaintext + 4, 4));
            clientDamaged.store((uint32_t) smt::ReadBE(plaintext + 12, 4));
            if (plaintext[1] & 0x01) {
                // Rate-limited, because a client that lost a fragment of an IDR
                // asks for another IDR, which is bigger, which loses more.
                const long long now = Now();
                if (MillisBetween(lastIdrAt.load(), now) > 200.0) {
                    lastIdrAt.store(now);
                    idrRequests.fetch_add(1);
                    // Through a copy, for the same reason as everywhere else:
                    // this is the receive thread, and the pass it is asking for
                    // a keyframe may be the one the capture thread is closing.
                    std::shared_ptr<Encoder> encoderPtr;
                    {
                        std::lock_guard<std::mutex> guard(mediaLock);
                        encoderPtr = encoder;
                    }
                    if (encoderPtr) { encoderPtr->RequestIdr(); }
                }
            }
            break;
        }
        case smt::kTypeBye:
            Log("[media] the client said goodbye");
            running.store(false);
            break;
        default:
            break;
    }
}

void MediaSession::Impl::ReceiveLoop() {
    unsigned char buffer[2048];
    bool complained = false;
    for (;;) {
        if (!running.load()) { break; }
        sockaddr_in from{};
        int fromLen = sizeof(from);
        const int n = recvfrom(socket, (char*) buffer, sizeof(buffer), 0,
                               (sockaddr*) &from, &fromLen);
        if (n <= 0) {
            // The expected case is the 200 ms receive timeout, which is what lets
            // this loop notice `running` going false. Everything else has to be
            // told apart from it: an error that does NOT block returns here
            // immediately, and a bare `continue` then spins this thread at the
            // speed of the system call. WSAECONNRESET is the one that actually
            // happens -- Windows reports an ICMP port-unreachable on the next
            // recvfrom of an unconnected UDP socket -- and a Mac that has gone
            // is precisely when it arrives. One core at 100% for the fifteen
            // seconds until the silence timeout fires, on a machine whose owner
            // is not watching.
            const int error = n < 0 ? WSAGetLastError() : 0;
            if (error != 0 && error != WSAETIMEDOUT) {
                if (!complained) {
                    complained = true;
                    Log("[media] recvfrom failed with %d; pacing the receive loop",
                        error);
                }
                Sleep(5);
            }
            continue;
        }
        complained = false;
        datagramsReceived.fetch_add(1);
        unsigned char* plaintext = nullptr;
        size_t plaintextLen = 0;
        uint64_t counter = 0;
        if (!smt::Open(fromClient, replay, buffer, (size_t) n, &plaintext,
                       &plaintextLen, &counter)) {
            rejected.fetch_add(1);
            continue;
        }
        // The peer is learned from a packet that AUTHENTICATED, never from one
        // that merely arrived. A host that starts sending video to whatever
        // address spoke to it first is a reflector.
        bool firstContact = false;
        {
            std::lock_guard<std::mutex> guard(peerLock);
            if (!havePeer || from.sin_addr.s_addr != peer.sin_addr.s_addr
                || from.sin_port != peer.sin_port) {
                firstContact = !havePeer;
                peer = from;
                havePeer = true;
                char who[64] = {};
                inet_ntop(AF_INET, &from.sin_addr, who, sizeof(who));
                Log("[media] client at %s:%u", who, ntohs(from.sin_port));
            }
        }
        if (firstContact) {
            // The session's first keyframe has already been encoded by now, and
            // sent nowhere: the capture thread starts encoding the moment the
            // pass opens, and the client only learns the port, and speaks,
            // after Start has answered. Keyframes come only on request, so
            // every session began with P-frames the client could not decode,
            // until it asked -- and on a still window the next picture was the
            // 250 ms refresh. One is asked for here instead, and the request
            // limit is started from it, so a client that asks as it opens is
            // not sent a second one.
            lastIdrAt.store(Now());
            std::shared_ptr<Encoder> encoderPtr;
            {
                std::lock_guard<std::mutex> guard(mediaLock);
                encoderPtr = encoder;
            }
            if (encoderPtr) { encoderPtr->RequestIdr(); }
        }
        lastHeardAt.store(Now());
        HandlePlaintext(plaintext, plaintextLen);
    }
    // Let go of whatever the client was holding, here and now. A session ends
    // on its own -- the silence timeout, a BYE, the captured window closing --
    // well before anything calls Stop(), which waits for the agent channel to
    // drop or for the next session to start. Until then a key or button the
    // Mac had down stayed down on the host. This is the thread that applies
    // input, so releasing here cannot race an Apply; Stop() releases again
    // after joining it, which finds nothing held and does nothing.
    input.ReleaseAll();
}

// ── Lifetime ─────────────────────────────────────────────────────────────────

MediaSession::MediaSession() : impl_(std::make_unique<Impl>()) {
    QueryPerformanceFrequency(&g_frequency);
}

MediaSession::~MediaSession() { Stop(); }

MediaSession& MediaSession::Instance() {
    static MediaSession session;
    return session;
}

bool MediaSession::Start(const unsigned char* okm, const MediaConfig& config,
                         std::string* error) {
    Impl& s = *impl_;
    Stop();

    if (!Capture::Supported()) {
        if (error) { *error = "Windows.Graphics.Capture is not available"; }
        return false;
    }
    if (!config.window && !config.monitor) {
        if (error) { *error = "no window and no display to capture"; }
        return false;
    }

    static bool mfStarted = false;
    if (!mfStarted) {
        if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
            if (error) { *error = "Media Foundation would not start"; }
            return false;
        }
        mfStarted = true;
    }

    s.config = config;
    s.toClient.key = smt::MakeKey(okm);
    s.fromClient.key = smt::MakeKey(okm + 32);
    memcpy(s.toClient.fixed, okm + 64, 6);
    memcpy(s.fromClient.fixed, okm + 70, 6);
    s.toClient.counter = 0;
    s.fromClient.counter = 0;
    s.replay = smt::ReplayWindow{};
    s.sessTag = okm[79];   // low byte of the 32-bit session id at 76..80
    // Two BCrypt key handles now exist, and every failure path from here down
    // has to destroy them itself. Stop() cannot do it: its guard turns Stop into
    // a no-op when `running` was never set and the socket was never opened,
    // which is exactly the state a failure below leaves behind. The next Start
    // overwrites both handles with fresh ones, so whatever leaked can never be
    // reached again -- a port that is taken, retried a few times, quietly costs
    // a key handle per attempt.
    auto dropKeys = [&s] {
        if (s.toClient.key) { BCryptDestroyKey(s.toClient.key); s.toClient.key = nullptr; }
        if (s.fromClient.key) { BCryptDestroyKey(s.fromClient.key); s.fromClient.key = nullptr; }
    };
    if (!s.toClient.key || !s.fromClient.key) {
        dropKeys();   // one of the two may have imported
        if (error) { *error = "the media keys would not import"; }
        return false;
    }

    s.socket = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s.socket == INVALID_SOCKET) {
        dropKeys();
        if (error) { *error = "no UDP socket"; }
        return false;
    }
    int sndbuf = 1 << 21;
    setsockopt(s.socket, SOL_SOCKET, SO_SNDBUF, (const char*) &sndbuf, sizeof(sndbuf));
    int rcvbuf = 1 << 20;
    setsockopt(s.socket, SOL_SOCKET, SO_RCVBUF, (const char*) &rcvbuf, sizeof(rcvbuf));
    DWORD timeout = 200;
    setsockopt(s.socket, SOL_SOCKET, SO_RCVTIMEO, (const char*) &timeout, sizeof(timeout));
    // Exclusive, as the agent's TCP port is and for the same reason: without it
    // Windows lets another process that asks for SO_REUSEADDR bind this port on
    // top of this one, and which of the two then receives the Mac's input
    // datagrams is up to the stack. Set before bind, which is the only time it
    // counts.
    BOOL exclusive = TRUE;
    setsockopt(s.socket, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char*) &exclusive,
               sizeof(exclusive));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(config.port);
    if (bind(s.socket, (sockaddr*) &address, sizeof(address)) == SOCKET_ERROR) {
        closesocket(s.socket);
        s.socket = INVALID_SOCKET;
        dropKeys();
        if (error) { *error = "UDP port " + std::to_string(config.port) + " is taken"; }
        return false;
    }

    InputTarget target;
    target.window = config.window;
    target.monitor = config.monitor;
    // Before the target, and unconditionally: the injector outlives the session
    // it belongs to, and its dedupe window is only meaningful within one.
    s.input.Reset();
    s.input.SetTarget(target);

    s.startedAt = Now();
    s.lastHeardAt.store(0);
    s.lastIdrAt.store(0);
    s.nextSlot = s.startedAt;
    // Pace at twice the encoder's target. Metering at exactly the bitrate makes
    // every IDR late by construction, and metering at line rate is what loses
    // their fragments.
    const double pacingBits = (double) config.bitrate * 2.0;
    s.ticksPerByte = (double) g_frequency.QuadPart / (pacingBits / 8.0);

    s.datagramsSent = 0; s.bytesSent = 0;
    s.picturesSent = 0; s.picturesDropped = 0;
    s.idrsSent = 0; s.idrBytes = 0;
    s.audioBytesSent = 0;
    s.datagramsReceived = 0; s.rejected = 0; s.idrRequests = 0;

    {
        std::lock_guard<std::mutex> guard(s.openLock);
        s.opened = false;
        s.openError.clear();
    }

    s.running.store(true);
    s.receiveThread = std::thread([&s] { s.ReceiveLoop(); });
    s.senderThread = std::thread([&s] { s.SenderLoop(); });
    s.captureThread = std::thread([&s] { s.CaptureLoop(); });
    if (config.audio) {
        s.audioThread = std::thread([&s] {
            s.audio.Run(s.config.audioEncoding, s.config.audioProcesses,
                        [&s](const unsigned char* data, size_t length, uint32_t seq,
                             uint32_t timestampUs, uint32_t rate, uint16_t channels,
                             unsigned char format) {
                unsigned char packet[smt::kMaxPlaintext];
                if (length + 16 > sizeof(packet)) { return; }
                packet[0] = smt::kTypeAudio;
                packet[1] = 0;
                packet[2] = (unsigned char) channels;
                packet[3] = format;   // 1 S16 little-endian interleaved, 2 Opus
                smt::PutBE(packet + 4, seq, 4);
                smt::PutBE(packet + 8, timestampUs, 4);
                smt::PutBE(packet + 12, rate, 4);
                memcpy(packet + 16, data, length);
                s.audioBytesSent.fetch_add(s.SendSealed(packet, 16 + length));
            }, [&s] { return s.running.load(); });
        });
    }

    // Wait for the capture thread to say whether the source and the encoder
    // actually opened. Without this the answer on the agent channel was decided
    // before anything had been tried: a window that had just closed, a WGC item
    // that would not start, a machine with no hardware encoder -- all of them
    // returned "streaming: true" and then sent not one datagram, and the Mac sat
    // on a black window with nothing to explain it.
    //
    // Bounded, because the wait is on the agent's command thread and the thing
    // being waited for talks to a graphics driver. The bound has to clear the
    // slowest honest path, which is RunCapture's wait for a first frame: 100
    // tries of 50 ms is five seconds before it gives up, and the encoder opens
    // after that. Eight seconds leaves room for both and is still well inside
    // the agent's own 30-second idle timeout, so a wedged driver costs a slow
    // answer rather than a dropped channel.
    constexpr int kOpenWaitMs = 8000;
    std::string failure;
    bool answered = false;
    {
        std::unique_lock<std::mutex> guard(s.openLock);
        answered = s.openReported.wait_for(guard, std::chrono::milliseconds(kOpenWaitMs),
                                           [&s] { return s.opened; });
        if (answered) { failure = s.openError; }
    }
    if (answered && !failure.empty()) {
        // Tear the whole session down rather than leave a socket bound and four
        // threads running for a session that will never carry a picture. The
        // capture thread has already returned from its pass, so this joins
        // immediately.
        Stop();
        if (error) { *error = failure; }
        return false;
    }
    if (!answered) {
        // Deliberately not a failure. Nothing has gone wrong that anyone can
        // point at; the capture is simply still opening, and it may well open a
        // moment from now. Tearing down a session that is about to work would be
        // the worse mistake, so the session runs and the Mac is told why the
        // answer is not a confident one.
        Log("[media] the capture had not opened after %d ms; letting it carry on",
            kOpenWaitMs);
        if (error) {
            *error = "the capture had not opened after "
                     + std::to_string(kOpenWaitMs / 1000) + " s";
        }
    }

    Log("[media] session started on UDP %u", config.port);
    return true;
}

void MediaSession::Stop() {
    Impl& s = *impl_;
    std::lock_guard<std::mutex> serialised(s.stopLock);
    if (!s.running.exchange(false) && s.socket == INVALID_SOCKET) {
        return;
    }
    s.queueReady.notify_all();
    s.audio.Stop();
    if (s.captureThread.joinable()) { s.captureThread.join(); }
    if (s.senderThread.joinable()) { s.senderThread.join(); }
    if (s.audioThread.joinable()) { s.audioThread.join(); }
    if (s.receiveThread.joinable()) { s.receiveThread.join(); }
    // Whatever the client was holding down when it disappeared, let go of.
    s.input.ReleaseAll();
    if (s.socket != INVALID_SOCKET) {
        closesocket(s.socket);
        s.socket = INVALID_SOCKET;
    }
    if (s.toClient.key) { BCryptDestroyKey(s.toClient.key); s.toClient.key = nullptr; }
    if (s.fromClient.key) { BCryptDestroyKey(s.fromClient.key); s.fromClient.key = nullptr; }
    {
        std::lock_guard<std::mutex> guard(s.queueLock);
        s.queue.clear();
    }
    {
        std::lock_guard<std::mutex> guard(s.peerLock);
        s.havePeer = false;
    }
}

bool MediaSession::Running() const { return impl_->running.load(); }

bool MediaSession::Retarget(HWND window, HMONITOR monitor) {
    Impl& s = *impl_;
    if (!s.running.load() || (!window && !monitor)) {
        return false;
    }
    {
        std::lock_guard<std::mutex> guard(s.configLock);
        s.config.window = window;
        s.config.monitor = monitor;
        // The CANVAS SURVIVES A RETARGET. These two used to be zeroed here, with
        // a note saying the new source decides the size -- and the new source is
        // exactly the thing that must not. The Mac asks for a canvas because
        // every crop it draws is expressed in it, and its decoder is set up for
        // it; the first retarget silently dropped that and re-opened the encoder
        // at whatever the new window happened to be, so the picture came back at
        // the wrong size and every crop was taken from the wrong pixels. A
        // retarget changes WHAT is captured, never how large the encoded frame
        // is. A client that wants a different canvas opens a new session.
    }
    InputTarget target;
    target.window = window;
    target.monitor = monitor;
    s.input.SetTarget(target);
    // The socket, the keys and the counter all survive: this is a new picture
    // on the same session, not a new session. The counter especially -- the
    // client's replay window indexes on it, and restarting it would look
    // exactly like an attack.
    s.retargetWanted.store(true);
    return true;
}

std::string MediaSession::StatsJson() const {
    const Impl& s = *impl_;
    char buffer[768];
    // This runs on the agent's command thread, so the same rule applies as in
    // the sender's report: copy the two pointers under the lock and ask the
    // copies, or the capture thread can destroy an encoder between the null
    // check and the call.
    std::shared_ptr<Capture> capturePtr;
    std::shared_ptr<Encoder> encoderPtr;
    {
        std::lock_guard<std::mutex> guard(s.mediaLock);
        capturePtr = s.capture;
        encoderPtr = s.encoder;
    }
    snprintf(buffer, sizeof(buffer),
                "{\"running\":%s,\"pictures\":%llu,\"dropped\":%llu"
                ",\"datagrams\":%llu,\"bytes\":%llu"
                ",\"received\":%llu,\"rejected\":%llu"
                ",\"idrRequests\":%llu,\"clientFrame\":%u,\"clientDamaged\":%u"
                ",\"encoderSubmitted\":%llu,\"encoderPictures\":%llu"
                ",\"encoderDropped\":%llu,\"encoderExtraSamples\":%llu"
                ",\"captureDelivered\":%llu,\"glassToWireMs\":%.2f"
                ",\"audioPackets\":%llu,\"audioBytes\":%llu,\"audioCodec\":\"%s\""
                ",\"audioApps\":%d}",
                s.running.load() ? "true" : "false",
                (unsigned long long) s.picturesSent.load(),
                (unsigned long long) s.picturesDropped.load(),
                (unsigned long long) s.datagramsSent.load(),
                (unsigned long long) s.bytesSent.load(),
                (unsigned long long) s.datagramsReceived.load(),
                (unsigned long long) s.rejected.load(),
                (unsigned long long) s.idrRequests.load(),
                s.clientLastFrame.load(), s.clientDamaged.load(),
                (unsigned long long) (encoderPtr ? encoderPtr->Submitted() : 0),
                (unsigned long long) (encoderPtr ? encoderPtr->Pictures() : 0),
                (unsigned long long) (encoderPtr ? encoderPtr->Dropped() : 0),
                (unsigned long long) (encoderPtr ? encoderPtr->ExtraSamples() : 0),
                (unsigned long long) (capturePtr ? capturePtr->Delivered() : 0),
                s.lastGlassToWireMs.load(),
                (unsigned long long) s.audio.Packets(),
                (unsigned long long) s.audioBytesSent.load(),
                s.config.audioEncoding.codec == AudioEncoding::Codec::Opus ? "opus" : "pcm",
                s.audio.AppSources());
    return buffer;
}

}  // namespace solstream::media
