// ports.h — where SolStream listens.
//
// There are three numbers in the whole system now. There used to be nine: seven
// GameStream ports derived from a Sunshine base by fixed offsets, plus a second
// base to try in case the user had installed Sunshine themselves. All of that
// existed because SolStream was talking to somebody else's server.
//
// The Mac's copy of this table is macos/SolStreamClient/Sources/AgentChannel/
// StreamPorts.swift, and the two have to agree.

#pragma once

namespace solstream {

/// The agent's control socket: newline-JSON, token-authenticated, sixteen
/// commands. Everything starts here, including the media session's keys.
constexpr unsigned short kDefaultPort = 47630;

/// SMT/1's UDP socket. Named in the answer to `media open` rather than assumed,
/// so a host that has to move it can say so.
constexpr unsigned short kDefaultMediaPort = 47631;

/// Where a Mac asks "is anybody there" and a host answers.
constexpr unsigned short kDiscoveryPort = 47629;

}  // namespace solstream
