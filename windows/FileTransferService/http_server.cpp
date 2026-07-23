#include "http_server.h"
#include "path_validator.h"
#include "clipboard_object.h"

#include <ole2.h>
#include <algorithm>
#include <charconv>
#include <cstring>
#include <format>
#include <sstream>
#include <thread>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "ole32.lib")

namespace solstream::filetransfer {

// ══════════════════════════════════════════════════════════════════════════════
// Construction / Destruction
// ══════════════════════════════════════════════════════════════════════════════

FileTransferServer::FileTransferServer(CleanupEngine& cleanup)
    : m_cleanup(cleanup) {}

FileTransferServer::~FileTransferServer() { Stop(); }

// ══════════════════════════════════════════════════════════════════════════════
// Start / Stop
// ══════════════════════════════════════════════════════════════════════════════

bool FileTransferServer::Start(uint16_t port) {
    if (m_running.exchange(true, std::memory_order_acq_rel))
        return false;

    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0)
        return false;

    // Initialize OLE for clipboard operations (must be done once per thread).
    HRESULT oleHr = OleInitialize(nullptr);
    if (FAILED(oleHr) && oleHr != S_OK) {
        WSACleanup();
        return false;
    }

    m_listenSock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (m_listenSock == INVALID_SOCKET) { WSACleanup(); return false; }

    int reuse = 1;
    setsockopt(m_listenSock, SOL_SOCKET, SO_REUSEADDR,
               (const char*)&reuse, sizeof(reuse));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_LOOPBACK;  // Dev only
    addr.sin_port = htons(port);

    if (bind(m_listenSock, (sockaddr*)&addr, sizeof(addr)) != 0 ||
        listen(m_listenSock, SOMAXCONN) != 0) {
        closesocket(m_listenSock);
        WSACleanup();
        return false;
    }

    try {
        m_acceptThread = std::thread([this]{ AcceptLoop(); });
    } catch (...) {
        closesocket(m_listenSock);
        WSACleanup();
        m_running.store(false, std::memory_order_release);
        return false;
    }

    return true;
}

void FileTransferServer::Stop() {
    m_running.store(false, std::memory_order_release);
    if (m_listenSock != INVALID_SOCKET) {
        closesocket(m_listenSock);
        m_listenSock = INVALID_SOCKET;
    }
    {
        std::lock_guard lk(m_connMutex);
        for (auto s : m_clientSocks) closesocket(s);
        m_clientSocks.clear();
    }
    if (m_acceptThread.joinable())
        m_acceptThread.join();

    // Uninitialize OLE (paired with OleInitialize in Start).
    OleUninitialize();
    WSACleanup();
}

int FileTransferServer::ConnectionCount() const noexcept {
    return m_connCount.load(std::memory_order_acquire);
}

// ══════════════════════════════════════════════════════════════════════════════
// Accept loop
// ══════════════════════════════════════════════════════════════════════════════

void FileTransferServer::AcceptLoop() {
    while (m_running.load(std::memory_order_acquire)) {
        sockaddr_in client{};
        int addrLen = sizeof(client);
        SOCKET s = accept(m_listenSock, (sockaddr*)&client, &addrLen);
        if (s == INVALID_SOCKET) continue;

        {
            std::lock_guard lk(m_connMutex);
            m_clientSocks.push_back(s);
        }
        m_connCount.fetch_add(1, std::memory_order_release);

        std::thread([this, s]{
            HandleClient(s);
            RemoveClient(s);
        }).detach();
    }
}

void FileTransferServer::RemoveClient(SOCKET sock) {
    std::lock_guard lk(m_connMutex);
    auto it = std::find(m_clientSocks.begin(), m_clientSocks.end(), sock);
    if (it != m_clientSocks.end()) m_clientSocks.erase(it);
    m_connCount.fetch_sub(1, std::memory_order_release);
}

// ══════════════════════════════════════════════════════════════════════════════
// Client handler
// ══════════════════════════════════════════════════════════════════════════════

