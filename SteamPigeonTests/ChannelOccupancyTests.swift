import XCTest
@testable import SteamPigeon

/// "Who else is on this channel" — with the emphasis on **else**.
///
/// The first version of this on Android shipped a warning that fired on the channel the
/// user's own locator was already using, telling them that staying put would put two
/// locators on one channel. It was right about the occupancy and wrong about everything
/// that mattered.
///
/// Ported from Android's `ChannelOccupancyTest.kt`.
final class ChannelOccupancyTests: XCTestCase {

    private let ours: UInt32 = 0x1111_1111
    private let theirs: UInt32 = 0x2222_2222

    private func survey(_ occupants: [(channel: Int, id: UInt32)],
                        home: Int) -> ChannelSurvey.Result {
        ChannelSurvey.analyze(status: .ok,
                              levels: Array(repeating: -110, count: 64),
                              homeChannel: home,
                              confirmedChannels: occupants.map(\.channel),
                              confirmedFrames: occupants.map { _ in 2 },
                              confirmedLocatorIds: occupants.map(\.id))
    }

    /// The reported bug. A scan run while connected always finds us on our own channel —
    /// that is the scan working, not a conflict.
    func testOurOwnLocatorOnOurOwnChannelIsNotAnOccupant() {
        let r = survey([(34, ours)], home: 34)
        XCTAssertNil(ChannelOccupancy.occupant(of: 34, survey: r, search: nil,
                                               excludeLocatorId: ours,
                                               labelOf: { $0 == self.ours ? "Twist 0" : nil }))
    }

    /// Same channel, different rocket: somebody really is sharing it with us, and
    /// ADR-0019's home-channel exclusion must not swallow that. This is the whole reason
    /// occupancy is excluded **by identity rather than by channel**.
    func testADifferentLocatorOnOurChannelIsAnOccupant() {
        let r = survey([(34, theirs)], home: 34)
        XCTAssertEqual("Prometheus",
                       ChannelOccupancy.occupant(of: 34, survey: r, search: nil,
                                                 excludeLocatorId: ours,
                                                 labelOf: { $0 == self.theirs ? "Prometheus" : nil }))
    }

    func testALocatorOnAnotherChannelIsReported() {
        let r = survey([(34, ours), (12, theirs)], home: 34)
        XCTAssertEqual("Prometheus",
                       ChannelOccupancy.occupant(of: 12, survey: r, search: nil,
                                                 excludeLocatorId: ours,
                                                 labelOf: { $0 == self.theirs ? "Prometheus" : nil }))
    }

    /// A search went looking for exactly this, and did so more recently.
    func testASearchHitOutranksTheSurvey() {
        let r = survey([(12, theirs)], home: 34)
        let search = LocatorSearch.Run(
            running: false,
            hits: [LocatorSearch.Hit(channel: 12, locatorId: 0x3333_3333,
                                     deviceName: "Testy McTestface",
                                     rssi: -60, snr: 8, armed: false)],
            status: .done)
        XCTAssertEqual("Testy McTestface",
                       ChannelOccupancy.occupant(of: 12, survey: r, search: search,
                                                 excludeLocatorId: ours))
    }

    /// Not only the survey path: a search run while connected finds us as readily.
    func testASearchHitFromOurselvesIsExcludedToo() {
        let search = LocatorSearch.Run(
            running: false,
            hits: [LocatorSearch.Hit(channel: 34, locatorId: ours, deviceName: "Twist 0",
                                     rssi: -50, snr: 8, armed: false)],
            status: .done)
        XCTAssertNil(ChannelOccupancy.occupant(of: 34, survey: nil, search: search,
                                               excludeLocatorId: ours))
    }

    func testAnUnknownLocatorFallsBackToItsId() {
        let r = survey([(12, theirs)], home: 34)
        XCTAssertEqual("22222222",
                       ChannelOccupancy.occupant(of: 12, survey: r, search: nil,
                                                 excludeLocatorId: ours))
    }

    /// Occupancy without identity: a frame type that carries no `locator_id`. The channel
    /// is still occupied — the survey excludes it from suggestions — but there is no name
    /// to put on it, and "00000000" would be a lie.
    func testAnOccupiedChannelWithNoIdReportsNothingRatherThanZero() {
        let r = survey([(12, 0)], home: 34)
        XCTAssertNil(ChannelOccupancy.occupant(of: 12, survey: r, search: nil,
                                               excludeLocatorId: ours))
    }

    func testAnUnscannedChannelIsUnknownNotFree() {
        XCTAssertNil(ChannelOccupancy.occupant(of: 7, survey: nil, search: nil,
                                               excludeLocatorId: ours))
    }
}
