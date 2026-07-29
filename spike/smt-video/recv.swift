// recv.swift — the Mac half of step 5: open, reassemble by byte offset, verify.
//
// Verification regenerates each frame's expected bytes from its frame number and
// compares. That is deliberately not a hash the sender computed: a hash both
// ends compute the same wrong way agrees with itself, and the thing being tested
// is precisely whether the bytes arrive where they were put.
//
//   swift spike/smt-video/recv.swift <host> [frames] [port]

import Foundation
import CryptoKit
import Darwin

func hexBytes(_ s: String) -> Data {
    var out = Data(); var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!); i = j
    }
    return out
}

let keyC2H = SymmetricKey(data: hexBytes("4aa5aaf36c0cb3dacd26251c0c0e84b96c6910d1d87bcd803f0df616e7dd3b87"))
let keyH2C = SymmetricKey(data: hexBytes("8c83fc537b9b19d56753962eacc673097a76510c95b60f41fdb5056a5062aaea"))
let fixedC2H = hexBytes("593154045ebd")
let fixedH2C = hexBytes("4a20dd1ecfc0")
let sessTag: UInt8 = 0x62

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: recv.swift <host> [frames] [port]"); exit(2) }
let hostName = args[1]
let expectFrames = args.count > 2 ? Int(args[2])! : 300
let port = args.count > 3 ? UInt16(args[3])! : 47631

let fd = socket(AF_INET, SOCK_DGRAM, 0)
var rcvbuf: Int32 = 4 << 20
setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
var timeout = timeval(tv_sec: 3, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

var target = sockaddr_in()
target.sin_family = sa_family_t(AF_INET)
target.sin_port = port.bigEndian
guard inet_pton(AF_INET, hostName, &target.sin_addr) == 1 else { print("bad address"); exit(1) }

func be48(_ v: UInt64) -> Data {
    var d = Data(count: 6); for i in 0..<6 { d[i] = UInt8((v >> (40 - 8 * i)) & 0xFF) }; return d
}
var sendCounter: UInt64 = 0
func seal(_ plaintext: Data) -> Data {
    var header = Data(); header.append((1 << 4) | 0); header.append(sessTag)
    header += be48(sendCounter)
    let nonce = try! AES.GCM.Nonce(data: fixedC2H + be48(sendCounter))
    sendCounter += 1
    let box = try! AES.GCM.seal(plaintext, using: keyC2H, nonce: nonce, authenticating: header)
    return header + box.ciphertext + box.tag
}
func open(_ d: Data) -> Data? {
    guard d.count >= 24, d[d.startIndex] >> 4 == 1 else { return nil }
    let header = d.prefix(8)
    let counterBytes = d.subdata(in: d.startIndex + 2..<d.startIndex + 8)
    guard let nonce = try? AES.GCM.Nonce(data: fixedH2C + counterBytes),
          let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: d.dropFirst(8).dropLast(16),
                                           tag: d.suffix(16)),
          let plain = try? AES.GCM.open(box, using: keyH2C, authenticating: header)
    else { return nil }
    return plain
}

/// Speak first: the sender needs an address to send to, and one it has seen a
/// packet from rather than one it was told about.
let hello = seal(Data([0x01, 0, 0, 0, 0, 0, 0, 0, 0]))
_ = hello.withUnsafeBytes { raw in
    withUnsafePointer(to: &target) { addr in
        addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}
print("smt-video receiver -> \(hostName):\(port), expecting \(expectFrames) frames")

// ── Reassembly ───────────────────────────────────────────────────────────────
//
// A frame is a buffer plus how many bytes have landed in it. fragOff is a BYTE
// OFFSET rather than a fragment index, so a fragment is a memcpy at base+off and
// variable-length fragments -- which is what slice-early sending produces -- need
// no index arithmetic at all.
struct Assembly {
    var bytes: Data = Data()
    var have = 0
    var total = -1
    var firstSeen = DispatchTime.now().uptimeNanoseconds
}
var building: [UInt32: Assembly] = [:]
var complete = 0, corrupt = 0, datagrams = 0, unauthenticated = 0
var latencies: [Double] = []
var started: UInt64 = 0

func expectedFrame(_ id: UInt32, _ size: Int) -> Data {
    var d = Data(count: size)
    d.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: UInt8.self)
        for i in 0..<size { p[i] = UInt8((id &* 31 &+ UInt32(i) &* 17) & 0xFF) }
    }
    return d
}

var buffer = [UInt8](repeating: 0, count: 2048)
while complete < expectFrames {
    let n = recv(fd, &buffer, buffer.count, 0)
    if n <= 0 { break }                      // 3s of silence ends the run
    datagrams += 1
    guard let p = open(Data(buffer[0..<n])), p.count > 16, p[p.startIndex] == 0x10 else {
        unauthenticated += 1; continue
    }
    if started == 0 { started = DispatchTime.now().uptimeNanoseconds }

    let b = [UInt8](p)
    let flags = b[1]
    let frameId = (UInt32(b[4]) << 24) | (UInt32(b[5]) << 16) | (UInt32(b[6]) << 8) | UInt32(b[7])
    let fragOff = (Int(b[8]) << 16) | (Int(b[9]) << 8) | Int(b[10])
    let payload = Array(b[16...])

    // Preallocated once, then memcpy. Growing a Data per fragment and calling
    // replaceSubrange is O(n) each time, so a 168-fragment IDR is quadratic --
    // and the datagrams that pile up in the socket buffer while that runs look
    // exactly like network loss. Rule the instrument out before blaming the path.
    var a = building[frameId] ?? Assembly(bytes: Data(count: 320_000))
    a.bytes.withUnsafeMutableBytes { raw in
        let base = raw.bindMemory(to: UInt8.self).baseAddress!
        payload.withUnsafeBufferPointer { src in
            base.advanced(by: fragOff).update(from: src.baseAddress!, count: src.count)
        }
    }
    a.have += payload.count
    if flags & 0x04 != 0 { a.total = fragOff + payload.count }   // FRAME_END
    building[frameId] = a

    if a.total >= 0 && a.have >= a.total {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - a.firstSeen) / 1e6
        latencies.append(elapsed)
        if a.bytes.prefix(a.total) == expectedFrame(frameId, a.total) {
            complete += 1
        } else {
            corrupt += 1
        }
        building.removeValue(forKey: frameId)
    }
}

let seconds = started == 0 ? 0
    : Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
latencies.sort()
func at(_ q: Double) -> Double { latencies.isEmpty ? 0 : latencies[Int(q * Double(latencies.count - 1))] }

print("""

=== reassembly ===
  frames complete      \(complete) of \(expectFrames)
  frames CORRUPT       \(corrupt)
  frames left partial  \(building.count)  \(building.keys.sorted().map(String.init).joined(separator: " "))
  of which are IDRs    \(building.keys.filter { $0 % 60 == 1 }.count)  (IDRs are every 60th frame from 1)
  datagrams            \(datagrams)   unauthenticated \(unauthenticated)
  throughput           \(String(format: "%.1f", seconds > 0 ? Double(datagrams) / seconds : 0)) pkt/s
  first fragment -> complete, milliseconds
    p50 \(String(format: "%.2f", at(0.50)))   p95 \(String(format: "%.2f", at(0.95)))   max \(String(format: "%.2f", latencies.last ?? 0))
""")
exit(corrupt == 0 && complete == expectFrames ? 0 : 1)
