import CoreGraphics
import Foundation

/// Geometry, limits and event placement for the flight-profile chart.
///
/// Everything here is pure — the drawing lives in `FlightProfilesView`, and the parts
/// that are easy to get subtly wrong (focal-point zoom, gridline intervals, matching
/// an event time to a sample) are testable without a view.
enum FlightChart {

    // MARK: - Charting safety limits
    //
    // A value outside these bounds is treated as corrupt and its sample is excluded
    // from the chart, rather than producing an unintelligible draw call.

    static let maxSaneAltitudeM: Float = 30_000     // ~100 kft, well above any amateur rocket
    static let minSaneAltitudeM: Float = -500       // allow slightly below-pad readings
    static let maxSaneAccelMps2: Float = 3_000      // ~300 g, covers extreme high-power motors
    static let minSaneAccelMps2: Float = -3_000
    static let maxSaneTimestampMs = 600_000         // 10 minutes, more than any flight
    static let minSamplesToChart = 2                // two points make a line

    // MARK: - Chart geometry
    //
    // Android draws its chart in raw **pixels** — `CHART_MARGIN_X = 64f` and
    // `textSize = 32f` are DrawScope units, not dp — so its apparent size changes with
    // display density. SwiftUI's Canvas works in points, so the constants are divided
    // by the density of the phone the chart was tuned on (a Pixel 9 Pro XL, 3.0) to
    // land at the same apparent size. This is the one number in the port with no exact
    // answer; it is recorded in `docs/UI_PARITY.md` with what would settle it.
    //
    // Stroke widths and marker radii are NOT converted: Android writes those as
    // `1.dp.toPx()` / `3.dp.toPx()`, and a dp is a point.

    static let androidChartDensity: CGFloat = 3

    /// Left gutter for the altitude labels.
    ///
    /// Android's `CHART_MARGIN_X`, which was **64 px and clipped the first character off
    /// any label wider than 56 px**: a label is right-aligned into the gutter 8 px from
    /// its edge, and "900m" measures about 79 px at the 32 px axis size, putting its left
    /// edge at −23. The altitude axis of an altitude chart was losing its leading digit,
    /// on both platforms — reproduced here deliberately, since Android is the reference
    /// implementation and a silent divergence is worse than a shared defect.
    ///
    /// **112 px** covers the widest realistic integer label: Roboto digits advance
    /// ~0.556 em and `m` ~0.86 em, so "1234m" is about 99 px plus the 8 px gap, and four
    /// digits is the practical ceiling at 9999 m = 32,800 ft. Deep zoom can still produce
    /// a decimal label ("900.5m") too wide for it, so `FlightProfilesView` also clamps the
    /// label's left edge to 0 — it butts against the plot rather than losing a character,
    /// which is the failure worth having.
    ///
    /// The gutter rather than the text size, of the two levers: these are raw pixels, so
    /// 32 px is already only ~11 sp on a 3× phone, and shrinking it to fix a legibility
    /// bug reads badly. Ported from Android `5d52383`; **not yet seen on a device on
    /// either platform** — it is a legibility judgement and wants a flight with 3- and
    /// 4-digit altitudes.
    static let marginX: CGFloat = 112 / androidChartDensity
    /// Bottom gutter for the time labels.
    static let marginY: CGFloat = 32 / androidChartDensity
    static let axisTextSize: CGFloat = 32 / androidChartDensity
    static let bodyTextSize: CGFloat = 24 / androidChartDensity
    /// Target gridlines per axis.
    static let gridCount = 5

    /// Event annotations grow as you zoom in, where there is room for them. Growth is
    /// by sqrt(zoom) rather than zoom so it stays gentle, and caps at 2× the base size
    /// (reached at 4× zoom) — beyond that the labels crowd out the trace they annotate.
    /// Axis labels deliberately do NOT scale: they are chart furniture, not content.
    static let maxEventTextScale: CGFloat = 2

