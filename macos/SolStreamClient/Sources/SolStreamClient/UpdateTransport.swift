import CryptoKit
import Foundation

/// The updater's HTTPS client: one URLSession, its own delegate, and the rules
/// docs/updates.md sets for every byte it fetches.
///
/// A delegate rather than `URLSession.data(for:)` because the rules live in
/// the delegate callbacks: a redirect is checked before it is followed, and a
/// download is cut off the moment it passes its cap -- not after it has been
/// written out in full. The file is hashed as it arrives, so the digest that
/// decides whether it is installed is of the bytes that reached the disk.
final class UpdateTransport: NSObject, URLSessionDataDelegate {
    struct Response {
        let status: Int
        /// The body, when it was kept in memory: always for small fetches, and
        /// for a download that was answered with anything but 200.
        let body: Data
        /// SHA-256 of what was written to the file, as lowercase hex.
        let digest: String?
        let bytes: Int64
    }

    enum Failure: Error, Equatable {
        /// An address, or a redirect, off the allow-list or not HTTPS.
        case refusedAddress(String)
        case tooLarge
        case offline
        case timedOut
        case network(String)
        case cannotWrite
        /// The Swift task awaiting it was cancelled: a stream opened.
        case cancelled
    }

    private var session: URLSession!
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]

    private final class Transfer {
        var limit: Int64
        var file: URL?
        var handle: FileHandle?
        var hasher = SHA256()
        var body = Data()
        var status = 0
        var received: Int64 = 0
        var expected: Int64?
        var failure: Failure?
        let progress: ((Int64, Int64?) -> Void)?
        let continuation: CheckedContinuation<Response, Error>

        init(limit: Int64, file: URL?, progress: ((Int64, Int64?) -> Void)?,
             continuation: CheckedContinuation<Response, Error>) {
            self.limit = limit
            self.file = file
            self.progress = progress
            self.continuation = continuation
        }
    }

    /// Ephemeral, so no cookie, cache entry or credential outlives the check,
    /// and nothing GitHub sets is sent back to it.
    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.waitsForConnectivity = false
        // Per request: how long a silence may last. Per resource: the whole
        // download, generous enough for a slow line and short enough that a
        // stalled one does not hold "Downloading…" up all day.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        return configuration
    }

    init(configuration: URLSessionConfiguration = UpdateTransport.defaultConfiguration()) {
        super.init()
        // Serial, so a transfer's state is only ever touched by one callback
        // at a time.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "SolStream.update"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// The session holds its delegate until it is invalidated.
    func invalidate() {
        session.invalidateAndCancel()
    }

    /// Fetch `request`, keeping the body in memory or, with `file`, streaming
    /// it there. Any status comes back as a response; only the transport's own
    /// failures throw. Cancelling the calling task stops the transfer, deletes
    /// what it wrote, and throws `.cancelled`.
    func fetch(_ request: URLRequest, limit: Int64, into file: URL? = nil,
               progress: ((Int64, Int64?) -> Void)? = nil) async throws -> Response {
        guard UpdateHosts.isAllowed(request.url) else {
            throw Failure.refusedAddress(request.url?.host ?? "an address that is not HTTPS")
        }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let transfer = Transfer(limit: limit, file: file, progress: progress,
                                        continuation: continuation)
                lock.lock()
                transfers[task.taskIdentifier] = transfer
                lock.unlock()
                task.resume()
                // A cancel that came before the transfer was registered found
                // nothing to stop, so it is looked for again now that there is.
                if Task.isCancelled { cancel(task) }
            }
        } onCancel: {
            cancel(task)
        }
    }

    /// On the delegate queue, so the failure is recorded in turn with the
    /// callbacks that read it; a transfer already finished is left alone.
    private func cancel(_ task: URLSessionTask) {
        session.delegateQueue.addOperation { [self] in
            guard let transfer = transfer(for: task) else { return }
            if transfer.failure == nil { transfer.failure = .cancelled }
            task.cancel()
        }
    }

    private func transfer(for task: URLSessionTask) -> Transfer? {
        lock.lock()
        defer { lock.unlock() }
        return transfers[task.taskIdentifier]
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfer(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        transfer.status = status
        if status == 200 {
            let length = response.expectedContentLength
            transfer.expected = length >= 0 ? length : nil
            // Refused before a byte of it arrives, when the server says so.
            if length > transfer.limit {
                transfer.failure = .tooLarge
                completionHandler(.cancel)
                return
            }
            if let file = transfer.file {
                try? FileManager.default.removeItem(at: file)
                guard FileManager.default.createFile(atPath: file.path, contents: nil),
                      let handle = try? FileHandle(forWritingTo: file) else {
                    transfer.failure = .cannotWrite
                    completionHandler(.cancel)
                    return
                }
                transfer.handle = handle
            }
        } else {
            // An error page is read only far enough to log a line of it, and
            // never written where the download was meant to go.
            transfer.file = nil
            transfer.limit = min(transfer.limit, UpdateSource.maximumSmallAssetBytes)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask), transfer.failure == nil else { return }
        transfer.received += Int64(data.count)
        guard transfer.received <= transfer.limit else {
            transfer.failure = .tooLarge
            dataTask.cancel()
            return
        }
        if let handle = transfer.handle {
            do {
                try handle.write(contentsOf: data)
            } catch {
                transfer.failure = .cannotWrite
                dataTask.cancel()
                return
            }
            transfer.hasher.update(data: data)
            transfer.progress?(transfer.received, transfer.expected)
        } else {
            transfer.body.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = UpdateHosts.redirect(request, from: task.currentRequest ?? task.originalRequest) else {
            // Declining delivers the redirect itself as the answer; the
            // failure recorded here is what the caller hears instead.
            transfer(for: task)?.failure = .refusedAddress(request.url?.host ?? "an address that is not HTTPS")
            completionHandler(nil)
            return
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let transfer = transfers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let transfer else { return }
        try? transfer.handle?.close()

        let failure: Failure?
        if let recorded = transfer.failure {
            failure = recorded
        } else if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed,
                 .internationalRoamingOff:
                failure = .offline
            case .timedOut:
                failure = .timedOut
            default:
                failure = .network(error.localizedDescription)
            }
        } else if let error {
            failure = .network(error.localizedDescription)
        } else {
            failure = nil
        }

        if let failure {
            if let file = transfer.file { try? FileManager.default.removeItem(at: file) }
            transfer.continuation.resume(throwing: failure)
            return
        }
        let wroteFile = transfer.handle != nil
        transfer.continuation.resume(returning: Response(
            status: transfer.status, body: transfer.body,
            digest: wroteFile ? ChecksumList.hex(transfer.hasher.finalize()) : nil,
            bytes: transfer.received))
    }
}
