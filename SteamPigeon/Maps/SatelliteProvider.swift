import Foundation

/// A satellite tile provider — imagery source plus offline limits.
///
/// Both the live map and the download screen resolve the active one through
/// `MapProviderPrefs`, so downloads and rendering stay on the same source.
///
/// **Note (Mapbox), carried over from Android:** consuming Mapbox raster tiles through
/// MapLibre is fine for evaluation and gives deeper recovery detail, but Mapbox's ToS
/// generally expects their own SDK in production — especially for the offline bulk
/// caching done here. Revisit before ship; it is part of issue #26 on both platforms.
enum SatelliteProvider: String, CaseIterable, Identifiable {
    /// Esri World Imagery: raster tiles to ~z19.
    case esri
    /// Mapbox Satellite raster tiles, via a token in the tile URL.
    case mapbox

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .esri:   return "Esri"
        case .mapbox: return "Mapbox"
        }
    }

    /// Always cached down to this level, whatever the chosen maximum: each lower level
    /// has ~4× fewer tiles, so the whole context pyramid costs almost nothing — while
    /// omitting it leaves the map blank offline at any zoomed-out level, which is
    /// exactly when someone is getting their bearings on site.
    var minOfflineZoom: Int { 10 }

    /// Mapbox's source has tiles to z22, but the cap is z20: MapLibre zoom runs about a
    /// level deeper than Google's (512- vs 256-px tile convention), so z20 ≈ the most
    /// satellite detail Google Maps used to give us — and each extra level costs 4×
    /// storage.
    var maxOfflineZoom: Int {
        switch self {
        case .esri:   return 19
        case .mapbox: return 20
        }
    }

    /// Measured average payload of one 256-px SOURCE tile at source zoom `z` — the zoom
    /// in the tile URL, which is one deeper than the map zoom (see
    /// `TileMath.sourceZoom(of:)`). Varies strongly by zoom, which is why the estimate
    /// sums per level instead of multiplying one constant.
    ///
    /// Read through `TileMath.tileBytesCalibration`, which reconciles these historical
    /// figures with a real download; see the note there before trusting the absolute
    /// values.
    func avgTileBytes(_ z: Int) -> Int {
        switch self {
        // Measured flat across z13–z17 (21.6–24.0 KB, mean 22.7 KB) on a real download.
        case .esri:
            return 23_000
        // Measured on a real download (2026-07-16, Puget Sound). Bytes per tile COLLAPSE
        // past z19 — z20 9.5 KB, z21 5.5 KB, z22 4.0 KB against ~20 KB at z17–18 —
        // because Mapbox's native imagery runs out around z19–20 there and deeper tiles
        // are upscaled blur that JPEG-compresses to nothing. Cheap bytes, but no new
        // detail: 4× the tile count per level, all of it interpolation.
        case .mapbox:
            switch z {
            case 22...: return 4_000
            case 21:    return 5_500
            case 20:    return 9_500
            case 16...: return 19_000     // z16–z19 measured 16.4–21.1 KB
            default:    return 14_000     // z ≤ 15, sparse samples averaged ~8–18 KB
            }
        }
    }

    /// Mapbox is selectable only when a token is configured.
    ///
    /// Android reads it from `secrets.properties` into `BuildConfig`; the iOS analogue
    /// is an Info.plist value fed by a build setting. **Never a literal in the repo** —
    /// the token is a credential, and this file is public.
    var isAvailable: Bool { self != .mapbox || !Self.mapboxToken.isEmpty }

    static var mapboxToken: String {
        (Bundle.main.object(forInfoDictionaryKey: "MAPBOX_TOKEN") as? String) ?? ""
    }

    /// The style document this provider renders and downloads from.
    ///
    /// Returned as a STRING rather than a URL because the offline downloader cannot
    /// read a local one (ADR-0014): it accepts only `http(s)`, so the JSON has to be
    /// served rather than pointed at. See `LocalStyleServer`.
    func styleJSON() -> String {
        switch self {
        case .esri:
            // The same file the live map renders from, and the same one Android ships
            // as an asset — one style, both platforms, per ADR-0014.
            guard let url = Bundle.main.url(forResource: "satellite_style", withExtension: "json"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return text
        case .mapbox:
            return Self.mapboxStyleJSON(token: Self.mapboxToken)
        }
    }

    /// A MapLibre style whose raster source is Mapbox Satellite (256-px JPEG, to z22).
    static func mapboxStyleJSON(token: String) -> String {
        """
        {
          "version": 8,
          "name": "Mapbox Satellite",
          "sources": {
            "satellite": {
              "type": "raster",
              "tiles": ["https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}.jpg?access_token=\(token)"],
              "tileSize": 256,
              "minzoom": 0,
              "maxzoom": 22,
              "attribution": "© Mapbox © Maxar"
            }
          },
          "layers": [
            { "id": "background", "type": "background", "paint": { "background-color": "#0b0f14" } },
            { "id": "satellite", "type": "raster", "source": "satellite", "paint": { "raster-opacity": 1.0 } }
          ]
        }
        """
    }
}

/// App-wide selected satellite provider. Android persists this in SharedPreferences;
/// `UserDefaults` is the same thing.
enum MapProviderPrefs {
    private static let key = "map_provider"

    static func get(_ defaults: UserDefaults = .standard) -> SatelliteProvider {
        let stored = defaults.string(forKey: key).flatMap(SatelliteProvider.init(rawValue:))
        // A provider whose token has since been removed falls back rather than leaving
        // the screen pointed at a source it cannot fetch.
        guard let stored, stored.isAvailable else { return .esri }
        return stored
    }

    static func set(_ provider: SatelliteProvider, _ defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: key)
    }
}
