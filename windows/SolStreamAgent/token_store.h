// token_store.h — where the host keeps its pairing token.
//
// Encrypted with DPAPI for the Windows account the host runs as: that account
// can read it -- the host shows it in its window, for the person at the PC to
// type on their Mac -- and nobody else can, nor anyone holding a copy of the
// profile taken off the machine. It used to be a plain file anyone running as
// that user, or reading the disk, could copy, which an external review
// flagged.
//
// A plain agent.token from before is moved in, once, so a PC's pairings
// survive the update. The encrypted copy has a name of its own: a host from
// before this, run again, finds no token it could misread and makes a fresh
// one -- a pairing to redo, never a broken one.

#pragma once

#include <string>

namespace solstream {

/// The token kept in `folder` (normally %LOCALAPPDATA%\SolStream), made the
/// first time. Empty only when none could be read or made at all.
std::string LoadOrCreateToken(const std::wstring& folder);

/// DPAPI, for this account, with SolStream's own entropy. False when Windows
/// would not.
bool ProtectToken(const std::string& token, std::string& blob);
bool UnprotectToken(const std::string& blob, std::string& token);

/// What a token may be: 16 to 127 printable ASCII characters, no spaces --
/// what the host has always accepted from agent.token, so no PC's token is
/// refused on the way in. One the host makes is 32 lowercase hex digits.
bool IsTokenText(const std::string& text);

}  // namespace solstream
