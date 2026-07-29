// Drive one media handshake against a live host and report whether both ends
// derived the same keys.
//
// A RUNLOOP, not a semaphore. AgentConnection reports every state change with
// DispatchQueue.main.async, so a command-line tool that blocks the main thread
// waiting for one of those waits forever: the queue it is waiting on is the
// queue it is blocking. The real client never sees this because AppKit is
// already running the loop.
import Foundation
import StreamConnection
import SolStreamLogging

setbuf(stdout, nil)

let host = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "100.101.102.103"
let token = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let agent = AgentConnection(host: host, token: token)
var finished = false

agent.onState = { state in
    print("[state] \(state)")
    guard case .connected = state else { return }
    Task {
        let started = DispatchTime.now().uptimeNanoseconds
        if let keys = await agent.openMediaSession() {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            print("HANDSHAKE OK in \(String(format: "%.1f", ms)) ms")
            print("  sessionTag  \(String(format: "%02x", keys.sessionTag))")
            print("  h2c key     \(keys.hostToClient.withUnsafeBytes { Data($0).smtHex })")
            print("  c2h key     \(keys.clientToHost.withUnsafeBytes { Data($0).smtHex })")
            print("  fixed h2c   \(keys.fixedHostToClient.smtHex)")
            print("  fixed c2h   \(keys.fixedClientToHost.smtHex)")
            print("  hostAuth    \(keys.hostAuth.smtHex)  <- matched the host's")
        } else {
            print("HANDSHAKE FAILED")
        }
        finished = true
    }
}
agent.connect()

let deadline = Date().addingTimeInterval(25)
while !finished && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
exit(finished ? 0 : 1)
