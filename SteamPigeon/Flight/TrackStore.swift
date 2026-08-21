import Foundation

/// The recorded track, on disk.
///
/// Android persists to `flight_path.csv` and reloads on launch, so a track survives the
/// app being killed — which matters because the app is killed: it is in a pocket, in a
/// field, being switched between while someone walks. Losing the track of the flight
/// you are walking toward is the worst moment to lose it.
///
/// Same file name and same CSV shape as Android's, including the legacy three-column
/// rows, so the two apps' files are readable by either.
struct TrackStore {

    private let url: URL

    init(directory: URL? = nil) {
        let dir = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = dir.appendingPathComponent("flight_path.csv")
    }

    /// Rows written before capture times were recorded carry a synthetic timestamp,
    /// kept monotonic so it cannot look like a clock that ran backwards. It is written
    /// back as the three-column row it came from, so a restored track is never promoted
    /// to looking like it carries real capture times.
    static let legacyPlaceholderIntervalMs: Int64 = 1_000

    func load() -> [TrackPoint] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").enumerated().compactMap { index, line in
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard let lat = Double(parts.first ?? ""), parts.count >= 3,
                  let lon = Double(parts[1]), let alt = Float(parts[2]) else { return nil }
            switch parts.count {
            case 4:
                guard let ts = Int64(parts[3]) else { return nil }
                return TrackPoint(latitude: lat, longitude: lon, altitudeM: alt, timestampMs: ts)
            case 3:
                return TrackPoint(latitude: lat, longitude: lon, altitudeM: alt,
                                  timestampMs: Int64(index) * Self.legacyPlaceholderIntervalMs)
            default:
                return nil
            }
        }
    }

    /// Best-effort, like Android's. A track that fails to save is not worth interrupting
    /// a flight over, and the in-memory copy is unaffected.
    func save(_ points: [TrackPoint]) {
        let text = points.map {
            "\($0.latitude),\($0.longitude),\($0.altitudeM),\($0.timestampMs)"
        }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
