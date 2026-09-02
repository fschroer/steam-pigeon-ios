import Foundation

/// The app-side flight log: what the phone saw, as opposed to what the locator archived.
///
/// The locator's own archive is the authority on the flight — 20 Hz, GPS-disciplined, and
/// downloadable afterwards (`FlightDataRepository`). It cannot answer a different class of
/// question, because it does not know any of it: what the RSSI and SNR were at the phone,
/// when the app decided the link had degraded, what it announced out loud and when. Those
/// live only here, they are gone the moment the app is closed, and during a flight nobody
/// can watch them go past.
///
/// So this is deliberately NOT a second copy of the telemetry. It is the received frame
/// *plus* the receiver's measurement of how it arrived *plus* what the app did about it,
/// on one timeline, which is the only place those three can be compared.
///
/// ## Rate
///
/// The locator transmits exactly once per second — a 20 Hz superloop
/// (`SAMPLES_PER_SECOND`) whose `case 2` is the only branch that reaches the radio, so one
/// frame per second, pre-launch or telemetry, armed or not. Every received frame is
/// logged; at 1 Hz there is nothing to downsample and no reason to.
///
/// ## Format
///
/// A pure CSV with one wide schema: ``csvHeader``. Sample rows leave the event columns
/// blank, event rows leave the telemetry columns blank, and a column a given message type
/// does not carry is blank rather than zero — 0 m AGL is a real reading and must not be
/// confused with "this message has no altitude".
///
/// There is no `#` metadata preamble. Everything about the file that is not a measurement
/// rides in ``LogEvent/sessionOpened`` as an ordinary row, so the file opens in Excel,
/// `pandas.read_csv` and `csvkit` with no options and no dialect.
///
/// Ported from Android's `data/FlightLog.kt` (ADR-0030). Timestamps are `Date` where
/// Android uses epoch milliseconds; the rendering is identical.
enum FlightLog {

    /// Fixed formats use `en_US_POSIX`, on purpose and not as a default.
    ///
    /// This is the same requirement as Android's explicit `Locale.US`: a phone set to a
    /// locale with a comma decimal separator would otherwise render `-27,5` for an SNR and
    /// put a field break in the middle of a number, silently, on the device of whoever is
    /// least likely to notice. The file is a data interchange format, so its number format
    /// is fixed rather than the user's. (`String(format:)` is already unlocalized, which
    /// covers the numbers; the date formatters need saying out loud.)
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Wall-clock stamp, ISO-8601 with offset so a log is placeable without a note.
    private static func timestampFormatter(_ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = posix
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"
        return f
    }

    /// The date-time half of a log's filename — see ``fileName(locatorName:at:zone:)``.
    private static func fileNameFormatter(_ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = posix
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }

    static let fileExtension = ".csv"

    static let csvHeader = [
        "timestamp", "elapsed_s", "source", "event", "detail",
        "flight_state", "lat", "lon", "agl_m",
        "vel_n_ms", "vel_e_ms", "vel_d_ms",
        "accel_x", "accel_y", "accel_z",
        "gyro_x", "gyro_y", "gyro_z",
        "q_w", "q_x", "q_y", "q_z",
        "satellites", "hacc_m",
        "rssi_dbm", "snr_db", "noise_floor_dbm", "bad_frames", "link_quality",
        "armed", "deploy_armed_mask", "deploy_fired_mask",
        "drogue_detected", "main_detected", "pad_alert",
        "locator_batt_mv", "receiver_batt_mv", "receiver_channel", "locator_id",
    ].joined(separator: ",")

    /// Number of columns in ``csvHeader``; every row renders exactly this many.
    static let columnCount = csvHeader.filter { $0 == "," }.count + 1

    // MARK: - Naming

    /// Fallback when a locator name is empty or entirely unusable.
    static let unnamedLocator = "locator"

    private static let maxNameChars = 24

