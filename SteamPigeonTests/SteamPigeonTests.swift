import XCTest
@testable import SteamPigeon

/// Smoke test proving the unit-test target builds, links against the app target,
/// and runs. The real work lands here next, per the ADR's build order:
///
///   - `WireLayoutTests.swift`  — the THIRD copy of the wire format, pinned to the
///     same constants as the firmware `static_assert`s in `MessageProtocol.hpp`
///     and the Android `WireLayoutTest.kt`. All three change in one session.
///   - `LocatorAuthTests.swift` — ported from `LocatorAuthTest.kt` with the SAME
///     test vectors. A silent mismatch here fails closed or open; both are bad.
///
/// Neither needs hardware, which is why they come before the CoreBluetooth layer.
final class SteamPigeonTests: XCTestCase {
    func testTargetBuildsAndRuns() {
        XCTAssertTrue(true)
    }
}
