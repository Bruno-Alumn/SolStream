// MediaClient.swift — the Mac's end of an SMT/1 session.
//
// One UDP socket, four jobs: take video apart and hand it to the decoder, play
// the audio, send input, and tell the host what arrived. It replaces the entire
// GameStream client path -- the RTSP setup, the ENet control channel, the
// Reed-Solomon FEC and the certificate factory -- with a socket and a key
// schedule that were agreed on a channel both ends had already authenticated.
//
// THIS SIDE SPEAKS FIRST. The host learns where to send video from a packet
// that authenticated, never from one that merely arrived: a host that starts
// streaming at whatever address spoke to it is a reflector. It also means NAT
// and the Mac's firewall see an outbound packet before an inbound one, which is
// what makes this work without a port forward.

import Foundation
import CryptoKit
import Darwin
import SolStreamLogging

public final class MediaClient {

    public struct Stats: Sendable {
        /// 0 until the first pong.
        public var rttMs: Double = 0
        public var framesComplete: UInt64 = 0
        public var framesDamaged: UInt64 = 0
        public var datagramsReceived: UInt64 = 0
        public var datagramsRejected: UInt64 = 0
        public var bytesReceived: UInt64 = 0
        public var audioPackets: UInt64 = 0
        // There was a `glassToDecodeMs` here. It was declared, reported as zero
        // for the life of every session, and nothing ever computed it: turning
        // the host's capture clock into milliseconds on this side needs a clock
        // offset that was never estimated. The host measures the same interval
        // end to end -- "glass->wire last/min/mean" in its five-second line -- so
        // a field that could only ever say nothing is worse than no field.

        /// The round trip, or nil while no pong has measured one: before then
        /// `rttMs` reads 0, and the path is unknown rather than short.
        var measuredRttMs: Double? { rttMs > 0 ? rttMs : nil }
    }

    /// A complete coded picture, in Annex B, and whether it is a keyframe.
    public var onVideo: ((Data, Bool) -> Void)?
    /// One packet of the host's sound: PCM or Opus, as its format byte says.
    public var onAudio: ((SMTAudioPacket) -> Void)?
    public var onStats: ((Stats) -> Void)?
    /// Called when the session gives up: the host stopped answering.
    public var onEnded: (() -> Void)?

    private let host: String
    private let port: UInt16
    private let toHost: SMTDirection
    private let fromHost: SMTDirection
    private let sessionTag: UInt8

    private var window = SMTReplayWindow()
    private let reassembler = VideoReassembler()

    private var fd: Int32 = -1
    private var receiveThread: Thread?
    /// Guarded by `stateLock`. Read it through `isRunning`, never directly from
    /// another thread: it is written by whichever of the three threads notices
    /// the session ending first.
    private var running = false
    /// Whether the teardown below has already been performed. Guarded by
    /// `stateLock`, and separate from `running` on purpose: `running` is cleared
    /// by whichever thread notices the session ending, and `stop()` used to take
    /// that as "somebody else has cleaned up" when nobody had.
    private var tornDown = false
    private let sendLock = NSLock()
    private let stateLock = NSLock()
    /// Held for the whole of `stop()`, so a caller that arrives while the
    /// session is tearing itself down waits for it rather than being told the
    /// socket is closed while the receive thread is still inside it.
    private let teardownLock = NSLock()
    /// Signalled by the receive thread as it leaves, so `stop()` can be sure
    /// nothing is inside the socket before the descriptor is closed.
    private let receiveFinished = DispatchSemaphore(value: 0)

    private var stats = Stats()
    /// The reassembler's `lastCompleteFrame`, mirrored under `stateLock` so the
    /// feedback packet can report it without reaching across a thread.
    private var lastCompleteFrame: UInt32 = 0
    private var startedAt = DispatchTime.now().uptimeNanoseconds
    private var lastHeardAt: UInt64 = 0
    /// When the reassembler was last given a chance to retire a picture that
    /// will never complete. Receive-thread only, so it needs no lock.
    private var lastTickAt: UInt64 = 0