    /// `<locator>_YYYY-MM-DD_HHmmss.csv`, in the phone's own zone.
    ///
    /// Local time rather than UTC because the name is read by a person deciding which of
    /// six logs was the flight after lunch, and a launch at 14:20 local filed under 21:20
    /// is the wrong answer to that question. The rows carry the offset, so nothing is lost.
    ///
    /// The locator name is sanitised to `[A-Za-z0-9._-]` and truncated: it comes off the
    /// wire as an arbitrary 20-byte field the user typed, and a `/` in it would otherwise
    /// name a directory that does not exist. An empty or entirely unusable name falls back
    /// to ``unnamedLocator`` rather than producing a file that begins with the separator.
    static func fileName(locatorName: String, at date: Date, zone: TimeZone) -> String {
        let mapped = String(locatorName.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_" ? ch : "_"
        })
        var safe = String(mapped.prefix(maxNameChars))
        while safe.hasPrefix("_") { safe.removeFirst() }
        while safe.hasSuffix("_") { safe.removeLast() }
        if safe.isEmpty { safe = unnamedLocator }
        return "\(safe)_\(fileNameFormatter(zone).string(from: date))\(fileExtension)"
    }

    // MARK: - Rendering

    /// One CSV row.
    ///
    /// `t0` is the launch-detect instant, so `elapsed_s` runs negative through the pre-roll
    /// and crosses zero at the launch — which is what makes "two seconds before launch
    /// detect" checkable by looking at the file rather than trusting the code that wrote it.
    static func row(_ record: FlightLogRecord, t0: Date, zone: TimeZone) -> String {
        var cells = [String](repeating: "", count: columnCount)
        cells[0] = timestampFormatter(zone).string(from: record.timestamp)
        cells[1] = num(record.timestamp.timeIntervalSince(t0), 3)
        cells[2] = record.source.label

        switch record {
        case .event(let e):
            cells[3] = e.event.label
            cells[4] = escape(e.detail)
        case .sample(let s):
            cells[5] = s.flightState?.logName ?? ""
            cells[6] = num(s.latitude, 7)
            cells[7] = num(s.longitude, 7)
            cells[8] = num(s.aglM, 2)
            cells[9]  = num(s.velNed?.x, 2)
            cells[10] = num(s.velNed?.y, 2)
            cells[11] = num(s.velNed?.z, 2)
            cells[12] = num(s.accel?.x, 3)
            cells[13] = num(s.accel?.y, 3)
            cells[14] = num(s.accel?.z, 3)
            cells[15] = num(s.gyro?.x, 3)
            cells[16] = num(s.gyro?.y, 3)
            cells[17] = num(s.gyro?.z, 3)
            cells[18] = num(s.attitude?.w, 5)
            cells[19] = num(s.attitude?.x, 5)
            cells[20] = num(s.attitude?.y, 5)
            cells[21] = num(s.attitude?.z, 5)
            cells[22] = s.satellites.map(String.init) ?? ""
            cells[23] = num(s.haccM, 2)
            cells[24] = s.rssi.map(String.init) ?? ""
            cells[25] = s.snr.map(String.init) ?? ""
            // The receiver reports "unknown" as a sentinel rather than a reading. Writing
            // the sentinel would put a plausible-looking −32768 dBm floor in the data, so
            // it goes out blank.
            cells[26] = s.noiseFloor.flatMap {
                $0 == LinkQuality.noiseFloorUnknown ? nil : String($0)
            } ?? ""
            cells[27] = s.badFrames.map(String.init) ?? ""
            cells[28] = s.linkQuality?.logName ?? ""
            cells[29] = s.armed.map { $0 ? "1" : "0" } ?? ""
            cells[30] = s.deployArmedMask.map(String.init) ?? ""
            cells[31] = s.deployFiredMask.map(String.init) ?? ""
            cells[32] = s.drogueDetected.map { $0 ? "1" : "0" } ?? ""
            cells[33] = s.mainDetected.map { $0 ? "1" : "0" } ?? ""
            cells[34] = s.padAlert?.logName ?? ""
            cells[35] = s.locatorBatteryMv.map(String.init) ?? ""
            cells[36] = s.receiverBatteryMv.map(String.init) ?? ""
            cells[37] = s.receiverChannel.map(String.init) ?? ""
            cells[38] = s.locatorId.map(String.init) ?? ""
        }
        return cells.joined(separator: ",")
    }

    /// A number that is absent, infinite or NaN renders blank rather than as text.
    ///
    /// `nan` in a numeric column stops most readers dead or, worse, is read as a category
    /// and turns the whole column into strings. AGL arrives non-finite often enough that
    /// the live path guards against it too.
    ///
    /// `String(format:)` is unlocalized, which is what keeps the decimal separator a dot
    /// on a phone set to a comma locale.
    private static func num(_ v: Double?, _ decimals: Int) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(decimals)f", v)
    }

    private static func num(_ v: Float?, _ decimals: Int) -> String {
        num(v.map(Double.init), decimals)
    }

    /// Minimal RFC 4180 quoting, for the one column that carries free text.
    private static func escape(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Which stream a row came from — the message type, or the app itself.
enum LogSource: String {
    case prelaunch, telemetry, receiverInfo, app

    var label: String {
        switch self {
        case .prelaunch:    return "prelaunch"
        case .telemetry:    return "telemetry"
        case .receiverInfo: return "receiver_info"
        case .app:          return "app"
        }
    }
}

/// App-side occurrences worth a row.
///
/// The list is short on purpose. Everything here is either a decision the app made that is
/// invisible afterwards (`linkQualityChanged`, `announcement`) or a boundary that explains
/// a discontinuity in the rows around it (`receiverChannelChanged`, `connectionChanged`) —
/// without which a gap in a log is indistinguishable from a radio dropout, which is exactly
/// the thing the log exists to measure.
///
/// Nothing here restates a column. The pad-alert verdict and the per-channel fired bits
/// ride on every frame as `pad_alert` and `deploy_fired_mask`, so an event for either would
/// be a second, lower-rate copy of a fact the rows already carry — and two sources for one
/// fact is two things that can disagree.
enum LogEvent {
    /// First row of every file: locator, app version, why the log opened.
    case sessionOpened
    /// Last row of every file, carrying the close reason.
    case sessionClosed
    /// The grounded → airborne transition this log is named for.
    case launchDetected
    /// The locator said Landed, or the app concluded it. Does not end the log.
    case landingDetected
    case flightStateChanged
    /// Spoken aloud. The event's `detail` is the exact text.
    case announcement
    case linkQualityChanged
    /// The BLE link to the receiver came up or went down.
    ///
    /// Load-bearing since a dropped link stopped closing the log: a gap in the rows is
    /// otherwise ambiguous between "the rocket went quiet" — which is about the LoRa link
    /// and is what the log exists to measure — and "the phone lost the receiver in your
    /// pocket", which is about neither.
    case connectionChanged
    case armedStateChanged
    case receiverChannelChanged
    case locatorChanged

    var label: String {
        switch self {
        case .sessionOpened:         return "session_opened"
        case .sessionClosed:         return "session_closed"
        case .launchDetected:        return "launch_detected"
        case .landingDetected:       return "landing_detected"
        case .flightStateChanged:    return "flight_state_changed"
        case .announcement:          return "announcement"
        case .linkQualityChanged:    return "link_quality_changed"
        case .connectionChanged:     return "connection_changed"
        case .armedStateChanged:     return "armed_state_changed"
        case .receiverChannelChanged: return "receiver_channel_changed"
        case .locatorChanged:        return "locator_changed"
        }
    }
}

/// Why an open log stopped — the `sessionClosed` detail.
enum LogCloseReason {
    case disarmed
    case receiverChannelChanged
    case locatorChanged
    case newLaunch
    case appStopped

    var label: String {
        switch self {
        case .disarmed:               return "locator disarmed"
        case .receiverChannelChanged: return "receiver channel changed"
        case .locatorChanged:         return "connected locator changed"
        case .newLaunch:              return "a new launch was detected"
        case .appStopped:             return "app stopped"
        }
    }
}

/// One line of a log: a received frame, or something the app did.
enum FlightLogRecord {

    /// A received frame.
    ///
    /// Every field is optional because the two message types are near-disjoint —
    /// `PreLaunchData` carries the IMU and the batteries, `TelemetryData` carries velocity,
    /// attitude and flight state, and neither carries the other's. Nil means "this message
    /// type has no such field", which the renderer writes as blank; it is never a zero.
    struct Sample {
        var timestamp: Date
        var source: LogSource
        var flightState: FlightStates?
        var latitude: Double?
        var longitude: Double?
        var aglM: Float?
        var velNed: Vec3f?
        var accel: Vec3f?
        var gyro: Vec3f?
        var attitude: Quaternionf?
        var satellites: Int?
        var haccM: Float?
        var rssi: Int?
        var snr: Int?
        var noiseFloor: Int?
        var badFrames: Int?
        var linkQuality: LinkQuality.Verdict?
        var armed: Bool?
        var deployArmedMask: Int?
        var deployFiredMask: Int?
        var drogueDetected: Bool?
        var mainDetected: Bool?
        var padAlert: PadAlertState?
        var locatorBatteryMv: Int?
        var receiverBatteryMv: Int?
        var receiverChannel: Int?
        var locatorId: UInt32?

        init(timestamp: Date,
             source: LogSource,
             flightState: FlightStates? = nil,
             latitude: Double? = nil,
             longitude: Double? = nil,
             aglM: Float? = nil,
             velNed: Vec3f? = nil,
             accel: Vec3f? = nil,
             gyro: Vec3f? = nil,
             attitude: Quaternionf? = nil,
             satellites: Int? = nil,
             haccM: Float? = nil,
             rssi: Int? = nil,
             snr: Int? = nil,
             noiseFloor: Int? = nil,
             badFrames: Int? = nil,
             linkQuality: LinkQuality.Verdict? = nil,
             armed: Bool? = nil,
             deployArmedMask: Int? = nil,
             deployFiredMask: Int? = nil,
             drogueDetected: Bool? = nil,
             mainDetected: Bool? = nil,
             padAlert: PadAlertState? = nil,
             locatorBatteryMv: Int? = nil,
             receiverBatteryMv: Int? = nil,
             receiverChannel: Int? = nil,
             locatorId: UInt32? = nil) {
            self.timestamp = timestamp
            self.source = source
            self.flightState = flightState
            self.latitude = latitude
            self.longitude = longitude
            self.aglM = aglM
            self.velNed = velNed
            self.accel = accel
            self.gyro = gyro
            self.attitude = attitude
            self.satellites = satellites
            self.haccM = haccM
            self.rssi = rssi
            self.snr = snr
            self.noiseFloor = noiseFloor
            self.badFrames = badFrames
            self.linkQuality = linkQuality
            self.armed = armed
            self.deployArmedMask = deployArmedMask
            self.deployFiredMask = deployFiredMask
            self.drogueDetected = drogueDetected
            self.mainDetected = mainDetected
            self.padAlert = padAlert
            self.locatorBatteryMv = locatorBatteryMv
            self.receiverBatteryMv = receiverBatteryMv
            self.receiverChannel = receiverChannel
            self.locatorId = locatorId
        }
    }

    struct Event {
        var timestamp: Date
        var event: LogEvent
        var detail: String = ""
        var source: LogSource = .app
    }

    case sample(Sample)
    case event(Event)

    var timestamp: Date {
        switch self {
        case .sample(let s): return s.timestamp
        case .event(let e):  return e.timestamp
        }
    }

    var source: LogSource {
        switch self {
        case .sample(let s): return s.source
        case .event(let e):  return e.source
        }
    }
}

// MARK: - Enum names as the CSV writes them
//
// Android renders `enumValue.name`, so these are Kotlin's case names rather than the
// display text the UI uses. `FlightStates.label` is deliberately NOT this: it maps every
// state to prose for the stats panel, and a log column carrying "Drogue Primary" would not
// match what the Android app writes for the same flight.

extension FlightStates {
    var logName: String {
        switch self {
        case .waitingLaunch:      return "WaitingLaunch"
        case .launched:           return "Launched"
        case .burnout:            return "Burnout"
        case .noseover:           return "Noseover"
        case .droguePrimaryEvent: return "DroguePrimaryEvent"
        case .drogueBackupEvent:  return "DrogueBackupEvent"
        case .mainPrimaryEvent:   return "MainPrimaryEvent"
        case .mainBackupEvent:    return "MainBackupEvent"
        case .landed:             return "Landed"
        case .noSignal:           return "NoSignal"
        }
    }
}

extension LinkQuality.Verdict {
    var logName: String {
        switch self {
        case .normal:       return "Normal"
        case .congested:    return "Congested"
        case .interference: return "Interference"
        }
    }
}

extension PadAlertState {
    var logName: String {
        switch self {
        case .quiet:    return "Quiet"
        case .alerting: return "Alerting"
        case .snoozed:  return "Snoozed"
        }
    }
}
