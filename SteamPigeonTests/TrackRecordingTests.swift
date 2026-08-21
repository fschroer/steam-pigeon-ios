import XCTest
@testable import SteamPigeon

/// When the recorded track starts, stops, and is thrown away.
///
/// Ported from Android's `PathDedupTest`, `LandingPathFreezeTest` and `NewFlightResetTest`.
/// These rules decide whether the one place the user is walking to gets drawn, and every
/// one of them is a rule rather than a rendering detail.
final class TrackRecordingTests: XCTestCase {

    // MARK: - Dedup

    /// In flight the locator transmits at ~5 Hz while its position payload refreshes at
    /// ~1 Hz, so about five consecutive frames repeat one fix. Drop exactly those.
    func testAnIdenticalFixIsARepeatAndTheFirstIsNot() {
        let p = TrackPoint(latitude: 47.6146, longitude: -122.5526, altitudeM: 100,
                           timestampMs: 1_700_000_000_000)
        XCTAssertFalse(TrackRecording.repeatsFix(nil, latitude: p.latitude,
                                                 longitude: p.longitude, altitudeM: 100))
        XCTAssertTrue(TrackRecording.repeatsFix(p, latitude: p.latitude,
                                                longitude: p.longitude, altitudeM: 100))
    }

    /// The risk on the other side is silently swallowing real slow movement, which is
    /// what a descent under canopy looks like. A sub-metre step is NOT a repeat.
    func testATinyRealMovementIsNotARepeat() {
        let p = TrackPoint(latitude: 47.6146, longitude: -122.5526, altitudeM: 100,
                           timestampMs: 1)
        XCTAssertFalse(TrackRecording.repeatsFix(p, latitude: 47.614601,
                                                 longitude: -122.5526, altitudeM: 100))
        XCTAssertFalse(TrackRecording.repeatsFix(p, latitude: p.latitude,
                                                 longitude: p.longitude, altitudeM: 99))
    }

    // MARK: - What records

    /// Nothing is recorded on the pad. This is what keeps GPS noise from scribbling
    /// before launch — not a minimum-separation filter.
    func testNothingRecordsWhileWaitingOnThePad() {
        XCTAssertFalse(TrackRecording.recordsPathPoint(state: .waitingLaunch,
                                                       landingConcluded: false,
                                                       landedStatusReceived: false))
    }

    func testAirborneRecords() {
        for state in [FlightStates.launched, .burnout, .noseover, .mainPrimaryEvent] {
            XCTAssertTrue(TrackRecording.recordsPathPoint(state: state, landingConcluded: false,
                                                          landedStatusReceived: false))
        }
    }

    /// Once the app infers the landing, what arrives is a rocket settling in the grass
    /// and a fix wandering around it — a scribble over the spot being walked to.
    func testAnInferredLandingFreezesTheTrack() {
        XCTAssertFalse(TrackRecording.recordsPathPoint(state: .mainPrimaryEvent,
                                                       landingConcluded: true,
                                                       landedStatusReceived: false))
    }

    /// But the locator's own Landed fix outranks anything inferred — it is its account
    /// of where the rocket is lying, and an inference made before a dropout can end the
    /// track short of where it actually came down.
    func testTheLocatorsOwnLandedFixStillDraws() {
        XCTAssertTrue(TrackRecording.recordsPathPoint(state: .landed, landingConcluded: true,
                                                      landedStatusReceived: false))
    }

    /// And that fix is the end of it. The hours of fixes it goes on sending are not flight.
    func testAfterLandedNothingElseRecords() {
        for state in [FlightStates.landed, .waitingLaunch, .mainPrimaryEvent] {
            XCTAssertFalse(TrackRecording.recordsPathPoint(state: state, landingConcluded: true,
                                                           landedStatusReceived: true))
        }
    }

    // MARK: - Landing inference

    func testLandingIsImminentBelowTheAltitudeFloorWhateverTheRate() {
        XCTAssertTrue(TrackRecording.landingImminent(aglM: 10, descentRateMs: 0))
    }

    func testLandingIsImminentWhenTouchdownIsSecondsAway() {
        XCTAssertTrue(TrackRecording.landingImminent(aglM: 40, descentRateMs: 20))
        XCTAssertFalse(TrackRecording.landingImminent(aglM: 400, descentRateMs: 5))
    }

    /// A rate near zero is noise or a rocket that is not descending, not a landing about
    /// to happen — it must not divide out to "about to touch down".
    func testANearZeroDescentRateIsNotALanding() {
        XCTAssertEqual(Float.greatestFiniteMagnitude,
                       TrackRecording.timeToGroundSeconds(aglM: 500, descentRateMs: 0))
        XCTAssertFalse(TrackRecording.landingImminent(aglM: 500, descentRateMs: 0.5))
    }

    /// Only after noseover. A rocket 10 m up on the way UP is not landing.
    func testAscentIsNeverALanding() {
        XCTAssertFalse(TrackRecording.landingConcluded(state: .launched, aglM: 10, descentRateMs: 0))
        XCTAssertTrue(TrackRecording.landingConcluded(state: .mainPrimaryEvent, aglM: 10,
                                                      descentRateMs: 0))
    }

    // MARK: - New flight

