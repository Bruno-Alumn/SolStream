#pragma once

/// @file http_server.h
/// HTTP server on port 47992 for file upload/download with auth token.
/// Supports multipart POST uploads and GET downloads.
///
/// Thread safety: the accept loop runs on its own thread. Each client
/// connection is handled synchronously.

#include <Windows.h>
#include <winsock2.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "cleanup.h"

namespace solstream::filetransfer {

// ══════════════════════════════════════════════════════════════════════════════
// Callbacks
// ══════════════════════════════════════════════════════════════════════════════

/// Called when a file upload completes successfully.
/// Parameters: sessionId, fileName, localFilePath, fileSize
using UploadCompleteCallback = std::function<void(
    const std::wstring&, const std::wstring&,
    const std::wstring&, uint64_t)>;

// ══════════════════════════════════════════════════════════════════════════════
// FileTransferServer
// ══════════════════════════════════════════════════════════════════════════════
//
class FileTransferServer {
public:
    FileTransferServer(CleanupEngine& cleanup);
    ~FileTransferServer();

    FileTransferServer(const FileTransferServer&) = delete;
    FileTransferServer& operator=(const FileTransferServer&) = delete;

    /// Start the HTTP server on the given port.
    [[nodiscard]] bool Start(uint16_t port = 47992);

    /// Stop the server and join the accept thread.
    void Stop();

    /// Set the auth token. Requests without this token are rejected (401).
    void SetAuthToken(const std::string& token) { m_authToken = token; }

    /// Set the callback for completed uploads.
    void SetUploadCallback(UploadCompleteCallback cb) { m_uploadCb = std::move(cb); }

    /// Number of active connections.
    [[nodiscard]] int ConnectionCount() const noexcept;

private:
    CleanupEngine& m_cleanup;

    SOCKET m_listenSock{INVALID_SOCKET};
    std::atomic<bool> m_running{false};
    std::thread m_acceptThread;
    std::string m_authToken;

    UploadCompleteCallback m_uploadCb;

    mutable std::mutex m_connMutex;
    std::vector<SOCKET> m_clientSocks;
    std::atomic<int> m_connCount{0};

    // Accept loop.
    void AcceptLoop();

    // Handle a single client connection.
    void HandleClient(SOCKET clientSock);

    // Parse an HTTP request.
    struct HttpRequest {
        std::string method;
        std::string path;
        std::string body;
        std::string authHeader;
        std::string boundary;  // For multipart
    };
    HttpRequest ParseRequest(const std::vector<char>& raw);

    // Send HTTP response.
    void SendResponse(SOCKET sock, int statusCode,
                      const std::string& statusText,
                      const std::string& contentType,
                      const std::string& body,
                      bool isAttachment = false,
                      const std::string& filename = "");

    // Handle GET /download/{session}/{filename}
    void HandleDownload(SOCKET sock, const HttpRequest& req);

    // Handle POST /upload
    void HandleUpload(SOCKET sock, const HttpRequest& req);

    // Extract boundary from Content-Type header.
    std::string ExtractBoundary(const std::string& contentType);

    // Parse multipart body to extract filename and data.
    struct MultipartPart {
        std::string filename;
        std::string data;
        std::string sessionId;
    };
    MultipartPart ParseMultipart(const std::string& body,
                                  const std::string& boundary);

    // Validate auth token.
    bool ValidateAuth(const HttpRequest& req);

    // Remove client from tracking.
    void RemoveClient(SOCKET sock);
};

} // namespace solstream::filetransfer