    // Input: sequence numbers, the unacknowledged tail, and the repeat timer.
    private var nextSeq: UInt32 = 1
    private var unacked: [(seq: UInt32, blob: Data)] = []
    private var inputAck: UInt32 = 0
    private var lastInputSentAt: UInt64 = 0

    private var needKeyframe = false
    /// Set by damage, cleared by the IDR that repairs it. While it is set,
    /// P-frames are not decoded: each one references the picture that never
    /// arrived, and decoding them smears the damage across the window --
    /// worst on text, which is most of what a desktop application is. The
    /// last good picture stays on screen instead, for the round trip an IDR
    /// takes. And the request is repeated until one arrives, because a
    /// keyframe request is one datagram on the same lossy link. Guarded by
    /// `stateLock`; the rule itself is in KeyframeHold.swift.
    private var hold = KeyframeHold()
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "solstream.media.timer")

    public init(keys: MediaKeys, host: String, port: UInt16) {
        self.host = host
        self.port = port
        self.toHost = SMTDirection(key: keys.clientToHost, fixed: keys.fixedClientToHost)
        self.fromHost = SMTDirection(key: keys.hostToClient, fixed: keys.fixedHostToClient)
        self.sessionTag = keys.sessionTag

        reassembler.onPicture = { [weak self] picture in
            guard let self else { return }
            self.stateLock.lock()
            self.stats.framesComplete = self.reassembler.complete
            // Here as well as on damage: a picture an IDR made unnecessary is
            // counted without being reported.
            self.stats.framesDamaged = self.reassembler.damaged
            self.lastCompleteFrame = picture.frameId
            let verdict = self.hold.picture(frameId: picture.frameId, isIdr: picture.isIdr,
                                            now: DispatchTime.now().uptimeNanoseconds)
            if verdict == .holdAndAsk { self.needKeyframe = true }
            self.stateLock.unlock()
            if verdict == .holdAndAsk {
                self.sendFeedback()
                Log.debug("[media] frame \(picture.frameId) does not follow the last one "
                          + "decoded; asking for a keyframe")
            }
            guard verdict == .decode else { return }
            self.onVideo?(picture.bytes, picture.isIdr)
        }
        reassembler.onDamaged = { [weak self] frameId in
            guard let self else { return }
            self.stateLock.lock()
            self.stats.framesDamaged = self.reassembler.damaged
            let verdict = self.hold.damaged(frameId: frameId,
                                            now: DispatchTime.now().uptimeNanoseconds)
            if verdict != .ignore { self.needKeyframe = true }
            self.stateLock.unlock()
            switch verdict {
            case .ignore:
                Log.debug("[media] frame \(frameId) never completed; a keyframe after "
                          + "it, decoded or on its way, already repairs it")
            case .holdAndAsk:
                // Now, from this thread, not on the next 50 ms feedback tick:
                // the tick added up to half a frame-period of recovery on top
                // of the damage itself. Once per burst -- a lost run reports
                // every frame in it, and the host takes one request per 200 ms
                // anyway.
                self.sendFeedback()
                Log.debug("[media] frame \(frameId) never completed; asking for a keyframe")
            case .hold, .decode:
                Log.debug("[media] frame \(frameId) never completed; a keyframe is "
                          + "already asked for")
            }
        }
        reassembler.onIdrFragment = { [weak self] frameId in
            guard let self else { return }
            self.stateLock.lock()
            self.hold.idrArriving(frameId: frameId, now: DispatchTime.now().uptimeNanoseconds)
            self.stateLock.unlock()
        }
    }

    deinit { stop() }

    // MARK: - Lifetime

    public func start() -> Bool {
        // Resolve the name. This used to be `inet_pton`, which accepts a dotted
        // quad and nothing else, so connecting to a host by name never produced
        // a single frame -- and did it silently, because the agent channel gets
        // there first and it uses Network.framework, which resolves names
        // perfectly well. Everything looked connected: the channel was up, the
        // host agreed a key and started capturing, and the only symptom was a
        // window that stayed on "Waiting for video" for ever.
        //
        // IPv4 only, deliberately. The socket below is AF_INET, the packet path
        // is a `sockaddr_in` throughout and the host's own sender is IPv4, so an
        // AAAA answer is of no use here -- better to say so than to connect to
        // an address nothing will ever send from.
        //
        // getaddrinfo blocks, and start() is called on the main thread. That is
        // survivable because the agent channel has already reached this same
        // host by this same name moments ago, so the answer is one the resolver
        // has just been given rather than one it has to go and find.
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: IPPROTO_UDP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var resolved: UnsafeMutablePointer<addrinfo>?
        // The service is the port as a number, so the resolver fills in
        // `sin_port` as well and there is nothing left to set by hand.
        let resolution = getaddrinfo(host, String(port), &hints, &resolved)
        guard resolution == 0, let first = resolved else {
            Log.error("[media] cannot resolve \(host): "
                      + String(cString: gai_strerror(resolution)))
            return false
        }
        defer { freeaddrinfo(resolved) }

        var address = sockaddr_in()
        var haveAddress = false
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let entry = candidate, !haveAddress {
            if entry.pointee.ai_family == AF_INET, let raw = entry.pointee.ai_addr,
               entry.pointee.ai_addrlen >= socklen_t(MemoryLayout<sockaddr_in>.size) {
                address = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee
                }
                haveAddress = true
            }
            candidate = entry.pointee.ai_next
        }
        guard haveAddress else {
            Log.error("[media] \(host) resolved, but to no IPv4 address; "
                      + "this transport cannot use the result")
            return false
        }

        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            Log.error("[media] no UDP socket: \(String(cString: strerror(errno)))")
            return false
        }
        var receiveBuffer: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer,
                   socklen_t(MemoryLayout<Int32>.size))
        // A 200 ms receive timeout, so the thread can retire timed-out
        // assemblies and notice a stop even while nothing is arriving.
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        // connect() on a datagram socket: send() needs no address, and recv()
        // will not hand us a packet from anywhere else -- which removes a whole
        // class of off-path injection before the AEAD is even asked.
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Log.error("[media] connect failed: \(String(cString: strerror(errno)))")
            close(fd)
            fd = -1
            return false
        }

        // Under the lock, like every other write to it, and clearing `tornDown`
        // with it. `tornDown` is what gates `stop()`, and a client restarted
        // without clearing it was a session `stop()` returned from at its first
        // line: socket open, timer firing every 10 ms, receive thread parked in
        // `recv`, for the life of the process. Nothing does that today — every
        // session builds a fresh MediaClient — but the invariant belongs here
        // rather than in the knowledge of the callers.
        stateLock.lock()
        running = true
        tornDown = false
        startedAt = DispatchTime.now().uptimeNanoseconds
        lastHeardAt = startedAt
        stateLock.unlock()

        let thread = Thread { [weak self] in self?.receiveLoop() }
        thread.name = "solstream.media.receive"
        thread.qualityOfService = .userInteractive
        thread.start()
        receiveThread = thread

        sendPing()
        // And the first keyframe request straight after it, rather than on the
        // first feedback tick or once a P-frame has shown the decoder it has
        // nothing to start from. See `KeyframeHold.holding`. Before the timer
        // starts, so it is this request and not the timer's.
        stateLock.lock()
        let askNow = hold.reaskDue(now: DispatchTime.now().uptimeNanoseconds, rttMs: nil)
        if askNow { needKeyframe = true }
        stateLock.unlock()
        if askNow { sendFeedback() }
        startTimer()
        Log.info("[media] streaming from \(host):\(port)")
        return true
    }

    /// End the session and close the socket, in an order that cannot hand the
    /// descriptor to somebody else while a thread is still inside it.
    ///
    /// THE OLD ORDER WAS UNSAFE, and ThreadSanitizer says so on every run:
    /// `close(fd)` from the main thread while the receive thread sat between
    /// `while running` and `recv(fd, …)`. A closed descriptor number is handed
    /// straight back out by the kernel, and this process opens sockets while a
    /// session is ending — the agent channel reconnects, the next session binds
    /// its own — so the loser of that race does not get an error, it reads
    /// somebody else's socket. Hard to hit and impossible to diagnose.
    ///
    /// So: stop the clock, make sure no timer handler is still in flight, then
    /// `shutdown` — which wakes `recv` WITHOUT freeing the number — then wait
    /// for the receive thread to actually leave, and only then close.
    ///
    /// The gate at the top is `tornDown`, not `running`. It was `running`, and
    /// that quietly turned this whole function into a no-op for the two ways a
    /// session ends by itself -- a BYE from the host, and the silence watchdog
    /// -- because both clear `running` where they stand. The socket, the timer
    /// and the receive thread survived every such session for the life of the
    /// process. See `endedByItself` below.
    public func stop() {
        teardownLock.lock()
        defer { teardownLock.unlock() }
        stateLock.lock()
        guard !tornDown else { stateLock.unlock(); return }
        tornDown = true
        running = false
        stateLock.unlock()

        timer?.cancel()
        timer = nil
        // A cancelled DispatchSourceTimer may still have a handler running. Its
        // handlers run on this queue, so a barrier here is what makes "no more
        // sends" true rather than likely.
        timerQueue.sync {}

        sendRaw(Data([SMT.typeBye]))

        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
        }
        // Bounded: the loop's own receive timeout is 200 ms, so a second is
        // several chances to notice.
        //
        // Missing that deadline used to mean abandoning the descriptor for the
        // life of the process -- a leak per session, taken deliberately because
        // hanging the main thread on a socket that will not wake is worse, and
        // closing it under a thread that is still inside `recv` hands the
        // number straight back out to the next socket this process opens.
        //
        // Neither is necessary. The descriptor goes to a thread of its own that
        // does the waiting the caller could not afford, and closes it whenever
        // the receive thread finally leaves. `fd` is cleared first, so nothing
        // here sends into it in the meantime, and the closure holds only the
        // number and the semaphore -- not `self` -- so this client is free to
        // be deallocated while that thread is still waiting.
        if receiveThread != nil {
            if receiveFinished.wait(timeout: .now() + 1.0) == .timedOut {
                Log.error("[media] the receive thread did not stop within a "
                          + "second; closing its socket from a separate thread "
                          + "once it does")
                sendLock.lock()
                let stranded = fd
                fd = -1
                sendLock.unlock()
                receiveThread = nil
                let finished = receiveFinished
                // A Thread rather than a global queue: this waits without a
                // deadline, and a libdispatch worker blocked indefinitely is
                // one taken out of a pool the rest of the app shares.
                let closer = Thread {
                    finished.wait()
                    if stranded >= 0 { close(stranded) }
                }
                closer.name = "solstream.media.close"
                closer.qualityOfService = .utility
                closer.start()
                return
            }
            receiveThread = nil
        }
        sendLock.lock()
        let toClose = fd
        fd = -1
        sendLock.unlock()
        if toClose >= 0 {
            close(toClose)
        }
    }

    /// The session ended without anybody here asking: the host said BYE, or the
    /// watchdog gave up on a host that had gone quiet.
    ///
    /// Both paths used to set `running = false` and call `onEnded`, and that was
    /// all. `stop()` arriving afterwards found `running` already false and
    /// returned at its first line, so the socket stayed open, the 10 ms timer
    /// kept firing into it and the receive thread kept sitting in `recv` — one
    /// set of each, per session, until the app quit.
    ///
    /// Neither caller can do the teardown where it stands. The watchdog runs on
    /// `timerQueue` and `stop()` does `timerQueue.sync {}`, which from that
    /// queue is an immediate self-deadlock; the BYE is handled on the receive
    /// thread, and `stop()` waits for that thread to leave `recv`, which it
    /// cannot do while it is standing inside `stop()`. So `running` is cleared
    /// here — that is what gets both of them to unwind — and the teardown goes
    /// somewhere neither of them is. `onEnded` fires after it, so by the time
    /// anyone hears the session ended, it has actually finished ending.
    private func endedByItself() {
        stateLock.lock()
        guard running else { stateLock.unlock(); return }
        running = false
        stateLock.unlock()
        // Strong on purpose: this client has to outlive its own teardown, and
        // nothing else is holding it up while the callback runs.
        DispatchQueue.global(qos: .userInitiated).async {
            self.stop()
            self.onEnded?()
        }
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    public func requestKeyframe() {
        stateLock.lock()
        needKeyframe = true
        stateLock.unlock()
    }

    /// The decoder can do nothing until an IDR: it has no parameter sets, or a
    /// failure took its reference pictures with it. Hold P-frames back from it
    /// as for damage, and ask now.
    ///
    /// `requestKeyframe` used to be all it had. That set a flag for the next
    /// feedback tick and held nothing back, so every P-frame until the IDR went
    /// on into a decoder that could only fail on it.
    public func holdUntilKeyframe() {
        stateLock.lock()
        let verdict = hold.lostReference(now: DispatchTime.now().uptimeNanoseconds)
        needKeyframe = true
        stateLock.unlock()
        if verdict == .holdAndAsk { sendFeedback() }
    }

    // MARK: - Sending

    /// Seal and send, with the descriptor held for the whole of it.
    ///
    /// `fd` used to be read outside this lock while `stop()` was free to close it
    /// from another thread — and `stop()` genuinely does run elsewhere, because
    /// `endedByItself` hands it to a global queue. So the main thread could read a
    /// live descriptor, lose the race, and then `send()` into a number the kernel
    /// had already handed back out to the next socket this process opened: the
    /// agent channel reconnecting, or the next session's own. That is not an
    /// error the caller sees, it is a datagram delivered somewhere else.
    ///
    /// `stop()` therefore sends its BYE before it takes this lock to clear `fd`,
    /// and never while holding it — NSLock is not recursive.
    private func sendRaw(_ plaintext: Data) {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard fd >= 0 else { return }
        guard let datagram = SMTPacket.seal(plaintext, direction: toHost,
                                            sessionTag: sessionTag) else { return }
        _ = datagram.withUnsafeBytes { raw in
            Darwin.send(fd, raw.baseAddress, raw.count, 0)
        }
    }

    private func sendPing() {
        var packet = Data([SMT.typePing])
        packet.append(SMTPacket.be(nowMicros(), 8))
        sendRaw(packet)
    }

    /// Queue one input event. The datagram carries it plus the unacknowledged
    /// tail, so a single loss costs nothing.
    public func sendInput(_ blob: Data) {
        guard isRunning, blob.count >= 2 else { return }
        stateLock.lock()
        let seq = nextSeq
        nextSeq &+= 1
        unacked.append((seq, blob))
        if unacked.count > 32 { unacked.removeFirst(unacked.count - 32) }
        let batch = unacked.suffix(8)
        lastInputSentAt = DispatchTime.now().uptimeNanoseconds
        stateLock.unlock()
        sendInputBatch(Array(batch))
    }

    private func sendInputBatch(_ events: [(seq: UInt32, blob: Data)]) {
        guard !events.isEmpty else { return }
        var packet = Data(capacity: 4 + events.reduce(0) { $0 + $1.blob.count + 4 })
        packet.append(SMT.typeInput)
        packet.append(UInt8(min(events.count, 255)))
        packet.append(0)
        packet.append(0)
        for event in events {
            packet.append(SMTPacket.be(UInt64(event.seq), 4))
            packet.append(event.blob)
        }
        guard packet.count <= SMT.maxPlaintext else { return }
        sendRaw(packet)
    }

    private func sendFeedback() {
        stateLock.lock()
        let wantKeyframe = needKeyframe
        needKeyframe = false
        // From the mirror, not from the reassembler. Its counters are written
        // on the receive thread without this lock, so reading them here was a
        // race on every feedback packet -- fifty a second, for the whole
        // session. The callbacks above already copy them across under the lock.
        let complete = stats.framesComplete
        let damaged = stats.framesDamaged
        let last = lastCompleteFrame
        let received = stats.datagramsReceived
        stateLock.unlock()

        var packet = Data(capacity: 24)
        packet.append(SMT.typeFeedback)
        packet.append(wantKeyframe ? 0x01 : 0x00)
        packet.append(0)
        packet.append(0)
        packet.append(SMTPacket.be(UInt64(last), 4))
        packet.append(SMTPacket.be(complete & 0xFFFF_FFFF, 4))
        packet.append(SMTPacket.be(damaged & 0xFFFF_FFFF, 4))
        packet.append(SMTPacket.be(received & 0xFFFF_FFFF, 4))
        packet.append(SMTPacket.be(0, 4))
        sendRaw(packet)
    }

    // MARK: - The timer

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        // 10 ms, which is the input repeat interval. Feedback and pings are
        // sent on multiples of it rather than on timers of their own.
        source.schedule(deadline: .now() + .milliseconds(10),
                        repeating: .milliseconds(10))
        var ticks = 0
        source.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            ticks += 1

            // Repeat the unacknowledged input tail.
            //
            // Defect #2 of the six in docs/transport-smt1.md: the redundancy
            // window repeats recent events on SUBSEQUENT datagrams, and when
            // the user stops typing there are none -- so a lost final key-up is
            // a key that stays down, and auto-repeats, until something else is
            // typed. This timer is the thing that makes that impossible.
            self.stateLock.lock()
            let pending = self.unacked.filter { $0.seq > self.inputAck }
            let sinceSent = Self.millis(since: self.lastInputSentAt)
            let giveUp = sinceSent > 300
            if !pending.isEmpty && !giveUp {
                self.stateLock.unlock()
                self.sendInputBatch(Array(pending.suffix(8)))
            } else {
                if giveUp && !pending.isEmpty {
                    // 300 ms of a host that will not acknowledge is a host that
                    // is not listening. Holding the events forever would repeat
                    // them into a session that has moved on.
                    self.unacked.removeAll()
                }
                self.stateLock.unlock()
            }

            // Still holding for a keyframe a quarter-second after asking, with
            // none of it arriving: the request or the IDR was lost. Ask again
            // -- just past the host's 200 ms rate limit, so the repeat is never
            // the one it ignores. See `KeyframeHold.reaskDue`.
            self.stateLock.lock()
            if self.hold.reaskDue(now: DispatchTime.now().uptimeNanoseconds,
                                  rttMs: self.stats.measuredRttMs) {
                self.needKeyframe = true
            }
            self.stateLock.unlock()

            if ticks % 5 == 0 { self.sendFeedback() }        // 50 ms
            if ticks % 100 == 0 { self.sendPing() }          // 1 s

            // Copied under the lock: the receive thread writes it on every
            // datagram that authenticates, roughly two hundred times a second.
            self.stateLock.lock()
            let heardAt = self.lastHeardAt
            self.stateLock.unlock()
            let silentMs = Self.millis(since: heardAt)
            if silentMs > 5000 {
                Log.error("[media] the host has been silent for 5 s")
                self.endedByItself()
            }
            if ticks % 5 == 0 {
                self.stateLock.lock()
                let snapshot = self.stats
                self.stateLock.unlock()
                self.onStats?(snapshot)
            }
        }
        source.resume()
        timer = source
    }

    // MARK: - Receiving

    private func nowMicros() -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds &- startedAt) / 1000
    }

    /// Milliseconds since a timestamp another thread may have just moved.
    ///
    /// UInt64 subtraction TRAPS on underflow in Swift, and `now` and the stored
    /// stamp are read at different instants: the compiler is free to put the
    /// load of the field after the call that produced `now`, so the receive
    /// thread can write a NEWER value in between. The result is a process that
    /// dies with "arithmetic overflow" a few seconds into a stream, on a line
    /// whose arithmetic is obviously non-negative. It was.
    private static func millis(since stamp: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        return now > stamp ? Double(now - stamp) / 1e6 : 0
    }

    private func receiveLoop() {
        // Signalled however this returns, including the early exits below:
        // `stop()` waits on it before closing the socket, and a path that
        // forgot to signal would stall it for a second and then strand the
        // descriptor on a closer thread that never gets to close it.
        defer { receiveFinished.signal() }
        var buffer = [UInt8](repeating: 0, count: 2048)
        // The descriptor is read once, here. `stop()` does not close it until
        // this function has returned, so a local copy is valid for the whole
        // loop and is not a field two threads share.
        let socket = fd
        while isRunning {
            let n = recv(socket, &buffer, buffer.count, 0)
            if n <= 0 {
                // A timeout, which is the only quiet moment there is: retire
                // assemblies that will never complete.
                reassembler.tick()
                lastTickAt = DispatchTime.now().uptimeNanoseconds
                continue
            }
            // AND WHILE PACKETS ARE ARRIVING, which is when it matters. The
            // idle path above only runs after 200 ms of complete silence, and a
            // stream that is losing fragments is not silent -- so a picture
            // missing one fragment was never retired, never reported damaged,
            // and never prompted the keyframe that would have recovered it.
            // Its 512 KB assembly buffer stayed in `building` for the life of
            // the session, one per lost fragment, and the picture the user was
            // looking at simply stopped moving.
            if Self.millis(since: lastTickAt) >= 25 {
                reassembler.tick()
                lastTickAt = DispatchTime.now().uptimeNanoseconds
            }
            let datagram = Data(buffer[0..<n])
            stateLock.lock()
            stats.datagramsReceived &+= 1
            stats.bytesReceived &+= UInt64(n)
            stateLock.unlock()

            guard let (plaintext, _) = SMTPacket.open(datagram, direction: fromHost,
                                                      window: &window) else {
                stateLock.lock()
                stats.datagramsRejected &+= 1
                stateLock.unlock()
                continue
            }
            stateLock.lock()
            lastHeardAt = DispatchTime.now().uptimeNanoseconds
            stateLock.unlock()
            handle(plaintext)
        }
    }

    private func handle(_ plaintext: Data) {
        guard let type = plaintext.first else { return }
        switch type {
        case SMT.typeVideo:
            reassembler.ingest(plaintext)
        case SMT.typeAudio:
            guard let packet = SMTAudioPacket(plaintext: plaintext) else { return }
            stateLock.lock()
            stats.audioPackets &+= 1
            stateLock.unlock()
            onAudio?(packet)
        case SMT.typePong:
            guard plaintext.count >= 9 else { return }
            let sent = SMTPacket.readBE([UInt8](plaintext)[1..<9])
            let now = nowMicros()
            // The echoed stamp is this Mac's own clock, so an honest pong is
            // never from the future -- but `&-` is there because a host that
            // echoes the wrong eight bytes would otherwise trap, and what it
            // wraps to is around 1.8e13 milliseconds. The smoothing below has no
            // way back from that: one bad sample sets the reported round trip to
            // half a billion years and every later sample moves it 20% of the way
            // towards the truth, so the figure stays useless for the whole
            // session. Discarded rather than smoothed.
            guard now >= sent else { return }
            let rtt = Double(now - sent) / 1000.0
            guard rtt < 10_000 else {
                Log.debug("[media] ignoring a pong claiming a \(Int(rtt)) ms round trip")
                return
            }
            stateLock.lock()
            // A little smoothing, because one sample of a round trip on a
            // shared link says more about that instant than about the path.
            stats.rttMs = stats.rttMs == 0 ? rtt : stats.rttMs * 0.8 + rtt * 0.2
            stateLock.unlock()
        case SMT.typeHostStat:
            guard plaintext.count >= 8 else { return }
            let ack = UInt32(SMTPacket.readBE([UInt8](plaintext)[4..<8]))
            stateLock.lock()
            inputAck = ack
            unacked.removeAll { $0.seq <= ack }
            stateLock.unlock()
        case SMT.typeBye:
            Log.info("[media] the host ended the session")
            endedByItself()
        default:
            break
        }
    }
}
