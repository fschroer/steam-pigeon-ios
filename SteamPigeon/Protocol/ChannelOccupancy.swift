import Foundation

/// Who — other than us — is known to be sitting on a given channel.
///
/// Both scans already answer this; the value of having it in one place is the word
/// **other**. A scan run while connected reports our own rocket on our own channel, every
/// time, correctly. Every consumer of this answer is asking in order to warn about
/// *sharing* a channel with somebody, so the one locator that cannot possibly collide
/// with itself has to come out first — and on Android it was left in twice, in two
/// different ways, which is why this is no longer inline in a view.
///
/// Excluded **by identity, not by channel**. `ChannelSurvey.Result.occupied` drops the
/// home channel wholesale, which is the closest ADR-0019 could get: when it was written
/// the sweep reported a frame count and no id, so "on our channel" was the only available
/// stand-in for "ours". It is a lossy one — it also hides a genuine neighbour sharing
/// your channel, which is precisely the thing worth warning about. Now that `locator_id`
/// rides in the response (ADR-0029), the question can be asked directly, so this reads
/// `confirmed` and filters on who rather than where.
///
/// A locator with no id reported (an older receiver, or a frame type that carries none)
/// resolves to no name and therefore to nil: the channel is still occupied and the survey
/// still withholds it from suggestions, but naming nobody would be a warning with nothing
/// in it.
enum ChannelOccupancy {

    /// - Parameters:
    ///   - excludeLocatorId: the connected locator — its broadcasts are why the channel
    ///     reads occupied, and they are not a conflict.
    ///   - labelOf: resolves a stored display name for an id, or nil if unknown. A
    ///     closure rather than the known-locator store so this stays testable on its own.
    /// - Returns: a display name, a hex id when nothing better is known, or nil when
    ///   nothing is known at all — which is **not** the same as "channel free": a channel
    ///   nothing has scanned is simply unmeasured.
    static func occupant(of channel: Int,
                         survey: ChannelSurvey.Result?,
                         search: LocatorSearch.Run?,
                         excludeLocatorId: UInt32? = nil,
                         labelOf: (UInt32) -> String? = { _ in nil }) -> String? {
        // Search hits win: a search is the more recent and more direct evidence, since it
        // went looking for exactly this.
        if let hit = search?.hits.first(where: {
            $0.channel == channel && $0.locatorId != excludeLocatorId
        }) {
            if !hit.deviceName.isEmpty { return hit.deviceName }
            if let label = labelOf(hit.locatorId) { return label }
            return String(format: "%08X", hit.locatorId)
        }
        guard let occupied = survey?.confirmed.first(where: {
            $0.channel == channel && $0.occupiedByLocator && $0.locatorId != excludeLocatorId
        }) else { return nil }

        if let label = labelOf(occupied.locatorId) { return label }
        return occupied.locatorId != 0 ? String(format: "%08X", occupied.locatorId) : nil
    }
}
