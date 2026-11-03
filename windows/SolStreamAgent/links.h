// links.h — links clicked in a streamed app, opened on the Mac.
//
// SolStream registers as a browser Windows can offer in Default apps. Chosen
// there for http, https or mailto, a link clicked on the PC starts
// `SolStream.exe --open-url <link>`, which hands it to the running host, and
// the host to the Mac. With no Mac connected the link opens in Edge instead,
// so choosing SolStream never leaves a click going nowhere. Windows lets no
// program make itself the default, so it is the person's choice to make.

#pragma once

#include <string>

namespace solstream {

/// Whether a link may go to the Mac: http, https or mailto, and nothing a
/// command line or a JSON line could be fooled by -- no spaces or control
/// characters, and at most a few kilobytes.
bool IsForwardableLink(const std::string& url);

/// `url` as a browser's address bar would take it: spaces and control
/// characters trimmed from both ends, tabs and line breaks dropped, and each
/// space left inside written %20. Some apps hand a link over unencoded, and
/// the click's one quoted argument keeps it whole.
std::string CleanLink(const std::string& url);

/// Whether `url`'s scheme -- in any case -- is mailto, or http or https.
bool IsMailLink(const std::string& url);
bool IsWebLink(const std::string& url);

/// Offer SolStream in Settings > Default apps for http, https and mailto,
/// opening links with `exe --open-url`. Machine-wide, as the install is; the
/// choice of default stays each user's. Logged, never fatal.
void RegisterLinkHandler(const std::wstring& exe);

/// Take that offer back.
void RemoveLinkHandler();

}  // namespace solstream
