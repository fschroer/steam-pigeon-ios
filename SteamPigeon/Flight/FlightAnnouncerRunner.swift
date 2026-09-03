import Foundation

/// Drives `FlightAnnouncer` — the timer and the speech engine that its pure half
/// deliberately does not hold.
///
/// Android's counterpart is two `LaunchedEffect`s inside `FlightSpeechAnnouncer`: one
/// keyed on the flight state, one a `while (true)` loop keyed on `inFlight` that reads the
/// latest telemetry through `rememberUpdatedState`. `sample` is that closure, and the
/// timer is that loop — started when the flight starts and stopped when it ends, so
/// nothing polls between flights.
@MainActor
final class FlightAnnouncerRunner {

    /// Reads the current state of the world. Set once, by whoever owns the model.
    var sample: (() -> FlightAnnouncer.Sample)?

    private var announcer = FlightAnnouncer()
    private let speech: FlightSpeech
    private var timer: Timer?

    init(speech: FlightSpeech) {
        self.speech = speech
    }

    /// The flight began or ended. Android keys its poll loop on exactly this.
    func setInFlight(_ inFlight: Bool) {
        guard inFlight != (timer != nil) else { return }
        if inFlight {
            announcer.pollingStarted()
            let timer = Timer.scheduledTimer(
                withTimeInterval: FlightAnnouncer.announcementInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.poll() }
                }
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// A new flight state arrived.
    func flightStateChanged() {
        guard let sample else { return }
        say(announcer.flightStateChanged(sample()))
    }

    /// Stop polling. The announcer's own guards are left alone — a flight is concluded by
    /// the locator saying so, never by a screen going away.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let sample else { return }
        say(announcer.poll(sample()))
    }

    private func say(_ lines: [FlightAnnouncer.Line]) {
        for line in lines { speech.say(line.text, priority: line.priority) }
    }
}
