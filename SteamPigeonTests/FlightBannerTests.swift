import XCTest
import SwiftUI
@testable import SteamPigeon

/// The centre-of-map banner.
///
/// Composed exactly as Android composes it, and tested because the composition is the
/// part with rules: two independent lines, an escalation that REPLACES rather than
/// adds, and a pulse that must stay off for the ordinary states.
final class FlightBannerTests: XCTestCase {

    private func text(padAlert: PadAlertState = .quiet, snooze: Int = 0,
                      armed: Bool = false, gps: Bool = true) -> String? {
        FlightBanner.text(padAlert: padAlert, snoozeMinutes: snooze,
                          armed: armed, locatorGpsLock: gps)
    }

    /// The observation that started this: a disarmed locator showed nothing at all.
    func testADisarmedRocketSaysSo() {
        XCTAssertEqual("Disarmed", text(armed: false, gps: true))
    }

    /// An armed rocket with a fix has nothing wrong with it, so the banner is absent
    /// rather than empty — an empty Text still takes layout in the middle of the map.
    func testAnArmedRocketWithAFixSaysNothing() {
        XCTAssertNil(text(armed: true, gps: true))
    }

    func testNoGpsIsReportedIndependentlyOfArming() {
        XCTAssertEqual("No GPS", text(armed: true, gps: false))
        XCTAssertEqual("Disarmed\nNo GPS", text(armed: false, gps: false))
    }

    // MARK: - Escalation

    /// The pad alert REPLACES "Disarmed" rather than adding to it: it is the same fact
    /// escalated, and saying it twice reads as two faults.
    func testThePadAlertReplacesTheDisarmedLine() {
        let banner = try? XCTUnwrap(text(padAlert: .alerting, armed: false))
        XCTAssertTrue(banner!.contains("ROCKET ON PAD — NOT ARMED"))
        XCTAssertFalse(banner!.contains("Disarmed"))
        XCTAssertTrue(banner!.contains("tap top panel to snooze"),
                      "the banner has to say how to silence it")
    }

    /// Snoozed is shown distinctly, with the minutes remaining. A silenced locator that
    /// looks identical to a healthy one is the failure ADR-0021 started from.
    func testSnoozedShowsTheMinutesRemaining() {
        XCTAssertEqual("NOT ARMED — alert snoozed 10 min",
                       text(padAlert: .snoozed, snooze: 10, armed: false))
    }

    func testEscalationStillReportsAMissingFix() {
        XCTAssertEqual("NOT ARMED — alert snoozed 5 min\nNo GPS",
                       text(padAlert: .snoozed, snooze: 5, armed: false, gps: false))
    }

    // MARK: - Colour and pulse

    func testColourEscalates() {
        XCTAssertEqual(Color.red, FlightBanner.color(padAlert: .alerting))
        XCTAssertEqual(Color.yellow, FlightBanner.color(padAlert: .snoozed))
        XCTAssertEqual(Color.white, FlightBanner.color(padAlert: .quiet))
    }

    /// Only an escalated banner pulses. A disarmed rocket and a missing fix are the
    /// states the app sits in for most of its working life, and pulsing through all of
    /// it trains the eye to ignore the thing the escalation needs it to notice.
    func testOnlyAnEscalatedBannerPulses() {
        XCTAssertFalse(FlightBanner.pulses(padAlert: .quiet))
        XCTAssertTrue(FlightBanner.pulses(padAlert: .alerting))
        XCTAssertTrue(FlightBanner.pulses(padAlert: .snoozed))
    }

    // MARK: - Wire decode this rests on

    /// An unrecognised byte must never present as "nothing wrong".
    func testAnUnknownAlertByteIsNotQuiet() {
        XCTAssertEqual(.quiet, PadAlertState.from(0))
        XCTAssertEqual(.alerting, PadAlertState.from(1))
        XCTAssertEqual(.snoozed, PadAlertState.from(2))
        XCTAssertEqual(.snoozed, PadAlertState.from(200))
    }

    func testSnoozeMinutesDecode() {
        XCTAssertEqual(0, PadAlertState.snoozeMinutes(1))
        XCTAssertEqual(0, PadAlertState.snoozeMinutes(2))
        XCTAssertEqual(13, PadAlertState.snoozeMinutes(15))
    }
}
