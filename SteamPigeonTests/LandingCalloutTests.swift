import XCTest
@testable import SteamPigeon

/// When the app decides the rocket has landed. Ported from Android's
/// `LandingCalloutTest`, case for case.
///
/// The case that matters is the one observed in the field: the link dies in the last few
/// hundred metres, because that is where line of sight to a rocket across a field runs
/// out, and it does not come back until someone walks toward it. A landing callout that
/// waits to *hear* the touchdown therefore almost never fires — which is the bug these
/// tests exist to keep fixed.
///
/// The opposing risk is real too: concluding a flight is not a decision that can be taken
/// back, so a routine dropout must not trigger it.
final class LandingCalloutTests: XCTestCase {

    func testTimeToGroundIsAltitudeOverRate() {
        XCTAssertEqual(20, FlightAnnouncer.timeToGroundSeconds(aglM: 100, descentRateMs: 5),
                       accuracy: 1e-3)
    }

    /// Ascending, hovering, or noise around zero: dividing by it would produce a huge or
    /// negative time, and treating either as a landing would end the flight while the
    /// rocket is still climbing.
    func testANegligibleDescentRateNeverPredictsAGround() {
        for rate in [Float(0), -30, 0.5] {
            XCTAssertEqual(.greatestFiniteMagnitude,
                           FlightAnnouncer.timeToGroundSeconds(aglM: 100, descentRateMs: rate))
        }
    }

    func testLandingIsImminentNearTheGroundOrSecondsFromIt() {
        XCTAssertTrue(FlightAnnouncer.landingImminent(aglM: 20, descentRateMs: 5),
                      "below the altitude floor")
        XCTAssertTrue(FlightAnnouncer.landingImminent(aglM: 10, descentRateMs: 5),
                      "two seconds out")
        XCTAssertFalse(FlightAnnouncer.landingImminent(aglM: 300, descentRateMs: 5),
                       "still under canopy at 300 m")
    }

    /// 3 s gaps happen constantly. At 300 m under a main there is a minute of flight left,
    /// and calling it landed here would suppress every callout for the rest of a flight
    /// still in progress.
    func testARoutineDropoutDoesNotConcludeTheFlight() {
        for age in [TimeInterval(3), 10, 30] {
            XCTAssertFalse(FlightAnnouncer.landedThroughBlackout(aglM: 300, descentRateMs: 5,
                                                                 messageAge: age))
        }
    }

    /// The fix: link lost at 300 m descending 5 m/s — 60 s to the ground. The app hears
    /// nothing more, and must conclude the landing on its own.
    func testTheRocketIsDownOnceItHasHadTimeToGetThere() {
        XCTAssertFalse(FlightAnnouncer.landedThroughBlackout(aglM: 300, descentRateMs: 5,
                                                             messageAge: 59), "too early at 59 s")
        XCTAssertTrue(FlightAnnouncer.landedThroughBlackout(aglM: 300, descentRateMs: 5,
                                                            messageAge: 61), "landed by 61 s")
    }

    /// Lost at 40 m: under 10 s of flight left, so the blackout floor governs rather than
    /// the descent time.
    func testALinkLostLowStillConcludesQuickly() {
        XCTAssertFalse(FlightAnnouncer.landedThroughBlackout(aglM: 40, descentRateMs: 5,
                                                             messageAge: 4))
        XCTAssertTrue(FlightAnnouncer.landedThroughBlackout(aglM: 40, descentRateMs: 5,
                                                            messageAge: 9))
    }

    /// Below the altitude threshold the last known position IS the landing site, so only
    /// the dropout floor has to elapse.
    func testALinkLostAlreadyOnTheGroundConcludesAtTheFloor() {
        XCTAssertFalse(FlightAnnouncer.landedThroughBlackout(aglM: 10, descentRateMs: 5,
                                                             messageAge: 4))
        XCTAssertTrue(FlightAnnouncer.landedThroughBlackout(aglM: 10, descentRateMs: 5,
                                                            messageAge: 5))
    }

    /// Lost at apogee, 3000 m, descending 25 m/s under drogue: 120 s. The callout has to
    /// wait it out rather than firing on the dropout alone — announcing a landing two
    /// minutes early would send the user walking to a point the rocket has not reached.
    func testABlackoutFromHighUnderDrogueTakesTheWholeDescent() {
        XCTAssertFalse(FlightAnnouncer.landedThroughBlackout(aglM: 3000, descentRateMs: 25,
                                                             messageAge: 30))
        XCTAssertFalse(FlightAnnouncer.landedThroughBlackout(aglM: 3000, descentRateMs: 25,
                                                             messageAge: 119))
        XCTAssertTrue(FlightAnnouncer.landedThroughBlackout(aglM: 3000, descentRateMs: 25,
                                                            messageAge: 121))
    }

    /// No descent rate to reckon with (hung in a tree, or the last packet caught it at a
    /// rate near zero). Silence is correct: the app has no basis for saying where or
    /// whether it came down.
    func testABlackoutWithNoUsableDescentRateNeverConcludes() {
        XCTAssertFalse(FlightAnnouncer.landedThroughBlackout(aglM: 500, descentRateMs: 0,
                                                             messageAge: 600))
    }
}
