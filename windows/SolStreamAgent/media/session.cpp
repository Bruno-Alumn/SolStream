#include "session.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include "capture.h"
#include "encoder.h"
#include "input.h"
#include "smt.h"
#include "audio.h"
#include "log.h"

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
    std::unique_ptr<Capture> capture;
    std::unique_ptr<Encoder> encoder;
    AudioCapture audio;
    InputInjector input;

    std::atomic<bool> running{false};
    std::thread captureThread, senderThread, receiveThread, audioThread;

    std::mutex queueLock;
    std::condition_variable queueReady;
    std::deque<Picture> queue;

    long long startedAt = 0;
    long long lastHeardAt = 0;
    long long lastIdrAt = 0;
    long long nextSlot = 0;
    double ticksPerByte = 0;

    std::atomic<uint64_t> datagramsSent{0}, bytesSent{0};
    std::atomic<uint64_t> picturesSent{0}, picturesDropped{0};
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

    void CaptureLoop();
    void RunCapture();
    void SenderLoop();
    void ReceiveLoop();
    void SendPicture(const Picture& picture);
    void SendSealed(const unsigned char* plaintext, size_t length);
    void WaitUntil(long long deadline);
    void HandlePlaintext(const unsigned char* plaintext, size_t length);
};

// ── Sealing and sending ──────────────────────────────────────────────────────

void MediaSession::Impl::SendSealed(const unsigned char* plaintext, size_t length) {
    unsigned char datagram[smt::kMaxPlaintext + smt::kOverhead];
    size_t total = 0;
    sockaddr_in to{};
    {
        std::lock_guard<std::mutex> guard(peerLock);
        if (!havePeer) { return; }
        to = peer;
    }
    {
        std::lock_guard<std::mutex> guard(sealLock);
        total = smt::Seal(toClient, sessTag, plaintext, length, datagram, sizeof(datagram));
    }
    if (total == 0) { return; }
    sendto(socket, (const char*) datagram, (int) total, 0, (sockaddr*) &to, sizeof(to));
    datagramsSent.fetch_add(1);
    bytesSent.fetch_add(total);
}

