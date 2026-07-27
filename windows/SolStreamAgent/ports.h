// ports.h — where SolStream listens, and why it is not where Sunshine listens.
//
// Sunshine derives every port it uses from a single `port` setting by adding a
// fixed offset (net::map_port, network.cpp). The offsets are part of the
// GameStream protocol rather than Sunshine's own invention, so they are the same
// for any host a Moonlight-derived client talks to:
//
//     https (client, mTLS)  port - 5     pairing and /launch
//     http                  port + 0     unauthenticated pairing endpoints
//     web UI (confighttp)   port + 1     the browser configuration page
//     video   (UDP)         port + 9
//     control (ENet, UDP)   port + 10
//     audio   (UDP)         port + 11
//     rtsp                  port + 21
//
// SolStream runs its own Sunshine on its own base, deliberately away from the
// 47989 default. A machine that already has Sunshine installed is a machine
// somebody set up for Moonlight, and taking its ports would break that — the
// point of shipping our own copy is that the user needs nothing else, not that
// they have to give something up. Two instances can then run side by side; they
// only collide over the capture display, and SolStream captures the virtual one
// that nothing else is using.
//
// The Mac mirrors this table in StreamPorts.swift. Both are derived from one
// number, so moving the base moves everything on both sides at once — but the
// two numbers still have to agree, which is what makes this a header rather than
// a scattering of literals.

#pragma once

namespace solstream {

/// The base SolStream's own Sunshine runs on.
///
/// 47600 keeps the whole derived block (47595–47621) clear of Sunshine's default
/// 47984–48010, and of 47989 itself, so `netstat` on a dual-install machine
/// shows two obviously distinct groups.
constexpr unsigned short kDefaultSunshineBase = 47600;

/// The agent's own control socket — the newline-JSON protocol this program
/// speaks to the Mac. Deliberately outside the derived block: it moved off
/// 47997, which sat *inside* Sunshine's default 47984–48010 range and would have
/// collided the day Sunshine claimed one more offset.
constexpr unsigned short kDefaultAgentPort = 47630;

/// Sunshine's port offsets, straight from its own headers.
enum class SunshinePort {
    kHttps = -5,   ///< nvhttp.h  PORT_HTTPS
    kHttp = 0,     ///< nvhttp.h  PORT_HTTP
    kWebUi = 1,    ///< confighttp.h PORT_HTTPS
    kVideo = 9,    ///< stream.h  VIDEO_STREAM_PORT
    kControl = 10, ///< stream.h  CONTROL_PORT
    kAudio = 11,   ///< stream.h  AUDIO_STREAM_PORT
    kRtsp = 21,    ///< rtsp.h    RTSP_SETUP_PORT
};

constexpr unsigned short MapPort(unsigned short base, SunshinePort which) {
    return static_cast<unsigned short>(static_cast<int>(base) + static_cast<int>(which));
}

}  // namespace solstream
