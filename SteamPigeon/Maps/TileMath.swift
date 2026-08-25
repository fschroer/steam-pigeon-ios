import Foundation

/// Web-mercator tile arithmetic for the download estimate, and the two formatters that
/// present it.
///
/// Pure, and tested, because this is the number someone decides on: an estimate that is
/// wrong by a factor is how a "small" region turns into a download that never finishes
/// at a launch site with one bar of signal.
enum TileMath {

    /// The SOURCE tile zoom MapLibre fetches when the map is at `mapZoom`.
    ///
    /// The style declares `"tileSize": 256` while MapLibre's logical tile grid is 512,
    /// so it fetches source tiles one level deeper than the map zoom asks for — four
    /// tiles where this arithmetic used to count one.
    ///
    /// That is the whole of the old under-count. A 22 × 22 km region estimated 12,484
    /// tiles against MapLibre's own 49,155 resources: a ratio of 3.94, which is one zoom
    /// level and not a coincidence. The provider's note about detail ("MapLibre zoom
    /// runs about a level deeper than Google's") was the same fact, applied to what the
    /// user sees but never to the count.
    ///
    /// The DOWNLOAD is unaffected — it is defined by the map-zoom range handed to
    /// `MLNTilePyramidOfflineRegion`, and always fetched these tiles. Only the estimate
    /// was wrong. Android: `OfflineMapManager.sourceZoomOf`.
    static func sourceZoom(of mapZoom: Int) -> Int { mapZoom + 1 }

    /// Source tiles fetched for `bounds` over the **map**-zoom range `minZoom…maxZoom`.
    static func tileCount(_ bounds: GeoBounds, minZoom: Int, maxZoom: Int) -> Int {
        guard minZoom <= maxZoom else { return 0 }
        return (minZoom...maxZoom).reduce(0) { $0 + tileCount(bounds, at: sourceZoom(of: $1)) }
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

    /// Correction on `SatelliteProvider.avgTileBytes`, derived from one real download.
    ///
    /// The per-zoom figures were measured before `sourceZoom(of:)` existed, so whatever
    /// total they were divided by was the old under-count — they are ~1.5× high. Rather
    /// than rewrite five numbers that would then read as measurements, the historical
    /// table is kept and the one factor that reconciles it with reality is named here.
    ///
    /// Anchor: a 9.1 × 9.1 km region at z10–z17 near 47.6 N downloaded **139 MB**. At the
    /// corrected count (10,876 source tiles) the untouched table predicts ~205 MB, so
    /// 139/205 = 0.68 — a real tile there averages ~12.8 kB against the table's 19 kB for
    /// that depth.
    ///
    /// ONE anchor, at ONE depth: 75% of that region's tiles are its single deepest level,
    /// so this pins source z18 and inherits the SHAPE of everything else — including the
    /// collapse past z20, which no measurement here reaches. It is a calibration, not a
    /// measurement, and a download at a different zoom range would do better than refine
    /// it. Esri carries the same factor: both tables were built the same way in the same
    /// commit, and correcting only the one with an anchor would leave the other ~3.9×
    /// high. Android: `OfflineMapManager.TILE_BYTES_CALIBRATION`, the same 0.68.
    private static let tileBytesCalibration = 0.68

    /// Estimated bytes for `bounds` across the **map**-zoom range `minZoom…maxZoom`,
    /// summed **per zoom** over the SOURCE tiles actually fetched (see `sourceZoom(of:)`).
    ///
    /// Not tiles × one constant: measured tile size swings ~5× across the range (Mapbox
    /// ~20 KB at z17 against ~4 KB at z22, where the imagery is upscaled), and the
    /// deepest level is ~75% of all tiles — so a flat average badly misprices whichever
    /// end the user picks.
    ///
    /// The old estimate was ~2.7× LOW, and low is the dangerous direction here: the 1 GB
    /// guard reads this number, so an under-estimate waves through a region that is
    /// really over budget rather than refusing one that would have fit.
    static func estimateBytes(_ bounds: GeoBounds, minZoom: Int, maxZoom: Int,
                              provider: SatelliteProvider) -> Int {
        guard minZoom <= maxZoom else { return 0 }
        let total = (minZoom...maxZoom).reduce(0.0) { running, mapZoom in
            let source = sourceZoom(of: mapZoom)
            return running + Double(tileCount(bounds, at: source))
                * Double(provider.avgTileBytes(source)) * tileBytesCalibration
        }
        return Int(total)
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
