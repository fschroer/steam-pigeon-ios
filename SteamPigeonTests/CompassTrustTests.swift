import XCTest
@testable import SteamPigeon

/// ADR-0023 §3b and §4. Arithmetic rather than a vendor's opinion, which is exactly
/// why this part is testable at all.
final class CompassTrustTests: XCTestCase {

    // MARK: - Bands

    func testRestingFieldReadsHigh() {
        // Measured resting magnitudes from the ADR: 52.3–53.2 and ≤50 µT.
        XCTAssertEqual(.high, FieldMagnitude.classify(magnitudeUt: 52.3))
        XCTAssertEqual(.high, FieldMagnitude.classify(magnitudeUt: 53.2))
        XCTAssertEqual(.high, FieldMagnitude.classify(magnitudeUt: 50))
    }

    func testEarthEnvelopeBoundsAreInclusive() {
        XCTAssertEqual(.high, FieldMagnitude.classify(magnitudeUt: 20))
        XCTAssertEqual(.high, FieldMagnitude.classify(magnitudeUt: 70))
    }

    func testJustOutsideTheEnvelopeRaisesThePromptButDoesNotSuppress() {
        XCTAssertEqual(.low, FieldMagnitude.classify(magnitudeUt: 19.9))
        XCTAssertEqual(.low, FieldMagnitude.classify(magnitudeUt: 70.1))
        XCTAssertEqual(.low, FieldMagnitude.classify(magnitudeUt: 99))
    }

    func testGrossReadingsAreUnreliable() {
        XCTAssertEqual(.unreliable, FieldMagnitude.classify(magnitudeUt: 9.9))
        XCTAssertEqual(.unreliable, FieldMagnitude.classify(magnitudeUt: 101))
        XCTAssertEqual(.unreliable, FieldMagnitude.classify(magnitudeUt: 0))
    }

    /// A magnet swept around a phone peaked at ~106 µT and crossed all three bands.
    /// That measurement is what turned the envelope from a guess into a bound.
    func testMeasuredMagnetPeakIsDetected() {
        XCTAssertEqual(.unreliable, FieldMagnitude.classify(magnitudeUt: 106))
    }

    // MARK: - Hold (§4)

    func testDegradationIsImmediate() {
        var h = CompassTrustHold()
        XCTAssertEqual(.unreliable, h.update(.unreliable), "a warning must never wait")
    }

    func testRecoveryWaitsThreeSeconds() {
        var h = CompassTrustHold()
        let t = Date()
        _ = h.update(.unreliable, now: t)
        XCTAssertEqual(.unreliable, h.update(.high, now: t.addingTimeInterval(2.9)))
        XCTAssertEqual(.high, h.update(.high, now: t.addingTimeInterval(3.0)))
    }

    /// The 30 ms chatter under a real magnet must not flicker the warning off.
    func testChatterDoesNotFlickerTheWarning() {
        var h = CompassTrustHold()
        var t = Date()
        for _ in 0..<50 {
            t = t.addingTimeInterval(0.03)
            _ = h.update(.high, now: t)
            XCTAssertEqual(.unreliable, h.update(.unreliable, now: t))
        }
    }

    func testCleanRunNeverWarns() {
        var h = CompassTrustHold()
        var t = Date()
        for _ in 0..<100 {
            t = t.addingTimeInterval(0.1)
            XCTAssertEqual(.high, h.update(.high, now: t))
        }
    }

    // MARK: - worst-of

    func testPessimisticReadingWins() {
        XCTAssertEqual(.unreliable, CompassTrustHold.worstOf([.high, .unreliable]))
        XCTAssertEqual(.low, CompassTrustHold.worstOf([.high, .low]))
    }

    /// A source that has never reported must contribute NOTHING, not `high` — that
    /// silent-sensor-votes-healthy bug was reintroduced twice on different hardware.
    func testSilentSourceCannotOutvoteALiveOne() {
        XCTAssertEqual(.unreliable, CompassTrustHold.worstOf([nil, .unreliable]))
        XCTAssertEqual(.low, CompassTrustHold.worstOf([.low, nil]))
    }

    func testNoLiveSourcesYieldsNoVerdict() {
        XCTAssertNil(CompassTrustHold.worstOf([nil, nil]))
    }

    /// Only UNRELIABLE suppresses. Suppressing at LOW would take the bearing away in
    /// ordinary use — the ADR reached LOW simply by sitting next to a laptop.
    func testOnlyUnreliableSuppresses() {
        XCTAssertTrue(CompassTrust.low > .unreliable)
        XCTAssertTrue(CompassTrust.high > .low)
    }
}
