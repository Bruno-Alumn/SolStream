// send_to_mac.h — files sent from the PC to the Mac.
//
// "Send to Mac" in Explorer's right-click menu starts `SolStream.exe
// --send-to-mac <file>`, which hands the path to the running host. The host
// offers the file to the signed-in Mac -- only to one that says it
// understands offers -- and the Mac fetches it, a chunk at a time, into its
// Downloads\SolStream. Only a file offered that way can be fetched, by the
// number its offer was given: the Mac never names a path on the PC.

#pragma once

#include <cstdint>
#include <string>

namespace solstream {

/// Why `path` can't be sent, in words for the person who asked, or empty
/// when it can: it has to be a file, not a folder, of at most
/// kMaxUploadBytes, that this account can open while whatever else has it
/// open does. Asked by the click before the host is, and by the host
/// again when it makes the offer.
std::string FileOfferRefusal(const std::wstring& path, unsigned long long* size = nullptr);

/// Offer `path` (a file, not a folder, at most kMaxUploadBytes) to the Mac.
/// Its offer number, or 0 with `error` saying why not -- to the person who
/// asked -- and `full` set when the reason is that 16 are already open.
/// Offers expire after half an hour.
uint64_t AddFileOffer(const std::wstring& path, std::string& error, bool* full = nullptr);

/// The push that tells the Mac about offer `id`: its name and size.
std::string FileOfferJson(uint64_t id);

/// The reply to `{"cmd":"download","id":N,"offset":O}`: up to
/// kTransferChunkBytes of the offered file from O, or `ok:false` with a
/// `message` for the person who sent it. Refused once the file is not the one
/// offered as it was then -- another file, a new size, saved since -- and the
/// offer withdrawn with it, as it is when the file is gone. The last
/// chunk closes the offer, and each one served gives every open offer another
/// half hour, so neither a slow transfer of a large file nor the files queued
/// behind it run out of time.
std::string DownloadJson(long long id, long long offset);

/// Close offer `id`: the Mac gave up on it (`"cancel":1`), or it was never
/// told of it. Its slot is free again at once.
void ForgetFileOffer(uint64_t id);

/// The "Send to Mac" item on every file's right-click menu, machine-wide, as
/// the install is. Logged, never fatal.
void RegisterSendToMac(const std::wstring& exe);
void RemoveSendToMac();

}  // namespace solstream
