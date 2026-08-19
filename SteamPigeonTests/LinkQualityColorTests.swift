import XCTest
import SwiftUI
@testable import SteamPigeon

/// Band boundaries, mirrored from Android's `rssiColor` / `snrColor`. Exact values,
/// because a band edge shifted by one is invisible until the colour is wrong at
/// exactly the moment someone is judging whether to keep walking.
final class LinkQualityColorTests: XCTestCase {

    private func hex(_ c: Color) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt32((r * 255).rounded()) << 16)
             | (UInt32((g * 255).rounded()) << 8)
             |  UInt32((b * 255).rounded())
    }

    private let green = UInt32(0x4CAF50)
    private let amber = UInt32(0xFFC107)
    private let orange = UInt32(0xFF9800)
    private let red = UInt32(0xF44336)

    func testRssiBandEdges() {
        XCTAssertEqual(green,  hex(RssiBand.color(-80)))
        XCTAssertEqual(amber,  hex(RssiBand.color(-81)))
        XCTAssertEqual(amber,  hex(RssiBand.color(-100)))
        XCTAssertEqual(orange, hex(RssiBand.color(-101)))
        XCTAssertEqual(orange, hex(RssiBand.color(-110)))
        XCTAssertEqual(red,    hex(RssiBand.color(-111)))
    }

    func testSnrBandEdges() {
        XCTAssertEqual(green,  hex(SnrBand.color(5)))
        XCTAssertEqual(amber,  hex(SnrBand.color(4)))
        XCTAssertEqual(amber,  hex(SnrBand.color(0)))
        XCTAssertEqual(orange, hex(SnrBand.color(-1)))
        XCTAssertEqual(orange, hex(SnrBand.color(-5)))
        XCTAssertEqual(red,    hex(SnrBand.color(-6)))
    }

    /// A strong link at close range must read green on both, or the panel would look
    /// alarming sitting next to the rocket on the pad.
    func testPadSideReadingsAreGreen() {
        XCTAssertEqual(green, hex(RssiBand.color(-45)))
        XCTAssertEqual(green, hex(SnrBand.color(9)))
    }

    // MARK: - Deployment channel text

    func testDeployChannelTextMatchesAndroidFormatting() {
        var cfg = PreLaunchData()
        cfg.droguePrimaryDelay = 15          // tenths of a second
        cfg.drogueBackupDelay = 20
        cfg.mainPrimaryAltitude = 130
        cfg.mainBackupAltitude = 120

        XCTAssertEqual("Ch 1: Drogue Prm  1.5 s",
                       DeployChannelText.line(channel: 1, mode: .droguePrimary, config: cfg))
        XCTAssertEqual("Ch 2: Drogue Bkp  2.0 s",
                       DeployChannelText.line(channel: 2, mode: .drogueBackup, config: cfg))
        XCTAssertEqual("Ch 3: Main   Prm  130 m",
                       DeployChannelText.line(channel: 3, mode: .mainPrimary, config: cfg))
        XCTAssertEqual("Ch 4: Main   Bkp  120 m",
                       DeployChannelText.line(channel: 4, mode: .mainBackup, config: cfg))
        XCTAssertEqual("Ch 4: Unused",
                       DeployChannelText.line(channel: 4, mode: .unused, config: cfg))
    }

    /// Delays are tenths, so a whole second must not print as "10.0".
    func testDelayTenthsAreDecodedNotPrintedRaw() {
        var cfg = PreLaunchData()
        cfg.droguePrimaryDelay = 10
        XCTAssertEqual("Ch 1: Drogue Prm  1.0 s",
                       DeployChannelText.line(channel: 1, mode: .droguePrimary, config: cfg))
    }
}
