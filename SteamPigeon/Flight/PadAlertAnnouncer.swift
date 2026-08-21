import Foundation
import CoreHaptics
import UIKit

/// The spoken and felt halves of the prepped-and-disarmed alert (ADR-0021, #37).
///
/// Three independent paths reach the operator: the locator's buzzer, this voice, and
/// this haptic. The banner is the fourth and is deliberately silent — it is the
/// anti-habituation channel, permanently visible, which is what lets the voice stay on
/// a long cadence.
@MainActor
final class PadAlertAnnouncer {

    /// Android's `padAlertRepeatMillis`. Long on purpose: the ESCALATION lives in the
    /// locator's buzzer, which gets louder and more frequent. Escalating here as well
    /// would just be two things shouting.
    static let repeatInterval: TimeInterval = 30

    /// Android's exact wording.
    static let spokenWarning = "Warning. Rocket is on the pad and not armed."

    private let speech: FlightSpeech
    private var repeatTimer: Timer?
    private var haptics: PadAlertHaptics?
    private var lastState: PadAlertState = .quiet

    init(speech: FlightSpeech) {
        self.speech = speech
    }

    /// Called whenever the locator's verdict changes.
    ///
    /// Only `alerting` speaks and vibrates. **A snoozed alert is shown, never spoken or
    /// felt** — speaking through a snooze would make the control useless, which is the
    /// same reasoning that keeps the snooze bounded.
    func update(_ state: PadAlertState) {
        guard state != lastState else { return }
        lastState = state

        stop()
        guard state == .alerting else { return }

        // Rising edge speaks immediately and OUTRANKS whatever routine callout is
        // mid-sentence, then repeats on a fixed cadence while the condition holds.
        speech.say(Self.spokenWarning, priority: .urgent)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval,
                                           repeats: true) { [weak self] _ in
            Task { @MainActor in self?.speech.say(Self.spokenWarning) }
        }

        let h = PadAlertHaptics()
        h.start()
        haptics = h
    }

    /// Cancel on ANY exit — snoozed, armed, laid down, or the screen going away.
    ///
    /// A haptic that outlives its cause is worse than none: it teaches the operator that
    /// the phone is broken rather than that the rocket is unarmed.
    func stop() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        haptics?.stop()
        haptics = nil
    }

    deinit {
        repeatTimer?.invalidate()
    }
}

/// The haptic channel.
///
/// The one path that still works with the phone muted, in a pocket, or on a loud flight
/// line — exactly where the buzzer and the voice fail. **Deliberately not gated on the
/// speech setting:** someone who turned speech off is MORE reliant on this, not less.
@MainActor
final class PadAlertHaptics {

    /// Android's waveform: two 260 ms pulses 140 ms apart, then a 2.4 s gap, repeating.
    /// A deliberate "something is wrong" rhythm rather than the single buzz of an
    /// ordinary notification, echoing the locator's doubled buzzer pattern.
    private static let pulse: TimeInterval = 0.26
    private static let gapBetweenPulses: TimeInterval = 0.14
    private static let restBetweenCycles: TimeInterval = 2.4
    static var cycle: TimeInterval { pulse * 2 + gapBetweenPulses + restBetweenCycles }

    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    /// Fallback for devices with no haptic engine.
    private var fallbackTimer: Timer?

    func start() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            startFallback()
            return
        }
        do {
            let engine = try CHHapticEngine()
            // The engine is stopped by the system on interruption or backgrounding. If
            // it dies while the rocket is still unarmed the alert must come back, not
            // quietly stay gone.
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    try? self?.engine?.start()
                    self?.restartPlayer()
                }
            }
            try engine.start()
            self.engine = engine

            let events = [
                Self.continuousPulse(at: 0),
                Self.continuousPulse(at: Self.pulse + Self.gapBetweenPulses),
            ]
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            player.loopEnabled = true
            // Loop over the WHOLE cycle including the rest, so the gap is part of the
            // rhythm rather than the pattern restarting the instant the second pulse
            // ends — which reads as one continuous buzz.
            player.loopEnd = Self.cycle
            try player.start(atTime: CHHapticTimeImmediate)
            self.player = player
        } catch {
            startFallback()
        }
    }

    private static func continuousPulse(at time: TimeInterval) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                // Full strength. Android drives amplitude 255; this is the channel that
                // has to survive a pocket.
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
            ],
            relativeTime: time,
            duration: pulse)
    }

    private func restartPlayer() {
        try? player?.start(atTime: CHHapticTimeImmediate)
    }

    /// Older or haptics-less devices: two taps per cycle. Weaker than the waveform, and
    /// the right kind of weaker — the rhythm still reads as "two pulses, pause".
    private func startFallback() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: Self.cycle,
                                             repeats: true) { _ in
            Task { @MainActor in
                generator.impactOccurred()
                try? await Task.sleep(for: .seconds(Self.pulse + Self.gapBetweenPulses))
                generator.impactOccurred()
            }
        }
        fallbackTimer?.fire()
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        engine?.stop()
        engine = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    deinit {
        fallbackTimer?.invalidate()
    }
}