void MediaSession::Impl::WaitUntil(long long deadline) {
    for (;;) {
        const long long now = Now();
        if (now >= deadline) { return; }
        const long long remainingUs =
            (deadline - now) * 1000000 / g_frequency.QuadPart;
        if (remainingUs > 2000) {
            Sleep(1);
        }
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
}

void MediaSession::Impl::RunCapture() {
    capture = std::make_unique<Capture>();
    encoder = std::make_unique<Encoder>();
    struct Teardown {
        Impl* self;
        ~Teardown() {
            if (self->encoder) { self->encoder->Close(); }
            if (self->capture) { self->capture->Stop(); }
            self->encoder.reset();
            self->capture.reset();
        }
    } teardown{this};

    if (config.window) {
        if (!capture->StartWindow(config.window)) {
            Log("[media] capture of window %p failed", (void*) config.window);
            return;
        }
    } else if (!capture->StartMonitor(config.monitor)) {
        Log("[media] capture of monitor %p failed", (void*) config.monitor);
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
        return;
    }

    const UINT encodeWidth = config.width ? config.width : frame.width;
    const UINT encodeHeight = config.height ? config.height : frame.height;
    if (!encoder->Open(capture->Device(), encodeWidth, encodeHeight, config.fps,
                      config.bitrate)) {
        Log("[media] the hardware encoder would not open at %ux%u",
            encodeWidth, encodeHeight);
        return;
    }
    Log("[media] capturing %ux%u, encoding %ux%u at %u fps, %u kbit/s",
        frame.width, frame.height, encoder->Width(), encoder->Height(),
        config.fps, config.bitrate / 1000);

    encoder->OnPicture([this](const CodedPicture& coded) {
        Picture picture;
        picture.bytes.assign(coded.data, coded.data + coded.length);
        picture.frameId = coded.frameId;
        picture.isIdr = coded.isIdr;
        picture.capturedAt = coded.capturedAt;
        picture.encodedAt = coded.encodedAt;
        {
            std::lock_guard<std::mutex> guard(queueLock);
            if (queue.size() >= kSendQueueDepth) {
                // The sender cannot keep up, so the queue is full of pictures
                // that will be stale before they leave. Throwing them away and
                // asking for a keyframe recovers in one frame; sending them
                // recovers in however long the backlog takes.
                queue.clear();
                picturesDropped.fetch_add(1);
                if (encoder) { encoder->RequestIdr(); }
            }
            queue.push_back(std::move(picture));
        }
        queueReady.notify_one();
    });

    uint64_t lastSerial = 0;
    // The heartbeat that makes a still window streamable. WGC delivers nothing
    // while nothing changes, so without this the last frame's damage is never
    // repaired and a client joining a static screen waits forever.
    const int idleMs = 1000 / (int) (config.fps ? config.fps : 60);
    long long lastEncodedAt = Now();
    while (running.load() && !retargetWanted.load()) {
        Frame current{};
        if (!capture->Acquire(current, lastSerial, idleMs)) {
            if (!capture->Running()) { break; }
            continue;
        }
        const bool stale = MillisBetween(lastEncodedAt, Now()) > 250.0;
        if (!current.isNew && !stale) {
            continue;
        }
        lastSerial = current.serial;
        lastEncodedAt = Now();
        encoder->Submit(current.texture, current.width, current.height,
                       current.isNew ? current.capturedAt : Now(), false);
    }
}

void MediaSession::Impl::SenderLoop() {
    timeBeginPeriod(1);
    long long lastStat = 0;
    long long lastReport = Now();
    uint64_t lastReportPictures = 0, lastReportBytes = 0;
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
            Log("[media] %.1f fps, %.1f Mbit/s | capture %llu, encoder %llu/%llu"
                " (dropped %llu, extra samples %llu) | glass->wire last %.1f min %.1f"
                " mean %.1f ms | client frame %u, damaged %u, idr asks %llu"
                " | rx %llu, rejected %llu",
                elapsed > 0 ? (double) (pictures - lastReportPictures) / elapsed : 0.0,
                elapsed > 0
                    ? (double) (bytesSent.load() - lastReportBytes) * 8.0 / elapsed / 1e6
                    : 0.0,
                (unsigned long long) (capture ? capture->Delivered() : 0),
                (unsigned long long) (encoder ? encoder->Pictures() : 0),
                (unsigned long long) (encoder ? encoder->Submitted() : 0),
                (unsigned long long) (encoder ? encoder->Dropped() : 0),
                (unsigned long long) (encoder ? encoder->ExtraSamples() : 0),
                lastGlassToWireMs.load(),
                minGlassToWireMs.load() > 1e8 ? 0.0 : minGlassToWireMs.load(),
                pictures ? sumGlassToWireMs.load() / (double) pictures : 0.0,
                clientLastFrame.load(), clientDamaged.load(),
                (unsigned long long) idrRequests.load(),
                (unsigned long long) datagramsReceived.load(),
                (unsigned long long) rejected.load());
            lastReport = now;
            lastReportPictures = pictures;
            lastReportBytes = bytesSent.load();
        }

        if (lastHeardAt != 0 && MillisBetween(lastHeardAt, now) > kSilenceTimeoutMs) {
            Log("[media] the client has been silent for %d ms; ending the session",
                kSilenceTimeoutMs);
            running.store(false);
            break;
        }
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
                if (MillisBetween(lastIdrAt, now) > 200.0) {
                    lastIdrAt = now;
                    idrRequests.fetch_add(1);
                    if (encoder) { encoder->RequestIdr(); }
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
    for (;;) {
        if (!running.load()) { break; }
        sockaddr_in from{};
        int fromLen = sizeof(from);
        const int n = recvfrom(socket, (char*) buffer, sizeof(buffer), 0,
                               (sockaddr*) &from, &fromLen);
        if (n <= 0) {
            continue;   // the socket has a receive timeout so this loop can exit
        }
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
        {
            std::lock_guard<std::mutex> guard(peerLock);
            if (!havePeer || from.sin_addr.s_addr != peer.sin_addr.s_addr
                || from.sin_port != peer.sin_port) {
                peer = from;
                havePeer = true;
                char who[64] = {};
                inet_ntop(AF_INET, &from.sin_addr, who, sizeof(who));
                Log("[media] client at %s:%u", who, ntohs(from.sin_port));
            }
        }
        lastHeardAt = Now();
        HandlePlaintext(plaintext, plaintextLen);
    }
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
    if (!s.toClient.key || !s.fromClient.key) {
        if (error) { *error = "the media keys would not import"; }
        return false;
    }

    s.socket = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s.socket == INVALID_SOCKET) {
        if (error) { *error = "no UDP socket"; }
        return false;
    }
    int sndbuf = 1 << 21;
    setsockopt(s.socket, SOL_SOCKET, SO_SNDBUF, (const char*) &sndbuf, sizeof(sndbuf));
    int rcvbuf = 1 << 20;
    setsockopt(s.socket, SOL_SOCKET, SO_RCVBUF, (const char*) &rcvbuf, sizeof(rcvbuf));
    DWORD timeout = 200;
    setsockopt(s.socket, SOL_SOCKET, SO_RCVTIMEO, (const char*) &timeout, sizeof(timeout));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(config.port);
    if (bind(s.socket, (sockaddr*) &address, sizeof(address)) == SOCKET_ERROR) {
        closesocket(s.socket);
        s.socket = INVALID_SOCKET;
        if (error) { *error = "UDP port " + std::to_string(config.port) + " is taken"; }
        return false;
    }

    InputTarget target;
    target.window = config.window;
    target.monitor = config.monitor;
    s.input.SetTarget(target);

    s.startedAt = Now();
    s.lastHeardAt = 0;
    s.lastIdrAt = 0;
    s.nextSlot = s.startedAt;
    // Pace at twice the encoder's target. Metering at exactly the bitrate makes
    // every IDR late by construction, and metering at line rate is what loses
    // their fragments.
    const double pacingBits = (double) config.bitrate * 2.0;
    s.ticksPerByte = (double) g_frequency.QuadPart / (pacingBits / 8.0);

    s.datagramsSent = 0; s.bytesSent = 0;
    s.picturesSent = 0; s.picturesDropped = 0;
    s.datagramsReceived = 0; s.rejected = 0; s.idrRequests = 0;

    s.running.store(true);
    s.receiveThread = std::thread([&s] { s.ReceiveLoop(); });
    s.senderThread = std::thread([&s] { s.SenderLoop(); });
    s.captureThread = std::thread([&s] { s.CaptureLoop(); });
    if (config.audio) {
        s.audioThread = std::thread([&s] {
            s.audio.Run([&s](const unsigned char* pcm, size_t length, uint32_t seq,
                             uint32_t timestampUs, uint32_t rate, uint16_t channels) {
                unsigned char packet[smt::kMaxPlaintext];
                if (length + 16 > sizeof(packet)) { return; }
                packet[0] = smt::kTypeAudio;
                packet[1] = 0;
                packet[2] = (unsigned char) channels;
                packet[3] = 1;    // S16 little-endian, interleaved
                smt::PutBE(packet + 4, seq, 4);
                smt::PutBE(packet + 8, timestampUs, 4);
                smt::PutBE(packet + 12, rate, 4);
                memcpy(packet + 16, pcm, length);
                s.SendSealed(packet, 16 + length);
            }, [&s] { return s.running.load(); });
        });
    }

    Log("[media] session started on UDP %u", config.port);
    return true;
}

