import Foundation

/// The locator's unsolicited `PreLaunchData` broadcast, as relayed by the receiver.
///
/// Sent while **disarmed**. Field order and offsets mirror the firmware struct and
/// Android's `parsePrelaunch`; the offsets are asserted to land on
/// `prelaunchBaseStructSize` (118) and the full relayed length (147), so a drift
/// fails a test rather than silently shifting every field after it.
struct PreLaunchData: Equatable {
    // Locator
    var latitude = 0.0
    var longitude = 0.0
    var rawLatitude = 0.0
    var rawLongitude = 0.0
    var satellites: UInt8 = 0
    var horizontalAccuracy: Float = 0
    var imuStatus: SensorHealth = .stale
    var baroStatus: SensorHealth = .stale
    var gpsStatus: SensorHealth = .stale
    var deployStatus: UInt8 = 0

    /// Continuity per deployment channel, bits 0–3 of `deployStatus`.
    ///
    /// A channel with no continuity is drawn in the error colour: it means the app
    /// cannot see an igniter on that channel, which is exactly what someone checks
    /// before walking away from an armed rocket.
    var deployChannelContinuity: [Bool] {
        (0..<4).map { deployStatus & (1 << UInt8($0)) != 0 }
    }
    var altitudeAgl: Float = 0
    var accel = Vec3f(x: 0, y: 0, z: 0)
    var gyro = Vec3f(x: 0, y: 0, z: 0)
    var deployChannelModes: [DeployMode] = []
    var droguePrimaryDelay: UInt8 = 0
    var drogueBackupDelay: UInt8 = 0
    var mainPrimaryAltitude: UInt16 = 0
    var mainBackupAltitude: UInt16 = 0
    var deviceName = ""
    var locatorBatteryMv: UInt16 = 0
    var noseAxis: NoseAxis = .auto
    /// Stated arm state (ADR-0021, #35). Inside the authenticated region.
    var armed = false
    var padAlert: PadAlertState = .quiet
    var padAlertSnoozeMinutes = 0
    /// The 32-bit identity everything keys on (ADR-0006). Platform-neutral.
    var locatorId: UInt32 = 0
    var authTag: UInt32 = 0

    // Receiver-appended — outside the authenticated region
    var channel: UInt8 = 0
    var receiverBatteryMv: UInt16 = 0
    var receiverName = ""
    var rssi: Int16 = 0
    var snr: Int8 = 0
    var noiseFloor: Int16 = 0
    var badFrames: UInt8 = 0

