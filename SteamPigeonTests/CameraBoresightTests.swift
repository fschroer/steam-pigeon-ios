import CoreMotion
import XCTest
@testable import SteamPigeon

/// Where the back camera is pointing.
///
/// The reason these exist at all: CoreMotion does not say which way
/// `CMAttitude.rotationMatrix` maps, and the two readings differ by a transpose — which
/// for this axis is the difference between the rocket's bearing and the opposite one. The
/// implementation resolves it against gravity, so every pose here is checked BOTH ways
/// round and has to give the same answer.
final class CameraBoresightTests: XCTestCase {

    // MARK: - Elevation

    /// Gravity alone, no reference frame: flat on its back the camera looks at the
    /// ground, upright it looks at the horizon, face down it looks at the sky.
    func testElevationReadsTheDeviceZComponentOfGravity() {
        XCTAssertEqual(-90, CameraBoresight.elevationDeg(gravity: CMAcceleration(x: 0, y: 0, z: -1)),
                       accuracy: 1e-9)
        XCTAssertEqual(0, CameraBoresight.elevationDeg(gravity: CMAcceleration(x: 0, y: -1, z: 0)),
                       accuracy: 1e-9)
        XCTAssertEqual(90, CameraBoresight.elevationDeg(gravity: CMAcceleration(x: 0, y: 0, z: 1)),
                       accuracy: 1e-9)
        XCTAssertEqual(30, CameraBoresight.elevationDeg(
            gravity: CMAcceleration(x: 0, y: -cos(30 * Double.pi / 180), z: 0.5)), accuracy: 1e-9)
    }

    /// A sample slightly over unit length — the accelerometer is not a unit vector when
    /// the phone is moving — must not produce a NaN out of `asin`.
    func testElevationClampsAnOverLengthSample() {
        XCTAssertEqual(90, CameraBoresight.elevationDeg(gravity: CMAcceleration(x: 0, y: 0, z: 1.02)),
                       accuracy: 1e-9)
    }

    // MARK: - Azimuth

    /// Phone in landscape, camera aimed due east at the horizon.
    func testCameraLookingEastReadsNinetyDegrees() {
        let pose = Pose(x: (0, 0, 1), y: (1, 0, 0), z: (0, 1, 0))
        assertAzimuth(90, pose)
    }

    /// Aimed due north and 30° up — the pose the sight is actually used in.
    func testCameraLookingNorthAndUpReadsZero() {
        let c = cos(30 * Double.pi / 180), s: Double = 0.5
        let pose = Pose(x: (0, -1, 0), y: (-s, 0, c), z: (-c, 0, -s))
        assertAzimuth(0, pose)
        XCTAssertEqual(30, CameraBoresight.elevationDeg(gravity: pose.gravity), accuracy: 1e-9)
    }

    /// West is 270, not −90: the overlay differences this against a 0…360 bearing.
    func testAzimuthIsWrappedIntoAFullTurn() {
        let pose = Pose(x: (0, 0, 1), y: (-1, 0, 0), z: (0, -1, 0))
        assertAzimuth(270, pose)
    }

    // MARK: - Poses

    /// A device attitude written the way it can be reasoned about: where each of the
    /// device's own axes points, in the true-north reference frame (X = north, Y = west,
    /// Z = up). The back camera looks along −Z.
    private struct Pose {
        /// Device X, Y, Z in reference coordinates.
        let x: (Double, Double, Double)
        let y: (Double, Double, Double)
        let z: (Double, Double, Double)

        /// Device-to-reference: the device axes are its columns.
        var deviceToReference: CMRotationMatrix {
            CMRotationMatrix(m11: x.0, m12: y.0, m13: z.0,
                             m21: x.1, m22: y.1, m23: z.1,
                             m31: x.2, m32: y.2, m33: z.2)
        }

        /// The other reading CoreMotion might mean: the same rotation, transposed.
        var referenceToDevice: CMRotationMatrix {
            let m = deviceToReference
            return CMRotationMatrix(m11: m.m11, m12: m.m21, m13: m.m31,
                                    m21: m.m12, m22: m.m22, m23: m.m32,
                                    m31: m.m13, m32: m.m23, m33: m.m33)
        }

        /// Down (0, 0, −1 in the reference frame) resolved onto the device's axes, which
        /// is what the accelerometer reports.
        var gravity: CMAcceleration { CMAcceleration(x: -x.2, y: -y.2, z: -z.2) }
    }

    private func assertAzimuth(_ expected: Double, _ pose: Pose,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(expected,
                       CameraBoresight.azimuthDeg(rotation: pose.deviceToReference,
                                                  gravity: pose.gravity),
                       accuracy: 1e-9, "device-to-reference reading", file: file, line: line)
        XCTAssertEqual(expected,
                       CameraBoresight.azimuthDeg(rotation: pose.referenceToDevice,
                                                  gravity: pose.gravity),
                       accuracy: 1e-9, "reference-to-device reading", file: file, line: line)
    }
}
