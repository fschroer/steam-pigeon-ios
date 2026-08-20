import XCTest
@testable import SteamPigeon

/// Field-offset tests for the two authenticated broadcasts.
///
/// A wrong offset does not fail loudly — it shifts every field after it and shows
/// plausible-looking nonsense, which on this system means a recovery bearing to the
/// wrong place. So these build frames by writing at **explicitly stated offsets**
/// taken from the firmware struct, rather than by reusing the parser's own walk.
final class BroadcastParsingTests: XCTestCase {

    // MARK: - Frame building at explicit offsets

    private func blank(_ type: MsgType, total: Int) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: total)
        f[0] = WireProtocol.systemId
        f[1] = type.rawValue
        return f
    }

    private func put<T: FixedWidthInteger>(_ v: T, _ f: inout [UInt8], _ o: Int) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { for (i, b) in $0.enumerated() { f[o + i] = b } }
    }

    private func putF32(_ v: Float, _ f: inout [UInt8], _ o: Int) { put(v.bitPattern, &f, o) }
    private func putF64(_ v: Double, _ f: inout [UInt8], _ o: Int) { put(v.bitPattern, &f, o) }

    private func putName(_ s: String, _ f: inout [UInt8], _ o: Int) {
        for (i, b) in Array(s.utf8).prefix(WireProtocol.deviceNameLength).enumerated() { f[o + i] = b }
    }

    private func sealCrc(_ f: inout [UInt8]) {
        f[4] = 0; f[5] = 0
        let crc = PacketFramer.computeCrc(f)
        f[4] = UInt8(truncatingIfNeeded: crc)
        f[5] = UInt8(truncatingIfNeeded: crc >> 8)
    }

    // MARK: - PreLaunchData
    //
    // Offsets from the firmware struct, header at 0:
    //   6 lat f64 | 14 lon f64 | 22 rawLat f64 | 30 rawLon f64 | 38 sats | 39 hacc f32
    //   43 imu | 44 baro | 45 gps | 46 deployStatus | 47 agl f32
    //   51 accel[3]f32 | 63 gyro[3]f32 | 75 deployModes[4] | 79 drogueP | 80 drogueB
    //   81 mainP u16 | 83 mainB u16 | 85 name[20] | 105 batt u16 | 107 noseAxis
    //   108 armed | 109 padAlert | 110 locatorId u32 | 114 authTag u32  == 118 base
    //   118 channel | 119 recvBatt u16 | 121 recvName[20] | 141 rssi i16
    //   143 snr i8 | 144 noiseFloor i16 | 146 badFrames  == 147 total

    func testPrelaunchFieldsLandOnTheRightOffsets() throws {
        var f = blank(.preLaunchData, total: 147)
        putF64(47.123456, &f, 6)
        putF64(-122.654321, &f, 14)
        putF64(47.5, &f, 22)
        putF64(-122.5, &f, 30)
        f[38] = 11
        putF32(2.5, &f, 39)
        f[43] = SensorHealth.ok.rawValue
        f[44] = SensorHealth.warning.rawValue
        f[45] = SensorHealth.ok.rawValue
        f[46] = 0x0F
        putF32(123.75, &f, 47)
        putF32(1, &f, 51); putF32(2, &f, 55); putF32(3, &f, 59)          // accel
        putF32(4, &f, 63); putF32(5, &f, 67); putF32(6, &f, 71)          // gyro
        f[75] = DeployMode.droguePrimary.rawValue
        f[76] = DeployMode.drogueBackup.rawValue
        f[77] = DeployMode.mainPrimary.rawValue
        f[78] = DeployMode.unused.rawValue
        f[79] = 2                                                        // drogue primary delay
        f[80] = 3                                                        // drogue backup delay
        put(UInt16(130), &f, 81)                                         // main primary altitude
        put(UInt16(120), &f, 83)                                         // main backup altitude
        putName("Frank's Rocket", &f, 85)
        put(UInt16(4050), &f, 105)
        f[107] = NoseAxis.z.rawValue
        f[108] = 1                                                       // armed
        f[109] = 7                                                       // pad alert: snoozed, 5 min
        put(UInt32(0xDEADBEEF), &f, 110)
        put(UInt32(0x12345678), &f, 114)
        f[118] = 42                                                      // channel
        put(UInt16(3900), &f, 119)
        putName("Frank's Receiver", &f, 121)
        put(Int16(-91), &f, 141)
        f[143] = UInt8(bitPattern: -7)                                   // snr
        put(Int16(-104), &f, 144)
        f[146] = 3                                                       // bad frames
        sealCrc(&f)

        let m = try XCTUnwrap(PreLaunchData.parse(f))
        XCTAssertEqual(47.123456, m.latitude, accuracy: 1e-9)
        XCTAssertEqual(-122.654321, m.longitude, accuracy: 1e-9)
        XCTAssertEqual(47.5, m.rawLatitude, accuracy: 1e-9)
        XCTAssertEqual(-122.5, m.rawLongitude, accuracy: 1e-9)
        XCTAssertEqual(11, m.satellites)
        XCTAssertEqual(2.5, m.horizontalAccuracy)
        XCTAssertEqual(.ok, m.imuStatus)
        XCTAssertEqual(.warning, m.baroStatus)
        XCTAssertEqual(.ok, m.gpsStatus)
        XCTAssertEqual(123.75, m.altitudeAgl)
        XCTAssertEqual(Vec3f(x: 1, y: 2, z: 3), m.accel)
        XCTAssertEqual(Vec3f(x: 4, y: 5, z: 6), m.gyro)
        XCTAssertEqual([.droguePrimary, .drogueBackup, .mainPrimary, .unused], m.deployChannelModes)
        XCTAssertEqual(2, m.droguePrimaryDelay)
        XCTAssertEqual(3, m.drogueBackupDelay)
        XCTAssertEqual(130, m.mainPrimaryAltitude)
        XCTAssertEqual(120, m.mainBackupAltitude)
        XCTAssertEqual("Frank's Rocket", m.deviceName)
        XCTAssertEqual(4050, m.locatorBatteryMv)
        XCTAssertEqual(.z, m.noseAxis)
        XCTAssertTrue(m.armed)
        XCTAssertEqual(.snoozed, m.padAlert)
        XCTAssertEqual(5, m.padAlertSnoozeMinutes)
        XCTAssertEqual(0xDEADBEEF, m.locatorId)
        XCTAssertEqual(0x12345678, m.authTag)
        XCTAssertEqual(42, m.channel)
        XCTAssertEqual(3900, m.receiverBatteryMv)
        XCTAssertEqual("Frank's Receiver", m.receiverName)
        XCTAssertEqual(-91, m.rssi)
        XCTAssertEqual(-7, m.snr)
        XCTAssertEqual(-104, m.noiseFloor)
        XCTAssertEqual(3, m.badFrames)
    }

    // MARK: - TelemetryData
    //
    //   6 lat f64 | 14 lon f64 | 22 sats | 23 hacc f32 | 27 imu | 28 baro | 29 gps
    //   30 chStats[4] | 34 physStats | 35 agl f32 | 39 velNed[3]f32
    //   51 quat[4]f32 | 67 flightState | 68 armed | 69 locatorId u32 | 73 authTag u32 == 77 base
    //   77 rssi i16 | 79 snr | 80 noiseFloor i16 | 82 badFrames == 83 total

    func testTelemetryFieldsLandOnTheRightOffsets() throws {
        var f = blank(.telemetryData, total: 83)
        putF64(47.0, &f, 6)
        putF64(-122.0, &f, 14)
        f[22] = 9
        putF32(1.5, &f, 23)
        f[27] = SensorHealth.ok.rawValue
        f[28] = SensorHealth.ok.rawValue
        f[29] = SensorHealth.error.rawValue
        f[30] = 0x11; f[31] = 0x22; f[32] = 0x33; f[33] = 0x44
        f[34] = 0x55
        putF32(250.5, &f, 35)
        putF32(-1, &f, 39); putF32(-2, &f, 43); putF32(-30, &f, 47)     // vel NED
        putF32(0.5, &f, 51); putF32(0.5, &f, 55)
        putF32(0.5, &f, 59); putF32(0.5, &f, 63)                        // quaternion
        f[67] = FlightStates.droguePrimaryEvent.rawValue
        f[68] = 1
        put(UInt32(0xCAFEBABE), &f, 69)
        put(UInt32(0x0BADF00D), &f, 73)
        put(Int16(-85), &f, 77)
        f[79] = UInt8(bitPattern: -3)
        put(Int16(-110), &f, 80)
        f[82] = 1
        sealCrc(&f)

        let m = try XCTUnwrap(TelemetryData.parse(f))
        XCTAssertEqual(47.0, m.latitude, accuracy: 1e-9)
        XCTAssertEqual(-122.0, m.longitude, accuracy: 1e-9)
        XCTAssertEqual(9, m.satellites)
        XCTAssertEqual(1.5, m.horizontalAccuracy)
        XCTAssertEqual(.error, m.gpsStatus)
        XCTAssertEqual([0x11, 0x22, 0x33, 0x44], m.deploymentChannelStats)
        XCTAssertEqual(0x55, m.physicalDeploymentStats)
        XCTAssertEqual(250.5, m.altitudeAgl)
        XCTAssertEqual(Vec3f(x: -1, y: -2, z: -30), m.velocityNed)
        XCTAssertEqual(Quaternionf(w: 0.5, x: 0.5, y: 0.5, z: 0.5), m.attitude)
        XCTAssertEqual(.droguePrimaryEvent, m.flightState)
        XCTAssertTrue(m.armed)
        XCTAssertEqual(0xCAFEBABE, m.locatorId)
        XCTAssertEqual(0x0BADF00D, m.authTag)
        XCTAssertEqual(-85, m.rssi)
        XCTAssertEqual(-3, m.snr)
        XCTAssertEqual(-110, m.noiseFloor)
        XCTAssertEqual(1, m.badFrames)
    }

    // MARK: - The parser and the auth layer must agree about where the tag is

    /// `LocatorAuth` finds `auth_tag` by offset from the END of the base struct; the
    /// parser walks to it field by field. If those two ever disagree the app does not
    /// fail to parse — it authenticates the wrong bytes, which fails closed or open.
    func testParsedAuthTagIsTheOneLocatorAuthVerifies() throws {
        for (type, total, base) in [
            (MsgType.preLaunchData, 147, WireProtocol.prelaunchBaseStructSize),
            (MsgType.telemetryData, 83, WireProtocol.telemetryBaseStructSize),
        ] {
            var f = blank(type, total: total)
            for i in 6..<total { f[i] = UInt8(truncatingIfNeeded: i &* 7 &+ 3) }
            f[1] = type.rawValue

            let key = LocatorAuth.deriveKey("s3cret")
            let tag = try XCTUnwrap(LocatorAuth.expectedAuthTag(frame: f, passwordKey: key, baseSize: base))
            f[base - 4] = UInt8(truncatingIfNeeded: tag)
            f[base - 3] = UInt8(truncatingIfNeeded: tag >> 8)
            f[base - 2] = UInt8(truncatingIfNeeded: tag >> 16)
            f[base - 1] = UInt8(truncatingIfNeeded: tag >> 24)
            sealCrc(&f)

            XCTAssertTrue(LocatorAuth.verifyFrame(frame: f, passwordKey: key, baseSize: base))

            let parsedTag: UInt32 = type == .preLaunchData
                ? try XCTUnwrap(PreLaunchData.parse(f)).authTag
                : try XCTUnwrap(TelemetryData.parse(f)).authTag
            XCTAssertEqual(tag, parsedTag, "\(type): parser and auth layer disagree about auth_tag")
        }
    }

    // MARK: - Safety

    func testShortFrameReturnsNilRatherThanTrapping() {
        XCTAssertNil(PreLaunchData.parse([UInt8](repeating: 0, count: 146)))
        XCTAssertNil(TelemetryData.parse([UInt8](repeating: 0, count: 82)))
        XCTAssertNil(PreLaunchData.parse([]))
    }

    /// Unknown enum values must resolve to the safe reading, never the reassuring one.
    func testUnknownEnumValuesFailSafe() throws {
        var f = blank(.telemetryData, total: 83)
        f[27] = 200                                  // unknown sensor health
        f[67] = 200                                  // unknown flight state
        sealCrc(&f)
        let m = try XCTUnwrap(TelemetryData.parse(f))
        XCTAssertEqual(.stale, m.imuStatus, "unknown health must not read as healthy")
        XCTAssertEqual(.noSignal, m.flightState, "unknown state must not read as a real state")

        var p = blank(.preLaunchData, total: 147)
        p[109] = 200                                 // unknown pad-alert encoding
        sealCrc(&p)
        let pm = try XCTUnwrap(PreLaunchData.parse(p))
        XCTAssertNotEqual(.quiet, pm.padAlert, "an uninterpretable alert must not present as quiet")
    }

    /// A frame straight off the framer must parse — ties the two layers together.
    func testFrameFromTheFramerParses() throws {
        var f = blank(.preLaunchData, total: 147)
        putName("Rocket", &f, 85)
        put(UInt32(1234), &f, 110)
        sealCrc(&f)

        var framer = PacketFramer()
        let out = framer.append(f)
        XCTAssertEqual(1, out.count)
        let m = try XCTUnwrap(PreLaunchData.parse(try XCTUnwrap(out.first)))
        XCTAssertEqual("Rocket", m.deviceName)
        XCTAssertEqual(1234, m.locatorId)
    }
}