    /// Upper bound on pinch zoom. At 25× a 60 s flight shows ~2.4 s across the plot,
    /// which is ~48 samples at the 20 Hz archive cadence — past that the trace is just
    /// line segments between adjacent samples.
    static let maxZoom: CGFloat = 25

    /// How far an event timestamp may sit from the nearest sample before the event is
    /// dropped as unplottable. Samples are 50 ms apart, so the nearest is normally
    /// within 25 ms; the slack covers a gap left by packets still in flight (one lost
    /// packet = 8 samples = 400 ms).
    static let eventMatchToleranceMs = 1_000

    /// Standard gravity, as Android's `RocketViewModel.G_FORCE_MS2`. The accelerometer
    /// axis is labelled in g, so this is the only place the two units meet.
    static let gForceMps2: CGFloat = 9.80665
}

/// Pan/zoom state for the chart, and the single definition of how data coordinates map
/// to canvas points.
///
/// Traces, gridlines and event markers all project through `screenXOfMs` /
/// `screenYOfValue`, so they cannot drift apart. Identity (zoom 1, pan zero) fits the
/// whole flight in the plot area; `pan` is in canvas points and both axes share `zoom`.
struct ChartViewport: Equatable {
    var zoom: CGFloat = 1
    var pan: CGPoint = .zero

    /// Apply one pinch/drag gesture, holding the data under `centroid` still.
    ///
    /// `plotW` / `plotH` are the plot area — the canvas minus the axis gutters.
    /// Panning is clamped so the data can never be dragged off-screen, which also
    /// means zooming back out to 1 restores the exact original fit.
    func transform(centroid: CGPoint,
                   panChange: CGPoint,
                   zoomChange: CGFloat,
                   plotW: CGFloat,
                   plotH: CGFloat) -> ChartViewport {
        guard plotW > 0, plotH > 0 else { return self }

        let newZoom = min(max(zoom * zoomChange, 1), FlightChart.maxZoom)
        // The factor actually applied after clamping — using zoomChange directly would
        // drift the viewport when pinching past either limit.
        let k = newZoom / zoom

        // X grows rightward from the gutter; Y is inverted (altitude grows up from the
        // baseline at plotH), hence the different arrangement.
        let cx = centroid.x - FlightChart.marginX
        let newPanX = cx - (cx - pan.x) * k + panChange.x
        let newPanY = (centroid.y - plotH) + (plotH + pan.y - centroid.y) * k + panChange.y

        return ChartViewport(
            zoom: newZoom,
            pan: CGPoint(x: min(max(newPanX, -(newZoom - 1) * plotW), 0),
                         y: min(max(newPanY, 0), (newZoom - 1) * plotH)))
    }

    /// Canvas X for a time offset, given the full-flight duration `totalMs`.
    func screenXOfMs(_ tMs: CGFloat, plotW: CGFloat, totalMs: CGFloat) -> CGFloat {
        FlightChart.marginX + pan.x + tMs * (plotW / totalMs * zoom)
    }

    /// Canvas Y for a value on an axis spanning `axisMin…axisMax` over the plot height.
    /// Used for both altitude (0…maxAgl) and acceleration.
    func screenYOfValue(_ value: CGFloat, plotH: CGFloat,
                        axisMin: CGFloat, axisMax: CGFloat) -> CGFloat {
        plotH + pan.y - (value - axisMin) * (plotH / (axisMax - axisMin) * zoom)
    }

    /// Inverse of `screenXOfMs` at the plot's left and right edges.
    func visibleMsRange(plotW: CGFloat, totalMs: CGFloat) -> ClosedRange<CGFloat> {
        let scale = plotW / totalMs * zoom
        return (-pan.x / scale)...((plotW - pan.x) / scale)
    }

    /// Inverse of `screenYOfValue` at the plot's bottom and top edges.
    func visibleValueRange(plotH: CGFloat,
                           axisMin: CGFloat, axisMax: CGFloat) -> ClosedRange<CGFloat> {
        let scale = plotH / (axisMax - axisMin) * zoom
        return (axisMin + pan.y / scale)...(axisMin + (plotH + pan.y) / scale)
    }
}

