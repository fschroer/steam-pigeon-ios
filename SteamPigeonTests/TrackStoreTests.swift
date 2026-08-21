import XCTest
@testable import SteamPigeon

/// The track on disk.
///
/// The app is killed — it is in a pocket, in a field, being switched between while
/// someone walks — and losing the track of the flight you are walking toward is the
/// worst moment to lose it.
final class TrackStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testARoundTrip() {
        let store = TrackStore(directory: dir)
        let points = [
            TrackPoint(latitude: 47.6146, longitude: -122.5526, altitudeM: 0, timestampMs: 1),
            TrackPoint(latitude: 47.6150, longitude: -122.5520, altitudeM: 312.5, timestampMs: 2),
        ]
        store.save(points)
        XCTAssertEqual(points, store.load())
    }

    func testNoFileIsAnEmptyTrackRatherThanAFailure() {
        XCTAssertEqual([], TrackStore(directory: dir).load())
    }

    func testDeleteClearsIt() {
        let store = TrackStore(directory: dir)
        store.save([TrackPoint(latitude: 1, longitude: 2, altitudeM: 3, timestampMs: 4)])
        store.delete()
        XCTAssertEqual([], store.load())
    }

    /// Android's three-column rows predate capture times. They still load, with a
    /// synthetic timestamp kept monotonic so it cannot look like a clock that ran
    /// backwards.
    func testLegacyThreeColumnRowsLoad() throws {
        let file = dir.appendingPathComponent("flight_path.csv")
        try "47.0,-122.0,10.0\n47.1,-122.1,20.0".write(to: file, atomically: true, encoding: .utf8)
        let loaded = TrackStore(directory: dir).load()
        XCTAssertEqual(2, loaded.count)
        XCTAssertEqual(47.1, loaded[1].latitude)
        XCTAssertLessThan(loaded[0].timestampMs, loaded[1].timestampMs)
    }

    /// A truncated write — the app killed mid-save — must cost the bad row, not the
    /// whole track.
    func testAMalformedRowIsSkippedRatherThanLosingTheTrack() throws {
        let file = dir.appendingPathComponent("flight_path.csv")
        try "47.0,-122.0,10.0,1\nrubbish\n47.2,-122.2,30.0,3"
            .write(to: file, atomically: true, encoding: .utf8)
        let loaded = TrackStore(directory: dir).load()
        XCTAssertEqual(2, loaded.count)
        XCTAssertEqual(47.2, loaded[1].latitude)
    }
}