void MediaSession::Stop() {
    Impl& s = *impl_;
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
        s.config.width = 0;      // the new source decides the size
        s.config.height = 0;
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
    snprintf(buffer, sizeof(buffer),
                "{\"running\":%s,\"pictures\":%llu,\"dropped\":%llu"
                ",\"datagrams\":%llu,\"bytes\":%llu"
                ",\"received\":%llu,\"rejected\":%llu"
                ",\"idrRequests\":%llu,\"clientFrame\":%u,\"clientDamaged\":%u"
                ",\"encoderSubmitted\":%llu,\"encoderPictures\":%llu"
                ",\"encoderDropped\":%llu,\"encoderExtraSamples\":%llu"
                ",\"captureDelivered\":%llu,\"glassToWireMs\":%.2f}",
                s.running.load() ? "true" : "false",
                (unsigned long long) s.picturesSent.load(),
                (unsigned long long) s.picturesDropped.load(),
                (unsigned long long) s.datagramsSent.load(),
                (unsigned long long) s.bytesSent.load(),
                (unsigned long long) s.datagramsReceived.load(),
                (unsigned long long) s.rejected.load(),
                (unsigned long long) s.idrRequests.load(),
                s.clientLastFrame.load(), s.clientDamaged.load(),
                (unsigned long long) (s.encoder ? s.encoder->Submitted() : 0),
                (unsigned long long) (s.encoder ? s.encoder->Pictures() : 0),
                (unsigned long long) (s.encoder ? s.encoder->Dropped() : 0),
                (unsigned long long) (s.encoder ? s.encoder->ExtraSamples() : 0),
                (unsigned long long) (s.capture ? s.capture->Delivered() : 0),
                s.lastGlassToWireMs.load());
    return buffer;
}

}  // namespace solstream::media
