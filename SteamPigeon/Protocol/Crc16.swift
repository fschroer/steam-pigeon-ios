import Foundation

/// The CRC-16 primitive shared by the whole Steam Pigeon link.
///
/// Mirrors `Communication::Crc16Update` / `Crc16Continue` in the firmware:
/// reflected, polynomial 0xA001, no final XOR. It is used two ways, and the
/// difference is only the seed and the byte range:
///
/// - **Message CRC** — seeded `kCrc16Key` (0xFFFF) over the frame with the crc
///   field itself skipped (`Communication::ValidateCRC`). See `PacketFramer`.
/// - **Password auth tag** — two passes seeded from the low and high halves of
///   the password key, over the base struct with crc *and* auth_tag zeroed
///   (`Communication::ComputePasswordAuthTag`). See `LocatorAuth`.
///
/// One implementation on purpose: a second hand-written copy of a checksum in a
/// codebase already maintaining the wire format by hand is an invitation to drift.
enum Crc16 {

    /// Firmware `kCrc16Key` — the standard initial value.
    static let initialSeed: UInt16 = 0xFFFF

    private static let poly: UInt16 = 0xA001

    static func update(_ crc: UInt16, _ byte: UInt8) -> UInt16 {
        var crc = crc ^ UInt16(byte)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ poly : crc >> 1
        }
        return crc
    }

    /// Feed a byte range into an already-running CRC (no re-seeding).
    static func accumulate<S: Sequence>(_ crc: UInt16, _ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc = crc
        for byte in bytes { crc = update(crc, byte) }
        return crc
    }
}
