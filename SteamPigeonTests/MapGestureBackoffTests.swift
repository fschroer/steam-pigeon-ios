import XCTest
import MapLibre
@testable import SteamPigeon

/// The auto-camera must stay out of the way while the user owns the camera.
///
/// This is the invariant behind three separately-reported symptoms — the map
/// wandering during a pinch, panning that snaps back, and rotation springing back
/// while magnetic orientation is on. All three were one cause: `applyCamera` runs from
/// `updateUIView`, and publishing the live camera back into SwiftUI state re-renders
/// the view, so every gesture frame invited a camera write on top of the finger.
///
/// Tested here rather than by eye because the window is five seconds long and the
/// failure looks like "the map feels wrong" rather than like an error.
final class MapGestureBackoffTests: XCTestCase {

    private func coordinator() -> FlightMapView.Coordinator { FlightMapView.Coordinator() }

    /// Matches Android's `userGestureRecent` window in `MapCameraController`.
    func testBackoffWindowMatchesAndroid() {
        XCTAssertEqual(5, FlightMapView.Coordinator.gestureBackoff)
    }

    func testNoGestureMeansTheCameraIsFree() {
        XCTAssertFalse(coordinator().userGestureRecent())
    }

    /// Every gesture MapLibre can report has to arm the backoff. A pinch that armed it
    /// but a rotate that did not would fix two of the three symptoms and leave the
    /// third, which is how this was reported in the first place.
    func testEveryGestureReasonArmsTheBackoff() {
        let gestures: [(String, MLNCameraChangeReason)] = [
            ("pan", .gesturePan),
            ("pinch", .gesturePinch),
            ("rotate", .gestureRotate),
            ("tilt", .gestureTilt),
            ("double-tap zoom in", .gestureZoomIn),
            ("two-finger zoom out", .gestureZoomOut),
            ("one-finger zoom", .gestureOneFingerZoom),
        ]
        for (name, reason) in gestures {
            let c = coordinator()
            c.noteGestureForTesting(reason)
            XCTAssertTrue(c.userGestureRecent(), "\(name) must hold the auto-camera off")
        }
    }

    /// A pinch arrives as several bits at once — MapLibre's own header says pinch and
    /// rotate are commonly set together — so the check has to be a set intersection,
    /// not an equality against one case.
    func testCombinedGestureBitsArmTheBackoff() {
        let c = coordinator()
        c.noteGestureForTesting([.gesturePinch, .gestureRotate])
        XCTAssertTrue(c.userGestureRecent())
    }

    /// Our own `setCamera` reports Programmatic. If that re-armed the window the
    /// camera would hold itself off forever after touching the map once.
    func testProgrammaticMovesDoNotArmTheBackoff() {
        let c = coordinator()
        c.noteGestureForTesting(.programmatic)
        XCTAssertFalse(c.userGestureRecent())
    }

    func testBackoffExpires() {
        let c = coordinator()
        c.noteGestureForTesting(.gesturePan)
        let afterWindow = Date().addingTimeInterval(FlightMapView.Coordinator.gestureBackoff + 0.1)
        XCTAssertFalse(c.userGestureRecent(now: afterWindow))
    }

    /// Still held at the boundary — the window is inclusive, as Android's `<= 5000` is.
    func testBackoffHoldsUpToTheBoundary() {
        let c = coordinator()
        c.noteGestureForTesting(.gesturePan)
        let atBoundary = Date().addingTimeInterval(FlightMapView.Coordinator.gestureBackoff - 0.1)
        XCTAssertTrue(c.userGestureRecent(now: atBoundary))
    }
}
