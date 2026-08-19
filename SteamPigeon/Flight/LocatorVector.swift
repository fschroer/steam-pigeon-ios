import Foundation

/// Where the rocket is, relative to the phone.
struct LocatorVector: Equatable {
    /// Great-circle ground distance, metres.
    let distanceM: Int
    /// True-north azimuth, degrees 0..<360.
    let azimuthDeg: Double
    /// Elevation above the horizon, degrees.
    let elevationDeg: Double

    /// Spoken compass point — "northeast" and so on.
    var ordinal: String {
        switch Int(azimuthDeg.rounded(.down)) {
        case 0...22, 338...359: return "north"
        case 23...67:           return "northeast"
        case 68...112:          return "east"
        case 113...157:         return "southeast"
        case 158...202:         return "south"
        case 203...247:         return "southwest"
        case 248...292:         return "west"
        case 293...337:         return "northwest"
        default:                return ""
        }
    }

    /// Haversine distance and initial bearing from `from` to `to`.
    ///
    /// **Ground distance only — there is no altitude term.** That is what makes the
    /// ADR-0022 speed bounds ground-speed bounds: a Mach 5 boost is Mach 5
    /// *vertically* and adds almost nothing here.
    static func between(from: (lat: Double, lon: Double),
                        to: (lat: Double, lon: Double),
                        altitudeAglM: Float = 0) -> LocatorVector {
        let earthRadiusM = 6_371_000.0

        let lat1 = from.lat * .pi / 180
        let lat2 = to.lat * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (to.lon - from.lon) * .pi / 180

        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        let distance = Int(earthRadiusM * c)

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let azimuth = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)

        let elevation = (atan2(Double(altitudeAglM), Double(distance)) * 180 / .pi + 360)
            .truncatingRemainder(dividingBy: 360)

        return LocatorVector(distanceM: distance, azimuthDeg: azimuth, elevationDeg: elevation)
    }
}

extension FlightStates {
    /// On the ground: before launch detection, or after landing detection.
    var isGrounded: Bool { self == .waitingLaunch || self == .landed }

    /// In the air: anywhere between launch detection and landing detection.
    var isAirborne: Bool { rawValue >= FlightStates.launched.rawValue
                        && rawValue <= FlightStates.mainBackupEvent.rawValue }
}
