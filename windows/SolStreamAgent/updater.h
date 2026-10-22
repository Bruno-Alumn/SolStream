// updater.h — SolStream for Windows finds, checks and installs its own updates.
//
// docs/updates.md is the contract this implements, shared with the Mac updater
// and the release workflow; change the three together. In short: ask GitHub for
// the latest release, ignore anything not strictly newer, fetch SHA256SUMS and
// its signature, verify the signature with the key compiled in below, and only
// then trust the checksum the sums give for SolStreamSetup-X.Y.Z.exe.
//
// Nothing is ever installed without the person saying so, and never while a Mac
// is streaming. A check only announces; Install is a button.

#pragma once

#include <windows.h>

#include <functional>
#include <string>
#include <utility>
#include <vector>

#include "installer.h"

namespace solstream::update {

/// Owner and repository: the one place either is written.
constexpr char kRepository[] = "Bruno-Alumn/SolStream";

/// The release signing key -- base64 of the 65-byte uncompressed P-256 point.
/// Its private half is not in the repository; see docs/updates.md.
constexpr char kPublicKey[] =
    "BAqYL3Fb9yQB0RbUnR8Bat8WVYHsUOM7oNvuiUmmYMxBtiB/g7HGlIBIPXaN+X4LdYuN+xyCt92Vhq9itHoNBOE=";

// ── The pieces, exposed so they can be tested without a network ─────────────

/// X.Y.Z, compared part by part as numbers.
struct Version {
    unsigned long parts[3] = {0, 0, 0};
};

/// "1.2.3" or "v1.2.3". Exactly three parts of digits, no leading zeros, so
/// the text a version came from and the text it prints as are the same.
bool ParseVersion(const std::string& text, Version& out);
int CompareVersions(const Version& a, const Version& b);
std::string VersionText(const Version& version);

/// The version this copy compares against: SOLSTREAM_PRETEND_VERSION when that
/// is set to a version, otherwise the one compiled in.
std::string CurrentVersion();

/// One asset of a release, as the GitHub API lists it.
struct Asset {
    std::string name;
    std::string api_url;       ///< `url`: takes a token, with Accept: octet-stream
    std::string download_url;  ///< `browser_download_url`: public repositories only
    unsigned long long size = 0;
};

/// The fields of GET /releases/latest this updater reads, and nothing else.
struct ReleaseInfo {
    std::string tag;
    bool draft = false;
    bool prerelease = false;
    std::vector<Asset> assets;
};

/// A real JSON parser, small: a key inside a string, or a "tag_name" nested in
/// somebody's release notes, cannot be mistaken for the field.
bool ParseRelease(const std::string& json, ReleaseInfo& out, std::string& error);

/// SHA256SUMS: one "<64 lowercase hex>  <name>\n" per asset. Strict -- it is
/// signed, so a line that does not match is a broken release, not a quirk.
bool ParseSums(const std::string& sums,
               std::vector<std::pair<std::string, std::string>>& out,
               std::string& error);

/// Strict base64: the standard alphabet, padded, nothing else.
bool DecodeBase64(const std::string& text, std::vector<unsigned char>& out);

/// ECDSA P-256 over SHA-256 of `sums`, with `signature_file` holding base64 of
/// the raw 64-byte r||s (a trailing newline is fine). `public_key_b64` is base64
/// of the uncompressed point. `error` says why when it returns false.
bool VerifySumsSignature(const std::string& sums, const std::string& signature_file,
                         const std::string& public_key_b64, std::string& error);

// ── Checking ─────────────────────────────────────────────────────────────────

/// An update that has been found and whose checksum is vouched for by a
/// verified SHA256SUMS. The installer itself has not been downloaded yet.
struct Release {
    std::string version;   ///< "1.0.1"
    Asset installer;       ///< SolStreamSetup-1.0.1.exe
    std::string sha256;    ///< lowercase hex, from the verified sums
};

enum class Outcome {
    UpToDate,        ///< the newest visible release is not newer than this
    NothingVisible,  ///< 404: nothing published this copy can see (a private repo)
    Found,           ///< `release` is newer, and its sums verified
    Failed,          ///< `error` says why, in words for the window
};

struct CheckResult {
    Outcome outcome = Outcome::Failed;
    std::string current;   ///< what was compared against
    std::string latest;    ///< the newest release seen, when one was
    Release release;       ///< when Found
    std::string error;     ///< when Failed: a sentence for a person
};

/// One check, start to finish. Blocks on the network: never call it on the UI
/// thread. Logs [update] lines; never logs the token.
CheckResult CheckForUpdate();

/// Download the installer (unless an earlier attempt already left a matching
/// one), verify it against the signed checksum while holding it open so it
/// cannot be swapped, and start it elevated with --install and `options` --
/// what the current install was set up with, so an update keeps it.
///
/// `step` is told what is happening, in words for the window. `may_install`
/// is asked once more right before the installer starts -- a Mac can connect
/// while a large download runs. Blocks: call it on a worker thread. True means
/// the installer has STARTED; it stops this process on its own, which is also
/// what lets go of the download (the hold outlives this call on purpose).
///
/// `installer_exited` is told, on a thread of its own and with the exit code,
/// if the installer finishes while this process is still alive -- which means
/// it did not replace this copy.
bool InstallUpdate(const Release& release, HWND owner, const InstallOptions& options,
                   const std::function<void(const std::wstring&)>& step,
                   const std::function<bool()>& may_install,
                   const std::function<void(DWORD exit_code)>& installer_exited,
                   std::string& error);

/// True from just before the elevation prompt until the installer exits or
/// fails to start. main.cpp turns new Macs away while it is: the prompt can stay
/// up for minutes, and the installer stopping this host would end their stream.
bool InstallStarting();

/// What became of the last install InstallUpdate started, as the copy running
/// now sees it. InstallUpdate leaves a note naming the version just before the
/// installer starts; the installer then stops that copy and starts the new one
/// hidden, so the note is how the new one knows somebody is waiting to hear.
/// Read once, at start -- the note is removed.
struct InstallNote {
    enum class Kind {
        None,          ///< no install was started, or the old copy saw how it went
        Installed,     ///< this copy is the version that was being installed
        NotInstalled,  ///< an install was started, and this copy is not its version
    };
    Kind kind = Kind::None;
    std::string version;   ///< the version that was being installed
    bool recent = false;   ///< started in the last ten minutes: somebody is waiting
};
InstallNote TakeInstallNote();

// ── Command line ─────────────────────────────────────────────────────────────

/// SolStream.exe --verify-update-signature <SHA256SUMS> <SHA256SUMS.sig> [<key>]
/// `argc`/`argv` are what follows the switch. <key> is base64 of the point, or
/// a file holding it; absent, the production key. Prints one line. Exits 0 when
/// the signature is valid and 1 when it is not.
int VerifySignatureCommand(int argc, wchar_t** argv);

/// SolStream.exe --check-updates [--download]: one check, said out loud, for
/// testing. Obeys SOLSTREAM_PRETEND_VERSION and SOLSTREAM_GITHUB_TOKEN. With
/// --download it also fetches and verifies the installer, and never runs it.
/// Exits 0 when the check completed, whatever it found, and 1 when it failed.
int CheckCommand(bool download);

// ── Schedule ─────────────────────────────────────────────────────────────────

struct SchedulerHooks {
    /// Macs streaming right now. A scheduled check waits while this is above 0.
    std::function<int()> streaming_clients;
    /// Every finished check. `asked` is true when a person asked for it.
    std::function<void(const CheckResult& result, bool asked)> finished;
};

/// A minute after start, then every 24 hours, on its own thread. Once. Only
/// for the copy installed in Program Files: it is the one the installer
/// replaces (main.cpp).
void StartScheduler(const SchedulerHooks& hooks);

/// A person asked ("Check for updates"). Joins a check already in flight
/// rather than starting a second one. False when no scheduler is running, so
/// nothing would ever answer.
bool CheckNow();

}  // namespace solstream::update
