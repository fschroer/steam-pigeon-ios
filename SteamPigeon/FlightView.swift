import SwiftUI

/// The recovery display: where the rocket is, how high, and what it is doing.
///
/// Laid out for the actual use — read at arm's length, outdoors, while walking. The
/// distance and bearing are the largest things on screen because they are what the
/// user is acting on; everything else is context.
///
/// Dark by default, matching Android, which sets dark regardless of the system
/// setting: this is looked at in daylight next to a launch rail, not in a browser.
struct FlightView: View {
    @ObservedObject var model: LinkViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            // ADR-0022: distance and bearing are suppressed TOGETHER, because both
            // come out of one vector — a rejected position aims a bearing just as
            // wrongly. What is withheld is the derived figure, never the position.
            if let v = model.vector {
                recovery(v)
            } else {
                suppressed
            }

            Divider()
            flightFacts
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SPColor.background)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(SPFont.titleLarge).foregroundStyle(SPColor.onBackground)
            Spacer()
            if let s = state {
                Text(s)
                    .font(SPFont.labelMedium)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(armed ? SPColor.errorContainer : SPColor.surfaceContainerHigh)
                    .clipShape(Capsule())
            }
        }
    }

    private func recovery(_ v: LocatorVector) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text("\(v.distanceM)")
                    .font(SPFont.telemetryBold(size: 64))
                Text("m").font(SPFont.titleLarge).foregroundStyle(SPColor.onSurfaceVariant)
            }
            HStack(spacing: 8) {
                Image(systemName: "location.north.fill")
                    .rotationEffect(.degrees(v.azimuthDeg))
                Text(String(format: "%.0f° %@", v.azimuthDeg, v.ordinal))
                    .font(SPFont.telemetry(size: 22))
            }
            .foregroundStyle(SPColor.secondary)
        }
    }

    private var suppressed: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Distance unavailable")
                .font(SPFont.titleLarge)
                .foregroundStyle(SPColor.onSurfaceVariant)
            if let why = model.vectorSuppressedReason {
                Text(why).font(SPFont.bodySmall).foregroundStyle(SPColor.onSurfaceVariant)
            }
        }
    }

    private var flightFacts: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = model.telemetry {
                row("altitude", String(format: "%.0f m", t.altitudeAgl))
                // NED: down is positive, so climb is the negation.
                row("vertical", String(format: "%+.1f m/s", -t.velocityNed.z))
                row("GPS", "\(t.satellites) sats · \(t.gpsStatus)")
            } else if let p = model.prelaunch {
                row("altitude", String(format: "%.0f m", p.altitudeAgl))
                row("GPS", "\(p.satellites) sats · \(p.gpsStatus)")
                row("battery", String(format: "%.2f V", Double(p.locatorBatteryMv) / 1000))
                if p.padAlert != .quiet { row("pad alert", "\(p.padAlert)") }
            } else {
                Text("No locator connected").font(SPFont.bodyMedium).foregroundStyle(SPColor.onSurfaceVariant)
            }

            if let acc = model.phone.horizontalAccuracyM {
                row("this phone", String(format: "±%.0f m", acc))
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(SPFont.labelMedium).foregroundStyle(SPColor.onSurfaceVariant)
                .frame(width: 84, alignment: .leading)
            Text(value).font(SPFont.telemetry).foregroundStyle(SPColor.onBackground)
            Spacer()
        }
    }

    // MARK: - Derived text

    private var name: String {
        if let n = model.prelaunch?.deviceName, !n.isEmpty { return n }
        if let id = model.connectedLocatorId { return String(format: "Locator %08x", id) }
        return "No locator"
    }

    private var armed: Bool { model.telemetry?.armed ?? model.prelaunch?.armed ?? false }

    private var state: String? {
        if let t = model.telemetry { return "\(t.flightState)" }
        if model.prelaunch != nil { return armed ? "armed" : "disarmed" }
        return nil
    }
}
