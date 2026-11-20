# Designs

Features and fixes worked out but not built, each waiting on a decision only
the owner of the project can make: a certificate to buy, a driver to ship, a
setting on somebody's PC to change. Each note says what it would take and what
the decision is.

| Note | Waiting on |
|---|---|
| [Windows notifications on the Mac](notifications.md) | A Windows code-signing certificate, which would also end the "Windows protected your PC" warning |
| [Game controllers](game-controllers.md) | Whether shipping a retired third-party driver is acceptable, or a signing certificate and hardware dev center account |
| [Staying connected across sign-out](sign-in-screen.md) | Whether SolStream should ever run anything as SYSTEM |
| [Microphone and webcam](microphone-and-webcam.md) | Whether a Windows-11-only camera comes before the microphone, and whether to sign a driver |
| [10-bit, HDR and AV1](10-bit-hdr-av1.md) | Which GPU and Mac chip are in use, and whether HDR is a goal |
| [Handing an update to the elevated installer](update-handover.md) | A live check of an update on the PC from a build with the fix to one after it |
| [How a launcher finds the PC](launcher-routes.md) | Which of three ways a Dock launcher should reach a PC away from home, and wake it |
| [Mouse acceleration in games](mouse-acceleration.md) | Whether SolStream may change the PC's pointer speed and "Enhance pointer precision" during a game |
| [Quality presets, a connection test, and commands around an app](presets-and-app-commands.md) | Whether SolStream may offer to lower quality mid-stream, and whether a Mac may ever set commands the PC runs |

A note leaves this list when it is built, and the code says what it does.
