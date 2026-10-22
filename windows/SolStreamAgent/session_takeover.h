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

/// HMAC-SHA256 through BCrypt, or empty if BCrypt refuses.
std::vector<unsigned char> TakeoverHmac(const std::vector<unsigned char>& key,
                                        const std::vector<unsigned char>& data);

/// Whether `proof_hex` is the takeover proof for these values under the token,
/// compared in constant time. False for anything malformed: a challenge or
/// nonce that is not 32 bytes, a proof that is not 32, an id of the wrong shape
/// or an empty token.
bool TakeoverProofMatches(const std::string& token_hex, const std::string& challenge_hex,
                          const std::string& cnonce_hex, const std::string& client_id,
                          const std::string& proof_hex);

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
