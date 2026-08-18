import XCTest
@testable import SteamPigeon

/// Verifies the app's password auth matches the firmware primitives byte-for-byte.
///
/// FNV-1a mirrors `PasswordKdf.hpp` (offset 0x811c9dc5, prime 0x01000193); the
/// canonical vectors below fix that. The `auth_tag` itself uses the same CRC-16
/// (poly 0xA001) as `Communication::ComputePasswordAuthTag` over the base struct
/// with crc and `auth_tag` zeroed — exercised here by a build/verify round-trip.
///
/// Ported from `LocatorAuthTest.kt` with the **same test vectors**, per ADR "iOS
/// port — CoreBluetooth and platform parity". A silent mismatch here fails closed
/// (the locator is never authorized) or open — both bad.
final class LocatorAuthTests: XCTestCase {

    /// Kotlin fills its fixtures with `(i * k + c).toByte()`, which truncates.
    private func fixture(count: Int, _ f: (Int) -> Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: f($0)) }
    }

    /// Embed `tag` where the locator would: last 4 bytes of the base struct, LE.
    private func embed(_ tag: UInt32, into frame: inout [UInt8], baseSize: Int) {
        frame[baseSize - 4] = UInt8(truncatingIfNeeded: tag)
        frame[baseSize - 3] = UInt8(truncatingIfNeeded: tag >> 8)
        frame[baseSize - 2] = UInt8(truncatingIfNeeded: tag >> 16)
        frame[baseSize - 1] = UInt8(truncatingIfNeeded: tag >> 24)
    }

    // MARK: - Canonical FNV-1a 32-bit test vectors (FNV reference)

    func testFnvEmptyIsOffsetBasis() {
        XCTAssertEqual(0x811c_9dc5, LocatorAuth.fnv1a32(""))
    }

    func testFnvA() {
        XCTAssertEqual(0xe40c_292c, LocatorAuth.fnv1a32("a"))
    }

    func testFnvFoobar() {
        XCTAssertEqual(0xbf9c_f968, LocatorAuth.fnv1a32("foobar"))
    }

    func testBlankPasswordIsOpenKey() {
        XCTAssertEqual(0, LocatorAuth.deriveKey(""))
    }

    func testRealPasswordIsNonZero() {
        XCTAssertNotEqual(0, LocatorAuth.deriveKey("launch42"))
    }

    // MARK: - Round trips

    func testAuthTagRoundTrip() throws {
        let size = WireProtocol.prelaunchBaseStructSize
        // Frame = base struct + a few receiver-appended bytes that must be ignored.
        var frame = fixture(count: size + 25) { $0 * 7 + 3 }
        // Simulate the receiver rewriting packet_header.crc — it must not affect auth.
        frame[4] = 0x12
        frame[5] = 0x34

        let key = LocatorAuth.deriveKey("s3cret")
        let tag = try XCTUnwrap(LocatorAuth.expectedAuthTag(frame: frame, passwordKey: key, baseSize: size))
        embed(tag, into: &frame, baseSize: size)

        XCTAssertTrue(LocatorAuth.verifyFrame(frame: frame, passwordKey: key, baseSize: size))
        XCTAssertFalse(LocatorAuth.verifyFrame(frame: frame,
                                               passwordKey: LocatorAuth.deriveKey("wrong"),
                                               baseSize: size))

        // Appended receiver metadata is outside the authenticated region.
        frame[size + 5] = frame[size + 5] &+ 1
        XCTAssertTrue(LocatorAuth.verifyFrame(frame: frame, passwordKey: key, baseSize: size))
    }

    func testTelemetryAuthTagRoundTrip() throws {
        // TelemetryData carries the same trailing locator_id + auth_tag pair, so an
        // ARMED locator authenticates by the identical rule — only the base size
        // differs. This is what lets the app recognize a locator it has never heard
        // a PreLaunchData from this session.
        let size = WireProtocol.telemetryBaseStructSize
        var frame = fixture(count: size + 2) { $0 * 5 + 11 }   // + appended rssi
        frame[4] = 0x56                                        // receiver's re-CRC
        frame[5] = 0x78

        let key = LocatorAuth.deriveKey("s3cret")
        let tag = try XCTUnwrap(LocatorAuth.expectedAuthTag(frame: frame, passwordKey: key, baseSize: size))
        embed(tag, into: &frame, baseSize: size)

        XCTAssertTrue(LocatorAuth.verifyFrame(frame: frame, passwordKey: key, baseSize: size))
        XCTAssertFalse(LocatorAuth.verifyFrame(frame: frame,
                                               passwordKey: LocatorAuth.deriveKey("wrong"),
                                               baseSize: size))

        // The receiver-appended RSSI is outside the authenticated region.
        frame[size] = frame[size] &+ 1
        XCTAssertTrue(LocatorAuth.verifyFrame(frame: frame, passwordKey: key, baseSize: size))
    }

    func testOpenLocatorAuthenticatesUnderKeyZeroOnBothMessages() throws {
        // An unprovisioned locator (no password) must keep working with no prompt,
        // armed or disarmed — the backward-compatibility guarantee in the ADR.
        for size in [WireProtocol.prelaunchBaseStructSize, WireProtocol.telemetryBaseStructSize] {
            var frame = fixture(count: size + 2) { $0 * 3 + 1 }
            let tag = try XCTUnwrap(LocatorAuth.expectedAuthTag(frame: frame, passwordKey: 0, baseSize: size))
            embed(tag, into: &frame, baseSize: size)
            XCTAssertTrue(LocatorAuth.verifyFrame(frame: frame, passwordKey: 0, baseSize: size),
                          "open locator rejected at base size \(size)")
        }
    }

    func testAFrameShorterThanItsBaseStructIsRejected() {
        // A truncated frame must fail closed rather than authenticating on
        // whatever bytes happened to be present.
        let short = [UInt8](repeating: 0, count: WireProtocol.telemetryBaseStructSize - 1)
        XCTAssertFalse(LocatorAuth.verifyFrame(frame: short,
                                               passwordKey: 0,
                                               baseSize: WireProtocol.telemetryBaseStructSize))
        XCTAssertNil(LocatorAuth.expectedAuthTag(frame: short,
                                                 passwordKey: 0,
                                                 baseSize: WireProtocol.telemetryBaseStructSize))
    }

    // MARK: - Properties the Kotlin suite implies but does not state

    /// The crc bytes are excluded from the authenticated region, so rewriting them
    /// cannot change the tag. The receiver rewrites them on every relayed frame.
    func testCrcBytesAreOutsideTheAuthenticatedRegion() throws {
        let size = WireProtocol.telemetryBaseStructSize
        let base = fixture(count: size) { $0 * 11 + 2 }
        let key = LocatorAuth.deriveKey("s3cret")

        var a = base
        a[4] = 0x00; a[5] = 0x00
        var b = base
        b[4] = 0xAB; b[5] = 0xCD

        let tagA = try XCTUnwrap(LocatorAuth.expectedAuthTag(frame: a, passwordKey: key, baseSize: size))
        let tagB = try XCTUnwrap(LocatorAuth.expectedAuthTag(frame: b, passwordKey: key, baseSize: size))
        XCTAssertEqual(tagA, tagB)
    }

    /// Flipping any byte inside the authenticated region must change the tag —
    /// including the `armed` byte, which ADR-0021 requires to be authenticated.
    func testAnyByteInsideTheRegionChangesTheTag() throws {
        let size = WireProtocol.telemetryBaseStructSize
        let base = fixture(count: size) { $0 * 13 + 5 }
        let key = LocatorAuth.deriveKey("s3cret")
        let reference = try XCTUnwrap(LocatorAuth.expectedAuthTag(frame: base, passwordKey: key, baseSize: size))

        // Skip crc (4,5) and the auth_tag itself (last 4) — both are zeroed by design.
        for i in 0..<(size - 4) where i != 4 && i != 5 {
            var mutated = base
            mutated[i] = mutated[i] &+ 1
            let tag = try XCTUnwrap(LocatorAuth.expectedAuthTag(frame: mutated, passwordKey: key, baseSize: size))
            XCTAssertNotEqual(reference, tag, "byte \(i) is not covered by the auth tag")
        }
    }

    // MARK: - Vectors generated from the COMPILED firmware implementation
    //
    // Everything above is a round trip: Swift verifying Swift. That proves internal
    // consistency and would pass just as happily if this CRC had drifted from the
    // firmware's — which is exactly the silent mismatch ADR-0006 warns about, since
    // it fails closed (locator never authorizes) or open, with nothing to see.
    //
    // These values were produced by compiling the locator's real
    // `PasswordKdf.hpp` and the `Crc16Update`/`Crc16Continue` from
    // `Communication/Inc/Communication.hpp` natively with clang++ and running
    // `ComputePasswordAuthTag`'s logic over the byte patterns below.
    // They pin Swift to the firmware, not to itself.
    //
    // Regenerate (against locator `4a4202d`) if and only if the firmware auth
    // primitives change — in which case Android's copy must move in the same
    // session too.

    func testFnvMatchesCompiledFirmware() {
        XCTAssertEqual(0x811c_9dc5, LocatorAuth.fnv1a32(""))
        XCTAssertEqual(0xe40c_292c, LocatorAuth.fnv1a32("a"))
        XCTAssertEqual(0xbf9c_f968, LocatorAuth.fnv1a32("foobar"))
        XCTAssertEqual(0xd5d1_b367, LocatorAuth.deriveKey("s3cret"))
        XCTAssertEqual(0x9a0a_43ac, LocatorAuth.deriveKey("launch42"))
        XCTAssertEqual(0x0000_0000, LocatorAuth.deriveKey(""))
    }

    func testPrelaunchAuthTagMatchesCompiledFirmware() throws {
        let size = WireProtocol.prelaunchBaseStructSize   // 118
        var frame = fixture(count: size) { $0 * 7 + 3 }
        frame[4] = 0x12
        frame[5] = 0x34

        let keyed = try XCTUnwrap(LocatorAuth.expectedAuthTag(
            frame: frame, passwordKey: LocatorAuth.deriveKey("s3cret"), baseSize: size))
        XCTAssertEqual(0x5d8f_ca2a, keyed)

        let open = try XCTUnwrap(LocatorAuth.expectedAuthTag(
            frame: frame, passwordKey: 0, baseSize: size))
        XCTAssertEqual(0x3c51_3c51, open)
    }

    func testTelemetryAuthTagMatchesCompiledFirmware() throws {
        let size = WireProtocol.telemetryBaseStructSize   // 77
        var frame = fixture(count: size) { $0 * 5 + 11 }
        frame[4] = 0x56
        frame[5] = 0x78

        let keyed = try XCTUnwrap(LocatorAuth.expectedAuthTag(
            frame: frame, passwordKey: LocatorAuth.deriveKey("s3cret"), baseSize: size))
        XCTAssertEqual(0xb6d8_2929, keyed)

        let open = try XCTUnwrap(LocatorAuth.expectedAuthTag(
            frame: frame, passwordKey: 0, baseSize: size))
        XCTAssertEqual(0x4b87_4b87, open)
    }

    // MARK: - Key derivation

    /// A different password must produce a different key, and the derived key must
    /// be stable across calls (it is persisted and compared later).
    func testKeyDerivationIsStableAndPasswordDependent() {
        XCTAssertEqual(LocatorAuth.deriveKey("s3cret"), LocatorAuth.deriveKey("s3cret"))
        XCTAssertNotEqual(LocatorAuth.deriveKey("s3cret"), LocatorAuth.deriveKey("s3crey"))
    }
}
