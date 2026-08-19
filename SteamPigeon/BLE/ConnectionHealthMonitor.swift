import Foundation

/// The ADR-0012 phantom-connection watchdog, as pure logic.
///
/// **Invariant 1 is load-bearing: silence triggers a probe, not a disconnect.**
/// The original Android watchdog tore the link down after 10 s of GATT silence, and
/// that was the bug — a healthy receiver has nothing to relay whenever the locator is
/// off, on the pad, or out of LoRa range. It tore down a good connection, reconnected,
/// saw 10 s more silence, and tore down again, which the user reported as "when the
/// app isn't receiving messages from a locator, it repeatedly disconnects and
/// reconnects the receiver."
///
/// What separates idle from dead is that **the receiver answers `receiverInfoRequest`
/// on its own behalf**, with no locator involved. A live receiver replies; a phantom
/// link does not. So silence provokes a probe, and only repeated *unanswered* probes
/// mean the link is dead.
///
/// Deliberately free of CoreBluetooth so the invariants can be tested without
/// hardware — the failure this encodes cost real bench time to find.
struct ConnectionHealthMonitor {

    /// One silent window. Android: `DATA_TIMEOUT_MS`.
    static let dataTimeout: TimeInterval = 10

    /// Consecutive unanswered probes before the link is declared phantom (~30 s).
    /// Android: `MAX_MISSED_HEALTH_PROBES`.
    static let maxMissedProbes = 3

    /// What the caller should do at the end of a window.
    enum Action: Equatable {
        /// Data arrived during the window — the link is healthy, stay quiet.
        /// While a locator is transmitting this is every window, so the watchdog
        /// adds no BLE chatter during real use.
        case none
        /// Silence. Ask the receiver to speak for itself.
        case sendProbe
        /// Enough consecutive unanswered probes. The link is phantom; reconnect.
        case declarePhantom
    }

    private(set) var missedProbes = 0
    private var sawDataThisWindow = false

    init() {}

    /// Call for **every** inbound byte — relayed locator traffic and probe replies
    /// alike. Android routes all inbound GATT data through `recordDataReceived`, and
    /// that is what makes a receiver answering any probe keep the link indefinitely.
    mutating func recordDataReceived() {
        sawDataThisWindow = true
        missedProbes = 0
    }

    /// Call once per `dataTimeout` window.
    mutating func windowElapsed() -> Action {
        if sawDataThisWindow {
            sawDataThisWindow = false
            missedProbes = 0
            return .none
        }
        missedProbes += 1
        return missedProbes >= Self.maxMissedProbes ? .declarePhantom : .sendProbe
    }

    /// Call on connect and on reconnect — a fresh link starts with a clean slate.
    mutating func reset() {
        missedProbes = 0
        sawDataThisWindow = false
    }
}
