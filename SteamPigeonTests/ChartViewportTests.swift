import UIKit
import XCTest
@testable import SteamPigeon

/// Pan/zoom arithmetic for the flight-profile chart, ported from Android's
/// `ChartViewportTest` with the same cases and tolerances.
///
/// The focal-point math is easy to get subtly wrong — particularly on Y, which is
/// inverted (altitude grows upward from a baseline at `plotH`) — and a sign error
/// there shows up as the chart sliding away under your fingers rather than as anything
/// a compiler catches.
final class ChartViewportTests: XCTestCase {

    private let plotW: CGFloat = 1000
    private let plotH: CGFloat = 600
    private let totalMs: CGFloat = 20_000        // 20 s flight
    private let maxAlt: CGFloat = 900
    private let eps: CGFloat = 0.01

    private func pinch(_ v: ChartViewport, centroid: CGPoint, zoomChange: CGFloat,
                       panChange: CGPoint = .zero) -> ChartViewport {
        v.transform(centroid: centroid, panChange: panChange, zoomChange: zoomChange,
                    plotW: plotW, plotH: plotH)
    }

    // MARK: - Identity

    func testIdentityGestureChangesNothing() {
        let v = pinch(ChartViewport(), centroid: CGPoint(x: 400, y: 300), zoomChange: 1)
        XCTAssertEqual(v.zoom, 1, accuracy: eps)
        XCTAssertEqual(v.pan.x, 0, accuracy: eps)
        XCTAssertEqual(v.pan.y, 0, accuracy: eps)
    }

    func testDefaultViewportFitsTheWholeFlight() {
        let v = ChartViewport()
        let ms = v.visibleMsRange(plotW: plotW, totalMs: totalMs)
        XCTAssertEqual(ms.lowerBound, 0, accuracy: eps)
        XCTAssertEqual(ms.upperBound, totalMs, accuracy: eps)

        let alt = v.visibleValueRange(plotH: plotH, axisMin: 0, axisMax: maxAlt)
        XCTAssertEqual(alt.lowerBound, 0, accuracy: eps)
        XCTAssertEqual(alt.upperBound, maxAlt, accuracy: eps)
    }

    // MARK: - Focal point

    func testZoomHoldsTheDataUnderTheCentroidStill() {
        let centroid = CGPoint(x: 700, y: 200)
        let before = ChartViewport()

        func msUnder(_ v: ChartViewport) -> CGFloat {
            let r = v.visibleMsRange(plotW: plotW, totalMs: totalMs)
            let frac = (centroid.x - FlightChart.marginX) / plotW
            return r.lowerBound + frac * (r.upperBound - r.lowerBound)
        }
        func altUnder(_ v: ChartViewport) -> CGFloat {
            let r = v.visibleValueRange(plotH: plotH, axisMin: 0, axisMax: maxAlt)
            let frac = (plotH - centroid.y) / plotH
            return r.lowerBound + frac * (r.upperBound - r.lowerBound)
        }

        let msBefore = msUnder(before)
        let altBefore = altUnder(before)

        let after = pinch(before, centroid: centroid, zoomChange: 2.5)
        XCTAssertEqual(after.zoom, 2.5, accuracy: eps)
        XCTAssertEqual(msUnder(after), msBefore, accuracy: 1, "time under centroid moved")
        XCTAssertEqual(altUnder(after), altBefore, accuracy: 0.5, "altitude under centroid moved")
    }

    func testRepeatedPinchesAccumulateWithoutDrift() {
        let centroid = CGPoint(x: 500, y: 300)
        var v = ChartViewport()
        for _ in 0..<5 { v = pinch(v, centroid: centroid, zoomChange: 1.2) }
        XCTAssertEqual(v.zoom, 2.488, accuracy: 0.01)      // 1.2^5

        // Zooming all the way back out must land exactly on the original fit.
        for _ in 0..<5 { v = pinch(v, centroid: centroid, zoomChange: 1 / 1.2) }
        XCTAssertEqual(v.zoom, 1, accuracy: eps)
        XCTAssertEqual(v.pan.x, 0, accuracy: eps)
        XCTAssertEqual(v.pan.y, 0, accuracy: eps)
    }

    // MARK: - Clamping

    func testZoomIsClampedToTheAllowedRange() {
        // Cannot zoom out below the full-flight fit.
        let out = pinch(ChartViewport(), centroid: CGPoint(x: 500, y: 300), zoomChange: 0.1)
        XCTAssertEqual(out.zoom, 1, accuracy: eps)

        // Cannot zoom in past the cap, however hard you pinch.
        var v = ChartViewport()
        for _ in 0..<30 { v = pinch(v, centroid: CGPoint(x: 500, y: 300), zoomChange: 2) }
        XCTAssertEqual(v.zoom, FlightChart.maxZoom, accuracy: eps)
    }

    func testPinchingPastTheZoomCapDoesNotDriftTheViewport() {
        // Once clamped at the cap, further pinches must not shift pan — the reason for
        // scaling by the APPLIED factor rather than by the requested one.
        var v = ChartViewport()
        for _ in 0..<30 { v = pinch(v, centroid: CGPoint(x: 500, y: 300), zoomChange: 2) }
        let settled = v.pan
        for _ in 0..<5 { v = pinch(v, centroid: CGPoint(x: 500, y: 300), zoomChange: 2) }
        XCTAssertEqual(v.pan.x, settled.x, accuracy: eps)
        XCTAssertEqual(v.pan.y, settled.y, accuracy: eps)
    }

