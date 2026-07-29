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
        public var rttMs: Double = 0
        public var framesComplete: UInt64 = 0
        public var framesDamaged: UInt64 = 0
        public var datagramsReceived: UInt64 = 0
        public var datagramsRejected: UInt64 = 0
        public var bytesReceived: UInt64 = 0
        public var audioPackets: UInt64 = 0
        /// Host capture clock to this picture being ready to decode, in
        /// milliseconds. Only meaningful once `clockOffsetUs` has settled.
        public var glassToDecodeMs: Double = 0
    }

    /// A complete coded picture, in Annex B, and whether it is a keyframe.
    public var onVideo: ((Data, Bool) -> Void)?
    /// Interleaved S16 PCM and its sample rate.
    public var onAudio: ((Data, UInt32) -> Void)?
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
    private var running = false
    private let sendLock = NSLock()
    private let stateLock = NSLock()

    private var stats = Stats()
    private var startedAt = DispatchTime.now().uptimeNanoseconds
    private var lastHeardAt: UInt64 = 0

    // Input: sequence numbers, the unacknowledged tail, and the repeat timer.
    private var nextSeq: UInt32 = 1
    private var unacked: [(seq: UInt32, blob: Data)] = []
    private var inputAck: UInt32 = 0
    private var lastInputSentAt: UInt64 = 0

    private var needKeyframe = false
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
            self.stateLock.unlock()
            self.onVideo?(picture.bytes, picture.isIdr)
        }
        reassembler.onDamaged = { [weak self] frameId in
            guard let self else { return }
            self.stateLock.lock()
            self.stats.framesDamaged = self.reassembler.damaged
            self.needKeyframe = true
            self.stateLock.unlock()
            Log.debug("[media] frame \(frameId) never completed; asking for a keyframe")
        }
    }

    deinit { stop() }

    // MARK: - Lifetime

    public func start() -> Bool {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            Log.error("[media] \(host) is not an address this build can use")
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

        running = true
        startedAt = DispatchTime.now().uptimeNanoseconds
        lastHeardAt = startedAt

        let thread = Thread { [weak self] in self?.receiveLoop() }
        thread.name = "solstream.media.receive"
        thread.qualityOfService = .userInteractive
        thread.start()
        receiveThread = thread

        startTimer()
        sendPing()
        Log.info("[media] streaming from \(host):\(port)")
        return true
    }

    public func stop() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        sendRaw(Data([SMT.typeBye]))
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    public var isRunning: Bool { running }

    public func requestKeyframe() {
        stateLock.lock()
        needKeyframe = true
        stateLock.unlock()
    }

    // MARK: - Sending

    private func sendRaw(_ plaintext: Data) {
        guard fd >= 0 else { return }
        sendLock.lock()
        let datagram = SMTPacket.seal(plaintext, direction: toHost, sessionTag: sessionTag)
        sendLock.unlock()
        guard let datagram else { return }
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
        guard running, blob.count >= 2 else { return }
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
        let complete = reassembler.complete
        let damaged = reassembler.damaged
        let last = reassembler.lastCompleteFrame
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
            guard let self, self.running else { return }
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
            let sinceSent = Double(DispatchTime.now().uptimeNanoseconds
                                   - self.lastInputSentAt) / 1e6
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

            if ticks % 5 == 0 { self.sendFeedback() }        // 50 ms
            if ticks % 100 == 0 { self.sendPing() }          // 1 s

            let silentMs = Double(DispatchTime.now().uptimeNanoseconds
                                  - self.lastHeardAt) / 1e6
            if silentMs > 5000 {
                Log.error("[media] the host has been silent for 5 s")
                self.running = false
                self.onEnded?()
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
        (DispatchTime.now().uptimeNanoseconds - startedAt) / 1000
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while running {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 {
                // A timeout, which is the only quiet moment there is: retire
                // assemblies that will never complete.
                reassembler.tick()
                continue
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
            lastHeardAt = DispatchTime.now().uptimeNanoseconds
            handle(plaintext)
        }
    }

    private func handle(_ plaintext: Data) {
        guard let type = plaintext.first else { return }
        switch type {
        case SMT.typeVideo:
            reassembler.ingest(plaintext)
        case SMT.typeAudio:
            guard plaintext.count > 16 else { return }
            let b = [UInt8](plaintext)
            let rate = (UInt32(b[12]) << 24) | (UInt32(b[13]) << 16)
                     | (UInt32(b[14]) << 8) | UInt32(b[15])
            stateLock.lock()
            stats.audioPackets &+= 1
            stateLock.unlock()
            onAudio?(plaintext.dropFirst(16), rate)
        case SMT.typePong:
            guard plaintext.count >= 9 else { return }
            let sent = SMTPacket.readBE([UInt8](plaintext)[1..<9])
            let rtt = Double(nowMicros() &- sent) / 1000.0
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
            running = false
            onEnded?()
        default:
            break
        }
    }
}
