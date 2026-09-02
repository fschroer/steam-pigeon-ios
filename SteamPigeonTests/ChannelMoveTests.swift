import XCTest
@testable import SteamPigeon

/// The ADR-0011 probe's verdict, pinned.
///
/// These are the cases that decide whether the app reverts the receiver, and the whole
/// point of the amendment is that it must revert only on evidence — so the "no evidence"
/// answers matter as much as the positive ones.
///
/// Ported from Android's `ChannelMoveTest.kt`, case for case.
final class ChannelMoveTests: XCTestCase {

    private let ours: UInt32 = 0x1122_3344
    private let theirs: UInt32 = 0x5566_7788

    private func hit(_ channel: Int, _ id: UInt32, _ rssi: Int, _ snr: Int) -> LocatorSearch.Hit {
        LocatorSearch.Hit(channel: channel, locatorId: id, deviceName: "Twist 0",
                          rssi: rssi, snr: snr, armed: false)
    }

    func testHeardOnTheNewChannelConfirmsTheMove() {
        XCTAssertEqual(.confirmed,
                       ChannelMove.verdict(hits: [hit(60, ours, -70, 9)],
                                           locatorId: ours, newChannel: 60, oldChannel: 34))
    }

    func testHeardOnTheOldChannelMeansTheLocatorStayedBehind() {
        XCTAssertEqual(.locatorStayed,
                       ChannelMove.verdict(hits: [hit(34, ours, -70, 9)],
                                           locatorId: ours, newChannel: 60, oldChannel: 34))
    }

    func testNothingHeardIsNoEvidenceNotAFailedMove() {
        XCTAssertEqual(.noEvidence,
                       ChannelMove.verdict(hits: [], locatorId: ours,
                                           newChannel: 60, oldChannel: 34))
    }

    /// The near-field artifact, which is why both dwells always run. One locator reported
    /// on both channels; `rssi + snr` picks the real one. Same figure of merit as
    /// `LocatorSearch.Run.suspectChannels`, validated on hardware 2026-08-28.
    func testHeardOnBothChannelsPicksTheStrongerByRssiPlusSnr() {
        XCTAssertEqual(.confirmed,
                       ChannelMove.verdict(hits: [hit(60, ours, -60, 10), hit(34, ours, -95, 2)],
                                           locatorId: ours, newChannel: 60, oldChannel: 34))
        XCTAssertEqual(.locatorStayed,
                       ChannelMove.verdict(hits: [hit(60, ours, -95, 2), hit(34, ours, -60, 10)],
                                           locatorId: ours, newChannel: 60, oldChannel: 34))
    }

    /// An artifact reading exactly as strong as the real channel separates nothing, and a
    /// tie must never be allowed to fire the revert.
    func testAnExactTieIsNoEvidence() {
        XCTAssertEqual(.noEvidence,
                       ChannelMove.verdict(hits: [hit(60, ours, -70, 5), hit(34, ours, -70, 5)],
                                           locatorId: ours, newChannel: 60, oldChannel: 34))
    }

    /// The reason the probe is a census rather than a targeted run: it surfaces a stranger
    /// on the new channel. That is worth showing the user, and it is not evidence about
    /// where OUR locator went.
    func testAnotherLocatorOnTheNewChannelIsNotConfirmation() {
        XCTAssertEqual(.noEvidence,
                       ChannelMove.verdict(hits: [hit(60, theirs, -55, 11)],
                                           locatorId: ours, newChannel: 60, oldChannel: 34))
    }

    func testAStrangerOnTheNewChannelDoesNotMaskOurLocatorOnTheOldOne() {
        XCTAssertEqual(.locatorStayed,
                       ChannelMove.verdict(hits: [hit(60, theirs, -55, 11), hit(34, ours, -90, 1)],
                                           locatorId: ours, newChannel: 60, oldChannel: 34))
    }

    /// With no id to attribute against, no hit can be evidence.
    func testAnUnknownConnectedLocatorYieldsNoEvidence() {
        XCTAssertEqual(.noEvidence,
                       ChannelMove.verdict(hits: [hit(60, ours, -60, 10)],
                                           locatorId: nil, newChannel: 60, oldChannel: 34))
        XCTAssertEqual(.noEvidence,
                       ChannelMove.verdict(hits: [hit(60, ours, -60, 10)],
                                           locatorId: 0, newChannel: 60, oldChannel: 34))
    }

    /// An unidentified frame (id 0) labels a channel and nothing else.
    func testAnUnidentifiedHitIsNotAttributedToUs() {
        XCTAssertEqual(.noEvidence,
                       ChannelMove.verdict(hits: [hit(60, 0, -55, 11)],
                                           locatorId: ours, newChannel: 60, oldChannel: 34))
    }

    func testProbeOrderPutsTheNewChannelFirst() {
        XCTAssertEqual([60, 34], ChannelMove.probeChannels(newChannel: 60, oldChannel: 34))
    }

    func testProbeChannelsAreDeduped() {
        XCTAssertEqual([34], ChannelMove.probeChannels(newChannel: 34, oldChannel: 34))
    }
}
