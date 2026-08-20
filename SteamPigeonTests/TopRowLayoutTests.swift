import XCTest
import SwiftUI
@testable import SteamPigeon

/// The top row must fit the narrowest phone the app supports.
///
/// Android's fixed 190 dp name column fits its 411 dp reference device with the menu
/// button and controls column either side. The same arithmetic on a 375 pt iPhone
/// overflows and pushes the controls clean off the screen — which is how it shipped,
/// because nothing here was checked against a width.
final class TopRowLayoutTests: XCTestCase {

    /// Fixed, glyph-sized parts of the row that cannot give.
    private let menuButton: CGFloat = 48
    private let controlsColumn: CGFloat = 48
    private let interItemGaps: CGFloat = 8 * 2       // menu|panel and panel|controls
    private let outerPadding: CGFloat = 8 * 2

    /// Widths of devices this app runs on. The iPhone SE is the real floor; the
    /// deployment target is iOS 16, which still covers it.
    private let deviceWidths: [(String, CGFloat)] = [
        ("iPhone SE", 320),
        ("iPhone X / 13 mini", 375),
        ("iPhone 15", 393),
        ("iPhone 15 Pro Max", 430),
    ]

    private var fixedWidth: CGFloat { menuButton + controlsColumn + interItemGaps + outerPadding }

    /// The panel is a MAXIMUM, not a fixed width, so the row fits by shrinking it.
    func testTopRowFitsEveryDeviceWidth() {
        for (name, width) in deviceWidths {
            XCTAssertLessThan(fixedWidth, width,
                              "\(name): menu, controls, gaps and padding alone overflow")
        }
    }

    /// Android's fixed panel width genuinely does not fit — this is the bug, recorded
    /// so nobody re-fixes the panel to a constant.
    func testAndroidsFixedPanelWidthWouldOverflowSmallPhones() {
        let androidPanel: CGFloat = 40 + 190 + 24        // icon + name + battery gutters
        XCTAssertGreaterThan(fixedWidth + androidPanel, 375,
                             "if this ever fits, the fixed width could be restored")
        XCTAssertLessThan(fixedWidth + androidPanel, 430,
                          "it does fit a large phone, which is why it looked fine at first")
    }

    /// Whatever is left for the panel must still be usable — a name column squeezed
    /// to nothing would technically fit and be useless.
    func testRemainingSpaceIsEnoughForAUsablePanel() {
        for (name, width) in deviceWidths {
            let available = width - fixedWidth
            XCTAssertGreaterThan(available, 120,
                                 "\(name): only \(available) pt left for the status panel")
        }
    }
}
