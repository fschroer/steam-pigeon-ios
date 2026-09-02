import Foundation

/// Arbitration for the app's single locator connection (ADR-0006, "One connection
/// at a time").
///
/// **Authorization and connection are different things.** Authorization answers
/// *"do I hold this locator's password?"* — a **set**, since anyone with two
/// locators is authorized for both, and since every *open* locator (key 0)
/// authenticates unconditionally, which is the default state. Connection is one
/// element of that set, and **an arriving packet never reassigns it**.
///
/// Collapsing the two is what let whichever authorized locator transmitted most
/// recently seize the display: the app alternated between two rockets packet by
/// packet, and against a second *open* locator the gate did nothing whatsoever.
///
/// Kept pure, exactly as Android keeps it, so the invariant is testable without a
/// view model.
enum LocatorConnection {

    /// How long the holder may be silent before another authorized locator may take
    /// the connection. Android: `CONNECTION_HOLD_MS`.
    ///
    /// Deliberately longer than the 5 s "link up" test used elsewhere, because the
    /// failures are asymmetric: holding too long costs a few seconds after a genuine
    /// power-down, while releasing too early puts **another rocket's data on screen
    /// mid-flight**.
    static let connectionHold: TimeInterval = 15

    /// May an authorized `sender` take the connection currently held by `connected`?
    ///
    /// True when the slot is free, when `sender` already holds it, or when the holder
    /// has been silent for at least `hold`. False for a *different* authorized locator
    /// while the holder is still live — the caller reports that as conflicting traffic
    /// and waits for the user to switch deliberately.
    ///
    /// `age` is the time since the last frame accepted from `connected`; it is
    /// meaningless when `connected` is nil and is ignored in that case.
    static func mayConnect(connected: UInt32?, sender: UInt32,
                           age: TimeInterval, hold: TimeInterval = connectionHold) -> Bool {
        connected == nil || connected == sender || age >= hold
    }

    /// Was this frame relayed from the channel a receiver-only move is **leaving**?
    ///
    /// A receiver-only change (ADR-0011 invariant 5) releases the connection before the
    /// change goes out, so the first authorized locator on the *new* channel can claim
    /// the slot without waiting out `mayConnect`'s hold. That opens a window: the BLE
    /// write, the receiver's own retune and its next relay all take time, and the locator
    /// we just let go of is still broadcasting on the old channel at 1 Hz. Its frames
    /// arrive into an empty slot and are perfectly authorized — so it takes the connection
    /// straight back and resolves the recognition cycle that was armed for a locator on a
    /// channel the receiver has not reached yet.
    ///
    /// Reported on Android 2026-08-29, and **intermittent for exactly that reason** — it
    /// depends on whether one of those broadcasts lands inside the window. Four locators
    /// on four channels, connected to Twist 0 on 34, Connect tapped on Twist Lock 5 on 60:
    /// the receiver arrived on 60, but the app had already re-adopted Twist 0, so the
    /// password prompt Twist Lock 5 should have raised never came. What came instead was
    /// the conflict banner — whose Connect action asks for the password, which is why the
    /// feature looked reachable by another route and broken by this one.
    ///
    /// The discriminator is the receiver's own channel stamp on every relayed frame
    /// (ADR-0011 invariant 3). A frame stamped with `previousChannel` was relayed before
    /// the retune and says nothing about where we are going. `TelemetryData` carries no
    /// stamp at all, so during the window it cannot be placed either and is treated the
    /// same way; an armed locator on the new channel is admitted a few seconds later, when
    /// the move resolves, and it could not have raised a challenge in the meantime anyway
    /// (the prompt needs a device name).
    ///
    /// Bounded by `moveInFlight` rather than by the recognition flag alone. The flag stays
    /// set until something arrives on the new channel, which may be never — a move onto an
    /// empty channel, say — and suppressing forever would leave the app deaf to the
    /// locator it still has. The receiver's config message state always returns to idle,
    /// so the window closes whether the move is acknowledged or times out.
    ///
    /// - Parameter frameChannel: the receiver's stamp, or nil for a message carrying none.
    static func isFromChannelBeingLeft(frameChannel: Int?,
                                       previousChannel: Int,
                                       awaitingRecognition: Bool,
                                       moveInFlight: Bool) -> Bool {
        awaitingRecognition && moveInFlight
            && (frameChannel == nil || frameChannel == previousChannel)
    }
}

