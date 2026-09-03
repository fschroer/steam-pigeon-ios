import CoreGraphics
import Foundation

/// The landscape AR overlay's geometry, ported from `CameraPreviewScreen` in
/// `FlightMapScreen.kt`.
///
/// Pure for the same reason `CameraFraming` is: these are the parts with rules — where
/// the marker goes, and when it stops being a circle and becomes an edge arrow — and
/// they are the parts that cannot be checked by looking at a simulator with no compass.
enum ARSight {

    // MARK: - Angles

    /// Positive when the locator is to the RIGHT of where the camera is aimed.
    ///
    /// The ±540 idiom is Android's, and it is what makes a pair straddling north read as
    /// the short way round rather than a 359° swing.
    static func horizontalDeltaDeg(locatorAzimuthDeg: Double, cameraAzimuthDeg: Double) -> Double {
        wrapToHalfTurn(locatorAzimuthDeg - cameraAzimuthDeg)
    }

    /// Positive when the locator is BELOW where the camera is aimed — the direction the
    /// canvas Y axis grows, so it can be added to a screen coordinate as it stands.
    static func verticalDeltaDeg(cameraElevationDeg: Double, locatorElevationDeg: Double) -> Double {
        wrapToHalfTurn(cameraElevationDeg - locatorElevationDeg)
    }

    private static func wrapToHalfTurn(_ degrees: Double) -> Double {
        let wrapped = (degrees + 540).truncatingRemainder(dividingBy: 360)
        return (wrapped < 0 ? wrapped + 360 : wrapped) - 180
    }

    // MARK: - Screen geometry

    /// Android's `scale = 10f`, which is ten **device pixels** per degree: it is applied
    /// to a canvas measured in pixels, where every other constant on that screen is in
    /// dp. Converting through the screen scale keeps the marker the same physical size
    /// per degree as Android — taking the 10 as points would swing it roughly three times
    /// as far for the same angle.
    static func pointsPerDegree(screenScale: CGFloat) -> CGFloat { 10 / screenScale }

    /// Marker radius, dp for dp with Android.
    static let markerRadius: CGFloat = 50
    /// How far in from the edge a clamped arrow sits.
    static let edgeMargin: CGFloat = 20
    /// Arrow length from base to tip.
    static let arrowSize: CGFloat = 14

    /// Where the locator is drawn, and as what.
    enum Marker: Equatable {
        /// On screen (or within one radius of it): the ring Android draws.
        case circle(centre: CGPoint)
        /// Off screen: an arrow at the edge pointing the way to turn. `direction` is a
        /// unit vector from `base` toward the locator.
        case edgeArrow(base: CGPoint, direction: CGVector)
    }

    /// The marker for a pair of deltas, or `nil` when the deltas carry no marker at all.
    ///
    /// Nothing is drawn when the bearing is not one the app stands behind — no ring, and
    /// no arrow either. Android is explicit that the arrow is the MORE confident of the
    /// two: it says the rocket is off screen in this direction, which is exactly the
    /// claim a suppressed vector cannot make.
    static func marker(horizontalDeltaDeg h: Double, verticalDeltaDeg v: Double,
                       size: CGSize, pointsPerDegree ppd: CGFloat) -> Marker {
        let cx = size.width / 2, cy = size.height / 2
        let x = cx + CGFloat(h) * ppd
        let y = cy + CGFloat(v) * ppd

        if x >= -markerRadius && x <= size.width + markerRadius
            && y >= -markerRadius && y <= size.height + markerRadius {
            return .circle(centre: CGPoint(x: x, y: y))
        }

        let ex = min(max(x, edgeMargin), size.width - edgeMargin)
        let ey = min(max(y, edgeMargin), size.height - edgeMargin)
        let dx = x - ex, dy = y - ey
        let len = max((dx * dx + dy * dy).squareRoot(), 1)
        return .edgeArrow(base: CGPoint(x: ex, y: ey),
                          direction: CGVector(dx: dx / len, dy: dy / len))
    }
}
