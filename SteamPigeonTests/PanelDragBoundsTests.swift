import XCTest
import SwiftUI
@testable import SteamPigeon

/// The stats panel shipped once with no bounds and could be dragged off screen, where
/// it could not be recovered without relaunching — and the panel is the telemetry, so
/// losing it loses the readout. Found in the field, which is why the arithmetic now
/// lives outside the gesture handler where it can be checked.
final class PanelDragBoundsTests: XCTestCase {

    private let container = CGSize(width: 400, height: 800)
    private let panel = CGSize(width: 200, height: 300)

    /// Anchored bottom-right, so offsets travel negative and zero is home.
    func testRestingPositionIsUnchanged() {
        XCTAssertEqual(CGSize.zero,
                       PanelDragBounds.clamp(.zero, panel: panel, container: container))
    }

    func testCannotBeDraggedPastTheLeftEdge() {
        let far = CGSize(width: -10_000, height: 0)
        let out = PanelDragBounds.clamp(far, panel: panel, container: container)
        // 400 - 200 - 16 = 184 of travel available.
        XCTAssertEqual(-184, out.width)
    }

    func testCannotBeDraggedPastTheTopEdge() {
        let far = CGSize(width: 0, height: -10_000)
        let out = PanelDragBounds.clamp(far, panel: panel, container: container)
        XCTAssertEqual(-484, out.height)   // 800 - 300 - 16 = 484 of travel
    }

    /// It starts bottom-right, so it must not travel further right or down.
    func testCannotBeDraggedPastItsHomeCorner() {
        let out = PanelDragBounds.clamp(CGSize(width: 500, height: 500),
                                        panel: panel, container: container)
        XCTAssertEqual(0, out.width)
        XCTAssertEqual(0, out.height)
    }

    func testMovementWithinBoundsIsUntouched() {
        let want = CGSize(width: -50, height: -120)
        XCTAssertEqual(want, PanelDragBounds.clamp(want, panel: panel, container: container))
    }

    /// The degenerate case Android guards explicitly: before measurement the available
    /// extent goes negative, and a naive range would put the lower bound above the
    /// upper one — which threw on Android when returning to the map screen.
    /// FAILS CLOSED. The first version returned the proposed offset unchanged when a
    /// size was missing, which is fail-open — and with the container measured late
    /// that was every drag, so the panel left the screen and could not be recovered.
    func testUnmeasuredSizesRefuseToMove() {
        XCTAssertEqual(CGSize.zero,
                       PanelDragBounds.clamp(CGSize(width: -5000, height: -5000),
                                             panel: .zero, container: container))
        XCTAssertEqual(CGSize.zero,
                       PanelDragBounds.clamp(CGSize(width: -5000, height: -5000),
                                             panel: panel, container: .zero))
    }

    /// Whatever the inputs, the result must never leave the container.
    func testNoInputCanEscapeTheContainer() {
        for w in stride(from: -5000.0, through: 5000.0, by: 250) {
            for h in stride(from: -5000.0, through: 5000.0, by: 250) {
                let out = PanelDragBounds.clamp(CGSize(width: w, height: h),
                                                panel: panel, container: container)
                XCTAssertLessThanOrEqual(out.width, 0)
                XCTAssertLessThanOrEqual(out.height, 0)
                XCTAssertGreaterThanOrEqual(out.width, -(container.width - panel.width))
                XCTAssertGreaterThanOrEqual(out.height, -(container.height - panel.height))
            }
        }
    }

    /// A panel larger than its container must still clamp to something valid rather
    /// than trapping — possible at large Dynamic Type sizes on a small phone.
    func testPanelBiggerThanContainerClampsToZero() {
        let out = PanelDragBounds.clamp(CGSize(width: -100, height: -100),
                                        panel: CGSize(width: 500, height: 900),
                                        container: container)
        XCTAssertEqual(0, out.width)
        XCTAssertEqual(0, out.height)
    }
}
