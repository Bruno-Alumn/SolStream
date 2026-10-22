# libopus, as SolStream carries it

The Windows host compresses the PC's sound with Opus when the Mac asks for it
(Settings → Sound → Quality). This directory is the encoder. It is the one
third-party component in anything SolStream ships, and it goes into the
Windows host only. The Mac decodes Opus with AudioToolbox and needs nothing.

| | |
| --- | --- |
| Version | 1.6.1 |
| From | <https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz> |
| SHA-256 | `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1`, as listed in Xiph's `SHA256SUMS.txt` |
| Licence | BSD 3-clause, in `COPYING`. The licence asks for its notice to travel with any binary built from this code, so the host embeds it as a resource, and `SolStream.exe --licenses` prints it. |

## Why it is here at all

SolStream otherwise uses only what the two operating systems ship. Windows
has no Opus encoder: Media Foundation's audio encoders, as registered on a
Windows 11 25H2 machine, are AAC, FLAC, ALAC, MP3, WMA, MPEG-2 audio and
AMR-NB. The AAC one was the alternative, and it is the wrong tool:

- It offers 96, 128, 160 and 192 kbit/s only, so neither High (256) nor Data
  saver (64) can be had from it.
- Its frames are 1024 samples, with lookahead behind them, which costs some
  50 ms. That puts the sound visibly behind a picture that leaves the PC
  7 to 20 ms after it was drawn.

With restricted low delay, Opus is CELT only, with 2.5 ms of lookahead. At
10 ms a packet, the sound plays 7.5 ms later than the 5 ms PCM packets it
replaces, and it is close to transparent at 256 kbit/s.

## What was taken

The release tarball, minus what the library does not need when it is built
by CMake with the options in `windows/SolStreamAgent/CMakeLists.txt`:

- `dnn/`: 22 MB of neural-network models and code. It is used only by deep
  PLC, DRED and OSCE, which are all off by default. Every include of it is
  behind the matching `ENABLE_*` define.
- `tests/`, `celt/tests/`, `silk/tests/` and `doc/`.
- The autotools and meson builds. `configure.ac` stays, because the CMake
  build reads the library version from it.

No file that was kept has been edited. Updating means doing the same again
with a newer release: check its checksum against Xiph's list, delete the same
directories, and build on Windows.
