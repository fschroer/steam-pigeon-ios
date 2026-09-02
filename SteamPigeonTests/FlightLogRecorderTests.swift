import XCTest
@testable import SteamPigeon

/// The recorder's sequencing: what is kept, what is discarded, what ends a file.
///
/// Driven against a scripted sink with no clock and no platform types, the same way
/// `ChannelMoveRunnerTests` drives the channel move — these are the decisions that can be
/// silently wrong, and none of them is observable from a green build.
///
/// Ported from Android's `FlightLogRecorderTest.kt`, case for case.
final class FlightLogRecorderTests: XCTestCase {

    private let zone = TimeZone(identifier: "UTC")!

    /// Epoch seconds, so the Android cases translate directly.
    private func t(_ ms: Int) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    /// Records every call so the ORDER can be asserted, not just the contents.
    private final class FakeSink: FlightLogRecorder.Sink {
        var opened: [String] = []
        var rows: [String] = []
        var closes = 0
        var refuseOpen = false

        func open(fileName: String) -> Bool {
            if refuseOpen { return false }
            opened.append(fileName)
            return true
        }
        func append(_ rows: [String]) { self.rows += rows }
        func close() { closes += 1 }
    }

    private func recorder(_ sink: FakeSink,
                          preRoll: TimeInterval = 2) -> FlightLogRecorder {
        let r = FlightLogRecorder(sink: sink, preRoll: preRoll)
        r.timeZone = zone
        return r
    }

    private func sample(_ ms: Int, rssi: Int = -80) -> FlightLogRecord {
        .sample(.init(timestamp: t(ms), source: .prelaunch, rssi: rssi))
    }

    private func event(_ ms: Int, _ text: String) -> FlightLogRecord {
        .event(.init(timestamp: t(ms), event: .announcement, detail: text))
    }

    // MARK: - Nothing is written without a launch

    func testASessionThatNeverFliesWritesNothingAtAll() {
        let sink = FakeSink()
        let r = recorder(sink)
        // Connect, arm, configure, disarm: two minutes of pre-launch broadcasts.
        for ms in stride(from: 0, to: 120_000, by: 1_000) { r.offer(sample(ms)) }
        r.offer(event(60_000, "Armed."))
        XCTAssertTrue(sink.opened.isEmpty, "no file may be opened without a launch")
        XCTAssertTrue(sink.rows.isEmpty)
        XCTAssertFalse(r.isRecording)
    }

    func testClosingWhenNothingIsOpenIsANoOp() {
        let sink = FakeSink()
        recorder(sink).close(at: t(1_000), reason: .disarmed)
        XCTAssertEqual(0, sink.closes)
        XCTAssertTrue(sink.rows.isEmpty)
    }

    // MARK: - The pre-roll

    /// The pre-roll window is a SPAN measured back from the newest record, so the frame
    /// sitting exactly on the boundary is kept. At 1 Hz that is three frames covering two
    /// seconds, not two frames covering one — which is the reading that satisfies "from 2
    /// seconds prior": the two-second-old frame is the one the requirement names, so
    /// dropping it would leave the window starting at 1 s.
    func testThePreRollSpansTwoSecondsBackFromTheNewestFrameAndNoFurther() {
        let sink = FakeSink()
        let r = recorder(sink)
        for i in 0...9 { r.offer(sample(i * 1_000, rssi: -100 + i)) }
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")

        // t=7000, 8000, 9000 span exactly 2 s back from the newest; t=6000 does not.
        XCTAssertEqual([-93, -92, -91], rssis(sink))
    }

    func testThePreRollHoldsTheLastFramesHeardNotTheLastTwoSecondsOfClock() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.offer(sample(0, rssi: -95))
        r.offer(sample(1_000, rssi: -96))
        // Then the signal is lost for a minute and the launch happens unheard.
        r.onLaunch(at: t(61_000), locatorName: "Pigeon", header: "header")

