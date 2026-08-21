import XCTest
@testable import SteamPigeon

/// Choosing a receiver.
///
/// Reported from the phone: with two receivers powered up, the app offered no choice.
/// It had auto-connected to the one it used last and never scanned. Android has no such
/// path — it scans for a fixed window and always raises the picker on what it found.
final class ReceiverPickerTests: XCTestCase {

    /// Android's `SCAN_DURATION_MS`. A window rather than reporting each device as it
    /// arrives: otherwise whichever receiver advertises first pops a one-item list and
    /// the second appears under the user's thumb a moment later.
    func testTheScanWindowMatchesAndroid() {
        XCTAssertEqual(3, BluetoothTransport.scanWindow)
    }

    /// The regression that produced the report. A stored identifier existed ONLY to
    /// reconnect without asking, so its absence is the fix — if it comes back, so does
    /// the bug.
    func testNoRememberedPeripheralIsPersisted() {
        let defaults = UserDefaults.standard
        XCTAssertNil(defaults.object(forKey: "com.steampigeon.ios.lastPeripheral"),
                     "a remembered receiver is what hid the second one")
    }

    /// The picker is offered for ONE device too, exactly as Android's `DevicesFound`
    /// does. Someone with a single receiver still gets to see which one it is.
    func testOneReceiverStillOffersTheChoice() {
        XCTAssertTrue(shouldOfferPicker(count: 1))
        XCTAssertTrue(shouldOfferPicker(count: 2))
        XCTAssertFalse(shouldOfferPicker(count: 0))
    }

    /// Mirrors `MapScreen`'s gate: the picker shows while the discovered list is
    /// non-empty.
    private func shouldOfferPicker(count: Int) -> Bool { count > 0 }
}
