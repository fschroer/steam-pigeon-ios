import SwiftUI

/// The centre-of-map banner: what is wrong with the rocket standing in front of you.
///
/// Ported from `FlightMapScreen.kt`'s `PulsingText` block. It is the app's
/// anti-habituation answer (ADR-0021 Decision 5): permanently visible and **silent**,
/// so the spoken warning can stay on a long cadence without the condition ever being
/// out of sight.
enum FlightBanner {

    /// What the banner says, or nil when there is nothing to say.
    ///
    /// Composed exactly as Android composes it, including that the two lines are
    /// independent: a disarmed rocket with a fix says one thing, a fixless armed one
    /// says another, and a disarmed fixless one says both.
    ///
    /// A pad alert REPLACES the plain "Disarmed" rather than adding to it. It is the
    /// same fact escalated — the rocket is prepped and not armed — and saying it twice
    /// reads as two faults.
    static func text(padAlert: PadAlertState,
                     snoozeMinutes: Int,
                     armed: Bool,
                     locatorGpsLock: Bool) -> String? {
        var head = ""
        switch padAlert {
        case .alerting:
            head = "ROCKET ON PAD — NOT ARMED\ntap top panel to snooze"
        case .snoozed:
            head = "NOT ARMED — alert snoozed \(snoozeMinutes) min"
        case .quiet:
            head = armed ? "" : "Disarmed"
        }
        let separator = (!armed && !locatorGpsLock) ? "\n" : ""
        let tail = locatorGpsLock ? "" : "No GPS"
        let all = head + separator + tail
        return all.isEmpty ? nil : all
    }

    /// Red while alerting, yellow while snoozed, white otherwise.
    ///
    /// Snoozed is coloured distinctly rather than folded into the quiet case: a
    /// silenced locator that looks identical to a healthy one is the failure ADR-0021
    /// started from.
    static func color(padAlert: PadAlertState) -> Color {
        switch padAlert {
        case .alerting: return .red
        case .snoozed:  return .yellow
        case .quiet:    return .white
        }
    }

    /// Whether the banner pulses.
    ///
    /// ONLY once a pad alert has escalated it. A disarmed rocket and a missing GPS lock
    /// are ordinary pre-flight states — true, worth showing, and not worth an animation.
    /// They are also the states the app sits in for most of its working life, and
    /// pulsing through all of it both spends battery and trains the eye to ignore the
    /// very thing the escalation needs it to notice. The colour already carries the
    /// distinction.
    static func pulses(padAlert: PadAlertState) -> Bool { padAlert != .quiet }
}

/// Android's `PulsingText`: a text that fades in and out while `pulse` is true, and is
/// an ordinary text when it is not.
struct PulsingText: View {
    let text: String
    let color: Color
    var pulse: Bool = false
    var font: Font = SPFont.displayLarge

    @State private var faded = false

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .multilineTextAlign()
            // No alpha layer at all when it is not pulsing — a constant 1 still costs
            // one, and this sits over a continuously rendering map.
            .opacity(pulse && faded ? 0 : 1)
            .animation(pulse ? .linear(duration: 0.5).repeatForever(autoreverses: true) : nil,
                       value: faded)
            .onAppear { if pulse { faded = true } }
            .onChange(of: pulse) { now in faded = now }
            .allowsHitTesting(false)     // the map owns every gesture underneath it
    }
}

private extension View {
    func multilineTextAlign() -> some View { multilineTextAlignment(.center) }
}
