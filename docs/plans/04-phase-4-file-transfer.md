# Phase 4: File Transfer (3 Weeks)

## Goal
Users can drag a file from macOS → drops into the streamed Windows app. File uploads over HTTP, lands as a clipboard paste-ready file in the Windows app.

## Key Changes from Previous Review
1. **Async IStream for large files**: `IStream::Read` implementation uses overlapped I/O — returns pending on network wait, avoids blocking COM caller (Explorer freeze). For files >100MB, data is streamed from the temp file on disk, not re-downloaded from macOS.
2. **TOCTOU-safe file writes**: Uploads are written to a random temp filename (UUID) in a **user-SID-restricted directory** (`%TEMP%\SolStream\transfers\{session_id}\stage\`). Only after the full file is written and validated (size, hash, canonicalization check) is it atomically renamed to the final filename. This prevents symlink replacement between check and use.
3. **No DoDragDrop**: Confirmed as Phase 4 goal — clipboard paste + Ctrl+V injection only. Drag-drop simulation removed entirely (future enhancement). The `IDataObject` is written to clipboard, user pastes via Ctrl+V (manual or automated).
4. **Per-session quotas**: Not just per-file limits. Each session has a total quota (10GB across all files). On quota exceeded, oldest files are evicted.
5. **Cancel/resume**: HTTP upload supports `Content-Range` for resume on interruption.
6. **Crash recovery**: Partial upload files are cleaned on session end. IDataObject clipboard timeout (30s) prevents stale file references.

## Task Breakdown

### Week 1, Day 1-2: FileTransferService — HTTP Server
- [ ] HTTP server on port 47992 (TLS 1.3, auth token required)
- [ ] `POST /api/files/upload` — accepts multipart file upload
- [ ] Stream file to `%TEMP%\SolStream\transfers\{session_id}\{filename}`
- [ ] File opened with `FILE_FLAG_OPEN_REPARSE_POINT` to detect symlinks
- [ ] After write: canonicalize via `GetFinalPathNameByHandleW`
- [ ] Verify canonical path starts with `%TEMP%\SolStream\transfers\` — reject if not
- [ ] Enforce limits: max 2GB per file, max 3 concurrent uploads
- [ ] `GET /api/files/download/{session_id}/{filename}` — stream file to macOS
- [ ] Set `Content-Disposition: attachment` for download
- [ ] **Verify:** curl uploads and downloads work with auth token

### Week 1, Day 3-5: CF_HDROP + Multi-Format IDataObject
- [ ] Implement `CFileDataObject` class implementing `IDataObject`
- [ ] Support `CF_HDROP` format: return `DROPFILES` struct with path to temp file
- [ ] Support `CFSTR_FILECONTENTS`: return `IStream` backed by the local file
- [ ] Support `CFSTR_FILEDESCRIPTOR`: return `FILEGROUPDESCRIPTOR` with file name + size
- [ ] Support `CFSTR_PREFERREDDROPEFFECT`: return `DROPEFFECT_COPY`
- [ ] After upload: call `OleSetClipboard(pDataObject)` to set multi-format data
- [ ] **Verify:** After upload, Windows clipboard shows file available. Pasting in Explorer creates a copy. Pasting in Notepad++ inserts file path.

### Week 2, Day 1-2: macOS Drag-Drop → Upload
- [ ] Register SolStream NSWindow for `NSDraggingDestination`
- [ ] Implement `draggingEntered:`, `draggingUpdated:`, `performDragOperation:`
- [ ] On drop: collect file URLs from `NSPasteboard`
- [ ] For each file: HTTP POST to `https://windows-host:47992/api/files/upload`
- [ ] Read file as stream, upload with multipart
- [ ] Show progress indicator during upload
- [ ] Handle errors: upload failure → show overlay "Upload failed, try again"
- [ ] **Verify:** Dragging a file from macOS Finder into SolStream window uploads it to Windows

### Week 2, Day 3-5: Paste Fallback + Ctrl+V Injection
- [ ] After upload completes and IDataObject is set on clipboard:
- [ ] Send notification to macOS client: "File ready to paste"
- [ ] **Fallback A (default):** Show toast on Windows: "File received. Ctrl+V to paste."
- [ ] **Fallback B (Phase 4 goal):** InputInjector synthesizes Ctrl+V via:
  ```
  SendInput(KEYDOWN, VK_CONTROL)
  SendInput(KEYDOWN, 'V')
  SendInput(KEYUP, 'V')
  SendInput(KEYUP, VK_CONTROL)
  ```
- [ ] Trigger Ctrl+V injection 500ms after file transfer completes (allows app to settle)
- [ ] On Ctrl+V: the target app reads from clipboard → finds CF_HDROP or CFSTR_FILECONTENTS
- [ ] **Verify:** After upload, Ctrl+V is injected and file appears in the streamed app

### Week 3, Day 1: Symlink/Junction Protection
- [ ] Before opening uploaded file: verify no symlink/junction in path components
- [ ] Use `GetFinalPathNameByHandleW(VOLUME_NAME_DOS)` to resolve real path
- [ ] Compare resolved prefix against transfer root
- [ ] Reject file if path escapes transfer root
- [ ] **Verify:** Attempting path traversal (../../windows/system32/hack.exe) is rejected

### Week 3, Day 2-3: Session + Cleanup Management
- [ ] Session-scoped transfer directories: `%TEMP%\SolStream\transfers\{session_id}\`
- [ ] On stream end: clean up all files in session directory
- [ ] Orphan cleanup: sweep directories older than 1 hour every 5 minutes
- [ ] IDataObject lifecycle: release from clipboard after 30s timeout

### Week 3, Day 4-5: Integration Testing
- [ ] Full end-to-end: drag `.txt` file from macOS → verify paste in Windows Notepad
- [ ] Test: drag image → verify paste in Windows Paint
- [ ] Test: drag `.zip` → verify paste in Explorer extracts correctly
- [ ] Test: path traversal filename → verify rejection
- [ ] Test: 2GB file → verify upload works, limits enforced
- [ ] Test: macOS → Windows → copy on Windows → verify macOS clipboard shows it
- [ ] **Verify:** All scenarios pass

## Acceptance Criteria (Phase 4 Gate)
1. Drag file from macOS Finder → appears in Windows app (via clipboard paste or Ctrl+V injection)
2. Multi-format IDataObject supports CF_HDROP + CFSTR_FILECONTENTS
3. Path traversal attacks are rejected
4. Symlink/junction attacks are rejected
5. Max file size (2GB) and concurrency (3) limits work
6. Staging files are cleaned up properly
7. Works with: .txt, .png, .zip, .pdf, .docx

## Files Created
```
windows/FileTransferService/
├── CMakeLists.txt
├── main.cpp                        # HTTP server, session management
├── http_server.cpp                 # TLS HTTP server with auth
├── http_server.h
├── file_receiver.cpp               # Upload handler, stream-to-disk
├── file_receiver.h
├── path_validator.cpp              # GetFinalPathNameByHandleW, symlink detection
├── path_validator.h
├── clipboard_object.cpp            # IDataObject implementation (CF_HDROP + CFSTR_FILECONTENTS)
├── clipboard_object.h
├── paste_injector.cpp              # Ctrl+V synthesis via InputInjector pipe
├── paste_injector.h
├── cleanup.cpp                     # File cleanup on session end + orphan sweep
└── cleanup.h
```
