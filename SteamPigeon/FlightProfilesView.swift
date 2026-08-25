import SwiftUI

/// Flight Profiles — the locator's archived flights, and one flight drawn.
///
/// Mirrors Android's `FlightProfilesScreen`, which is **two screens behind one flag**:
/// the record list until a record is opened, the chart afterwards. The flag lives in
/// `LinkViewModel` rather than here because it is really the locator's transfer state —
/// opening a record takes over the link, and leaving one has to tell the locator so.
///
/// Entering asks for the record list and keeps asking with a doubling backoff; leaving
/// tells the locator to go back to Disarmed so it resumes `PreLaunchData`. Neither is
/// optional: the locator stops broadcasting while it is in flight-profile mode, so a
/// screen that forgot to say goodbye would leave the map blank.
struct FlightProfilesView: View {
    @ObservedObject var model: LinkViewModel
    /// Closes the whole screen — Android's `onCancelButtonClicked`, which navigates up.
    var onReturn: () -> Void

    var body: some View {
        Group {
            if model.flightProfileDataDisplayState {
                chartOrStatus
            } else {
                recordList
            }
        }
        .background(SPColor.background)
        // Android requests metadata from a `LaunchedEffect` keyed on the service, and
        // ends the retries by cancelling that coroutine when the screen goes away.
        // `.task` is the same contract: cancelled on disappear.
        .task { await model.fetchFlightProfileMetadata() }
        .onDisappear { model.exitFlightProfileMode() }
    }

    // MARK: - Record list

