import SwiftUI
import XCTest
@testable import SteamPigeon

/// The status panel's rocket glyph is the only place on the map that says whether the
/// locator is **armed**, and it says it in colour alone. Reported from the phone on
/// 2026-08-23: it was tinted by GPS fix quality instead — `gpsStatus == .ok ? primary :
/// tertiary` — so it looked the same armed and disarmed, and changed for a reason
/// Android never changes it for.
///
/// Android, `FlightMapScreen.kt:2198`:
///
/// ```kotlin
/// val rocketIconTint = when {
///     armCommandPending -> if (!armedState) Color.Green else Color.White
///     armedState        -> Color.Green
///     else              -> Color.White
/// }
/// ```
final class RocketIconTintTests: XCTestCase {

    private let green = Color(hex: 0x00FF00)
    private let white = Color(hex: 0xFFFFFF)

    func testGreenMeansArmedAndWhiteMeansNot() {
        XCTAssertEqual(green, MapStatusPanel.rocketTint(armed: true,  pending: false))
        XCTAssertEqual(white, MapStatusPanel.rocketTint(armed: false, pending: false))
    }

    /// While a command is in flight the icon shows the colour it is heading FOR, so the
    /// blink reads as "taken" rather than as the state it is leaving.
    func testAPendingCommandShowsTheTargetColourNotTheCurrentOne() {
        XCTAssertEqual(green, MapStatusPanel.rocketTint(armed: false, pending: true),
                       "arming a disarmed locator blinks toward green")
        XCTAssertEqual(white, MapStatusPanel.rocketTint(armed: true, pending: true),
                       "disarming an armed locator blinks toward white")
    }

    /// Compose's `Color.Green` is pure #00FF00. SwiftUI's `.green` is the adaptive
    /// system green (#34C759 in light mode), which is a different colour on the panel.
    func testTheGreenIsComposesGreenNotTheSystemGreen() {
        XCTAssertNotEqual(Color.green, MapStatusPanel.rocketTint(armed: true, pending: false))
    }
}
