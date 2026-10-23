// session_takeover.h — letting a Mac back into the session it left behind.
//
// The host serves one Mac at a time, and it learns that a Mac has gone only
// when the socket says so. A Mac whose network changes under it -- Wi-Fi to
// Ethernet, a new address after waking, a Wi-Fi drop long enough for its
// heartbeat to time out -- leaves a socket behind that no FIN ever closes, and
// the session stays counted until the 30-second idle timeout runs out. The Mac
// reconnects two seconds after it noticed, so it used to be turned away as
// "already streaming to another Mac" by its own dead session.
//
// A Mac that says who it is -- a random id it keeps per install and sends with
// its auth proof -- may now take that session over, once the session has
// missed a heartbeat. A Mac that says nothing, which is every Mac built before
// this, is never let in over anybody and never has its session taken. These
// are the parts of that decision that need no socket, so they can be tested.

#pragma once

#include <string>
#include <vector>

namespace solstream {

/// How long the session must have been silent before its own Mac may take it
/// over.
///
/// The Mac pings every ten seconds, with a second's leeway, so a session
/// silent for this long has missed a heartbeat. Anything shorter could end the
/// live connection of a second copy of the app on the same Mac, and the two
/// would then take the session from each other for ever.
constexpr unsigned long long kTakeoverSilenceMs = 15000;

/// Whether `id` has the shape a Mac's client id has: 32 lowercase hex digits.
/// Anything else is treated as no id at all.
bool IsClientId(const std::string& id);

/// What a takeover proof is the HMAC of, keyed with the pairing token:
///
///     "SolStream agent takeover v1" || challenge || cnonce || client id
///
/// A label of its own, so a takeover proof can never stand in for an auth
/// proof or the other way round; and the id inside it, so a proof made for one
/// id cannot be replayed with another.
std::vector<unsigned char> TakeoverProofMessage(const std::vector<unsigned char>& challenge,
                                                const std::vector<unsigned char>& cnonce,
                                                const std::string& client_id);

/// HmacSha256 (util.h) under the name the tests know it by.
std::vector<unsigned char> TakeoverHmac(const std::vector<unsigned char>& key,
                                        const std::vector<unsigned char>& data);

/// Whether `proof_hex` is the takeover proof for these values under the token,
/// compared in constant time. False for anything malformed: a challenge or
/// nonce that is not 32 bytes, a proof that is not 32, an id of the wrong shape
/// or an empty token.
bool TakeoverProofMatches(const std::string& token_hex, const std::string& challenge_hex,
                          const std::string& cnonce_hex, const std::string& client_id,
                          const std::string& proof_hex);

/// What is known about when the session's Mac was last heard from.
///
/// Two things say so. The serving thread reads what the Mac sends, but not
/// while it is inside a command -- a launch waits up to a minute for its
/// window -- and the Mac's pings pile up unread on the socket meanwhile. So a
/// knock looks at how much is waiting unread as well, and a count that has
/// grown since the last look is the Mac heard from just now. A count that
/// has not grown says nothing: those bytes may have sat there since long
/// before the Mac's network went.
struct HolderHearing {
    /// When the serving thread last read something the Mac sent while the
    /// thread was waiting for it, by GetTickCount64.
    unsigned long long heard_at = 0;
    /// How much was waiting unread when last looked at, and when that last
    /// grew.
    unsigned long long unread = 0;
    unsigned long long unread_grew_at = 0;
};

/// A fresh hearing for a session that has just been authenticated at `now`.
HolderHearing HeardFresh(unsigned long long now);

/// The serving thread has read from the socket, and `left` bytes are still
/// waiting behind what it read.
///
/// `sent_by` is the latest the bytes it read can be said to have been sent:
/// now, for bytes that arrived while it was waiting, and the moment it went
/// into the last command for bytes that were already waiting when it came
/// out. Bytes that piled up during a long command are old by the time they
/// are read, and stamping them with the time of reading would restart the
/// silence of a Mac whose network went in the middle of that command.
void HearingRead(HolderHearing& hearing, unsigned long long sent_by, unsigned long long left);

/// How long the session has been silent, as a knock sees it at `now` with
/// `unread` bytes waiting on the session's socket. Records the look.
unsigned long long HearingSilentMs(HolderHearing& hearing, unsigned long long unread,
                                   unsigned long long now);

/// What to do with a Mac asking to take over the session.
enum class TakeoverVerdict {
    /// It is the Mac that holds the session, and the session has gone quiet,
    /// or there is no longer a session to hold: end it and let this one in.
    Take,
    /// It is the same Mac, but its session was heard from within
    /// kTakeoverSilenceMs. Tell it so; it tries again shortly.
    NotYet,
    /// Somebody else holds the session -- a Mac with another id, or one that
    /// gave none. Refused, and said to be refused for good.
    Another,
    /// The request proved nothing. Answered like any knock on a busy host,
    /// saying nothing about who holds the session.
    Refused,
};

/// The decision, from what the request proved and what is known about the
/// session it wants.
/// - Parameter holder_present: whether an authenticated session still exists.
/// - Parameter holder_id: the id that session's Mac gave, empty if none.
/// - Parameter holder_silent_ms: how long since that session last sent anything.
TakeoverVerdict DecideTakeover(bool proof_ok, const std::string& client_id,
                               bool holder_present, const std::string& holder_id,
                               unsigned long long holder_silent_ms);

}  // namespace solstream