    /// Decode a CRC-verified frame. Returns nil if it is too short — a frame that
    /// passed CRC should never be, but this layer refuses to read past its buffer.
    static func parse(_ f: [UInt8]) -> PreLaunchData? {
        guard f.count >= WireProtocol.headerSize + WireProtocol.prelaunchMessagePayloadSize
        else { return nil }

        var o = WireProtocol.headerSize
        var m = PreLaunchData()

        guard let lat = Bytes.f64(f, o) else { return nil };            o += 8; m.latitude = lat
        guard let lon = Bytes.f64(f, o) else { return nil };            o += 8; m.longitude = lon
        guard let rlat = Bytes.f64(f, o) else { return nil };           o += 8; m.rawLatitude = rlat
        guard let rlon = Bytes.f64(f, o) else { return nil };           o += 8; m.rawLongitude = rlon
        guard let sats = Bytes.u8(f, o) else { return nil };            o += 1; m.satellites = sats
        guard let hacc = Bytes.f32(f, o) else { return nil };           o += 4; m.horizontalAccuracy = hacc

        guard let imu = Bytes.u8(f, o) else { return nil };             o += 1; m.imuStatus = .from(imu)
        guard let baro = Bytes.u8(f, o) else { return nil };            o += 1; m.baroStatus = .from(baro)
        guard let gps = Bytes.u8(f, o) else { return nil };             o += 1; m.gpsStatus = .from(gps)

        guard let dep = Bytes.u8(f, o) else { return nil };             o += 1; m.deployStatus = dep
        guard let agl = Bytes.f32(f, o) else { return nil };            o += 4; m.altitudeAgl = agl

        guard let accel = Vec3f.read(f, o) else { return nil };         o += 12; m.accel = accel
        guard let gyro = Vec3f.read(f, o) else { return nil };          o += 12; m.gyro = gyro

        var modes: [DeployMode] = []
        for _ in 0..<4 {
            guard let raw = Bytes.u8(f, o) else { return nil }
            modes.append(.from(raw)); o += 1
        }
        m.deployChannelModes = modes

        guard let dp = Bytes.u8(f, o) else { return nil };              o += 1; m.droguePrimaryDelay = dp
        guard let db = Bytes.u8(f, o) else { return nil };              o += 1; m.drogueBackupDelay = db
        guard let mp = Bytes.u16(f, o) else { return nil };             o += 2; m.mainPrimaryAltitude = mp
        guard let mb = Bytes.u16(f, o) else { return nil };             o += 2; m.mainBackupAltitude = mb

        guard let name = Bytes.name(f, o, length: WireProtocol.deviceNameLength) else { return nil }
        o += WireProtocol.deviceNameLength; m.deviceName = name

        guard let batt = Bytes.u16(f, o) else { return nil };           o += 2; m.locatorBatteryMv = batt
        guard let axis = Bytes.u8(f, o) else { return nil };            o += 1; m.noseAxis = .from(axis)
        guard let armed = Bytes.u8(f, o) else { return nil };           o += 1; m.armed = armed != 0
        guard let alert = Bytes.u8(f, o) else { return nil }
        m.padAlert = .from(alert)
        m.padAlertSnoozeMinutes = PadAlertState.snoozeMinutes(alert);   o += 1

        guard let id = Bytes.u32(f, o) else { return nil };             o += 4; m.locatorId = id
        guard let tag = Bytes.u32(f, o) else { return nil };            o += 4; m.authTag = tag

        // Everything above is the authenticated base struct. Anything below is
        // appended by the receiver and is deliberately outside the auth_tag.
        assert(o == WireProtocol.prelaunchBaseStructSize)

        guard let ch = Bytes.u8(f, o) else { return nil };              o += 1; m.channel = ch
        guard let rb = Bytes.u16(f, o) else { return nil };             o += 2; m.receiverBatteryMv = rb
        guard let rn = Bytes.name(f, o, length: WireProtocol.deviceNameLength) else { return nil }
        o += WireProtocol.deviceNameLength; m.receiverName = rn
        guard let rssi = Bytes.i16(f, o) else { return nil };           o += 2; m.rssi = rssi
        guard let snr = Bytes.i8(f, o) else { return nil };             o += 1; m.snr = snr
        guard let nf = Bytes.i16(f, o) else { return nil };             o += 2; m.noiseFloor = nf
        guard let bf = Bytes.u8(f, o) else { return nil };              o += 1; m.badFrames = bf

        assert(o == WireProtocol.headerSize + WireProtocol.prelaunchMessagePayloadSize)
        return m
    }
}

/// The locator's unsolicited `TelemetryData` broadcast, sent while **armed**.
///
/// Carries the same trailing `locator_id` + `auth_tag` pair as `PreLaunchData`,
/// which is what lets the app recognize an armed locator it has never heard a
/// `PreLaunchData` from this session. Before that pair was added, opening the app
/// mid-flight showed "No Locator" for the whole flight.
struct TelemetryData: Equatable {
    var latitude = 0.0
    var longitude = 0.0
    var satellites: UInt8 = 0
    var horizontalAccuracy: Float = 0
    var imuStatus: SensorHealth = .stale
    var baroStatus: SensorHealth = .stale
    var gpsStatus: SensorHealth = .stale
    var deploymentChannelStats: [UInt8] = []
    var physicalDeploymentStats: UInt8 = 0

