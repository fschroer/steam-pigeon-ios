import Foundation

/// A pending password prompt for one locator (ADR-0006 Decision 6).
struct LocatorChallenge: Equatable, Identifiable {
    var id: UInt32 { locatorId }

    let locatorId: UInt32
    /// Only `PreLaunchData` carries a device name, which is why an **armed** stranger
    /// cannot be challenged — see `ChallengePolicy`.
    let deviceName: String
    /// Set when the user got it wrong; the dialog stays open to retry.
    var rejected = false
}

/// When to raise a password prompt, and when to stay quiet.
///
/// Pure, for the same reason `LocatorConnection` is: these rules are mostly about
/// *not* prompting, and a policy that nags every second is as broken as one that
/// never asks.
struct ChallengePolicy {

    enum Trigger {
        /// First contact with an unknown locator on the current channel.
        case passive
        /// A deliberate receiver channel change landed on an unknown locator.
        /// Cancelling this reverts the channel, so it is always worth asking.
        case channelChange
    }

    /// Locators the user dismissed. Remembered so a decline is not re-asked every
    /// broadcast — at 1 Hz that would be unusable.
    private(set) var declined: Set<UInt32> = []

    init() {}

    /// - Parameters:
    ///   - hasDeviceName: false for a telemetry-only (armed) locator. An unknown
    ///     armed locator **cannot** be challenged: the dialog needs the name only
    ///     `PreLaunchData` carries, so it raises the conflict warning instead and
    ///     becomes connectable when it disarms — the only state where connecting is
    ///     useful anyway.
    ///   - connected: the current holder. A passive prompt never interrupts a live
    ///     connection; an armed stranger must not knock out the locator we are on.
    func shouldChallenge(locatorId: UInt32,
                         hasDeviceName: Bool,
                         connected: UInt32?,
                         challengeOpen: Bool,
                         trigger: Trigger) -> Bool {
        guard hasDeviceName, !challengeOpen else { return false }
        switch trigger {
        case .channelChange:
            // The user just did this on purpose, so ask even if declined before.
            return true
        case .passive:
            return connected == nil && !declined.contains(locatorId)
        }
    }

    mutating func decline(_ locatorId: UInt32) { declined.insert(locatorId) }

    /// An explicit Connect action clears the decline — the user changed their mind.
    mutating func reconsider(_ locatorId: UInt32) { declined.remove(locatorId) }
}

/// Locators whose password we hold, and what every locator this app has heard calls
/// itself. Both persisted across launches.
///
/// Keys are derived (FNV-1a), never the plaintext password: the app has no reason to
/// keep what the user typed, and the derived key is all the auth check needs.
///
/// **Names are kept for locators with no password too**, which is where this goes
/// beyond Android (`docs/UI_PARITY.md`). An armed locator broadcasts `TelemetryData`,
/// which carries no device name at all, so a locator that is armed before the app opens
/// can only be named from something remembered. Android remembers a name only as
/// `KnownLocator.label`, written when a password is accepted — so an OPEN locator, the
/// default state, is never named while armed on either platform. Storing the name of
/// every locator whose broadcast is accepted closes that, and it is the same fact from
/// the same field, kept for one more locator.
struct KnownLocatorStore {

    private static let key = "com.steampigeon.ios.knownLocators"
    /// A SEPARATE defaults key, not a richer value under the one above: installs made
    /// before labels existed keep their stored keys, which is the half that matters —
    /// and names are now kept for locators that have no entry there at all.
    private static let labelKey = "com.steampigeon.ios.knownLocatorLabels"
    private let defaults: UserDefaults

    private(set) var keysById: [UInt32: UInt32] = [:]
    /// The last device name each locator was heard to carry. A superset of Android's
    /// `KnownLocator.label`: an id can have a name here with no password key.
    private(set) var labelsById: [UInt32: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.dictionary(forKey: Self.key) as? [String: NSNumber] {
            for (k, v) in raw {
                if let id = UInt32(k) { keysById[id] = v.uint32Value }
            }
        }
        if let raw = defaults.dictionary(forKey: Self.labelKey) as? [String: String] {
            for (k, v) in raw {
                if let id = UInt32(k) { labelsById[id] = v }
            }
        }
    }

    mutating func remember(locatorId: UInt32, passwordKey: UInt32, label: String = "") {
        keysById[locatorId] = passwordKey
        // An empty name never replaces one already held: only `PreLaunchData` carries a
        // name, so the empty case means "not known here", not "renamed to nothing".
        if !label.isEmpty { labelsById[locatorId] = label }
        persist()
    }

    /// Record what a locator calls itself, whether or not its password is held.
    ///
    /// Returns false when nothing changed, which is the common case: `PreLaunchData`
    /// arrives at 1 Hz and re-writing `UserDefaults` at that rate for a name that has
    /// not moved is pure churn.
    @discardableResult
    mutating func noteName(locatorId: UInt32, name: String) -> Bool {
        guard !name.isEmpty, labelsById[locatorId] != name else { return false }
        labelsById[locatorId] = name
        persist()
        return true
    }

    mutating func forget(locatorId: UInt32) {
        keysById.removeValue(forKey: locatorId)
        labelsById.removeValue(forKey: locatorId)
        persist()
    }

    func label(for locatorId: UInt32) -> String? {
        labelsById[locatorId]?.isEmpty == false ? labelsById[locatorId] : nil
    }

    private func persist() {
        var raw: [String: NSNumber] = [:]
        for (id, key) in keysById { raw[String(id)] = NSNumber(value: key) }
        defaults.set(raw, forKey: Self.key)
        var labels: [String: String] = [:]
        for (id, label) in labelsById { labels[String(id)] = label }
        defaults.set(labels, forKey: Self.labelKey)
    }

    /// Try `password` against `frame`. On success returns the derived key to store.
    ///
    /// A blank password derives key 0, which is exactly how an **open** locator
    /// authenticates — so "no password" is a legitimate answer to the prompt, not an
    /// empty submission to reject.
    static func verify(password: String, frame: [UInt8], baseSize: Int) -> UInt32? {
        let key = LocatorAuth.deriveKey(password)
        return LocatorAuth.verifyFrame(frame: frame, passwordKey: key, baseSize: baseSize) ? key : nil
    }
}
