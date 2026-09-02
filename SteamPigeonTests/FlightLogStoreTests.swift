import XCTest
@testable import SteamPigeon

/// The storage half, which is the part with no Android counterpart to copy.
///
/// Android answers "where do these live and how do they leave" with `filesDir` and a
/// `FileProvider`; iOS answers it with Application Support and a share sheet. The listing
/// order, the view cap and the path guard are shared requirements, and the filename parsing
/// is a reimplementation — which is exactly the code worth pinning.
final class FlightLogStoreTests: XCTestCase {

    private var container: URL!
    private var store: FlightLogStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlightLogStoreTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        store = FlightLogStore(container: container)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
        container = nil
        store = nil
        try super.tearDownWithError()
    }

    private func write(_ name: String, rows: [String] = ["a", "b"]) {
        let dir = container.appendingPathComponent(FlightLogStore.dirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = ([FlightLog.csvHeader] + rows).joined(separator: "\n") + "\n"
        try? body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - Listing

    /// Ordered by the CAPTURE TIME in the name rather than by mtime: mtime moves when a
    /// log is appended to, so an old flight still open through a long recovery would sort
    /// above a newer one that had already closed. The older file is touched last here, so
    /// mtime order is the opposite of the right answer.
    func testLogsAreListedNewestFirstByNameNotByModificationTime() {
        write("Pigeon_2025-08-24_014640.csv")
        write("Pigeon_2025-08-25_101500.csv")
        // Touch the OLDER file last, so mtime order is the opposite of name order.
        write("Pigeon_2025-08-24_014640.csv", rows: ["a", "b", "c"])

        XCTAssertEqual(["Pigeon_2025-08-25_101500.csv", "Pigeon_2025-08-24_014640.csv"],
                       store.list().map(\.name))
    }

    /// The defect this pair of files found. Sorting the whole filename is locator-major,
    /// because the name begins with the locator — so yesterday's `Twist_Lock_5` listed
    /// above today's `Kestrel`. Both platforms did it until 2026-09-01.
    func testNewestFirstAcrossDifferentLocators() {
        write("Kestrel_2025-08-24_014640.csv")          // newer
        write("Twist_Lock_5_2025-08-23_183012.csv")     // older, and used to sort first

        XCTAssertEqual(["Kestrel_2025-08-24_014640.csv", "Twist_Lock_5_2025-08-23_183012.csv"],
                       store.list().map(\.name))
    }

    /// A name that does not parse did not come from this recorder. Note that a naive sort
    /// on `capturedAt` would put it FIRST, since its stem starts with a letter and letters
    /// sort above digits descending — which is why the key is separate from the label.
    func testAnUnparseableNameSortsLastNotFirst() {
        write("Kestrel_2025-08-24_014640.csv")
        write("whatever.csv")

        XCTAssertEqual(["Kestrel_2025-08-24_014640.csv", "whatever.csv"],
                       store.list().map(\.name))
    }

    /// Deterministic rather than input-order dependent, for two logs captured in the same
    /// second by different airframes.
    func testOrderingIsStableForTwoLogsInTheSameSecond() {
        let a = FlightLogFile(name: "Alpha_2025-08-24_014640.csv", sizeBytes: 1,
                              modified: .distantPast)
        let b = FlightLogFile(name: "Bravo_2025-08-24_014640.csv", sizeBytes: 1,
                              modified: .distantPast)
        XCTAssertEqual([a, b].sortedNewestFirst(), [b, a].sortedNewestFirst())
    }

    /// The key is fixed-width and zero-padded, so string order IS chronological order and
    /// nothing has to parse a date to sort.
    func testCaptureKeysSortChronologicallyAsPlainStrings() {
        let keys = ["Rocket_2025-01-02_000000.csv",
                    "Rocket_2025-01-10_000000.csv",
                    "Rocket_2025-01-02_235959.csv"]
            .compactMap { FlightLogFile(name: $0, sizeBytes: 1, modified: .distantPast).captureKey }
        XCTAssertEqual(["2025-01-02_000000", "2025-01-02_235959", "2025-01-10_000000"],
                       keys.sorted())
    }

    func testOnlyCsvFilesAreListed() {
        write("Pigeon_2025-08-24_014640.csv")
        let dir = container.appendingPathComponent(FlightLogStore.dirName, isDirectory: true)
        try? "junk".write(to: dir.appendingPathComponent("notes.txt"),
                          atomically: true, encoding: .utf8)
        XCTAssertEqual(["Pigeon_2025-08-24_014640.csv"], store.list().map(\.name))
    }

    func testAnEmptyStoreListsNothingRatherThanFailing() {
        XCTAssertTrue(store.list().isEmpty)
    }

    // MARK: - Reading

    func testReadReturnsEveryRowIncludingTheHeader() {
        write("Pigeon_2025-08-24_014640.csv", rows: ["one", "two", "three"])
        let c = store.read("Pigeon_2025-08-24_014640.csv")
        XCTAssertEqual(4, c.totalRows)          // header + three
        XCTAssertEqual(FlightLog.csvHeader, c.rows.first)
        XCTAssertFalse(c.truncated)
    }

    /// The cap is a DISPLAY limit, never a transfer limit — `url(for:)` always hands over
    /// the whole file. It is reported so the screen can say the file has more in it rather
    /// than quietly ending early.
    func testReadCapsTheRowsAndSaysSo() {
        write("Pigeon_2025-08-24_014640.csv", rows: (0..<50).map(String.init))
        let c = store.read("Pigeon_2025-08-24_014640.csv", maxRows: 10)
        XCTAssertEqual(10, c.rows.count)
        XCTAssertEqual(51, c.totalRows)
        XCTAssertTrue(c.truncated)
    }

    func testReadingAMissingLogIsEmptyRatherThanACrash() {
        let c = store.read("nope.csv")
        XCTAssertTrue(c.rows.isEmpty)
        XCTAssertEqual(0, c.totalRows)
    }

    // MARK: - Deleting and sharing

    func testDeleteRemovesTheFileAndTheListing() {
        write("Pigeon_2025-08-24_014640.csv")
        XCTAssertTrue(store.delete("Pigeon_2025-08-24_014640.csv"))
        XCTAssertTrue(store.list().isEmpty)
    }

    func testShareUrlIsNilForAFileThatIsGone() {
        XCTAssertNil(store.url(for: "Pigeon_2025-08-24_014640.csv"))
        write("Pigeon_2025-08-24_014640.csv")
        XCTAssertNotNil(store.url(for: "Pigeon_2025-08-24_014640.csv"))
    }

    /// The names this store issues are safe by construction, but they round-trip through
    /// screen state before coming back, and a path check at the point of use costs nothing
    /// next to being wrong about that.
    func testANameThatEscapesTheDirectoryIsRefused() {
        let outside = container.appendingPathComponent("secret.csv")
        try? "sensitive".write(to: outside, atomically: true, encoding: .utf8)

        XCTAssertNil(store.url(for: "../secret.csv"))
        XCTAssertFalse(store.delete("../secret.csv"))
        XCTAssertTrue(store.read("../secret.csv").rows.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path),
                      "the guard must not merely fail to read — it must not delete either")
    }

    // MARK: - Name parsing

    func testTheLocatorNameAndLaunchTimeAreRecoveredFromTheFilename() {
        let f = FlightLogFile(name: "Kestrel_2025-08-24_014640.csv",
                              sizeBytes: 10, modified: .distantPast)
        XCTAssertEqual("Kestrel", f.locatorName)
        XCTAssertEqual("2025-08-24 01:46:40", f.capturedAt)
        XCTAssertEqual("2025-08-24_014640", f.captureKey)
    }

    /// A locator name may contain underscores — the sanitiser turns every unusable
    /// character into one — so the split has to come off the END rather than the start.
    func testAnUnderscoredLocatorNameSurvivesTheRoundTrip() {
        let name = FlightLog.fileName(locatorName: "Twist Lock 5",
                                      at: Date(timeIntervalSince1970: 1_756_000_000),
                                      zone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual("Twist_Lock_5", FlightLogFile(name: name, sizeBytes: 1,
                                                     modified: .distantPast).locatorName)
    }

    func testAnUnparseableNameFallsBackToTheStemRatherThanLying() {
        let f = FlightLogFile(name: "whatever.csv", sizeBytes: 1, modified: .distantPast)
        XCTAssertEqual("whatever", f.capturedAt)
        XCTAssertNil(f.captureKey)
        XCTAssertEqual(FlightLog.unnamedLocator, f.locatorName)
    }

    // MARK: - The file sink

    /// The sink is what the recorder writes through, and `open` is synchronous precisely
    /// because its result decides whether the recorder believes it is recording.
    func testTheSinkWritesAHeaderAndAppendsRows() throws {
        let sink = store.makeSink()
        XCTAssertTrue(sink.open(fileName: "Pigeon_2025-08-24_014640.csv"))
        sink.append(["row-one", "row-two"])
        sink.close()

        // The queue drains asynchronously; wait for the rows rather than racing them.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              store.read("Pigeon_2025-08-24_014640.csv").totalRows < 3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        let c = store.read("Pigeon_2025-08-24_014640.csv")
        XCTAssertEqual([FlightLog.csvHeader, "row-one", "row-two"], c.rows)
    }
}