void FileTransferServer::HandleClient(SOCKET sock) {
    // Read the full request (headers + body).
    std::vector<char> buf(65536);
    std::string raw;

    int n;
    do {
        n = recv(sock, buf.data(), (int)buf.size(), 0);
        if (n > 0) raw.append(buf.data(), (size_t)n);
    } while (n > 0 && raw.find("\r\n\r\n") == std::string::npos);

    if (raw.empty()) return;

    auto req = ParseRequest(std::vector<char>(raw.begin(), raw.end()));

    if (!ValidateAuth(req)) {
        SendResponse(sock, 401, "Unauthorized", "text/plain", "Unauthorized");
        return;
    }

    if (req.method == "GET") {
        HandleDownload(sock, req);
    } else if (req.method == "POST") {
        HandleUpload(sock, req);
    } else {
        SendResponse(sock, 405, "Method Not Allowed", "text/plain", "");
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Request parsing
// ══════════════════════════════════════════════════════════════════════════════

FileTransferServer::HttpRequest
FileTransferServer::ParseRequest(const std::vector<char>& raw) {
    HttpRequest req;
    std::string data(raw.begin(), raw.end());

    // Parse first line: METHOD PATH HTTP/1.1
    auto firstLf = data.find("\r\n");
    if (firstLf == std::string::npos) return req;
    auto firstLine = data.substr(0, firstLf);

    auto sp1 = firstLine.find(' ');
    auto sp2 = firstLine.rfind(' ');
    if (sp1 == std::string::npos || sp2 == std::string::npos) return req;

    req.method = firstLine.substr(0, sp1);
    req.path = firstLine.substr(sp1 + 1, sp2 - sp1 - 1);

    // Parse headers.
    auto headerEnd = data.find("\r\n\r\n");
    if (headerEnd == std::string::npos) return req;

    auto headers = data.substr(firstLf + 2, headerEnd - firstLf - 2);
    std::istringstream hdrStream(headers);
    std::string line;
    while (std::getline(hdrStream, line)) {
        if (line.back() == '\r') line.pop_back();
        auto colon = line.find(':');
        if (colon == std::string::npos) continue;
        auto key = line.substr(0, colon);
        auto val = line.substr(colon + 2);  // Skip ": "
        if (key == "Authorization" || key == "authorization")
            req.authHeader = val;
        if (key == "Content-Type" || key == "content-type")
            req.boundary = ExtractBoundary(val);
    }

    // Body starts after \r\n\r\n
    req.body = data.substr(headerEnd + 4);

    // For GET, the path may contain query parameters — strip them.
    auto qm = req.path.find('?');
    if (qm != std::string::npos)
        req.path = req.path.substr(0, qm);

    return req;
}

std::string FileTransferServer::ExtractBoundary(const std::string& contentType) {
    auto b = contentType.find("boundary=");
    if (b == std::string::npos) return "";
    return contentType.substr(b + 9);
}

// ══════════════════════════════════════════════════════════════════════════════
// Multipart parsing
// ══════════════════════════════════════════════════════════════════════════════

FileTransferServer::MultipartPart
FileTransferServer::ParseMultipart(const std::string& body,
                                    const std::string& boundary)
{
    MultipartPart part;
    if (boundary.empty() || body.empty()) return part;

    std::string delim = "--" + boundary;
    auto partStart = body.find(delim);
    if (partStart == std::string::npos) return part;
    partStart = body.find("\r\n\r\n", partStart);
    if (partStart == std::string::npos) return part;
    partStart += 4;  // Skip \r\n\r\n

    auto partEnd = body.find("\r\n--" + boundary, partStart);
    if (partEnd == std::string::npos) {
        partEnd = body.find(delim, partStart);
        if (partEnd == std::string::npos) partEnd = body.size();
    }

    part.data = body.substr(partStart, partEnd - partStart);

    // Extract filename from Content-Disposition header.
    auto cdPos = body.find("Content-Disposition:");
    if (cdPos != std::string::npos) {
        auto fnPos = body.find("filename=\"", cdPos);
        if (fnPos != std::string::npos) {
            fnPos += 10;  // Skip filename="
            auto fnEnd = body.find('"', fnPos);
            if (fnEnd != std::string::npos)
                part.filename = body.substr(fnPos, fnEnd - fnPos);
        }
        // Extract session from form field or URL query.
        auto sPos = body.find("name=\"session\"", cdPos);
        if (sPos != std::string::npos) {
            // The session value is in a separate part — simplified: use dummy.
            part.sessionId = "default";
        }
    }

    return part;
}

// ══════════════════════════════════════════════════════════════════════════════
// Upload handler
// ══════════════════════════════════════════════════════════════════════════════

void FileTransferServer::HandleUpload(SOCKET sock, const HttpRequest& req) {
    // Parse multipart.
    auto part = ParseMultipart(req.body, req.boundary);
    if (part.data.empty() || part.filename.empty()) {
        SendResponse(sock, 400, "Bad Request", "text/plain",
                     "Missing file or filename");
        return;
    }

    // Convert to wide strings.
    auto toWide = [](const std::string& s) -> std::wstring {
        if (s.empty()) return {};
        int len = MultiByteToWideChar(CP_UTF8, 0, s.data(),
                                       (int)s.size(), nullptr, 0);
        std::wstring ws((size_t)len, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(),
                            ws.data(), len);
        return ws;
    };

    std::wstring wsFilename = toWide(part.filename);
    std::wstring wsSession = toWide(part.sessionId);
    if (wsSession.empty()) wsSession = L"default";

    // Validate session.
    if (!IsValidSessionId(wsSession)) {
        SendResponse(sock, 400, "Bad Request", "text/plain",
                     "Invalid session ID");
        return;
    }

    // Validate filename.
    if (!IsValidFileName(wsFilename)) {
        SendResponse(sock, 400, "Bad Request", "text/plain",
                     "Invalid filename");
        return;
    }

    // Reserve upload in cleanup.
    if (!m_cleanup.ReserveUpload(wsSession, part.data.size())) {
        SendResponse(sock, 429, "Too Many Requests", "text/plain",
                     "Quota exceeded or too many concurrent uploads");
        return;
    }

    // Ensure session exists.
    m_cleanup.CreateSession(wsSession);

    // Create staging path.
    auto ext = wsFilename.substr(wsFilename.find_last_of(L'.'));
    auto stagingPath = CreateStagingPath(wsSession, ext);
    if (stagingPath.empty()) {
        m_cleanup.RollbackUpload(wsSession);
        SendResponse(sock, 500, "Internal Server Error", "text/plain",
                     "Failed to create staging path");
        return;
    }

    // Write file data to the staging path.
    {
        HANDLE hFile = CreateFileW(
            stagingPath.c_str(), GENERIC_WRITE, 0, nullptr,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (hFile == INVALID_HANDLE_VALUE) {
            m_cleanup.RollbackUpload(wsSession);
            SendResponse(sock, 500, "Internal Server Error", "text/plain",
                         "Failed to open staging file");
            return;
        }

        DWORD written = 0;
        WriteFile(hFile, part.data.data(),
                  (DWORD)part.data.size(), &written, nullptr);
        CloseHandle(hFile);
    }

    // Atomic finalize.
    auto finalPath = AtomicFinalize(stagingPath, wsFilename, wsSession);
    if (finalPath.empty()) {
        m_cleanup.RollbackUpload(wsSession);
        SendResponse(sock, 500, "Internal Server Error", "text/plain",
                     "Failed to finalize file");
        return;
    }

    // Commit to cleanup engine.
    m_cleanup.CommitFile(wsSession, part.data.size());

    // Set IDataObject on clipboard for paste.
    // OLE already initialized in Start() - just set clipboard.
    auto* dataObj = new FileDataObject(finalPath);
    OleSetClipboard(dataObj);
    dataObj->Release();

    // Notify callback.
    if (m_uploadCb)
        m_uploadCb(wsSession, wsFilename, finalPath, part.data.size());

    SendResponse(sock, 200, "OK", "application/json",
                 std::format(R"({{"status":"ok","filename":"{}","size":{}}})",
                             part.filename, part.data.size()));
}

// ══════════════════════════════════════════════════════════════════════════════
// Download handler
// ══════════════════════════════════════════════════════════════════════════════

void FileTransferServer::HandleDownload(SOCKET sock, const HttpRequest& req) {
    // Path format: /download/{session}/{filename}
    auto parts = req.path;
    // Strip leading /
    if (!parts.empty() && parts[0] == '/')
        parts = parts.substr(1);

    auto firstSlash = parts.find('/');
    if (firstSlash == std::string::npos) {
        SendResponse(sock, 400, "Bad Request", "text/plain",
                     "Path: /download/{session}/{filename}");
        return;
    }

    // Skip "download/"
    auto secondSlash = parts.find('/', firstSlash + 1);
    if (secondSlash == std::string::npos) {
        // Actually check: parts starts with "download/"
        if (parts.substr(0, 9) != "download/") {
            SendResponse(sock, 404, "Not Found", "text/plain", "Not found");
            return;
        }
        auto remaining = parts.substr(9);
        auto slash = remaining.find('/');
        if (slash == std::string::npos) {
            SendResponse(sock, 400, "Bad Request", "text/plain", "Invalid path");
            return;
        }
        auto session = remaining.substr(0, slash);
        auto filename = remaining.substr(slash + 1);

        std::wstring wsSession = std::wstring(session.begin(), session.end());
        std::wstring wsFilename = std::wstring(filename.begin(), filename.end());

        if (!IsValidSessionId(wsSession) || !IsValidFileName(wsFilename)) {
            SendResponse(sock, 400, "Bad Request", "text/plain", "Invalid path");
            return;
        }

        std::wstring filePath = TransferRoot() + wsSession + L"\\" + wsFilename;

        // Open and stream the file.
        HANDLE hFile = CreateFileW(
            filePath.c_str(), GENERIC_READ,
            FILE_SHARE_READ, nullptr,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);

        if (hFile == INVALID_HANDLE_VALUE) {
            SendResponse(sock, 404, "Not Found", "text/plain", "File not found");
            return;
        }

        LARGE_INTEGER fileSize{};
        GetFileSizeEx(hFile, &fileSize);

        // Read file content.
        std::vector<char> fileData((size_t)fileSize.QuadPart);
        DWORD read = 0;
        ReadFile(hFile, fileData.data(), (DWORD)fileData.size(), &read, nullptr);
        CloseHandle(hFile);

        SendResponse(sock, 200, "OK", "application/octet-stream",
                     std::string(fileData.data(), read), true, filename);
        return;
    }

    SendResponse(sock, 404, "Not Found", "text/plain", "Not found");
}

// ══════════════════════════════════════════════════════════════════════════════
// Auth / Response helpers
// ══════════════════════════════════════════════════════════════════════════════

bool FileTransferServer::ValidateAuth(const HttpRequest& req) {
    if (m_authToken.empty())
        return true;  // Dev mode: no auth required
    // Expect: "Bearer <token>"
    if (req.authHeader.size() <= 7)
        return false;
    if (req.authHeader.substr(0, 7) != "Bearer ")
        return false;
    return req.authHeader.substr(7) == m_authToken;
}

void FileTransferServer::SendResponse(
    SOCKET sock, int statusCode, const std::string& statusText,
    const std::string& contentType, const std::string& body,
    bool isAttachment, const std::string& filename)
{
    std::string response = std::format(
        "HTTP/1.1 {} {}\r\n"
        "Content-Type: {}\r\n"
        "Content-Length: {}\r\n"
        "Connection: close\r\n"
        "Access-Control-Allow-Origin: *\r\n",
        statusCode, statusText, contentType, body.size());

    if (isAttachment && !filename.empty()) {
        response += std::format(
            "Content-Disposition: attachment; filename=\"{}\"\r\n", filename);
    }

    response += "\r\n";
    response += body;

    send(sock, response.data(), (int)response.size(), 0);
    closesocket(sock);
}

} // namespace solstream::filetransfer
