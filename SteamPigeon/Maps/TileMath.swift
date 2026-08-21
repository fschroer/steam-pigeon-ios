import Foundation

/// Web-mercator tile arithmetic for the download estimate, and the two formatters that
/// present it.
///
/// Pure, and tested, because this is the number someone decides on: an estimate that is
/// wrong by a factor is how a "small" region turns into a download that never finishes
/// at a launch site with one bar of signal.
enum TileMath {

    /// Number of 256-px tiles covering `bounds` across `minZoom…maxZoom`.
    static func tileCount(_ bounds: GeoBounds, minZoom: Int, maxZoom: Int) -> Int {
        guard minZoom <= maxZoom else { return 0 }
        return (minZoom...maxZoom).reduce(0) { $0 + tileCount(bounds, at: $1) }
    }

    /// Tiles covering `bounds` at a single zoom.
    static func tileCount(_ bounds: GeoBounds, at z: Int) -> Int {
        guard z >= 0, z < 31 else { return 0 }
        let n = 1 << z
        let xMin = lonToTileX(bounds.west, n)
        let xMax = lonToTileX(bounds.east, n)
        let yMin = latToTileY(bounds.north, n)      // north = smaller y
        let yMax = latToTileY(bounds.south, n)
        let cols = max(xMax - xMin + 1, 1)
        let rows = max(yMax - yMin + 1, 1)
        return cols * rows
    }

    /// Estimated bytes for `bounds` across `minZoom…maxZoom`, summed **per zoom**.
    ///
    /// Not tiles × one constant: measured tile size swings ~5× across the range (Mapbox
    /// ~20 KB at z17 against ~4 KB at z22, where the imagery is upscaled), and the
    /// deepest level is ~75% of all tiles — so a flat average badly misprices whichever
    /// end the user picks.
    static func estimateBytes(_ bounds: GeoBounds, minZoom: Int, maxZoom: Int,
                              provider: SatelliteProvider) -> Int {
        guard minZoom <= maxZoom else { return 0 }
        return (minZoom...maxZoom).reduce(0) {
            $0 + tileCount(bounds, at: $1) * provider.avgTileBytes($1)
        }
    }

    static func lonToTileX(_ lon: Double, _ n: Int) -> Int {
        let x = floor((lon + 180) / 360 * Double(n))
        return min(max(Int(x), 0), n - 1)
    }

    static func latToTileY(_ lat: Double, _ n: Int) -> Int {
        let latRad = min(max(lat, -85.05112878), 85.05112878) * .pi / 180
        let y = (1 - asinh(tan(latRad)) / .pi) / 2 * Double(n)
        return min(max(Int(floor(y)), 0), n - 1)
    }
}

/// What a zoom level buys, in words. Android's ladder, unchanged — the number alone
/// means nothing to someone deciding how deep to cache.
func zoomHint(_ z: Int, provider: SatelliteProvider) -> String {
    switch z {
    case 20...: return "Maximum detail (\(provider.displayName))."
    case 19:    return "Bush-level detail."
    case 18:    return "Individual trees / vehicles."
    case 17:    return "Field features — good for recovery."
    case 16:    return "Buildings & roads."
    default:    return "Regional context."
    }
}

/// Decimal (SI) byte sizes, as Android formats them — the units a phone's storage
/// screen uses, so the estimate can be compared with the free space shown there.
func formatBytes(_ bytes: Int) -> String {
    switch bytes {
    case 1_000_000_000...:
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    case 1_000_000...:
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    case 1_000...:
        return String(format: "%.0f kB", Double(bytes) / 1_000)
    default:
        return "\(bytes) B"
    }
}

/// Thousands separators for the tile count, matching Android's `"%,d"`.
func formatCount(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}
