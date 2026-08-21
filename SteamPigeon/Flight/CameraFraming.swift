import Foundation

/// Ground geometry and the two deadbands the auto-camera is sized by.
///
/// Ported from `FlightMapScreen.kt`. Pure on purpose — the same reason ADR-0012's
/// watchdog is: these are the parts with rules rather than rendering, and they are the
/// parts that were wrong in the field. They are testable on a Mac with no map.
enum CameraFraming {

    // MARK: - Ground geometry

    /// Ground metres per LOGICAL point at `zoom` and `latitude`.
    ///
    /// 78271.516… is half the 256-px-tile constant: MapLibre reports zoom in the
    /// 512-px-tile convention, so its metres per pixel at a given zoom is half of the
    /// Google Maps figure at the same zoom.
    ///
    /// **Logical, not device, pixels** — this is the unit MapLibre's zoom is defined
    /// in. Android records that mixing the two inflated every distance by the display
    /// density: the scale bar overstated by 2.4×, and the centring deadband was
    /// checked against a viewport twice the real size.
    static func metersPerPoint(zoom: Double, latitude: Double) -> Double {
        78271.51696 * cos(latitude * .pi / 180) / pow(2, zoom)
    }

    /// Ground metres per DEVICE pixel — for comparing a real distance against a real
    /// count of screen pixels. `scale` is `UIScreen.main.scale`.
    static func metersPerDevicePixel(zoom: Double, latitude: Double, scale: Double) -> Double {
        metersPerPoint(zoom: zoom, latitude: latitude) / scale
    }

    /// Ground distance in metres between two coordinates.
    ///
    /// Equirectangular rather than haversine, deliberately — and NOT the same function
    /// as `LocatorVector.between`, which is the ADR-0022 distance the app *quotes* and
    /// stays haversine. This one is asked on every display frame and only ever about
    /// separations of tens of metres, where the two agree to well under a millimetre.
    ///
    /// The longitude difference is wrapped to ±180° so a pair straddling the
    /// antimeridian measures the short way round.
    static func metersBetween(_ a: (lat: Double, lon: Double),
                              _ b: (lat: Double, lon: Double)) -> Double {
        let earthR = 6_378_137.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLonDeg = ((b.lon - a.lon + 540).truncatingRemainder(dividingBy: 360)) - 180
        let dLon = dLonDeg * .pi / 180 * cos((a.lat + b.lat) / 2 * .pi / 180)
        return earthR * (dLat * dLat + dLon * dLon).squareRoot()
    }

    /// Share of each viewport dimension the bounds fit gives away as margin, so the two
    /// markers are never hard against an edge.
    ///
    /// A FRACTION, not absolute pixels: Android's previous 300 px per side surrendered
    /// 60% of the width on a 1008 px phone, which is why the markers sat in a fifth of
    /// the screen. It also has to clear the overlays drawn on top of the map, and those
    /// are laid out in fractions of the viewport too.
    static let boundsFitMarginFraction = 0.14

    /// Edge padding for the bounds fit, in points, as `(horizontal, vertical)`.
    ///
    /// Clamped so a small or not-yet-measured viewport cannot ask for padding that
    /// meets in the middle — the fit degenerates and zooms far out when it does, which
    /// looks exactly like the bug it replaces.
    static func boundsFitPadding(viewportWidth: Double, viewportHeight: Double) -> (h: Double, v: Double) {
        guard viewportWidth > 0, viewportHeight > 0 else { return (0, 0) }
        let h = min(viewportWidth * boundsFitMarginFraction, viewportWidth / 2 - 1)
        let v = min(viewportHeight * boundsFitMarginFraction, viewportHeight / 2 - 1)
        return (max(h, 0), max(v, 0))
    }

    // MARK: - Auto-centre deadband

    /// Floor and ceiling on the computed centring band, metres.
    ///
    /// The floor keeps an optimistically-reported fix from producing a band so small it
    /// never trips; the ceiling keeps a bad one — a locator under canopy claiming
    /// hundreds of metres — from pinning the camera somewhere stale while the user walks.
    static let recenterDeadbandMinM = 5.0
    static let recenterDeadbandMaxM = 40.0