/// Pick a human-friendly grid interval — 1, 2 or 5 × 10ⁿ — covering `range` in roughly
/// `targetCount` steps. Always returns a positive, finite value, so the gridline loops
/// that divide by it cannot spin.
func niceInterval(_ range: CGFloat, targetCount: Int = FlightChart.gridCount) -> CGFloat {
    let fallback: CGFloat = 1
    guard range.isFinite, range > 0, targetCount > 0 else { return fallback }
    let raw = range / CGFloat(targetCount)
    guard raw.isFinite, raw > 0 else { return fallback }

    let exponent = floor(log10(Double(raw)))
    let fraction = Double(raw) / pow(10, exponent)
    let nice: Double
    switch fraction {
    case ...1.0: nice = 1
    case ...2.0: nice = 2
    case ...5.0: nice = 5
    default:     nice = 10
    }
    let interval = CGFloat(nice * pow(10, exponent))
    return interval.isFinite && interval > 0 ? interval : fallback
}

extension FlightSample {
    /// False if any field is NaN, infinite, or outside sane flight bounds.
    var isSane: Bool {
        guard altitudeM.isFinite,
              altitudeM >= FlightChart.minSaneAltitudeM,
              altitudeM <= FlightChart.maxSaneAltitudeM else { return false }
        for v in [accel.x, accel.y, accel.z] {
            guard v.isFinite,
                  v >= FlightChart.minSaneAccelMps2,
                  v <= FlightChart.maxSaneAccelMps2 else { return false }
        }
        return timestampMs >= 0 && timestampMs <= FlightChart.maxSaneTimestampMs
    }
}

/// An event placed against the profile data: time from the locator, altitude from the
/// samples.
struct ResolvedEvent: Equatable {
    let event: FlightEventIndex
    let label: String
    let timestampMs: Int
    let sampleIndex: Int
    let altitudeM: Float
    /// Non-nil for deployment events — the three continuity/fired indicators.
    let stats: DeployChannelStats?
}

/// Deployment events carry per-channel fired / continuity indicators.
private let deploymentEventModes: [FlightEventIndex: DeployMode] = [
    .droguePrimaryDeploy: .droguePrimary,
    .drogueBackupDeploy:  .drogueBackup,
    .mainPrimaryDeploy:   .mainPrimary,
    .mainBackupDeploy:    .mainBackup,
]

/// Match each recorded event time to the nearest flight sample, in chronological order.
///
/// Events the locator did not record (absent from the present mask) and events with no
/// sample near their timestamp are **omitted rather than collapsed onto sample 0** —
/// drawing them at the origin is what made every marker pile up on the launch pad.
func resolveEvents(samples: [FlightSample], events: FlightEvents) -> [ResolvedEvent] {
    guard !samples.isEmpty, !events.isEmpty else { return [] }

    return FlightEventIndex.allCases.compactMap { event -> ResolvedEvent? in
        guard let eventMs = events.timestampMs(event) else { return nil }
        guard let index = samples.indices.min(by: {
            abs(samples[$0].timestampMs - eventMs) < abs(samples[$1].timestampMs - eventMs)
        }) else { return nil }
        guard abs(samples[index].timestampMs - eventMs) <= FlightChart.eventMatchToleranceMs
        else { return nil }

        let mode = deploymentEventModes[event]
        let channel = mode.flatMap { events.channel(for: $0) }
        // A deployment event whose mode is not assigned to any channel cannot be
        // attributed — skip it rather than draw indicators for a channel that was
        // never configured.
        if mode != nil && channel == nil { return nil }

        return ResolvedEvent(
            event: event,
            label: channel.map { "Ch \($0) \(event.label)" } ?? event.label,
            timestampMs: eventMs,
            sampleIndex: index,
            altitudeM: samples[index].altitudeM,
            stats: channel.flatMap { events.channelStats.indices.contains($0 - 1)
                                     ? events.channelStats[$0 - 1] : nil })
    }
    .sorted { $0.timestampMs < $1.timestampMs }
}