    /// ANY grounded → airborne transition, so losing the whole boost window does not
    /// leave the last flight's track drawn under the one now in the air.
    func testAnyGroundedToAirborneStartsANewFlight() {
        XCTAssertTrue(TrackRecording.startsNewFlight(previous: .waitingLaunch, current: .launched))
        XCTAssertTrue(TrackRecording.startsNewFlight(previous: .landed, current: .noseover))
        XCTAssertFalse(TrackRecording.startsNewFlight(previous: .launched, current: .burnout))
    }

    /// `noSignal` is what an unrecognised state byte decodes to. Treating it as grounded
    /// would make the next real packet look like a launch and wipe the flight in the air.
    func testNoSignalIsNotGrounded() {
        XCTAssertFalse(FlightStates.noSignal.isGrounded)
        XCTAssertFalse(TrackRecording.startsNewFlight(previous: .noSignal, current: .launched))
    }

    // MARK: - The recorder

    /// The first packet after a restart must not be read as a launch — otherwise an app
    /// restarted mid-flight erases the track of the flight it just rejoined.
    func testTheFirstObservedStateIsNeverALaunch() {
        var r = TrackRecorder()
        XCTAssertEqual(.record, r.observe(state: .launched, aglM: 100, descentRateMs: -50))
    }

    func testASecondFlightClearsTheFirst() {
        var r = TrackRecorder()
        _ = r.observe(state: .waitingLaunch, aglM: 0, descentRateMs: 0)
        XCTAssertEqual(.newFlight(record: true),
                       r.observe(state: .launched, aglM: 5, descentRateMs: -50))
    }

    /// The two fixes that end a flight are drawn, and then it stops — the whole sequence
    /// in order, because the flags are read before they are set for exactly this.
    func testTheEndOfAFlightDrawsThenStops() {
        var r = TrackRecorder()
        _ = r.observe(state: .waitingLaunch, aglM: 0, descentRateMs: 0)
        _ = r.observe(state: .launched, aglM: 50, descentRateMs: -60)

        // Descending, touchdown seconds away: this fix is the lowest known position and
        // the most useful point on the track, so it draws — and freezes what follows.
        XCTAssertEqual(.record, r.observe(state: .mainPrimaryEvent, aglM: 10, descentRateMs: 5))
        XCTAssertEqual(.skip, r.observe(state: .mainPrimaryEvent, aglM: 8, descentRateMs: 5))
        // The locator's own account outranks the inference.
        XCTAssertEqual(.record, r.observe(state: .landed, aglM: 0, descentRateMs: 0))
        XCTAssertEqual(.skip, r.observe(state: .landed, aglM: 0, descentRateMs: 0))
    }

    // MARK: - Surviving the app being killed

    /// Reported 2026-08-21: a track persisted to disk did not survive reopening the app.
    ///
    /// The app enters `.scanning` within a second of launching, and the handler for that
    /// cleared the readouts — reasonably — **and the track with them**, so the array
    /// restored in `init` was emptied before the map drew it. The next recorded point
    /// then saved the empty array back over the file, so the loss was permanent rather
    /// than merely on screen. The track describes the rocket, not the receiver relaying
    /// it; Android's connection state does not touch `_flightPath` at all.
    @MainActor
    func testARestoredTrackSurvivesTheLaunchScan() {
        let store = TrackStore()
        defer { store.delete() }
        store.save([TrackPoint(latitude: 47.6146, longitude: -122.5526,
                               altitudeM: 100, timestampMs: 1_700_000_000_000),
                    TrackPoint(latitude: 47.6147, longitude: -122.5527,
                               altitudeM: 140, timestampMs: 1_700_000_001_000)])

        let m = LinkViewModel()
        XCTAssertEqual(2, m.track.count, "the track is restored at launch")

        // Exactly what the first scan of a new session runs.
        m.clearLiveReadoutsForTesting()

        XCTAssertEqual(2, m.track.count, "a lost link says nothing about where the rocket went")
        XCTAssertEqual(2, TrackStore().load().count, "and the file is still there to reload")
    }

    /// The other half of the rule: what a lost link DOES invalidate still goes. These are
    /// readouts of a receiver the app is no longer talking to.
    @MainActor
    func testALostLinkStillDropsWhatDescribesTheLink() {
        let m = LinkViewModel()
        m.clearLiveReadoutsForTesting()
        XCTAssertNil(m.prelaunch)
        XCTAssertNil(m.telemetry)
        XCTAssertNil(m.vector)
        XCTAssertNil(m.connectedLocatorId)
        XCTAssertFalse(m.armed)
    }

    /// A manual reset re-arms even mid-descent: a cleared track that then refused to
    /// draw would look broken.
    func testResetResumesRecording() {
        var r = TrackRecorder()
        _ = r.observe(state: .waitingLaunch, aglM: 0, descentRateMs: 0)
        _ = r.observe(state: .launched, aglM: 50, descentRateMs: -60)
        _ = r.observe(state: .landed, aglM: 0, descentRateMs: 0)
        XCTAssertEqual(.skip, r.observe(state: .landed, aglM: 0, descentRateMs: 0))
        r.reset()
        XCTAssertEqual(.record, r.observe(state: .landed, aglM: 0, descentRateMs: 0))
    }
}