    private var recordList: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if !model.flightProfileMetadata.isEmpty {
                        // Always show the list while metadata is populated, whatever the
                        // message state, so a background state change never hides it.
                        ForEach(model.flightProfileMetadata) { item in
                            Spacer(minLength: 0)
                            recordRow(item, width: geo.size.width)
                            Spacer(minLength: 0)
                            Divider().background(SPColor.outlineVariant)
                        }
                    } else if model.flightProfileMetadataState == .ackUpdated {
                        Text("No flights recorded on locator \(model.remoteLocatorConfig.deviceName)")
                            .font(SPFont.bodyLarge)
                            .foregroundStyle(SPColor.onBackground)
                    } else {
                        // Show the attempt count once we are retrying, so a lossy link
                        // reads as "still trying" rather than as a frozen screen.
                        Text("Fetching flight data from locator "
                             + model.remoteLocatorConfig.deviceName
                             + (model.flightProfileMetadataAttempt > 1
                                ? " (attempt \(model.flightProfileMetadataAttempt))" : ""))
                            .font(SPFont.bodyLarge)
                            .foregroundStyle(SPColor.onBackground)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Spacer().frame(height: geo.size.height / 12)
                returnButton(action: onReturn)
            }
            .padding(16)
        }
    }

    /// One archive slot. Android lays this out as an icon, the slot number, a flexible
    /// gap of one unit, and the tappable detail column of five — so the detail text
    /// sits about a sixth of the way in from the numbers.
    private func recordRow(_ item: FlightRecordMetadata, width: CGFloat) -> some View {
        // 40 is the icon plus the slot number; the rest is Android's 1:5 split.
        let detailWidth = max((width - 32 - 40) * 5 / 6, 0)
        return HStack(spacing: 0) {
            Image("u_turn_right")
                .renderingMode(.template)
                .resizable().scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(SPColor.onBackground)
            Text("\(item.position)")
                .font(SPFont.bodyLarge)
                .foregroundStyle(SPColor.onBackground)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                if item.apogeeM > 0 {
                    if let date = item.date {
                        Text(Self.recordDateFormatter.string(from: date))
                            .font(SPFont.bodyLarge)
                            .foregroundStyle(SPColor.onBackground)
                    }
                    Text("Apogee: \(Self.apogeeText(item.apogeeM))m")
                        .font(SPFont.bodyLarge)
                        .foregroundStyle(SPColor.onBackground)
                } else {
                    // An empty slot is still listed, and still occupies its row: the
                    // slot numbers have to stay readable as positions.
                    Text("No flight data")
                        .font(SPFont.bodyLarge)
                        .foregroundStyle(SPColor.onBackground)
                    Text("")
                        .font(SPFont.bodyLarge)
                }
            }
            .frame(width: detailWidth, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard item.apogeeM > 0 else { return }
                model.openFlightProfile(position: item.position)
            }
        }
    }

    /// Android formats the archive date as `yyyy-MM-dd HH:mm:ss`, in the phone's zone.
    private static let recordDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Android rounds the apogee to one decimal **away from zero** (`RoundingMode.UP`),
    /// so a flight never reads as having gone lower than it did.
    private static func apogeeText(_ apogeeM: Float) -> String {
        String(format: "%.1f", (Double(apogeeM) * 10).rounded(.awayFromZero) / 10)
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartOrStatus: some View {
        if model.flightTransferProgress.noData {
            // The locator advertised a zero-length transfer: this record has no sample
            // data. A clear message, not a chart that loads forever.
            VStack(spacing: 8) {
                Text("No flight data for this record")
                    .font(SPFont.bodyLarge)
                    .foregroundStyle(SPColor.onBackground)
                Button("Return") { model.returnToFlightProfileList() }
                    .buttonStyle(.materialOutlined)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        } else if let metadata = currentMetadata {
            FlightProfileChart(samples: model.flightSamples,
                               events: model.flightEvents,
                               metadata: metadata,
                               progress: model.flightTransferProgress,
                               onReturn: { model.returnToFlightProfileList() })
        } else {
            // Metadata not ready — say so rather than charting against a record we
            // cannot describe.
            VStack(spacing: 8) {
                Text("Loading flight data…")
                    .font(SPFont.bodyLarge)
                    .foregroundStyle(SPColor.onBackground)
                if model.flightTransferProgress.packetCount > 0 {
                    Text("\(model.flightTransferProgress.receivedCount) / "
                         + "\(model.flightTransferProgress.packetCount) packets received")
                        .font(SPFont.bodyLarge)
                        .foregroundStyle(SPColor.onBackground)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        }
    }

    private var currentMetadata: FlightRecordMetadata? {
        model.flightProfileMetadata.first { $0.position == model.flightProfileArchivePosition }
    }

    /// Android's `OutlinedButton`, which carries `weight(1f)` and so fills the row.
    /// The width goes on the LABEL: a frame outside the style stretches the tap target
    /// and leaves the button itself hugging its text.
    private func returnButton(action: @escaping () -> Void) -> some View {
        Button(action: action) { Text("Return").frame(maxWidth: .infinity) }
            .buttonStyle(.materialOutlined)
    }
}

// MARK: - The chart

/// Altitude and three accelerometer axes against time, with the locator's flight
/// events annotated onto the altitude trace.
///
/// Pinch to zoom about the centroid, drag to pan, double-tap to fit the whole flight
/// again. There is no "descent" toggle: Android had one that truncated the chart at
/// apogee to make the ascent readable, and pinch-zoom does that better without hiding
/// data.
private struct FlightProfileChart: View {
    let samples: [FlightSample]
    let events: FlightEvents
    let metadata: FlightRecordMetadata
    let progress: FlightTransferProgress
    let onReturn: () -> Void

    @State private var viewport = ChartViewport()
    @State private var displayAltitude = true
    @State private var displayAccelX = true
    @State private var displayAccelY = true
    @State private var displayAccelZ = true

    // Android's chart palette. The three accelerometer axes are pure RGB primaries
    // rather than theme colours — they have to be told apart at a glance in sunlight,
    // and the legend is the only key to them.
    private static let drogueColor = Color(red: 0.5, green: 0.5, blue: 0, opacity: 0.5)
    private static let mainColor = Color(red: 0, green: 0.5, blue: 0, opacity: 0.5)
    private static let apogeeColor = Color(red: 0, green: 0, blue: 1)
    private static let accelXColor = Color(red: 1, green: 0, blue: 0)
    private static let accelYColor = Color(red: 1, green: 1, blue: 0)
    private static let accelZColor = Color(red: 0, green: 1, blue: 0)
    private static let indicatorColor = Color(white: 0.5)

    /// Only sane samples reach any calculation — done once, here.
    private var saneSamples: [FlightSample] { samples.filter(\.isSane) }

    var body: some View {
        let data = saneSamples
        let resolved = resolveEvents(samples: data, events: events)

        // ── Y-axis (altitude) range ──────────────────────────────────────────
        // Prefer the metadata apogee as the ceiling, falling back to the highest
        // sample seen if metadata is missing or suspiciously small.
        let observedMaxAlt = data.map(\.altitudeM).max() ?? 0
        let rawApogee = max(max(metadata.apogeeM, observedMaxAlt), 0) > 0
            ? CGFloat(max(metadata.apogeeM, observedMaxAlt)) : 1
        let baseInterval = niceInterval(rawApogee)
        let maxAgl = max(baseInterval * CGFloat(max(Int(ceil(rawApogee / baseInterval)), 1)), 1)

        // ── X-axis (time) range ──────────────────────────────────────────────
        // From the sample timestamps, not the metadata flight time: the latter uses
        // the old protocol's timing model, and `timestampMs` is authoritative.
        let firstTimestampMs = data.first?.timestampMs ?? 0
        let lastTimestampMs = data.last?.timestampMs ?? 0
        let safeChartMs = CGFloat(max(lastTimestampMs - firstTimestampMs, 1))

        return GeometryReader { geo in
            VStack(spacing: 0) {
                // Visible until the transfer is complete.
                if !progress.complete && progress.packetCount > 0 {
                    Text("Receiving: \(progress.receivedCount) / \(progress.packetCount) packets")
                        .font(SPFont.labelSmall)
                        .foregroundStyle(SPColor.onBackground)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Shown only while zoomed — it doubles as the discovery hint for
                // double-tap-to-reset, which is otherwise invisible.
                if viewport.zoom > 1.01 {
                    Text(String(format: "%.1f× — double-tap to reset", viewport.zoom))
                        .font(SPFont.labelSmall)
                        .foregroundStyle(SPColor.onBackground)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                canvas(data: data, resolved: resolved,
                       firstTimestampMs: firstTimestampMs,
                       safeChartMs: safeChartMs, maxAgl: maxAgl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Spacer().frame(height: geo.size.height / 12)

                Button(action: onReturn) { Text("Return").frame(maxWidth: .infinity) }
                    .buttonStyle(.materialOutlined)
            }
            .padding(16)
        }
        // The legend floats over the chart rather than taking layout from it, exactly
        // as Android's overlaid column does. Two spacers above and three below is how
        // Android weights it, and repeated spacers is how SwiftUI says the same thing.
        .overlay {
            VStack(spacing: 0) {
                Spacer(); Spacer()
                HStack(spacing: 0) {
                    Spacer()
                    legend
                }
                Spacer(); Spacer(); Spacer()
            }
        }
        // Samples arriving during a live transfer change the plotted range, and a
        // viewport computed against the old one would be left pointing nowhere.
        .onChange(of: safeChartMs) { _ in viewport = ChartViewport() }
        .onChange(of: maxAgl) { _ in viewport = ChartViewport() }
    }

    // MARK: Legend

    private var legend: some View {
        VStack(alignment: .trailing, spacing: 0) {
            legendCheckbox("Altitude", SPColor.primary, $displayAltitude)
            legendCheckbox("Accel X", Self.accelXColor, $displayAccelX)
            legendCheckbox("Accel Y", Self.accelYColor, $displayAccelY)
            legendCheckbox("Accel Z", Self.accelZColor, $displayAccelZ)
        }
    }

    private func legendCheckbox(_ label: String, _ color: Color,
                                _ checked: Binding<Bool>) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(SPFont.labelMedium)
                .foregroundStyle(color)
                .padding(.leading, 4)
            // Android's Material `Checkbox`, drawn with SF Symbols: a filled box in the
            // primary colour with the tick in `onPrimary`, an empty outlined box when
            // clear — the same two states, and the same colours, as
            // `CheckboxDefaults.colors` is given there.
            Button { checked.wrappedValue.toggle() } label: {
                Image(systemName: checked.wrappedValue ? "checkmark.square.fill" : "square")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(SPColor.onPrimary, SPColor.primary)
                    .font(.system(size: 20))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Canvas

    private func canvas(data: [FlightSample],
                        resolved: [ResolvedEvent],
                        firstTimestampMs: Int,
                        safeChartMs: CGFloat,
                        maxAgl: CGFloat) -> some View {
        Canvas { context, size in
            // Event annotations grow with zoom; axis furniture stays fixed.
            let eventScale = min(sqrt(viewport.zoom), FlightChart.maxEventTextScale)
            let bodyTextSize = FlightChart.bodyTextSize * eventScale
            let plotH = size.height - FlightChart.marginY
            let plotW = size.width - FlightChart.marginX

            guard plotH > 0, plotW > 0, data.count >= FlightChart.minSamplesToChart else { return }

            func xOfMs(_ tMs: CGFloat) -> CGFloat {
                viewport.screenXOfMs(tMs, plotW: plotW, totalMs: safeChartMs)
            }
            func yOfAlt(_ alt: CGFloat) -> CGFloat {
                viewport.screenYOfValue(alt, plotH: plotH, axisMin: 0, axisMax: maxAgl)
            }

            let visibleMs = viewport.visibleMsRange(plotW: plotW, totalMs: safeChartMs)
            let visibleAlt = viewport.visibleValueRange(plotH: plotH, axisMin: 0, axisMax: maxAgl)

            // ── Vertical grid lines (time axis) ──────────────────────────────
            // Stepped over the VISIBLE window rather than the whole flight, so the
            // gridline count stays constant as you zoom in.
            let xGridIntervalMs = niceInterval(visibleMs.upperBound - visibleMs.lowerBound)
            let timeDecimals = xGridIntervalMs < 100 ? 2 : 1
            var gridTimeMs = floor(visibleMs.lowerBound / xGridIntervalMs) * xGridIntervalMs
            while gridTimeMs <= visibleMs.upperBound {
                let gx = xOfMs(gridTimeMs)
                if gx >= FlightChart.marginX - 0.5, gx <= plotW + FlightChart.marginX + 0.5 {
                    stroke(context, from: CGPoint(x: gx, y: 0), to: CGPoint(x: gx, y: plotH),
                           color: SPColor.onPrimary)
                    // A gridline exactly at zero comes out of `floor` as -0.0, which
                    // formats as "-0.0s" — a negative time on a flight that starts at
                    // the pad.
                    let seconds = Double(gridTimeMs) / 1000
                    draw(context,
                         String(format: "%.\(timeDecimals)fs", seconds == 0 ? 0 : seconds),
                         size: FlightChart.axisTextSize, color: SPColor.secondaryContainer,
                         at: CGPoint(x: gx, y: baseline(plotH + FlightChart.axisTextSize,
                                                        size: FlightChart.axisTextSize)),
                         anchor: .center)
                }
                gridTimeMs += xGridIntervalMs
            }

            // ── Horizontal grid lines (altitude axis) ────────────────────────
            let yGridInterval = niceInterval(visibleAlt.upperBound - visibleAlt.lowerBound)
            var gridAlt = floor(visibleAlt.lowerBound / yGridInterval) * yGridInterval
            while gridAlt <= visibleAlt.upperBound {
                let gy = yOfAlt(gridAlt)
                if gy >= -0.5, gy <= plotH + 0.5 {
                    stroke(context, from: CGPoint(x: FlightChart.marginX, y: gy),
                           to: CGPoint(x: plotW + FlightChart.marginX, y: gy),
                           color: SPColor.onPrimary)
                    if displayAltitude {
                        // Sub-metre gridlines need a decimal, or a zoomed axis reads as
                        // several identical labels.
                        let label = yGridInterval < 1
                            ? String(format: "%.1fm", Double(gridAlt))
                            : "\(Int(gridAlt.rounded()))m"
                        drawAltitudeLabel(context, label,
                                          y: baseline(gy + FlightChart.axisTextSize / 2,
                                                      size: FlightChart.axisTextSize))
                    }
                }
                gridAlt += yGridInterval
            }

            let plotRect = CGRect(x: FlightChart.marginX, y: 0, width: plotW, height: plotH)

            // ── Altitude trace ───────────────────────────────────────────────
            // Clipped rather than clamped: clamping an out-of-view point to the edge
            // would draw a false line along the border.
            if displayAltitude {
                var clipped = context
                clipped.clip(to: Path(plotRect))
                var path = Path()
                for (i, sample) in data.enumerated() {
                    let point = CGPoint(x: xOfMs(CGFloat(sample.timestampMs - firstTimestampMs)),
                                        y: yOfAlt(CGFloat(sample.altitudeM)))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                clipped.stroke(path, with: .color(SPColor.primary), lineWidth: 1)
            }

            // ── Accelerometer traces ─────────────────────────────────────────
            let accelValues = data.flatMap { [$0.accel.x, $0.accel.y, $0.accel.z] }
                .filter { $0.isFinite }
            let rawMaxAccel = CGFloat(accelValues.max() ?? 0)
            let minAccel = CGFloat(accelValues.min() ?? 0)
            // Guard a zero-range accelerometer scale.
            let accelRange = (rawMaxAccel - minAccel) < 0.001 ? 1 : (rawMaxAccel - minAccel)

            if accelRange > 0.001, displayAccelX || displayAccelY || displayAccelZ {
                let accelAxisMax = minAccel + accelRange
                func yOfAccel(_ v: CGFloat) -> CGFloat {
                    viewport.screenYOfValue(v, plotH: plotH, axisMin: minAccel, axisMax: accelAxisMax)
                }

                // Right-hand axis, stepped in whole g over the visible span so the
                // labels stay round numbers at every zoom level.
                let visibleAccel = viewport.visibleValueRange(plotH: plotH, axisMin: minAccel,
                                                              axisMax: accelAxisMax)
                let g = FlightChart.gForceMps2
                let gInterval = niceInterval((visibleAccel.upperBound - visibleAccel.lowerBound) / g)
                let gDecimals = gInterval < 1 ? 1 : 0
                var gridG = floor(visibleAccel.lowerBound / g / gInterval) * gInterval
                while gridG <= visibleAccel.upperBound / g {
                    let gy = yOfAccel(gridG * g)
                    if gy >= -0.5, gy <= plotH + 0.5 {
                        let g = Double(gridG)
                        draw(context, String(format: "%.\(gDecimals)fg", g == 0 ? 0 : g),
                             size: FlightChart.axisTextSize, color: SPColor.secondaryContainer,
                             at: CGPoint(x: plotW + px(4),
                                         y: baseline(gy + FlightChart.axisTextSize / 2,
                                                     size: FlightChart.axisTextSize)),
                             anchor: .leading)
                    }
                    gridG += gInterval
                }

                var clipped = context
                clipped.clip(to: Path(plotRect))
                func drawAccelTrace(_ color: Color, _ value: (FlightSample) -> Float) {
                    var path = Path()
                    var penDown = false
                    for sample in data {
                        let v = value(sample)
                        // Skip a single axis spike that slipped through the per-sample
                        // check, lifting the pen rather than drawing across the gap.
                        guard v.isFinite, v >= FlightChart.minSaneAccelMps2,
                              v <= FlightChart.maxSaneAccelMps2 else {
                            penDown = false
                            continue
                        }
                        let point = CGPoint(x: xOfMs(CGFloat(sample.timestampMs - firstTimestampMs)),
                                            y: yOfAccel(CGFloat(v)))
                        if penDown { path.addLine(to: point) } else { path.move(to: point) }
                        penDown = true
                    }
                    clipped.stroke(path, with: .color(color), lineWidth: 1)
                }

                if displayAccelX { drawAccelTrace(Self.accelXColor) { $0.accel.x } }
                if displayAccelY { drawAccelTrace(Self.accelYColor) { $0.accel.y } }
                if displayAccelZ { drawAccelTrace(Self.accelZColor) { $0.accel.z } }
            }

            // ── Event markers ────────────────────────────────────────────────
            // Drawn last so the labels sit above every trace.
            if displayAltitude {
                drawEvents(context, resolved: resolved, firstTimestampMs: firstTimestampMs,
                           plotW: plotW, plotH: plotH, xOfMs: xOfMs, yOfAlt: yOfAlt,
                           bodyTextSize: bodyTextSize, eventScale: eventScale)
            }
        }
        .overlay {
            ChartGestureOverlay(
                onTransform: { centroid, panChange, zoomChange, size in
                    viewport = viewport.transform(
                        centroid: centroid,
                        panChange: panChange,
                        zoomChange: zoomChange,
                        plotW: size.width - FlightChart.marginX,
                        plotH: size.height - FlightChart.marginY)
                },
                onDoubleTap: { viewport = ChartViewport() })
        }
    }

    /// Place each event's annotation in the first row it fits, so events sharing a
    /// timestamp — a primary and its backup firing together, say — stay legible.
    private func drawEvents(_ context: GraphicsContext,
                            resolved: [ResolvedEvent],
                            firstTimestampMs: Int,
                            plotW: CGFloat, plotH: CGFloat,
                            xOfMs: (CGFloat) -> CGFloat,
                            yOfAlt: (CGFloat) -> CGFloat,
                            bodyTextSize: CGFloat,
                            eventScale: CGFloat) {
        // Rows already claimed, as spans per row index.
        var occupiedRows: [[ClosedRange<CGFloat>]] = []
        let rowHeight = bodyTextSize + px(8)

        for event in resolved {
            let x = xOfMs(CGFloat(event.timestampMs - firstTimestampMs))
            let y = yOfAlt(CGFloat(event.altitudeM))
            // Panned or zoomed out of the plot area — skipped entirely rather than
            // pinned to the edge, which would put a marker where nothing happened.
            guard x >= FlightChart.marginX, x <= plotW + FlightChart.marginX,
                  y >= 0, y <= plotH else { continue }

            let color: Color
            switch event.event {
            case .apogee:                  color = Self.apogeeColor
            case .drogueVelocityThreshold: color = Self.drogueColor
            case .mainVelocityThreshold:   color = Self.mainColor
            default:                       color = SPColor.secondaryContainer
            }

            let label = "\(event.label): "
                + String(format: "%.1f", Double(event.altitudeM)) + "m"

            // Indicator circles precede the text for deployment events, and scale with
            // it so the annotation reads as one unit.
            let indicatorWidth = event.stats != nil ? px(48) * eventScale : 0
            let text = Text(label).font(SPFont.chartLabel(size: bodyTextSize))
            let textWidth = context.resolve(text).measure(in: CGSize(width: plotW * 2,
                                                                     height: plotH)).width
            let annotationWidth = indicatorWidth + textWidth + px(8)

            // Flip the annotation to the left of the point when it would otherwise run
            // off the right edge, and keep it clear of the altitude axis either way.
            let flip = x + annotationWidth > plotW + FlightChart.marginX
            let startX = max(flip ? x - annotationWidth - px(8) : x + px(8), FlightChart.marginX)
            let span = startX...(startX + annotationWidth)

            var row = occupiedRows.firstIndex { claimed in
                !claimed.contains { $0.lowerBound <= span.upperBound
                                    && span.lowerBound <= $0.upperBound }
            }
            if row == nil {
                occupiedRows.append([])
                row = occupiedRows.count - 1
            }
            occupiedRows[row!].append(span)

            // Keep the stack inside the chart: below the point where there is room,
            // above it when the point sits low. The final clamp matters for a tall
            // stack at apogee, where both directions can overshoot.
            let stackOffset = CGFloat(row! + 1) * rowHeight
            let unclamped = y + stackOffset < plotH ? y + stackOffset : y - stackOffset
            let annotationY = min(max(unclamped, min(bodyTextSize, plotH)), plotH)

            // A dot at the true location — never shifted — plus a leader to its
            // annotation row, so the pairing is clear even when several events stack up.
            let dotRadius = 3 * eventScale
            context.fill(Path(ellipseIn: CGRect(x: x - dotRadius, y: y - dotRadius,
                                                width: dotRadius * 2, height: dotRadius * 2)),
                         with: .color(color))
            stroke(context,
                   from: CGPoint(x: x, y: y),
                   to: CGPoint(x: startX + (flip ? annotationWidth : 0), y: annotationY),
                   color: color)

            if let stats = event.stats {
                drawDeploymentIndicators(context, stats: stats,
                                         x: startX, y: annotationY, scale: eventScale)
            }
            context.draw(text.foregroundColor(color),
                         at: CGPoint(x: startX + indicatorWidth,
                                     y: baseline(annotationY + bodyTextSize / 3,
                                                 size: bodyTextSize)),
                         anchor: .leading)
        }
    }

    /// Pre-fire continuity, fired, post-fire continuity. Filled = true, outlined =
    /// false — an outlined "fired" beside a filled pre-fire continuity means the charge
    /// had continuity and never got a fire command.
    private func drawDeploymentIndicators(_ context: GraphicsContext,
                                          stats: DeployChannelStats,
                                          x: CGFloat, y: CGFloat, scale: CGFloat) {
        func indicator(_ offset: CGFloat, _ on: Bool) {
            let r = 4 * scale
            let rect = CGRect(x: x + offset * scale - r, y: y - r, width: r * 2, height: r * 2)
            let circle = Path(ellipseIn: rect)
            if on {
                context.fill(circle, with: .color(Self.indicatorColor))
            } else {
                context.stroke(circle, with: .color(Self.indicatorColor), lineWidth: 1 * scale)
            }
        }
        indicator(px(8), stats.preFireContinuity)
        indicator(px(24), stats.fired)
        indicator(px(40), stats.postFireContinuity)
    }

    // MARK: Canvas helpers

    /// Android writes its chart offsets in raw pixels; this is that number in points.
    /// See `FlightChart.androidChartDensity`.
    private func px(_ value: CGFloat) -> CGFloat { value / FlightChart.androidChartDensity }

    /// Where to CENTRE a label so it sits on the baseline Android draws it at.
    ///
    /// Android's `Canvas.drawText` positions text by its **baseline**; SwiftUI's
    /// `GraphicsContext.draw` positions it by an anchor on its bounding box. A box
    /// centred a quarter of the font size above the baseline puts the glyphs where
    /// Android puts them — which for the time axis is what keeps the labels inside
    /// their gutter instead of hanging out below the canvas.
    private func baseline(_ y: CGFloat, size: CGFloat) -> CGFloat { y - size / 4 }

    private func stroke(_ context: GraphicsContext, from: CGPoint, to: CGPoint, color: Color) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(color), lineWidth: 1)
    }

    private func draw(_ context: GraphicsContext, _ string: String, size: CGFloat,
                      color: Color, at point: CGPoint, anchor: UnitPoint) {
        context.draw(Text(string).font(SPFont.chartLabel(size: size)).foregroundColor(color),
                     at: point, anchor: anchor)
    }

    /// An altitude label, right-aligned into the left gutter 8 px from its edge — and
    /// **clamped so its left edge never goes negative**.
    ///
    /// Android's `tx = (chartMarginX - measureText - 8f).coerceAtLeast(0f)`, expressed
    /// for a trailing anchor: the anchor is the label's RIGHT edge here, so the clamp is
    /// on the anchor minus the measured width. A label too wide for the gutter — a
    /// decimal one at deep zoom, "900.5m" — then butts against the plot instead of losing
    /// its leading character off the canvas. See `FlightChart.marginX` for why the gutter
    /// is 112 px rather than the 64 it was.
    private func drawAltitudeLabel(_ context: GraphicsContext, _ label: String, y: CGFloat) {
        let text = Text(label)
            .font(SPFont.chartLabel(size: FlightChart.axisTextSize))
            .foregroundColor(SPColor.secondaryContainer)
        let resolved = context.resolve(text)
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude,
                               height: CGFloat.greatestFiniteMagnitude)
        let width = resolved.measure(in: unbounded).width
        let x = max(FlightChart.marginX - px(8), width)
        context.draw(resolved, at: CGPoint(x: x, y: y), anchor: .trailing)
    }
}

// MARK: - Gestures

/// Pinch-to-zoom about the touch centroid, one- or two-finger drag to pan, and
/// double-tap to reset.
///
/// UIKit recognizers rather than SwiftUI gestures because **`MagnificationGesture`
/// does not report where the pinch is**, and the focal point is the whole behaviour
/// here: without it a pinch zooms about the middle of the plot and the data slides out
/// from under the fingers. Compose's `detectTransformGestures` reports centroid, pan
/// delta and zoom delta together; a pinch recognizer and a pan recognizer running
/// simultaneously report the same three things, one part per callback, and the
/// transform composes either way.
private struct ChartGestureOverlay: UIViewRepresentable {
    /// centroid, pan delta, zoom factor, and the view's size — all in points.
    let onTransform: (CGPoint, CGPoint, CGFloat, CGSize) -> Void
    let onDoubleTap: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2

        pinch.delegate = context.coordinator
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(doubleTap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ChartGestureOverlay

        init(_ parent: ChartGestureOverlay) { self.parent = parent }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .changed, let view = recognizer.view else { return }
            let scale = recognizer.scale
            recognizer.scale = 1                       // report the DELTA, as Compose does
            parent.onTransform(recognizer.location(in: view), .zero, scale, view.bounds.size)
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .changed, let view = recognizer.view else { return }
            let t = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            parent.onTransform(recognizer.location(in: view), CGPoint(x: t.x, y: t.y),
                               1, view.bounds.size)
        }

        @objc func handleDoubleTap() { parent.onDoubleTap() }

        /// Pinch and pan have to run together: a two-finger gesture is usually both.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