/// Deployment-channel continuity, which is encoded **differently** in the two
/// broadcasts — bits 0–3 of one byte on the pad, bit 5 of each per-channel byte in
/// flight. Two encodings for the same fact, so decoding one as the other would show
/// a rocket with no igniters as fully armed, or the reverse.
final class DeployContinuityTests: XCTestCase {

    func testPrelaunchUsesBitsZeroToThree() {
        var m = PreLaunchData()
        m.deployStatus = 0b0000_0101          // channels 1 and 3
        XCTAssertEqual([true, false, true, false], m.deployChannelContinuity)
    }

    func testPrelaunchNoContinuityAtAll() {
        var m = PreLaunchData()
        m.deployStatus = 0
        XCTAssertEqual([false, false, false, false], m.deployChannelContinuity)
    }

    func testPrelaunchAllFour() {
        var m = PreLaunchData()
        m.deployStatus = 0b0000_1111
        XCTAssertEqual([true, true, true, true], m.deployChannelContinuity)
    }

    /// Bits above 3 belong to other fields and must not read as a fifth channel.
    func testPrelaunchIgnoresHigherBits() {
        var m = PreLaunchData()
        m.deployStatus = 0b1111_0000
        XCTAssertEqual([false, false, false, false], m.deployChannelContinuity)
    }

