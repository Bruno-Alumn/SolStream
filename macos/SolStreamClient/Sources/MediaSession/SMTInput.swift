// SMTInput.swift — input events, and why they carry a sequence number.
//
// UDP loses packets and input is not idempotent. A lost key-up leaves a key held
// down; a lost button-up leaves a drag running. So every event carries a
// sequence number, this side repeats recent events on later datagrams, and the
// host deduplicates on the sequence rather than trusting arrival. Repetition is
// then free, which is what makes it safe to be generous with it.
//
// A builder returns one event as `[kind, bodyLength] + body`. The sequence
// number, the redundancy and the framing are added by MediaClient, which is the
// only thing that knows what has been acknowledged.

import Foundation

public enum SMTInput {

    public enum Kind: UInt8 {
        case mouseAbs = 1
        case mouseRel = 2
        case button = 3
        case scrollV = 4
        case scrollH = 5
        case key = 6
        case text = 7
    }

    /// Mouse buttons, numbered the way the host's SendInput switch expects.
    public enum MouseButton: UInt8 {
        case left = 1
        case middle = 2
        case right = 3
        case extra1 = 4
        case extra2 = 5
    }

    /// Sent alongside a key event. The host does not currently act on it -- the
    /// modifier keys arrive as their own key events -- but a host that wants to
    /// resynchronise a stuck modifier needs to be told what this side believes.
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 0x01)
        public static let control = Modifiers(rawValue: 0x02)
        public static let alt = Modifiers(rawValue: 0x04)
        public static let meta = Modifiers(rawValue: 0x08)
    }

    /// One event, as `[kind, bodyLength] + body`.
    ///
    /// THE DECLARED LENGTH AND THE APPENDED LENGTH MUST BE THE SAME NUMBER.
    /// This used to write `min(body.count, 255)` and then append the whole
    /// body, and a body over 255 bytes was not a truncated event, it was the
    /// end of input for the session: the host advances its parser by exactly
    /// the declared length, so it lands inside the body, reads four of those
    /// bytes as the next event's sequence number, and that garbage number
    /// becomes `highest_`. Every real event after it is then more than 1024
    /// behind the dedupe window and discarded as a duplicate, silently, for as
    /// long as the session lasts.
    ///
    /// Refusing is the only answer that keeps the invariant true without
    /// inventing bytes or dropping some of them unannounced. Nothing below can
    /// reach it -- the fixed-shape builders are four bytes at most and `text`
    /// splits before it gets here -- so this is here to stop a future builder
    /// reintroducing the fault, not to handle a case that occurs.
    static func event(_ kind: Kind, _ body: Data) -> Data {
        guard body.count <= 255 else { return Data() }
        var out = Data(capacity: body.count + 2)
        out.append(kind.rawValue)
        out.append(UInt8(body.count))
        out.append(body)
        return out
    }

    static func be16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Absolute pointer position, as a fraction of the streamed picture.
    ///
    /// Normalised here rather than sent in pixels, so the host maps it onto
    /// whatever the captured window's rectangle currently is. A window that is
    /// resized on the host therefore needs no renegotiation for the pointer to
    /// keep landing in the right place.
    public static func mouseMoveAbsolute(x: Int, y: Int,
                                         referenceWidth: Int,
                                         referenceHeight: Int) -> Data {
        let width = max(1, referenceWidth)
        let height = max(1, referenceHeight)
        let nx = UInt16(clamping: max(0, min(width, x)) * 65535 / width)
        let ny = UInt16(clamping: max(0, min(height, y)) * 65535 / height)
        return event(.mouseAbs, be16(nx) + be16(ny))
    }

    public static func mouseMoveRelative(deltaX: Int, deltaY: Int) -> Data {
        let dx = UInt16(bitPattern: Int16(clamping: deltaX))
        let dy = UInt16(bitPattern: Int16(clamping: deltaY))
        return event(.mouseRel, be16(dx) + be16(dy))
    }

    public static func mouseButton(_ button: MouseButton, pressed: Bool) -> Data {
        event(.button, Data([button.rawValue, pressed ? 1 : 0]))
    }

    /// Vertical scroll, in Windows wheel units: 120 to a click.
    public static func scroll(amount: Int) -> Data {
        event(.scrollV, be16(UInt16(bitPattern: Int16(clamping: amount))))
    }

    public static func horizontalScroll(amount: Int) -> Data {
        event(.scrollH, be16(UInt16(bitPattern: Int16(clamping: amount))))
    }

    /// A key event carrying a Windows virtual key code.
    public static func key(code: UInt16, pressed: Bool, modifiers: Modifiers) -> Data {
        event(.key, be16(code) + Data([pressed ? 1 : 0, modifiers.rawValue]))
    }

    /// Characters no keycode can express, as UTF-16 code units.
    ///
    /// Several events rather than one, because the length byte above stops at
    /// 255 and a paste of any length would otherwise walk straight past it.
    /// Each element is one event for `MediaClient.sendInput`, so each gets its
    /// own sequence number and its own acknowledgement; the host injects code
    /// units in the order the events arrive and is indifferent to where a run
    /// of text was divided.
    ///
    /// The split is by SCALAR, not by byte. A cut on an odd byte would hand the
    /// host half a code unit, and a cut between the two halves of a surrogate
    /// pair would turn one emoji into two lone surrogates -- both of which the
    /// host would inject as garbage rather than reject. 254 bytes, which is 127
    /// code units, is the most the length byte can describe without the last
    /// one being cut in half.
    public static func text(_ string: String) -> [Data] {
        var events: [Data] = []
        var body = Data()
        for scalar in string.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if !body.isEmpty && body.count + units.count * 2 > 254 {
                events.append(event(.text, body))
                body = Data()
            }
            for unit in units { body.append(be16(unit)) }
        }
        if !body.isEmpty { events.append(event(.text, body)) }
        return events
    }
}
