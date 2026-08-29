import Foundation

/// A pending password prompt for one locator (ADR-0006 Decision 6).
struct LocatorChallenge: Equatable, Identifiable {
    var id: UInt32 { locatorId }

    let locatorId: UInt32
    /// Only `PreLaunchData` carries a device name, which is why an **armed** stranger
    /// cannot be challenged — see `ChallengePolicy`.
    let deviceName: String
    /// Where the receiver was before a deliberate channel change landed on this
    /// unknown locator, or nil for a passive prompt on the channel we are already on.
    ///
    /// **This is what makes cancelling safe.** Pointing the receiver at a locator whose
    /// password we do not hold leaves the app displaying nothing at all — the old
    /// locator is off-channel and the new one is not authorized — so "cancel" has to
    /// undo the move rather than merely dismiss the dialog. A passive challenge has
    /// nothing to undo, and is remembered as declined instead (ADR-0011, ADR-0006).
    var previousChannel: Int?
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
        /// The locator we believe we are CONNECTED to stopped authenticating — its
        /// password was changed on the device.
        ///
        /// Reproduced 2026-08-29: without this the app is permanently deaf to that
        /// locator and cannot say why. Its frames fail authorization so nothing is
        /// admitted; `connectedLocatorId` still names it, because nothing released a
        /// connection on an auth failure; and `passive` refuses to prompt while
        /// anything is connected — so the only thing on screen was the conflict banner
        /// calling the connected locator "another locator", over a status panel reading
        /// "No Locator" with the last good RSSI still on it. There was no way out inside
        /// the app.
        case credentialsChanged
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
        case .credentialsChanged:
            // The holder's OWN frame failed to authenticate, so `connected` is a stale
            // belief rather than a live connection to protect. Asked even though
            // something is "connected", and asked even if this locator was declined
            // before — a decline was about a locator we had no business displaying,
            // not about the one we are already showing.
            return true
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
    /// A third key, for the same reason the second one is separate: an install made
    /// before channels were remembered keeps everything it already had.
    private static let channelKey = "com.steampigeon.ios.knownLocatorChannels"
    private let defaults: UserDefaults

    private(set) var keysById: [UInt32: UInt32] = [:]
    /// The last device name each locator was heard to carry. A superset of Android's
    /// `KnownLocator.label`: an id can have a name here with no password key.
    private(set) var labelsById: [UInt32: String] = [:]
    /// The receiver's LoRa channel the last time each locator was heard on it — the
    /// memory the locator search runs on (ADR-0029). With several rockets and one
    /// receiver, "which channel was that one on again" is the question, and the app has
    /// already answered it every time it heard from each of them.
    ///
    /// **Absence is meaningful.** Channel 0 is the factory default (ADR-0025), so
    /// "never heard" and "heard on channel 0" must stay distinguishable — which is why
    /// this is a dictionary lookup rather than an `Int` defaulting to 0, and matches the
    /// `optional uint32 last_channel` Android's proto uses for explicit presence.
    private(set) var channelsById: [UInt32: Int] = [:]

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
        if let raw = defaults.dictionary(forKey: Self.channelKey) as? [String: NSNumber] {
            for (k, v) in raw {
                if let id = UInt32(k) { channelsById[id] = v.intValue }
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

    /// Record the channel `locatorId` was just heard on.
    ///
    /// **The channel from that frame, not the app's cached receiver config**, which lags
    /// by one broadcast and is wrong exactly when a locator broadcasts once and goes
    /// quiet. `PreLaunchData` carries the receiver's channel; `TelemetryData` has no room
    /// for one, so the caller falls back to the cached config there.
    ///
    /// Returns false when nothing changed, which is the common case: a broadcast arrives
    /// at 1 Hz and re-writing `UserDefaults` at that rate for a channel that has not
    /// moved is pure churn.
    @discardableResult
    mutating func noteChannel(locatorId: UInt32, channel: Int) -> Bool {
        guard ReceiverConfig.channelRange.contains(channel),
              channelsById[locatorId] != channel else { return false }
        channelsById[locatorId] = channel
        persist()
        return true
    }

    mutating func forget(locatorId: UInt32) {
        keysById.removeValue(forKey: locatorId)
        labelsById.removeValue(forKey: locatorId)
        channelsById.removeValue(forKey: locatorId)
        persist()
    }

    func label(for locatorId: UInt32) -> String? {
        labelsById[locatorId]?.isEmpty == false ? labelsById[locatorId] : nil
    }

    /// Where this locator was last heard, or nil if it never has been. Nil is **not**
    /// channel 0 — see `channelsById`.
    func lastChannel(for locatorId: UInt32) -> Int? { channelsById[locatorId] }

    /// Every id this store knows anything about — a password key, a name, or a channel.
    /// The search's target picker and its candidate list both read this, and a locator
    /// known only by the channel it was heard on is still worth looking for.
    var knownIds: Set<UInt32> {
        Set(keysById.keys).union(labelsById.keys).union(channelsById.keys)
    }

    /// **Every field is rewritten from the in-memory maps, so no writer can drop one it
    /// does not care about.** Android's writers each rebuilt the stored record and
    /// hand-copied the one other field that existed, which worked only while there were
    /// two: adding `last_channel` would have made every rename silently erase the
    /// locator's remembered channel, and the failure would have surfaced as a search that
    /// had forgotten where to look.
    private func persist() {
        var raw: [String: NSNumber] = [:]
        for (id, key) in keysById { raw[String(id)] = NSNumber(value: key) }
        defaults.set(raw, forKey: Self.key)
        var labels: [String: String] = [:]
        for (id, label) in labelsById { labels[String(id)] = label }
        defaults.set(labels, forKey: Self.labelKey)
        var channels: [String: NSNumber] = [:]
        for (id, channel) in channelsById { channels[String(id)] = NSNumber(value: channel) }
        defaults.set(channels, forKey: Self.channelKey)
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