    /// Continuity per channel while armed — **bit 5** of each channel's stats byte,
    /// not bits 0–3 of a single byte as in `PreLaunchData`. Two encodings for the
    /// same fact, so they are decoded separately rather than assumed alike.
    var deployChannelContinuity: [Bool] {
        deploymentChannelStats.map { $0 & 0x20 != 0 }
    }
    var altitudeAgl: Float = 0
    var velocityNed = Vec3f(x: 0, y: 0, z: 0)
    var attitude = Quaternionf(w: 0, x: 0, y: 0, z: 0)
    var flightState: FlightStates = .noSignal
    var armed = false
    var locatorId: UInt32 = 0
    var authTag: UInt32 = 0

    // Receiver-appended — outside the authenticated region
    var rssi: Int16 = 0
    var snr: Int8 = 0
    var noiseFloor: Int16 = 0
    var badFrames: UInt8 = 0

    static func parse(_ f: [UInt8]) -> TelemetryData? {
        guard f.count >= WireProtocol.headerSize + WireProtocol.telemetryMessagePayloadSize
        else { return nil }

        var o = WireProtocol.headerSize
        var m = TelemetryData()

        guard let lat = Bytes.f64(f, o) else { return nil };            o += 8; m.latitude = lat
        guard let lon = Bytes.f64(f, o) else { return nil };            o += 8; m.longitude = lon
        guard let sats = Bytes.u8(f, o) else { return nil };            o += 1; m.satellites = sats
        guard let hacc = Bytes.f32(f, o) else { return nil };           o += 4; m.horizontalAccuracy = hacc

        guard let imu = Bytes.u8(f, o) else { return nil };             o += 1; m.imuStatus = .from(imu)
        guard let baro = Bytes.u8(f, o) else { return nil };            o += 1; m.baroStatus = .from(baro)
        guard let gps = Bytes.u8(f, o) else { return nil };             o += 1; m.gpsStatus = .from(gps)

        var stats: [UInt8] = []
        for _ in 0..<4 {
            guard let s = Bytes.u8(f, o) else { return nil }
            stats.append(s); o += 1
        }
        m.deploymentChannelStats = stats

        guard let phys = Bytes.u8(f, o) else { return nil };            o += 1; m.physicalDeploymentStats = phys
        guard let agl = Bytes.f32(f, o) else { return nil };            o += 4; m.altitudeAgl = agl
        guard let vel = Vec3f.read(f, o) else { return nil };           o += 12; m.velocityNed = vel

        guard let qw = Bytes.f32(f, o), let qx = Bytes.f32(f, o + 4),
              let qy = Bytes.f32(f, o + 8), let qz = Bytes.f32(f, o + 12) else { return nil }
        m.attitude = Quaternionf(w: qw, x: qx, y: qy, z: qz);           o += 16

        guard let st = Bytes.u8(f, o) else { return nil };              o += 1; m.flightState = .from(st)
        guard let armed = Bytes.u8(f, o) else { return nil };           o += 1; m.armed = armed != 0
        guard let id = Bytes.u32(f, o) else { return nil };             o += 4; m.locatorId = id
        guard let tag = Bytes.u32(f, o) else { return nil };            o += 4; m.authTag = tag

        assert(o == WireProtocol.telemetryBaseStructSize)

        guard let rssi = Bytes.i16(f, o) else { return nil };           o += 2; m.rssi = rssi
        guard let snr = Bytes.i8(f, o) else { return nil };             o += 1; m.snr = snr
        guard let nf = Bytes.i16(f, o) else { return nil };             o += 2; m.noiseFloor = nf
        guard let bf = Bytes.u8(f, o) else { return nil };              o += 1; m.badFrames = bf

        assert(o == WireProtocol.headerSize + WireProtocol.telemetryMessagePayloadSize)
        return m
    }
}