/// The recognition gate: which locator's data reaches the screen, and which commands
/// are allowed out.
///
/// Enforcement is **app-side and deliberately soft** (ADR-0006 Decision 5): the
/// locator keeps accepting well-formed commands, and the password gates the honest
/// app, not a modified one. The threat model is accidental cross-connection at a
/// launch, not an attacker.
struct LocatorGate {

    enum Outcome: Equatable {
        /// Authorized and holds the connection — its data may be displayed.
        case accepted(UInt32)
        /// Authorized, but a different locator holds a live connection. Conflicting
        /// traffic: warn, leave the connection alone, let the user switch.
        case conflict(UInt32)
        /// We do not hold this locator's password and it is not open.
        case unauthorized(UInt32)
    }

    /// Password keys we hold, by locator id. A key of 0 means "open".
    private(set) var knownKeys: [UInt32: UInt32] = [:]

    /// The single connection holder. Never reassigned by an arriving packet.
    private(set) var connectedLocatorId: UInt32?

    /// When we last accepted a frame from the holder.
    private(set) var lastAcceptedFromHolder: Date?

    init(knownKeys: [UInt32: UInt32] = [:]) { self.knownKeys = knownKeys }

    mutating func remember(locatorId: UInt32, passwordKey: UInt32) {
        knownKeys[locatorId] = passwordKey
    }

    /// Explicit user switch — the conflict banner's Connect action. This is the only
    /// way a live connection changes hands other than the holder going silent.
    mutating func connect(to locatorId: UInt32, now: Date = Date()) {
        connectedLocatorId = locatorId
        lastAcceptedFromHolder = now
    }

    mutating func disconnect() {
        connectedLocatorId = nil
        lastAcceptedFromHolder = nil
    }

    /// Is `frame` authenticated for `locatorId`? True for a held key, or for an open
    /// locator (key 0), which authenticates unconditionally and is the default state.
    func isAuthorized(frame: [UInt8], locatorId: UInt32, baseSize: Int) -> Bool {
        if let key = knownKeys[locatorId],
           LocatorAuth.verifyFrame(frame: frame, passwordKey: key, baseSize: baseSize) {
            return true
        }
        return LocatorAuth.verifyFrame(frame: frame, passwordKey: 0, baseSize: baseSize)
    }

    /// Decide what to do with a broadcast. Mutating because accepting a frame from
    /// the holder refreshes the silence clock the hold is measured against.
    mutating func evaluate(frame: [UInt8], locatorId: UInt32,
                           baseSize: Int, now: Date = Date()) -> Outcome {
        guard isAuthorized(frame: frame, locatorId: locatorId, baseSize: baseSize) else {
            return .unauthorized(locatorId)
        }

        let age = lastAcceptedFromHolder.map { now.timeIntervalSince($0) } ?? .infinity
        guard LocatorConnection.mayConnect(connected: connectedLocatorId,
                                           sender: locatorId, age: age) else {
            return .conflict(locatorId)
        }

        connectedLocatorId = locatorId
        lastAcceptedFromHolder = now
        return .accepted(locatorId)
    }

    /// Commands are gated on **connected**, not merely authorized. Commands are
    /// addressed by the receiver's channel, so an Arm gated on the weaker condition
    /// could land on the wrong rocket.
    func mayCommand(_ locatorId: UInt32) -> Bool { connectedLocatorId == locatorId }
}
