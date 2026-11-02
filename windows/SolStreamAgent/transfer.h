// transfer.h — what crosses the agent channel in pieces: a picture on the
// clipboard, either way, and a file dropped on a streamed window.
//
// The channel is one JSON line per request, read whole at both ends and capped
// at kMaxLineBytes. A screenshot is megabytes and a file can be gigabytes, so
// both go as a run of requests, each carrying one chunk in base64, and each
// answered before the next goes: other commands -- placing a window, focus --
// wait behind one chunk at most, never behind the whole transfer.
//
// Pictures cross as PNG, which every application on both machines reads and
// which keeps transparency. Windows keeps a picture on its clipboard as a DIB,
// and often as PNG beside it; both directions convert with the Windows Imaging
// Component, which is part of Windows.
//
// A dropped file is written to Downloads\SolStream and put on the clipboard as
// a file, which Explorer, mail, chat and most other applications paste. The
// Mac never names a path to write: only a file name, which is cleaned here, and
// only files that folder holds can be put on the clipboard from the Mac.

#pragma once

#include <windows.h>

#include <cstddef>
#include <functional>
#include <string>
#include <vector>

namespace solstream {

/// One chunk's worth of a picture or a file, before base64: a third again on
/// the wire, well inside kMaxLineBytes.
constexpr size_t kTransferChunkBytes = 512 * 1024;
/// A picture on the clipboard larger than this as PNG is not offered.
constexpr size_t kMaxClipboardImageBytes = 32 * 1024 * 1024;
/// A picture larger than this on a side is not decoded at all.
constexpr unsigned int kMaxClipboardImageSide = 16384;
/// Nor one with more pixels than this, 8K's 33 million: a small PNG of a
/// huge flat picture would otherwise cost gigabytes as a DIB.
constexpr unsigned long long kMaxClipboardImagePixels = 7680ull * 4320ull;

/// Base64 without line breaks, and back. False for anything that is not.
std::string Base64Encode(const unsigned char* bytes, size_t size);
bool Base64Decode(const std::string& text, std::vector<unsigned char>& out);

/// Whether the clipboard holds a picture this host can send. The caller must
/// have it open.
bool ClipboardHoldsImage();

/// The reply to `{"cmd":"clipboardImage","seq":S,"offset":O}`: chunk O of the
/// clipboard's picture as PNG, encoded once per clipboard sequence and kept
/// while the Mac fetches it. Refused once the clipboard has moved on from S.
std::string ClipboardImageGetJson(long long seq, long long offset);

/// The reply to `{"cmd":"clipboardImage","offset":O,"total":T,"data":…}`: the
/// next chunk of a PNG from the Mac. The last puts the picture on the
/// clipboard, as PNG and as a DIB, and answers with the new sequence.
std::string ClipboardImageSetJson(long long offset, long long total, const std::string& base64);

/// The reply to `{"cmd":"upload","name":N,"offset":O,"total":T,"data":…}`: the
/// next chunk of a file dropped on a window, written under UploadFolder(). The
/// last answers with the path it was written to.
std::string UploadJson(const std::string& name, long long offset, long long total,
                       const std::string& base64);

/// Drop an upload that has not finished, deleting the part written: the Mac
/// gave up on it (`{"cmd":"upload","abort":1}`) or went away.
void AbandonUpload();

/// The reply to `{"cmd":"clipboardFiles","paths":"a\nb"}`: those files on the
/// clipboard, to paste, if every one is in UploadFolder().
std::string ClipboardFilesJson(const std::string& paths);

/// Downloads\SolStream in the user's profile, made if it is not there.
std::wstring UploadFolder();

/// A name to write a file under: no path, nothing Windows refuses in a name,
/// not a device name, and not endless.
std::wstring SafeFileName(const std::wstring& name);

/// `name` in `folder`, or "name (2).ext" and on, whichever `exists` says is
/// free.
std::wstring UniqueFilePath(const std::wstring& folder, const std::wstring& name,
                            const std::function<bool(const std::wstring&)>& exists);

/// Whether `path` names a file directly inside `folder`, compared as Windows
/// does: without case, and not fooled by "..".
bool IsDirectlyInside(const std::wstring& path, const std::wstring& folder);

/// CF_HDROP's data for `paths`: a DROPFILES header and the wide paths, each
/// ended by a zero and the list by another.
std::vector<unsigned char> DropFilesData(const std::vector<std::wstring>& paths);

}  // namespace solstream
