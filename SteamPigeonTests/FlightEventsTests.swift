import XCTest
@testable import SteamPigeon

/// Decode + placement tests for the FlightEvents message (MsgType 19), ported from
/// Android's `FlightEventsTest`.
///
/// These cover the two halves the firmware cannot be exercised against here: that the
/// app reads the C++ `FlightEventsMessage` layout at the right offsets, and that event
/// times land on the right samples. Field offsets are written out longhand in
/// `buildFrame` so a firmware layout change breaks the test rather than silently
/// shifting every event on the chart.
final class FlightEventsTests: XCTestCase {

    private let record = 3
    private let flightTsS: UInt32 = 1_770_000_000
    private let maxAlt: Float = 921.5

    /// Deployment stat byte: mode in bits 0–2, fired (3), pre-fire continuity (4),
    /// post-fire continuity (5). Mirrors the locator's `Constants.hpp`.
    private func statByte(_ mode: DeployMode, fired: Bool = false,
                          pre: Bool = false, post: Bool = false) -> UInt8 {
        mode.rawValue
            | (fired ? 1 << 3 : 0)
            | (pre ? 1 << 4 : 0)
            | (post ? 1 << 5 : 0)
    }

    /// Build a wire frame exactly as the locator lays `FlightEventsMessage` out.
    private func buildFrame(_ timestamps: [FlightEventIndex: Int],
                            channelStats: [UInt8]? = nil,
                            record: Int? = nil) -> [UInt8] {
        let stats = channelStats ?? [
            statByte(.droguePrimary, fired: true, pre: true),
            statByte(.drogueBackup),
            statByte(.mainPrimary, fired: true, pre: true, post: true),
            statByte(.mainBackup),
        ]

        var frame: [UInt8] = [WireProtocol.systemId, MsgType.flightEvents.rawValue, 0, 0, 0, 0]
        frame.append(UInt8(record ?? self.record))
        frame.append(0)                                   // reserved

        var mask: UInt16 = 0
        for event in timestamps.keys { mask |= UInt16(1 << event.rawValue) }
        frame += le16(mask)
        frame += le32(flightTsS)

        for event in FlightEventIndex.allCases {
            frame += le32(UInt32(timestamps[event] ?? 0))
        }
        frame += le32(maxAlt.bitPattern)
        frame += stats

        XCTAssertEqual(frame.count,
                       WireProtocol.headerSize + WireProtocol.flightEventsPayloadSize,
                       "frame not fully written")
        return frame
    }

