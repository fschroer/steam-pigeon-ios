import XCTest
@testable import SteamPigeon

/// Which track the map draws, and how long a downloaded record survives.
///
/// The conversion is pinned in `ArchivedPathTests`; this is the half that is easy to build
/// wrongly, because the obvious implementation works right up until you leave the chart —
/// which is the one moment the feature exists for.
@MainActor
final class ArchivedPathSourceTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ArchivedPathSourceTests.\(UUID().uuidString)")!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        defaults = nil
        super.tearDown()
    }

    private func model() -> LinkViewModel { LinkViewModel(defaults: defaults) }

    /// A short archived record with a usable fix throughout.
    private func record(_ n: Int = 40) -> [FlightSample] {
        (0..<n).map { i in
            FlightSample(timestampMs: i * 50,
                         altitudeM: Float(i) * 10,
                         accel: Vec3f(x: 0, y: 0, z: 0),
                         gyro: Vec3f(x: 0, y: 0, z: 0),
                         latRad: 47.6146 * .pi / 180 + Double(i) * 1e-7,
                         lonRad: -122.5526 * .pi / 180)
        }
    }

    // MARK: - Source selection

    func testTheMapDrawsTheLiveTrackUntilTheArchivedOneIsAskedFor() {
        let m = model()
        m.publishArchivedPathForTesting(record())
        XCTAssertFalse(m.archivedTrack.isEmpty, "precondition: a record is loaded")
        XCTAssertTrue(m.mapTrack.isEmpty, "the live track is empty, and that is what shows")

        m.toggleArchivedPath()
        XCTAssertEqual(m.archivedTrack, m.mapTrack)
    }

    /// The archived track SUBSTITUTES for the live one rather than drawing alongside it:
    /// they are the same quantity measured two ways, so overlaying them in one colour would
    /// read as a single noisy path rather than two estimates.
    func testTheArchivedTrackSubstitutesRatherThanOverlays() {
        let m = model()
        m.publishArchivedPathForTesting(record())
        m.toggleArchivedPath()
        XCTAssertEqual(m.archivedTrack.count, m.mapTrack.count)
    }

    /// A toggle with nothing downloaded must not blank the map. The control is hidden in
    /// that state, but the fallback is what makes hiding it a presentation choice rather
    /// than the only thing standing between the user and an empty screen.
    func testAskingForAnArchivedTrackThatIsNotThereFallsBackToLive() {
        let m = model()
        m.toggleArchivedPath()
        XCTAssertTrue(m.showArchivedPath)
        XCTAssertEqual(m.track, m.mapTrack)
    }

    // MARK: - Lifetime

    /// **The trap.** `clearFlightProfileData` runs when you navigate back from the chart,
    /// which is exactly the moment you would be heading to the map to look at the track. A
    /// snapshot derived from the transfer buffer — or cleared alongside it — is empty by the
    /// time the map is on screen, and the feature silently does nothing.
    func testLeavingTheChartDoesNotDiscardTheDownloadedRecord() {
        let m = model()
        m.publishArchivedPathForTesting(record())
        let loaded = m.archivedTrack
        XCTAssertFalse(loaded.isEmpty)

        m.clearFlightProfileData()

        XCTAssertTrue(m.flightSamples.isEmpty, "the transfer buffer is cleared, as it should be")
        XCTAssertEqual(loaded, m.archivedTrack, "but the map's snapshot must outlive the chart")
    }

    /// Reset is the map's "start clean" control, and leaving a downloaded track drawn after
    /// it would look like the reset had failed.
    func testResetClearsTheArchivedTrackAndFallsBackToLive() {
        let m = model()
        m.publishArchivedPathForTesting(record())
        m.toggleArchivedPath()
        XCTAssertTrue(m.showArchivedPath)

        m.resetTrack()

        XCTAssertTrue(m.archivedTrack.isEmpty)
        XCTAssertFalse(m.showArchivedPath)
    }

    /// The same trap, one layer down. `publishFlightSamples` runs on every absorbed packet,
    /// and leaving the chart empties the transfer buffer — so a single late packet arriving
    /// afterwards must not blank the snapshot.
    func testALatePacketAfterLeavingTheChartDoesNotBlankTheSnapshot() {
        let m = model()
        m.publishArchivedPathForTesting(record())
        let loaded = m.archivedTrack
        m.clearFlightProfileData()

        // What a late packet does: republish whatever the (now empty) buffer holds.
        m.publishArchivedPathForTesting([])

        XCTAssertEqual(loaded, m.archivedTrack)
    }

    /// A second record replaces the first rather than appending to it.
    func testANewRecordReplacesTheSnapshot() {
        let m = model()
        m.publishArchivedPathForTesting(record(40))
        m.publishArchivedPathForTesting(record(10))
        XCTAssertEqual(10, m.archivedTrack.count)
    }

    /// A record whose samples never carried a position leaves nothing to draw, so the
    /// control stays hidden rather than offering an empty track.
    func testARecordWithNoUsablePositionYieldsNoArchivedTrack() {
        let m = model()
        let fixless = (0..<20).map { i in
            FlightSample(timestampMs: i * 50, altitudeM: Float(i),
                         accel: Vec3f(x: 0, y: 0, z: 0), gyro: Vec3f(x: 0, y: 0, z: 0),
                         latRad: 0, lonRad: 0)
        }
        m.publishArchivedPathForTesting(fixless)
        XCTAssertTrue(m.archivedTrack.isEmpty)
    }
}
