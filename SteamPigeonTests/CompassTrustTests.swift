import CoreMotion
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

    // MARK: - The calibrated source (§3b on iOS)

    private func calibrated(_ magnitudeUt: Double,
                            _ accuracy: CMMagneticFieldCalibrationAccuracy = .high)
    -> CMCalibratedMagneticField {
        // Magnitude along one axis: the classifier takes the vector's length, and a
        // single axis is the clearest way to state the number being tested.
        CMCalibratedMagneticField(field: CMMagneticField(x: magnitudeUt, y: 0, z: 0),
                                  accuracy: accuracy)
    }

    /// The bands are unchanged — what changed is which sensor's number reaches them.
    func testTheCalibratedFieldIsClassifiedByTheSameBands() {
        XCTAssertEqual(.high, CalibratedField.classify(calibrated(52.3)))
        XCTAssertEqual(.low, CalibratedField.classify(calibrated(80)))
        XCTAssertEqual(.unreliable, CalibratedField.classify(calibrated(106)))
    }

    /// **The defect this exists to stop coming back.** An uncalibrated field arrives as
    /// zeros, which the gross band would read as a reading so far outside the Earth's
    /// envelope that the bearing is taken away. A source that cannot speak votes nothing.
    func testAnUncalibratedFieldVotesNothingRatherThanUnreliable() {
        XCTAssertNil(CalibratedField.classify(calibrated(0, .uncalibrated)))
        // Even carrying a plausible-looking number: the accuracy flag is the gate.
        XCTAssertNil(CalibratedField.classify(calibrated(52.3, .uncalibrated)))
    }

    /// Low and medium calibration still produce usable field values — only
    /// `.uncalibrated` is documented as unusable — so they are classified, not skipped.
    func testLowAndMediumCalibrationStillVote() {
        XCTAssertEqual(.high, CalibratedField.classify(calibrated(52.3, .low)))
        XCTAssertEqual(.high, CalibratedField.classify(calibrated(52.3, .medium)))
    }

    /// And the whole point of the change: a silent source cannot outvote a live one, so
    /// an uncalibrated field leaves the heading source deciding alone rather than
    /// dragging the verdict to unreliable.
    func testASilentFieldLeavesTheHeadingSourceDeciding() {
        XCTAssertEqual(.high, CompassTrustHold.worstOf([.high, nil]))
        XCTAssertEqual(.low, CompassTrustHold.worstOf([.low, nil]))
        XCTAssertNil(CompassTrustHold.worstOf([nil, nil]))
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