    /// How far the auto-centre target may drift before the camera follows it, metres.
    ///
    /// Three steps, because the obvious `√(σ_locator² + σ_phone²)` is wrong in two
    /// ways that look like they cancel and do not:
    ///
    /// 1. **The target is a midpoint, not a fix.** With both receivers framed the camera
    ///    targets the point between them, and a midpoint moves half as far as the two
    ///    independent errors it is drawn from: `σ_target = ½·√(σ_locator² + σ_phone²)`.
    ///    A nil `phoneAccuracyM` says the phone is not part of the framing, in which
    ///    case the target is the rocket itself and carries the locator's full error.
    /// 2. **Both ends of the comparison are noisy.** The band is measured from a latched
    ///    anchor, itself one noisy sample, so what has to clear it is the difference of
    ///    two independent draws — `√2` times as jumpy as either.
    /// 3. **2σ, not 1σ.** A 1σ band is crossed by a large fraction of fixes, which
    ///    leaves the camera nudging nearly as often as no band at all.
    ///
    /// About 8 m for a good fix at both ends (3 m locator, 5 m phone); about 35 m for a
    /// poor one.
    static func recenterDeadbandM(locatorAccuracyM: Double, phoneAccuracyM: Double?) -> Double {
        let locator = sane(locatorAccuracyM)
        let sigmaTarget: Double
        if let phoneAccuracyM {
            let phone = sane(phoneAccuracyM)
            sigmaTarget = 0.5 * (locator * locator + phone * phone).squareRoot()
        } else {
            sigmaTarget = locator
        }
        return min(max(2 * 2.0.squareRoot() * sigmaTarget, recenterDeadbandMinM), recenterDeadbandMaxM)
    }

    /// `recenterDeadbandM` limited to what the screen can actually absorb.
    ///
    /// The statistical band knows nothing about zoom, and at recovery range that is not
    /// a detail: framed a few metres across, a band computed from a phone reporting 7 m
    /// comes out wider than the whole viewport, and the anchor can sit far enough off
    /// that a marker leaves the screen. That was reported from the field as "the locator
    /// or the phone would be off screen".
    ///
    /// The cap is exactly the margin the bounds fit reserves outside the two markers —
    /// spending that slack on centre drift is spending what is there to be spent, and no
    /// more. It outranks the floor: a screen showing less ground than the floor is a
    /// different situation, and there the floor is the thing that is wrong.
    static func viewportLimitedDeadbandM(_ bandM: Double,
                                         viewportWidthPx: Double,
                                         metersPerDevicePixel: Double) -> Double {
        guard viewportWidthPx > 0, metersPerDevicePixel.isFinite, metersPerDevicePixel > 0
        else { return bandM }
        return min(bandM, boundsFitMarginFraction * viewportWidthPx * metersPerDevicePixel)
    }

    // MARK: - Auto-zoom deadband

    /// Band floor and ceiling, in zoom levels.
    ///
    /// The ceiling matters more than it looks: the honest statistics say that when
    /// separation and error are comparable the fitted zoom carries several levels of
    /// uncertainty and should never move at all — which would leave the map framed for
    /// 30 m while you stood 5 m away. Capping means the last stretch of an approach
    /// re-frames once rather than never.
    static let autoZoomDeadbandMinLevels = 0.25
    static let autoZoomDeadbandMaxLevels = 1.5

    /// How far the fitted zoom may drift before the camera follows it, in zoom levels.
    ///
    /// Same shape as `recenterDeadbandM` — 2σ of the drift between two noisy samples —
    /// but σ is derived differently, and the difference is not cosmetic:
    ///
    /// - **No halving.** The centring target is a midpoint, which moves half as far as
    ///   its inputs. Separation is a *difference*, so both errors land at full weight.
    /// - **Converted through the log.** Zoom is logarithmic in separation, so a fixed
    ///   error in metres is a large zoom error when the two are close and negligible
    ///   when they are far apart: `σ_zoom = σ_separation / (D·ln2)`. That is what makes
    ///   the band self-scaling.
    ///
    /// A non-positive or non-finite separation yields the widest band, which is the
    /// right failure direction: an unknown separation is not evidence the zoom should
    /// move.
    static func autoZoomDeadbandLevels(locatorAccuracyM: Double,
                                       phoneAccuracyM: Double?,
                                       separationM: Double) -> Double {
        let locator = sane(locatorAccuracyM)
        let phone = sane(phoneAccuracyM)
        let sigmaSeparation = (locator * locator + phone * phone).squareRoot()
        guard separationM.isFinite, separationM > 0 else { return autoZoomDeadbandMaxLevels }
        let sigmaZoom = sigmaSeparation / (separationM * log(2.0))
        return min(max(2 * 2.0.squareRoot() * sigmaZoom, autoZoomDeadbandMinLevels),
                   autoZoomDeadbandMaxLevels)
    }

    /// Non-positive values mean "not reported" and are treated as an
    /// unknown-but-perfect receiver; the floors above cover the shortfall.
    private static func sane(_ v: Double?) -> Double {
        guard let v, v.isFinite, v > 0 else { return 0 }
        return v
    }
}
