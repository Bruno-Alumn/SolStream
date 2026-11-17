import Darwin
import XCTest
import MediaSession
@testable import SolStreamClient

/// A send on a socket already shut used to end the app by SIGPIPE, with no
/// crash report, as a stream stopped. Were either guard missing, this test
/// process would end here instead of failing politely.
final class SIGPIPETests: XCTestCase {
    func testASendAfterShutdownFailsInsteadOfEndingTheApp() {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        MediaClient.refuseSIGPIPE(fd)
        var on: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, &size)
        XCTAssertNotEqual(on, 0, "the media socket would raise SIGPIPE")
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        shutdown(fd, SHUT_RDWR)
        let sent = send(fd, "x", 1, 0)
        XCTAssertEqual(sent, -1)
        XCTAssertEqual(errno, EPIPE)
    }

    /// App-wide, for any socket or pipe SolStream doesn't make itself.
    func testTheAppIgnoresSIGPIPE() {
        SolStreamApp.ignoreSIGPIPE()
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        XCTAssertEqual(unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self),
                       unsafeBitCast(SIG_IGN, to: Int.self))
    }
}
