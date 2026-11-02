# Game controllers (design, not built)

The goal: an Xbox or PlayStation controller paired with the Mac plays games
streamed from the PC.

## The Mac half: easy

Apple's GameController framework reads any MFi, Xbox, PlayStation or Switch
Pro controller as a `GCExtendedGamepad`: two sticks, two triggers, the d-pad
and the buttons. It would send them over SMT/1 as a new input message, about
20 bytes per change, beside the mouse and keyboard. Rumble can come back the
other way through `GCDeviceHaptics`.

## The PC half: needs a driver

Games read controllers through XInput, DirectInput or GameInput. All three
read hardware. To appear in them, a controller has to be a device, and a
device needs a **kernel driver**.

| | How | Reaches | Cost and risk |
|---|---|---|---|
| **A. ViGEmBus** | The well-known virtual Xbox 360/DS4 bus driver. Setup downloads and installs it, pinned and hash-checked, the way it installs the virtual display. | XInput, DirectInput, GameInput. Every game. | Retired by its author in 2023. Signed and still installs, but won't be fixed if a Windows update breaks it. |
| **B. Our own VHF driver** | A small KMDF driver using Microsoft's Virtual HID Framework, presenting an Xbox-compatible HID gamepad. | DirectInput and GameInput; XInput only through Windows' XInput-over-HID mapping. | Needs EV code signing and attestation signing through Microsoft's partner portal. Weeks of work. |
| **C. `InputInjector.InjectGamepadInput`** | A WinRT API, no driver. | Only apps that read `Windows.Gaming.Input`: some Store games, very few others. | May need package identity. Too few games to be worth it. |

## Recommendation

**A**, behind a setup checkbox like the virtual display's, accepting that
it's unmaintained, until there is a reason to sign a driver of our own (**B**).

## Decision needed

Is shipping a retired third-party driver acceptable? If not, **B** needs a
code-signing certificate and a Microsoft hardware dev center account.
