import Foundation

/// Little-endian readers for the wire format.
///
/// Every multi-byte field on this link is little-endian — the STM32 is, and the
/// structs cross the wire as raw memory. Android says so explicitly with
/// `.order(LITTLE_ENDIAN)` on its float and double reads, because Java's
/// `ByteBuffer` defaults to big-endian and would silently decode garbage.
/// Swift's `littleEndian` initialisers make it explicit here for the same reason.
///
/// Every reader is bounds-checked and returns nil rather than trapping. A frame
/// reaching this layer has passed its CRC, but a short read must not crash the app
/// mid-flight — the whole point of the recovery tool is that it keeps working.
enum Bytes {

    static func u8(_ b: [UInt8], _ o: Int) -> UInt8? {
        b.indices.contains(o) ? b[o] : nil
    }

    static func i8(_ b: [UInt8], _ o: Int) -> Int8? {
        u8(b, o).map { Int8(bitPattern: $0) }
    }

    static func u16(_ b: [UInt8], _ o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= b.count else { return nil }
        return UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    static func i16(_ b: [UInt8], _ o: Int) -> Int16? {
        u16(b, o).map { Int16(bitPattern: $0) }
    }

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= b.count else { return nil }
        return UInt32(b[o])
            | (UInt32(b[o + 1]) << 8)
            | (UInt32(b[o + 2]) << 16)
            | (UInt32(b[o + 3]) << 24)
    }

    static func f32(_ b: [UInt8], _ o: Int) -> Float? {
        u32(b, o).map { Float(bitPattern: $0) }
    }

    static func u64(_ b: [UInt8], _ o: Int) -> UInt64? {
        guard o >= 0, o + 8 <= b.count else { return nil }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = (v << 8) | UInt64(b[o + i]) }
        return v
    }

    static func f64(_ b: [UInt8], _ o: Int) -> Double? {
        u64(b, o).map { Double(bitPattern: $0) }
    }

    /// A fixed-width, NUL-padded device name. Stops at the first NUL, as Android does.
    static func name(_ b: [UInt8], _ o: Int, length: Int) -> String? {
        guard o >= 0, o + length <= b.count else { return nil }
        let field = b[o..<(o + length)]
        let trimmed = Array(field.prefix { $0 != 0 })
        return String(decoding: trimmed, as: UTF8.self)
    }
}

/// Three little-endian floats — an accel/gyro/velocity triple.
struct Vec3f: Equatable {
    let x: Float, y: Float, z: Float

    static func read(_ b: [UInt8], _ o: Int) -> Vec3f? {
        guard let x = Bytes.f32(b, o), let y = Bytes.f32(b, o + 4), let z = Bytes.f32(b, o + 8)
        else { return nil }
        return Vec3f(x: x, y: y, z: z)
    }
}

/// Attitude quaternion, w first on the wire.
struct Quaternionf: Equatable {
    let w: Float, x: Float, y: Float, z: Float
}