    private func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
    }

    private func le32(_ v: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
    }

    /// 20 Hz samples rising to apogee then descending, matching the archive cadence.
    private func samples(_ count: Int) -> [FlightSample] {
        let apogeeAt = count / 2
        return (0..<count).map { i in
            FlightSample(timestampMs: i * 50,
                         altitudeM: Float(i <= apogeeAt ? i * 2 : (2 * apogeeAt - i) * 2),
                         accel: Vec3f(x: 0, y: 0, z: 0),
                         gyro: Vec3f(x: 0, y: 0, z: 0),
                         latRad: 0, lonRad: 0)
        }
    }

    // MARK: - Decode

    func testParsesEveryFieldAtTheRightOffset() throws {
        let times: [FlightEventIndex: Int] = [
            .launch: 0, .burnout: 1_200, .apogee: 9_000, .landing: 60_000,
        ]
        let events = try XCTUnwrap(FlightEvents.parse(buildFrame(times)))

        XCTAssertEqual(events.record, record)
        XCTAssertEqual(events.flightTimestampS, flightTsS)
        XCTAssertEqual(events.maxAltitudeM, maxAlt, accuracy: 0.001)

        for (event, expected) in times {
            XCTAssertEqual(events.timestampMs(event), expected, "timestamp for \(event)")
        }
        // Events outside the present mask read as absent, not as time 0 — the
        // distinction is what keeps unrecorded events off the chart.
        XCTAssertNil(events.timestampMs(.mainPrimaryDeploy))
        XCTAssertNil(events.timestampMs(.noseover))

        // Launch at 0 ms IS present, and must not be confused with absent.
        XCTAssertEqual(events.timestampMs(.launch), 0)
    }

    func testDecodesChannelStatBits() throws {
        let events = try XCTUnwrap(FlightEvents.parse(buildFrame([:])))

        let ch1 = events.channelStats[0]
        XCTAssertEqual(ch1.mode, .droguePrimary)
        XCTAssertTrue(ch1.fired)
        XCTAssertTrue(ch1.preFireContinuity)
        XCTAssertFalse(ch1.postFireContinuity, "post-fire continuity should be clear")

        let ch2 = events.channelStats[1]
        XCTAssertEqual(ch2.mode, .drogueBackup)
        XCTAssertFalse(ch2.fired, "backup never fired")

        XCTAssertEqual(events.channel(for: .droguePrimary), 1)
        XCTAssertEqual(events.channel(for: .mainPrimary), 3)
        XCTAssertNil(events.channel(for: .unused))
    }

    func testRejectsShortFrame() {
        let short = Array(buildFrame([:]).prefix(WireProtocol.headerSize + 10))
        XCTAssertNil(FlightEvents.parse(short))
    }

    // MARK: - Placement

    func testPlacesEventsOnTheNearestSample() throws {
        // 200 samples @ 50 ms = 0…9950 ms, apogee at index 100 (5000 ms).
        let data = samples(200)
        let events = try XCTUnwrap(FlightEvents.parse(buildFrame([
            .launch: 0,
            .burnout: 1_220,        // between samples 24 (1200) and 25 (1250)
            .apogee: 5_000,
        ])))

        let resolved = resolveEvents(samples: data, events: events)
        XCTAssertEqual(resolved.count, 3)
        let byEvent = Dictionary(uniqueKeysWithValues: resolved.map { ($0.event, $0) })

        XCTAssertEqual(byEvent[.launch]?.sampleIndex, 0)
        // 1220 is 20 ms past sample 24 and 30 ms short of 25 — nearest is 24.
        XCTAssertEqual(byEvent[.burnout]?.sampleIndex, 24)
        XCTAssertEqual(byEvent[.apogee]?.sampleIndex, 100)

        // Altitude comes from the matched sample, so a marker sits on the trace.
        XCTAssertEqual(byEvent[.apogee]?.altitudeM ?? 0, data[100].altitudeM, accuracy: 0.001)
    }

    func testDropsEventsWithNoNearbySample() throws {
        // Landing is recorded well past the end of the sample data, as happens while a
        // transfer is still streaming. It must not collapse onto the last sample, nor
        // onto sample 0.
        let data = samples(50)          // 0…2450 ms
        let events = try XCTUnwrap(FlightEvents.parse(buildFrame([
            .burnout: 1_000, .landing: 60_000,
        ])))

        XCTAssertEqual(resolveEvents(samples: data, events: events).map(\.event), [.burnout])
    }

    func testSkipsDeploymentEventsWithNoChannelAssigned() throws {
        let data = samples(200)
        // No channel is configured for MainBackup, so its event cannot be attributed to
        // a set of continuity indicators.
        let events = try XCTUnwrap(FlightEvents.parse(buildFrame(
            [.mainPrimaryDeploy: 6_000, .mainBackupDeploy: 6_500],
            channelStats: [
                statByte(.droguePrimary, fired: true),
                statByte(.unused),
                statByte(.mainPrimary, fired: true),
                statByte(.unused),
            ])))

        let resolved = resolveEvents(samples: data, events: events)
        XCTAssertEqual(resolved.map(\.event), [.mainPrimaryDeploy])
        // Channel number is 1-based and carried into the label.
        XCTAssertEqual(resolved.first?.label, "Ch 3 Main Primary")
        XCTAssertEqual(resolved.first?.stats?.fired, true)
    }

    func testReturnsEventsInChronologicalOrder() throws {
        let data = samples(400)
        let events = try XCTUnwrap(FlightEvents.parse(buildFrame([
            .landing: 15_000, .launch: 0, .apogee: 10_000, .burnout: 1_000,
        ])))

        XCTAssertEqual(resolveEvents(samples: data, events: events).map(\.event),
                       [.launch, .burnout, .apogee, .landing])
    }

    func testEmptySummaryOrEmptySamplesResolvesToNothing() throws {
        // No summary received yet (or an old-firmware locator that never sends one).
        XCTAssertTrue(resolveEvents(samples: samples(100), events: FlightEvents()).isEmpty)

        // Summary in hand but no samples yet — the transfer has only just started.
        let events = try XCTUnwrap(FlightEvents.parse(buildFrame([.apogee: 5_000])))
        XCTAssertTrue(resolveEvents(samples: [], events: events).isEmpty)
    }

    // MARK: - Sanity filter

    /// The chart filters samples through `isSane` before anything else touches them.
    func testInsaneSamplesAreRejected() {
        func sample(alt: Float = 100, accel: Float = 0, t: Int = 1_000) -> FlightSample {
            FlightSample(timestampMs: t, altitudeM: alt,
                         accel: Vec3f(x: accel, y: 0, z: 0),
                         gyro: Vec3f(x: 0, y: 0, z: 0), latRad: 0, lonRad: 0)
        }
        XCTAssertTrue(sample().isSane)
        XCTAssertFalse(sample(alt: .nan).isSane)
        XCTAssertFalse(sample(alt: 40_000).isSane)
        XCTAssertFalse(sample(alt: -600).isSane)
        XCTAssertFalse(sample(accel: 4_000).isSane)
        XCTAssertFalse(sample(accel: .infinity).isSane)
        XCTAssertFalse(sample(t: -1).isSane)
        XCTAssertFalse(sample(t: 700_000).isSane)
    }
}