    func testTelemetryUsesBitFiveOfEachChannelByte() {
        var m = TelemetryData()
        m.deploymentChannelStats = [0x20, 0x00, 0x20, 0x00]
        XCTAssertEqual([true, false, true, false], m.deployChannelContinuity)
    }

    /// The other bits in that byte are mode, fired and pre-fire continuity — none of
    /// which means post-fire continuity.
    func testTelemetryIgnoresTheOtherBits() {
        var m = TelemetryData()
        m.deploymentChannelStats = [0x1F, 0x1F, 0x1F, 0x1F]   // everything except bit 5
        XCTAssertEqual([false, false, false, false], m.deployChannelContinuity)
    }

    /// The two encodings must not be interchangeable — if they were, one decoder
    /// would do and this test would be impossible to write.
    func testTheTwoEncodingsGenuinelyDiffer() {
        var pre = PreLaunchData()
        pre.deployStatus = 0x20                    // bit 5: nothing, on the pad
        XCTAssertEqual([false, false, false, false], pre.deployChannelContinuity)

        var tel = TelemetryData()
        tel.deploymentChannelStats = [0x01, 0x01, 0x01, 0x01]   // bit 0: nothing, in flight
        XCTAssertEqual([false, false, false, false], tel.deployChannelContinuity)
    }
}
