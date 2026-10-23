// util.h — the small helpers every part of the host needs, written once.
//
// Each of these used to exist two to four times over, in slightly different
// shapes, and the copies drifted: one RunHidden learned to kill a child that
// outlived its timeout and to stop reporting STILL_ACTIVE as an exit code, and
// the other one did not.

#pragma once

#include <windows.h>

#include <string>
#include <string_view>
#include <vector>

namespace solstream {

/// UTF-16 <-> UTF-8. Empty in, empty out; invalid input yields empty.
std::string ToUtf8(const std::wstring& text);
std::wstring ToWide(const std::string& text);

/// Escape UTF-8 text for embedding in a JSON string. Window titles are
/// arbitrary user text, so quotes, backslashes and control characters are
/// escaped; and anything that is not well-formed UTF-8 comes out as U+FFFD,
/// because the Mac's parser refuses a whole line over one bad byte.
std::string JsonEscape(const std::string& text);

/// Lower-cased copy, for case-insensitive comparison and searching.
std::wstring FoldCase(std::wstring text);

/// Lowercase hex, and back. FromHex returns empty on odd length or a non-hex
/// character.
std::string ToHex(const unsigned char* bytes, size_t count);
std::string ToHex(const std::vector<unsigned char>& bytes);
std::vector<unsigned char> FromHex(const std::string& hex);

/// HMAC-SHA256 through BCrypt, or empty if BCrypt refuses.
std::vector<unsigned char> HmacSha256(const std::vector<unsigned char>& key,
                                      const std::vector<unsigned char>& data);

/// Whether `proof` is HMAC-SHA256(key, message), compared in constant time.
/// False for a proof that is not 32 bytes, or when BCrypt refuses.
bool ProofMatchesHmac(const std::vector<unsigned char>& key,
                      const std::vector<unsigned char>& message,
                      const std::vector<unsigned char>& proof);

/// Exactly four hex digits at `at` in `text`, either case, as a JSON \u escape
/// carries them. False when there are fewer than four or one is not hex.
bool ParseHex4(std::string_view text, size_t at, unsigned& out);

/// Append one code point to `out` as UTF-8. The caller has already replaced
/// surrogates and anything past U+10FFFF.
void AppendUtf8(std::string& out, unsigned code);

/// `%LOCALAPPDATA%\SolStream\<file>`, creating the directory if needed. Empty
/// when LOCALAPPDATA is not set. Where the token, the media counter and the
/// host's log live.
std::wstring LocalDataPath(const wchar_t* file);

/// Read up to `limit` bytes from the start of the file at `path` into `out`,
/// with one ReadFile, sharing it for reading only. A longer file is cut, not
/// refused. False when it cannot be opened or read.
bool ReadSmallFile(const std::wstring& path, size_t limit, std::string& out);

/// Replace the file at `path` with `bytes`, creating it if need be and sharing
/// it with nobody while it is written. True when all of it was written.
bool WriteWholeFile(const std::wstring& path, const std::string& bytes);

/// What RunHidden answers when there is no exit code to give: the process never
/// started, or it was still running at the timeout and was killed. Neither value
/// is one netsh, schtasks, pnputil or powershell answers with.
constexpr DWORD kRunFailed = 0xFFFFFFFFu;
constexpr DWORD kRunTimedOut = 0xFFFFFFFEu;

/// Run a System32 command with no window and wait for it, returning its exit
/// code, kRunFailed or kRunTimedOut.
///
/// A bare executable name is resolved to System32 first: much of this runs
/// elevated, and CreateProcess's search order starts with the directory the
/// process was started from, which for a setup program is wherever it was
/// downloaded to. A child still running at the timeout is killed rather than
/// left to change the machine behind a screen that has already reported.
DWORD RunHidden(const std::wstring& command, DWORD timeout_ms = 60000);

/// What RunHidden actually runs: `command` with a bare program name (its first
/// word, quoted or not) rewritten to the copy in System32. A program given by
/// path is left as it is. Exposed for its tests.
std::wstring QualifySystemCommand(const std::wstring& command);
std::wstring CommandProgram(const std::wstring& command);

/// How a RunHidden answer reads in a sentence: "returned 1", "would not start",
/// "was still running after N seconds and was stopped".
std::string RunOutcome(DWORD code);

}  // namespace solstream
