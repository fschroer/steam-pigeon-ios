import CoreMotion
import Foundation

/// Where the back camera is pointing — the reference the landscape AR overlay
/// differences the locator's bearing and elevation against.
///
/// Android derives this in `RocketViewModel.updateOrientation` by remapping the rotation
/// matrix with `AXIS_X, AXIS_Z` so the screen-normal axis takes the role the top-of-phone
/// axis plays in portrait. It keeps the two apart deliberately: `handheldDeviceAzimuth`
/// (top of the phone) drives the map bearing and is 90° off in landscape, and it is
/// degenerate with the phone held up at the sky, which is the whole pose this screen is
/// used in. `handheldCameraAzimuth` is this one.
///
/// Pure, and tested against both readings of CoreMotion's matrix — see the note on
/// ``azimuthDeg(rotation:gravity:)``. The sensor plumbing is in `PhoneLocation`.
enum CameraBoresight {

    /// Elevation of the boresight above the horizon, degrees, positive when the camera
    /// looks UP. Signed −90…+90, never wrapped.
    ///
    /// From gravity alone, which needs no reference frame at all: `gravity` is expressed
    /// in the device's own frame and the back camera looks along the device's −Z axis, so
    /// gravity's Z component *is* the sine of the boresight's elevation. Flat on its back
    /// the phone reads −90° (camera at the ground), held upright 0°, screen down +90°.
    ///
    /// The sign matches Android's `_handheldDevicePitch = -orientation[1]`, which is what
    /// `CameraPreviewScreen`'s elevation delta expects: positive vertical delta means the
    /// locator is BELOW where the camera is aimed.
    static func elevationDeg(gravity: CMAcceleration) -> Double {
        asin(min(max(gravity.z, -1), 1)) * 180 / .pi
    }

    /// True-north bearing of the boresight, degrees in 0..<360.
    ///
    /// `rotation` must come from a device-motion stream started with
    /// `.xTrueNorthZVertical` — that frame is X = true north, Y = west, Z = up. Android
    /// has to add magnetic declination by hand (`GeomagneticField`); here the frame is
    /// already true-referenced, the same saving `PhoneLocation.trueHeadingDeg` gets.
    ///
    /// **Why gravity is a parameter.** CoreMotion does not state which way
    /// `CMAttitude.rotationMatrix` maps — reference-to-device or device-to-reference —
    /// and neither does its header. The two differ by a transpose, and for the axis this
    /// needs that is the difference between the camera's bearing and the exact opposite:
    /// an AR marker that sits confidently on the patch of sky 180° from the rocket. So it
    /// is not assumed. One of the two readings of the matrix's third row/column is the
    /// down vector in device coordinates and the other is the boresight in reference
    /// coordinates; gravity, whose frame CoreMotion *does* document, says which. The one
    /// that matches the accelerometer is the one that is not the camera.
    ///
    /// Where the two readings nearly agree the matrix is near-symmetric in that axis and
    /// both give the same bearing, so a wrong pick there costs nothing — the choice only
    /// bites when the two are far apart, which is exactly when gravity separates them
    /// cleanly.
    ///
    /// **Confirmed on hardware 2026-09-02: the marker lands on the rocket.** That is the
    /// only evidence this can have — both readings are internally consistent, the wrong
    /// one is confidently 180° out, and no simulator has a compass to tell them apart. A
    /// refactor that drops the gravity term will pass every test in the suite.
    static func azimuthDeg(rotation r: CMRotationMatrix, gravity: CMAcceleration) -> Double {
        let asColumn = (x: -r.m13, y: -r.m23, z: -r.m33)
        let asRow    = (x: -r.m31, y: -r.m32, z: -r.m33)

        func gap(_ v: (x: Double, y: Double, z: Double)) -> Double {
            let dx = v.x - gravity.x, dy = v.y - gravity.y, dz = v.z - gravity.z
            return dx * dx + dy * dy + dz * dz
        }

        let boresight = gap(asColumn) < gap(asRow) ? asRow : asColumn
        // X = true north, Y = west — so east is the negated Y component.
        let bearing = atan2(-boresight.y, boresight.x) * 180 / .pi
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }
}
