// ping.swift — the Mac half of step 3. Seals a PING, opens the PONG, times it.
//
// Only this clock is ever consulted: the timestamp goes out in the packet and
// comes back untouched, so the two machines never have to agree about time and
// the number is a true round trip rather than two one-way guesses added together.
//
//   swift spike/smt-ping/ping.swift <host> [count] [port]

import Foundation
import CryptoKit
import Darwin

// ── The frozen vector's keys ─────────────────────────────────────────────────
//
// Step 4 replaces these with the real handshake. The packet layer does not care
// where a key came from, which is exactly why it can be measured first.

func hexBytes(_ s: String) -> Data {
    var out = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

let keyC2H = SymmetricKey(data: hexBytes("4aa5aaf36c0cb3dacd26251c0c0e84b96c6910d1d87bcd803f0df616e7dd3b87"))
let keyH2C = SymmetricKey(data: hexBytes("8c83fc537b9b19d56753962eacc673097a76510c95b60f41fdb5056a5062aaea"))
let fixedC2H = hexBytes("593154045ebd")
let fixedH2C = hexBytes("4a20dd1ecfc0")
let sessTag: UInt8 = 0x62

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: ping.swift <host> [count] [port]")
    exit(2)
}
let hostName = arguments[1]
let count = arguments.count > 2 ? Int(arguments[2])! : 200
let port = arguments.count > 3 ? UInt16(arguments[3])! : 47631

// ── Socket ───────────────────────────────────────────────────────────────────

let fd = socket(AF_INET, SOCK_DGRAM, 0)
guard fd >= 0 else { print("socket failed"); exit(1) }
var timeout = timeval(tv_sec: 1, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

var target = sockaddr_in()
target.sin_family = sa_family_t(AF_INET)
target.sin_port = port.bigEndian
guard inet_pton(AF_INET, hostName, &target.sin_addr) == 1 else {
    print("bad address \(hostName)"); exit(1)
}

func be48(_ v: UInt64) -> Data {
    var d = Data(count: 6)
    for i in 0..<6 { d[i] = UInt8((v >> (40 - 8 * i)) & 0xFF) }
    return d
}

var counter: UInt64 = 0

/// Header || ciphertext || tag, with the header as the AAD verbatim.
func seal(_ plaintext: Data) -> Data {
    var header = Data()
    header.append((1 << 4) | 0)
    header.append(sessTag)
    header += be48(counter)
    let nonce = try! AES.GCM.Nonce(data: fixedC2H + be48(counter))
    counter += 1
    let box = try! AES.GCM.seal(plaintext, using: keyC2H, nonce: nonce,
                                authenticating: header)
    return header + box.ciphertext + box.tag
}

func open(_ datagram: Data) -> Data? {
    guard datagram.count >= 24, datagram[datagram.startIndex] >> 4 == 1 else { return nil }
    let header = datagram.prefix(8)
    let counterBytes = datagram.subdata(in: datagram.startIndex + 2..<datagram.startIndex + 8)
    let body = datagram.dropFirst(8).dropLast(16)
    let tag = datagram.suffix(16)
    guard let nonce = try? AES.GCM.Nonce(data: fixedH2C + counterBytes),
          let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body, tag: tag),
          let plaintext = try? AES.GCM.open(box, using: keyH2C, authenticating: header)
    else { return nil }
    return plaintext
}

func nowMicros() -> UInt64 { UInt64(DispatchTime.now().uptimeNanoseconds / 1000) }

// ── Measure ──────────────────────────────────────────────────────────────────

var samples: [Double] = []
var lost = 0
var forged = 0

print("smt-ping -> \(hostName):\(port), \(count) packets")
for _ in 0..<count {
    var plaintext = Data([0x01])           // PING
    let sent = nowMicros()
    withUnsafeBytes(of: sent.bigEndian) { plaintext.append(contentsOf: $0) }
    let datagram = seal(plaintext)

    let ok = datagram.withUnsafeBytes { raw in
        withUnsafePointer(to: &target) { addr in
            addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, raw.baseAddress, raw.count, 0, sa,
                       socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    if ok < 0 { lost += 1; continue }

    var buffer = [UInt8](repeating: 0, count: 2048)
    let n = recv(fd, &buffer, buffer.count, 0)
    let received = nowMicros()
    if n <= 0 { lost += 1; usleep(5000); continue }

    guard let reply = open(Data(buffer[0..<n])), reply.count == 9,
          reply[reply.startIndex] == 0x02 else {
        forged += 1
        continue
    }
    // The echoed timestamp, so a reply to an older ping cannot be timed against
    // the newest one.
    var echoed: UInt64 = 0
    for byte in reply.dropFirst() { echoed = (echoed << 8) | UInt64(byte) }
    samples.append(Double(received - echoed) / 1000.0)
    usleep(5000)
}

// Jitter FIRST, on arrival order. Sorting and then taking consecutive
// differences measures the mean gap in the distribution, which is a different
// number that happens to look plausible -- it read 0.132 ms where the real
// figure is an order of magnitude larger. Jitter is what a receiver has to
// absorb between one packet and the next, so it can only be computed in the
// order they arrived.
var jitter = 0.0
if samples.count > 1 {
    var deltas: [Double] = []
    for i in 1..<samples.count { deltas.append(abs(samples[i] - samples[i - 1])) }
    jitter = deltas.reduce(0, +) / Double(deltas.count)
}

samples.sort()
func at(_ q: Double) -> Double { samples.isEmpty ? 0 : samples[Int(q * Double(samples.count - 1))] }
let mean = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)

print("""

=== round trip, milliseconds ===
  replies      \(samples.count) of \(count)   lost \(lost)   unauthenticated \(forged)
  min          \(String(format: "%.3f", samples.first ?? 0))
  p50          \(String(format: "%.3f", at(0.50)))
  p95          \(String(format: "%.3f", at(0.95)))
  p99          \(String(format: "%.3f", at(0.99)))
  max          \(String(format: "%.3f", samples.last ?? 0))
  mean         \(String(format: "%.3f", mean))
  jitter       \(String(format: "%.3f", jitter))
""")
