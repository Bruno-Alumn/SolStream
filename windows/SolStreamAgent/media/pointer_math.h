// pointer_math.h — where a pointer position from the Mac lands, in pixels.
//
// Two conversions, each exact for every pixel: the Mac's position, a fraction
// of the target in 0..65535, back to a pixel of the target; and that pixel to
// SendInput's own 0..65535 over the virtual desktop. Both rounded down before,
// and two floors in a row put the pointer a pixel up and left of where it was
// aimed on almost every column -- two on a monitor beside the primary -- and
// the target's last pixel could not be reached at all.

#pragma once

#include <cstdint>

namespace solstream::media {

/// The pixel of a target `extent` wide that the Mac's `unit` (0..65535, which
/// it makes as pixel * 65535 / extent, rounded down) stands for. Rounded to
/// the nearest, which recovers the Mac's pixel exactly for any extent under
/// 32768.
inline int64_t PixelFromUnit(uint16_t unit, int64_t extent) {
    if (extent <= 0) {
        return 0;
    }
    const int64_t pixel = ((int64_t) unit * extent + 32767) / 65535;
    return pixel < extent ? pixel : extent - 1;
}

/// SendInput's MOUSEEVENTF_ABSOLUTE coordinate for `offset` pixels into a
/// virtual desktop `extent` wide. Aimed a quarter of a pixel in, so the pixel
/// comes back whether Windows rounds the coordinate down or to the nearest --
/// for any desktop up to 16384 pixels wide; past that, rounded down, a quarter
/// of a pixel is less than a unit and a few pixels can miss by one.
inline int32_t AbsoluteFromPixel(int64_t offset, int64_t extent) {
    if (extent <= 0 || offset <= 0) {
        return 0;
    }
    const int64_t value = ((4 * offset + 1) * 65536) / (4 * extent);
    return (int32_t) (value < 65535 ? value : 65535);
}

}  // namespace solstream::media
