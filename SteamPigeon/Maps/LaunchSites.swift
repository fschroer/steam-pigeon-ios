import CoreLocation
import Foundation

/// A geographic box, in the terms the download screen thinks in.
///
/// Its own type rather than `MLNCoordinateBounds` so the tile arithmetic and the CSV
/// parsing stay testable without a map: MapLibre's bounds type is a C struct from a
/// framework that wants a live view to be interesting.
struct GeoBounds: Equatable {
    var north: Double
    var south: Double
    var east: Double
    var west: Double

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (north + south) / 2, longitude: (east + west) / 2)
    }

    /// Approximate ground size as (widthKm, heightKm).
    ///
    /// Coverage is the question that actually matters when sizing a region — the live
    /// map's viewport is a rotating window that pans over it, not a shape to match — so
    /// the screen surfaces this next to the tile and byte estimate.
    var groundSizeKm: (width: Double, height: Double) {
        let heightKm = (north - south) * 111.32
        let centerLat = (north + south) / 2
        let widthKm = (east - west) * 111.32 * cos(centerLat * .pi / 180)
        return (abs(widthKm), abs(heightKm))
    }
}

/// Bounding box of `widthKm` × `heightKm` centred on a point.
func boundsAround(lat: Double, lon: Double, widthKm: Double, heightKm: Double) -> GeoBounds {
    let latDelta = (heightKm / 2) / 111.32
    // Longitude degrees shrink with latitude; guard the cos term near the poles.
    let lonDelta = (widthKm / 2) / (111.32 * max(cos(lat * .pi / 180), 0.01))
    return GeoBounds(north: min(max(lat + latDelta, -85), 85),
                     south: min(max(lat - latDelta, -85), 85),
                     east: lon + lonDelta,
                     west: lon - lonDelta)
}

/// A named area to cache, centred on `lat`/`lon` with total extents in km.
struct LaunchSite: Equatable, Identifiable {
    let name: String
    let lat: Double
    let lon: Double
    let widthKm: Double
    let heightKm: Double

    var id: String { "\(name)|\(lat)|\(lon)" }

    var bounds: GeoBounds { boundsAround(lat: lat, lon: lon, widthKm: widthKm, heightKm: heightKm) }
}

/// Preset launch sites for the offline map download screen.
///
/// Android reads these from a user-editable CSV in its external files dir, reachable
/// over USB with no permissions and no rebuild, seeded from a bundled template on first
/// use. The iOS equivalent of "reachable and editable" is the app's **Documents**
/// directory exposed through the Files app, which is what `UIFileSharingEnabled` and
/// `LSSupportsOpeningDocumentsInPlace` in the Info.plist are for. Same file, same
/// format, same "delete it to re-seed" behaviour.
enum LaunchSiteRepository {

    static let fileName = "launch_sites.csv"

    /// Extent used when a site line gives only a centre point.
    static let defaultExtentKm = 10.0

    /// The user-editable copy.
    static func fileURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(fileName)
    }

    /// Where to tell the user the file is. The Files-app path, not the sandbox path:
    /// the sandbox path names a container UUID that means nothing to anyone.
    static let displayPath = "Files → On My iPhone → Steam Pigeon → \(fileName)"

    /// Loads sites, seeding the editable copy from the bundled template if absent.
    /// Malformed lines are skipped rather than failing the whole file.
    static func load() -> [LaunchSite] {
        let bundled = Bundle.main.url(forResource: "launch_sites", withExtension: "csv")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

        guard let url = fileURL() else { return parse(bundled ?? "") }

        if !FileManager.default.fileExists(atPath: url.path), let bundled {
            try? bundled.write(to: url, atomically: true, encoding: .utf8)
        }
        // Documents unavailable or unreadable — fall back to the bundled template
        // rather than showing an empty list, which reads as "no sites configured".
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? bundled ?? ""
        return parse(text)
    }

    static func parse(_ text: String) -> [LaunchSite] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap(parseLine)
    }

    /// `name,lat,lon[,width_km[,height_km]]`
    ///
    /// Parses the **trailing** numeric fields as the values, so a name may contain
    /// commas ("Brothers, OR"). Extents are optional: height defaults to width
    /// (square), and both default to `defaultExtentKm` — writing just `name,lat,lon`
    /// is the obvious thing to do and must not silently drop the line.
    static func parseLine(_ line: String) -> LaunchSite? {
        let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }        // at least a name plus lat,lon

        func build(_ n: Int) -> LaunchSite? {
            // Require at least one leading field for the name; this also guarantees
            // `nums` has exactly n entries, so the indexing below is safe.
            guard parts.count > n else { return nil }
            let tail = parts.suffix(n)
            var nums: [Double] = []
            for field in tail {
                guard let v = Double(field) else { return nil }
                nums.append(v)
            }
            // Re-join with ", " since each field was trimmed ("Black Rock, NV").
            let name = parts.dropLast(n).joined(separator: ", ")
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }

            let lat = nums[0], lon = nums[1]
            let w = n >= 3 ? nums[2] : defaultExtentKm
            let h = n == 4 ? nums[3] : w
            guard abs(lat) <= 90, abs(lon) <= 180, w > 0, h > 0 else { return nil }
            return LaunchSite(name: name, lat: lat, lon: lon, widthKm: w, heightKm: h)
        }

        // Most specific first: name,lat,lon,w,h → name,lat,lon,size → name,lat,lon.
        return build(4) ?? build(3) ?? build(2)
    }
}

/// Parses "lat, lon" (comma- or space-separated). nil if invalid or out of range.
func parseLatLon(_ text: String) -> CLLocationCoordinate2D? {
    let parts = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 2 else { return nil }
    let (lat, lon) = (parts[0], parts[1])
    guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

/// Renders "lat, lon" in the form `parseLatLon` reads back.
///
/// Four decimals is ~11 m — far finer than any region this screen frames, and short
/// enough to read at a glance. The POSIX locale is deliberate: a locale whose decimal
/// mark is a comma would collide with the comma separating the pair, and `parseLatLon`
/// expects a dot regardless.
func formatLatLon(_ p: CLLocationCoordinate2D) -> String {
    String(format: "%.4f, %.4f", locale: Locale(identifier: "en_US_POSIX"),
           p.latitude, p.longitude)
}
