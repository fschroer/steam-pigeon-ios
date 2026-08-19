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

/// Locators whose password we hold, persisted across launches.
///
/// Keys are derived (FNV-1a), never the plaintext password: the app has no reason to
/// keep what the user typed, and the derived key is all the auth check needs.
struct KnownLocatorStore {

    private static let key = "com.steampigeon.ios.knownLocators"
    private let defaults: UserDefaults

    private(set) var keysById: [UInt32: UInt32] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.dictionary(forKey: Self.key) as? [String: NSNumber] {
            for (k, v) in raw {
                if let id = UInt32(k) { keysById[id] = v.uint32Value }
            }
        }
    }

    mutating func remember(locatorId: UInt32, passwordKey: UInt32) {
        keysById[locatorId] = passwordKey
        persist()
    }

    mutating func forget(locatorId: UInt32) {
        keysById.removeValue(forKey: locatorId)
        persist()
    }

    private func persist() {
        var raw: [String: NSNumber] = [:]
        for (id, key) in keysById { raw[String(id)] = NSNumber(value: key) }
        defaults.set(raw, forKey: Self.key)
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
