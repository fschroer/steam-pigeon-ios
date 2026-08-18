import Foundation

/// Password authentication for locator recognition (ADR "locator connect-password").
///
/// The locator authenticates both of its unsolicited broadcasts with a
/// password-seeded checksum (`auth_tag`): `PreLaunchData` while disarmed,
/// `TelemetryData` while armed. The seed is derived from the user's password with
/// FNV-1a (32-bit), mirroring the firmware's `PasswordKdf.hpp`. The tag itself is
/// two CRC-16 passes (poly 0xA001) over the base message bytes with
/// `packet_header.crc` and `auth_tag` zeroed, seeded from the low and high halves
/// of the key — mirroring `Communication::ComputePasswordAuthTag`.
///
/// Both message types are handled by the same code because the firmware
/// authenticates them by the same rule. All that differs is the size of the base
/// struct, which callers pass in: the crc always sits at bytes 4..5, and the
/// `auth_tag` is always the last 4 bytes of the base region, with any
/// receiver-appended metadata sitting outside it.
///
/// A key of 0 means "open" (no password set on the locator) and must keep working
/// with no prompt — the backward-compatibility guarantee in the ADR.
///
/// This is a platform-neutral security model ported from Android's `LocatorAuth.kt`
/// with the **same test vectors**. A silent mismatch here fails closed (the locator
/// is never authorized) or open — both bad.
enum LocatorAuth {

    private static let poly: UInt16 = 0xA001
    private static let fnvOffsetBasis: UInt32 = 0x811c_9dc5
    private static let fnvPrime: UInt32 = 0x0100_0193

    /// FNV-1a 32-bit over the password's UTF-8 bytes.
    static func fnv1a32(_ password: String) -> UInt32 {
        var hash = fnvOffsetBasis
        for byte in Array(password.utf8) {
            hash ^= UInt32(byte)
            hash = hash &* fnvPrime      // &* wraps, matching the 32-bit mask on the other two copies
        }
        return hash
    }

    /// Derive the stored key: blank clears (0 = open); a real password never yields 0.
    static func deriveKey(_ password: String) -> UInt32 {
        guard !password.isEmpty else { return 0 }
        let key = fnv1a32(password)
        return key == 0 ? 1 : key
    }

    private static func crc16(seed: UInt16, data: [UInt8], length: Int) -> UInt16 {
        var crc = seed
        for i in 0..<length {
            crc ^= UInt16(data[i])
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ poly : crc >> 1
            }
        }
        return crc
    }

    /// Recompute the expected `auth_tag` over a received `frame` whose base struct is
    /// `baseSize` bytes, using `passwordKey`. Returns nil if the frame is too short to
    /// contain the base struct — a truncated frame must fail closed rather than
    /// authenticating on whatever bytes happened to be present.
    static func expectedAuthTag(
        frame: [UInt8],
        passwordKey: UInt32,
        baseSize: Int = WireProtocol.prelaunchBaseStructSize
    ) -> UInt32? {
        guard frame.count >= baseSize, baseSize >= 6 else { return nil }
        var region = Array(frame[0..<baseSize])
        region[4] = 0                                            // packet_header.crc,
        region[5] = 0                                            // rewritten by the receiver
        for i in (baseSize - 4)..<baseSize { region[i] = 0 }      // auth_tag (last 4 bytes)
        let lo = crc16(seed: UInt16(truncatingIfNeeded: passwordKey), data: region, length: baseSize)
        let hi = crc16(seed: UInt16(truncatingIfNeeded: passwordKey >> 16), data: region, length: baseSize)
        return (UInt32(hi) << 16) | UInt32(lo)
    }

    /// True if `passwordKey` authenticates the `frame` carrying `authTag`.
    static func verify(
        frame: [UInt8],
        authTag: UInt32,
        passwordKey: UInt32,
        baseSize: Int = WireProtocol.prelaunchBaseStructSize
    ) -> Bool {
        expectedAuthTag(frame: frame, passwordKey: passwordKey, baseSize: baseSize) == authTag
    }

    /// The `auth_tag` embedded in a received `frame` (last 4 bytes of the base
    /// region, little-endian), or nil if too short.
    static func embeddedAuthTag(
        frame: [UInt8],
        baseSize: Int = WireProtocol.prelaunchBaseStructSize
    ) -> UInt32? {
        guard frame.count >= baseSize, baseSize >= 4 else { return nil }
        let o = baseSize - 4
        return UInt32(frame[o])
            | (UInt32(frame[o + 1]) << 8)
            | (UInt32(frame[o + 2]) << 16)
            | (UInt32(frame[o + 3]) << 24)
    }

    /// True if `passwordKey` authenticates `frame` against its own embedded tag.
    static func verifyFrame(
        frame: [UInt8],
        passwordKey: UInt32,
        baseSize: Int = WireProtocol.prelaunchBaseStructSize
    ) -> Bool {
        guard let expected = expectedAuthTag(frame: frame, passwordKey: passwordKey, baseSize: baseSize),
              let embedded = embeddedAuthTag(frame: frame, baseSize: baseSize) else { return false }
        return expected == embedded
    }
}