        // Both survive: ageing them against the launch instant would have discarded the
        // last frames before the dropout, which are the ones worth having.
        XCTAssertEqual([-95, -96], rssis(sink))
    }

    func testAppEventsInThePreRollAreKeptAlongsideTheFrames() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.offer(event(9_100, "Pad alert."))
        r.offer(sample(9_500))
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")
        XCTAssertTrue(sink.rows.contains { $0.contains("Pad alert.") })
    }

    func testPreRollSurvivesARefusedOpenSoTheNextLaunchStillHasIt() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.offer(sample(9_000, rssi: -77))
        sink.refuseOpen = true
        XCTAssertFalse(r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header"))
        XCTAssertFalse(r.isRecording, "a refused open must not look like recording")

        sink.refuseOpen = false
        XCTAssertTrue(r.onLaunch(at: t(10_500), locatorName: "Pigeon", header: "header"))
        XCTAssertTrue(rssis(sink).contains(-77))
    }

    func testDiscardPreRollDropsBufferedFramesSoTheyCannotReachTheNextFlight() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.offer(sample(9_000, rssi: -77))
        r.discardPreRoll()
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")
        XCTAssertFalse(rssis(sink).contains(-77))
    }

    // MARK: - Opening

    func testTheFileOpensWithTheSessionHeaderThenThePreRollThenTheLaunch() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.offer(sample(9_000))
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "locator=Pigeon")

        let events = sink.rows.map { cells($0)[Self.eventColumn] }
        XCTAssertEqual(LogEvent.sessionOpened.label, events.first)
        XCTAssertEqual("", events[1])                       // the pre-roll frame
        XCTAssertEqual(LogEvent.launchDetected.label, events.last)
    }

    func testTheHeaderRowIsStampedNoLaterThanTheOldestRowInTheFile() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.offer(sample(9_000))
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")
        // elapsed_s of the header must not be ahead of the first data row, or a reader
        // sorting by time finds the file's own header two seconds in.
        let elapsed = sink.rows.map { Double(cells($0)[Self.elapsedColumn])! }
        XCTAssertEqual(elapsed.sorted(), elapsed)
    }

    func testElapsedIsMeasuredFromLaunchDetectSoThePreRollIsNegative() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.offer(sample(8_000))
        r.offer(sample(9_000))
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")

        let elapsed = sink.rows.map { Double(cells($0)[Self.elapsedColumn])! }
        XCTAssertTrue(elapsed.contains { $0 < 0 }, "pre-roll rows sit before zero")
        XCTAssertEqual(0.0, elapsed.last!, accuracy: 1e-9)
    }

    func testRowsOfferedAfterTheLaunchReachTheFile() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")
        let before = sink.rows.count
        r.offer(sample(11_000, rssi: -60))
        XCTAssertEqual(before + 1, sink.rows.count)
        XCTAssertEqual("-60", cells(sink.rows.last!)[Self.rssiColumn])
    }

    // MARK: - Closing

    func testLandingDoesNotCloseTheLog() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")
        r.offer(.event(.init(timestamp: t(60_000), event: .landingDetected,
                             detail: "locator reported Landed")))
        XCTAssertTrue(r.isRecording, "the recovery walk-in is the point of the tail")
        XCTAssertEqual(0, sink.closes)

        // And the rows recorded during recovery still land in the file.
        r.offer(sample(120_000, rssi: -110))
        XCTAssertEqual("-110", cells(sink.rows.last!)[Self.rssiColumn])
    }

    func testCloseWritesTheReasonAsTheLastRow() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")
        r.close(at: t(200_000), reason: .disarmed)

        let last = cells(sink.rows.last!)
        XCTAssertEqual(LogEvent.sessionClosed.label, last[Self.eventColumn])
        XCTAssertTrue(last[Self.detailColumn].contains("disarmed"))
        XCTAssertEqual(1, sink.closes)
        XCTAssertFalse(r.isRecording)
    }

    func testRowsOfferedAfterACloseAreBufferedForTheNextFlightNotWritten() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")
        r.close(at: t(20_000), reason: .disarmed)
        let after = sink.rows.count
        r.offer(sample(21_000))
        XCTAssertEqual(after, sink.rows.count)
    }

    func testASecondLaunchClosesTheFirstLogAndOpensAnother() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")
        r.onLaunch(at: t(500_000), locatorName: "Pigeon", header: "header")

        XCTAssertEqual(2, sink.opened.count)
        XCTAssertEqual(1, sink.closes, "two flights must not share a file")
        XCTAssertTrue(r.isRecording)
        // The close of the first names the launch that caused it.
        XCTAssertTrue(sink.rows.contains { row in
            let c = cells(row)
            return c[Self.eventColumn] == LogEvent.sessionClosed.label
                && c[Self.detailColumn].contains(LogCloseReason.newLaunch.label)
        })
    }

    func testTheSecondFlightIsTimedFromItsOwnLaunch() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")
        r.onLaunch(at: t(500_000), locatorName: "Pigeon", header: "header")
        sink.rows.removeAll()
        r.offer(sample(501_000))
        XCTAssertEqual(1.0, Double(cells(sink.rows.last!)[Self.elapsedColumn])!, accuracy: 1e-9)
    }

    // MARK: - Naming

    func testTheFileIsNamedForTheLocatorAndTheLocalLaunchTime() {
        let sink = FakeSink()
        recorder(sink).onLaunch(at: t(1_756_000_000_000), locatorName: "Kestrel",
                                header: "header")
        XCTAssertEqual("Kestrel_2025-08-24_014640.csv", sink.opened.first)
        XCTAssertEqual(1, sink.opened.count)
    }

    func testALocatorNameThatWouldEscapeTheDirectoryIsMadeSafe() {
        XCTAssertEqual(".._etc_passwd_2025-08-24_014640.csv",
                       FlightLog.fileName(locatorName: "../etc/passwd",
                                          at: t(1_756_000_000_000), zone: zone))
    }

    func testAnUnnamedLocatorStillProducesAUsableFilename() {
        XCTAssertEqual("locator_2025-08-24_014640.csv",
                       FlightLog.fileName(locatorName: "", at: t(1_756_000_000_000),
                                          zone: zone))
    }

    // MARK: - Format

    func testEveryRowHasExactlyAsManyColumnsAsTheHeader() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.offer(sample(9_000))
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")
        r.offer(.sample(.init(timestamp: t(11_000), source: .telemetry,
                              flightState: .burnout,
                              latitude: 42.5, longitude: -71.25, aglM: 1234.5)))
        r.close(at: t(12_000), reason: .appStopped)

        for row in sink.rows {
            XCTAssertEqual(FlightLog.columnCount, cells(row).count, "row: \(row)")
        }
    }

    func testAnAnnouncementContainingACommaDoesNotBecomeTwoColumns() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")
        r.offer(event(11_000, "Landing, 240 meters north east of the pad."))

        let row = sink.rows.last!
        XCTAssertEqual(FlightLog.columnCount, cells(row).count)
        XCTAssertTrue(row.contains("\"Landing, 240 meters"), "free text must be quoted")
    }

    func testANonFiniteAltitudeRendersBlankRatherThanAsNaNText() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")
        r.offer(.sample(.init(timestamp: t(11_000), source: .telemetry, aglM: Float.nan)))
        XCTAssertEqual("", cells(sink.rows.last!)[Self.aglColumn])
    }

    func testAnUnknownNoiseFloorIsBlankRatherThanAPlausibleReading() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")
        r.offer(.sample(.init(timestamp: t(11_000), source: .telemetry,
                              noiseFloor: LinkQuality.noiseFloorUnknown)))
        XCTAssertEqual("", cells(sink.rows.last!)[Self.noiseFloorColumn])
    }

    /// The decimal separator is a dot whatever the phone's locale, because the file is a
    /// data interchange format. A comma here would put a field break inside a number.
    func testNumbersUseADotWhateverTheDeviceLocale() {
        let sink = FakeSink()
        let r = recorder(sink)
        r.onLaunch(at: t(10_000), locatorName: "Pigeon", header: "header")
        r.offer(.sample(.init(timestamp: t(11_500), source: .telemetry,
                              latitude: 42.5, aglM: -27.5)))
        let c = cells(sink.rows.last!)
        XCTAssertEqual("1.500", c[Self.elapsedColumn])
        XCTAssertEqual("42.5000000", c[Self.latColumn])
        XCTAssertEqual("-27.50", c[Self.aglColumn])
        XCTAssertEqual(FlightLog.columnCount, c.count)
    }

    // MARK: -

    private func rssis(_ sink: FakeSink) -> [Int] {
        sink.rows.compactMap { Int(cells($0)[Self.rssiColumn]) }
    }

    /// Splits on commas outside quotes, the way a CSV reader would.
    private func cells(_ row: String) -> [String] {
        var out: [String] = []
        var cell = ""
        var quoted = false
        var i = row.startIndex
        while i < row.endIndex {
            let c = row[i]
            let next = row.index(after: i)
            if quoted, c == "\"", next < row.endIndex, row[next] == "\"" {
                cell.append("\"")
                i = next
            } else if c == "\"" {
                quoted.toggle()
            } else if c == ",", !quoted {
                out.append(cell)
                cell = ""
            } else {
                cell.append(c)
            }
            i = row.index(after: i)
        }
        out.append(cell)
        return out
    }

    // Resolved from the header so a column added in the middle moves these rather than
    // silently re-pointing every assertion at its neighbour.
    private static let columns = FlightLog.csvHeader.components(separatedBy: ",")
    private static let elapsedColumn = columns.firstIndex(of: "elapsed_s")!
    private static let eventColumn = columns.firstIndex(of: "event")!
    private static let detailColumn = columns.firstIndex(of: "detail")!
    private static let latColumn = columns.firstIndex(of: "lat")!
    private static let aglColumn = columns.firstIndex(of: "agl_m")!
    private static let rssiColumn = columns.firstIndex(of: "rssi_dbm")!
    private static let noiseFloorColumn = columns.firstIndex(of: "noise_floor_dbm")!
}