    func testPanCannotDragDataOffThePlot() {
        var v = pinch(ChartViewport(), centroid: CGPoint(x: 500, y: 300), zoomChange: 4)
        v = pinch(v, centroid: CGPoint(x: 500, y: 300), zoomChange: 1,
                  panChange: CGPoint(x: 10_000, y: 10_000))

        XCTAssertLessThanOrEqual(v.pan.x, eps)
        XCTAssertGreaterThanOrEqual(v.pan.x, -(v.zoom - 1) * plotW - eps)
        XCTAssertGreaterThanOrEqual(v.pan.y, -eps)
        XCTAssertLessThanOrEqual(v.pan.y, (v.zoom - 1) * plotH + eps)

        // And the same in the opposite direction.
        v = pinch(v, centroid: CGPoint(x: 500, y: 300), zoomChange: 1,
                  panChange: CGPoint(x: -10_000, y: -10_000))
        XCTAssertLessThanOrEqual(v.pan.x, eps)
        XCTAssertGreaterThanOrEqual(v.pan.x, -(v.zoom - 1) * plotW - eps)
        XCTAssertGreaterThanOrEqual(v.pan.y, -eps)
        XCTAssertLessThanOrEqual(v.pan.y, (v.zoom - 1) * plotH + eps)
    }

    func testVisibleRangeStaysWithinTheData() {
        // At any zoom/pan the visible window stays inside the full extent, so the chart
        // can never show blank space beside the flight.
        var v = pinch(ChartViewport(), centroid: CGPoint(x: 900, y: 100), zoomChange: 6)
        v = pinch(v, centroid: CGPoint(x: 900, y: 100), zoomChange: 1,
                  panChange: CGPoint(x: 5_000, y: -5_000))

        let ms = v.visibleMsRange(plotW: plotW, totalMs: totalMs)
        XCTAssertGreaterThanOrEqual(ms.lowerBound, -1)
        XCTAssertLessThanOrEqual(ms.upperBound, totalMs + 1)

        let alt = v.visibleValueRange(plotH: plotH, axisMin: 0, axisMax: maxAlt)
        XCTAssertGreaterThanOrEqual(alt.lowerBound, -1)
        XCTAssertLessThanOrEqual(alt.upperBound, maxAlt + 1)
    }

    // MARK: - Projection

    func testProjectionMatchesItsOwnInverse() {
        let v = pinch(ChartViewport(), centroid: CGPoint(x: 300, y: 400), zoomChange: 3)

        let ms = v.visibleMsRange(plotW: plotW, totalMs: totalMs)
        XCTAssertEqual(v.screenXOfMs(ms.lowerBound, plotW: plotW, totalMs: totalMs),
                       FlightChart.marginX, accuracy: eps)
        XCTAssertEqual(v.screenXOfMs(ms.upperBound, plotW: plotW, totalMs: totalMs),
                       FlightChart.marginX + plotW, accuracy: eps)

        let alt = v.visibleValueRange(plotH: plotH, axisMin: 0, axisMax: maxAlt)
        XCTAssertEqual(v.screenYOfValue(alt.lowerBound, plotH: plotH, axisMin: 0, axisMax: maxAlt),
                       plotH, accuracy: eps)
        XCTAssertEqual(v.screenYOfValue(alt.upperBound, plotH: plotH, axisMin: 0, axisMax: maxAlt),
                       0, accuracy: eps)
    }

    func testDegeneratePlotSizeIsIgnored() {
        // A canvas measured at zero must not produce NaN pan/zoom.
        let v = ChartViewport().transform(centroid: .zero, panChange: .zero, zoomChange: 2,
                                          plotW: 0, plotH: 0)
        XCTAssertEqual(v.zoom, 1, accuracy: eps)
        XCTAssertEqual(v.pan.x, 0, accuracy: eps)
        XCTAssertEqual(v.pan.y, 0, accuracy: eps)
    }

    // MARK: - Gridline intervals

    // MARK: - The altitude gutter

    /// The defect Android fixed in `5d52383` and this port reproduced: the gutter was
    /// 64 px and "900m" measures ~79 px at the 32 px axis size, so the altitude axis of
    /// an altitude chart clipped the leading digit off its own labels.
    ///
    /// Measured in the real face at the real size, because that is what the bug was —
    /// arithmetic on the constant alone would have looked fine either way.
    func testTheAltitudeGutterFitsAFourDigitLabel() throws {
        let font = try XCTUnwrap(UIFont(name: "Roboto-Regular", size: FlightChart.axisTextSize))
        let gap = 8 / FlightChart.androidChartDensity
        let width = ("1234m" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertLessThanOrEqual(width, FlightChart.marginX - gap,
                                 "a four-digit label must fit: 9999 m is 32,800 ft")
    }

    /// Why the number moved, pinned so it cannot quietly move back: the old gutter did
    /// not fit even a three-digit label.
    func testTheOldGutterCouldNotFitAThreeDigitLabel() throws {
        let font = try XCTUnwrap(UIFont(name: "Roboto-Regular", size: FlightChart.axisTextSize))
        let oldMarginX = 64 / FlightChart.androidChartDensity
        let gap = 8 / FlightChart.androidChartDensity
        let width = ("900m" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThan(width, oldMarginX - gap)
    }

    /// `niceInterval` divides the gridline loops, so it must never return zero, a
    /// negative, or a NaN however degenerate the range it is handed.
    func testNiceIntervalIsAlwaysUsableAsADivisor() {
        for range in [CGFloat(0), -5, .nan, .infinity] {
            let interval = niceInterval(range)
            XCTAssertTrue(interval.isFinite && interval > 0, "interval for \(range)")
        }
        XCTAssertEqual(niceInterval(1000, targetCount: 5), 200, accuracy: 0.001)
        XCTAssertEqual(niceInterval(45, targetCount: 5), 10, accuracy: 0.001)
        XCTAssertEqual(niceInterval(0.4, targetCount: 5), 0.1, accuracy: 0.0001)
    }
}
