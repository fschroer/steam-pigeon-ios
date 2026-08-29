import Foundation

/// The receiver-driven hunt for a locator whose channel you have lost, and the pure
/// part of deciding where to look first (ADR-0029, #33 follow-up to ADR-0019).
///
/// This is the survey's opposite question and cannot share its sweep. The survey
/// shortlists the **quietest** channels and dwells there, because it is answering
/// "where should I move to". A locator you are looking for is by definition making
/// noise on the channel you want, so it is shortlisted by that rule only by accident.
///
/// The cost of a dwell is what shapes everything else. A locator is on air ~138 ms once
/// per second, so a dwell shorter than a full broadcast period reads an occupied channel
/// as empty most of the time — the coarse pass's known failure, and the reason the survey
/// has a confirm phase at all. At ~1.2 s per channel the whole band is ~77 s, which is a
/// long time to be deaf. Hence candidates first: a handful of channels the locator is
/// actually likely to be on answers the usual case in seconds, and the full band stays
/// available for when it does not.
///
/// Ported from Android's `data/LocatorSearch.kt`, rule for rule; `LocatorSearchTests`
/// mirrors its 23 cases.
enum LocatorSearch {

    /// Mirrors the firmware's `LocatorSearchStatus`.
    enum Status: Equatable {
        case progress, done, refusedArmed, refusedBusy, cancelled, unknown

        static func from(_ v: UInt8) -> Status {
            switch v {
            case 0:  return .progress
            case 1:  return .done
            case 2:  return .refusedArmed
            case 3:  return .refusedBusy
            case 4:  return .cancelled
            default: return .unknown
            }
        }
    }

    /// The channel every locator ships on, so it is where a factory-reset or freshly
    /// flashed one will be (ADR-0025 fixes the default at 0). Always worth a dwell: it
    /// costs one slot and covers the case where the locator's settings did not survive.
    static let defaultChannel = 0

    /// One locator heard on one channel.
    ///
    /// `locatorId` and `deviceName` are cleartext, straight off the air, and
    /// **unauthenticated** — the receiver holds no password and never inspects the auth
    /// tag. They are here to make a hit readable ("your Redline is on 12"), not to prove
    /// anything. Recognition happens the normal way once the receiver is pointed at the
    /// channel and real broadcasts start arriving.
    struct Hit: Equatable {
        let channel: Int
        let locatorId: UInt32
        let deviceName: String
        /// Shown on the hit row, in the same form and with the same colour scales the
        /// status panel already uses for the connected locator (`RssiBand` / `SnrBand`).
        ///
        /// Both numbers, because neither decides alone. A locator a few feet from the
        /// receiver is heard on channels it is nowhere near, and that artifact reads as
        /// strong; SNR is what separates it from a genuine occupant. Bench 2026-08-27
        /// hit exactly that — one locator reported on two channels — and relocating it
        /// 15–20 ft was the only way to tell which was real.
        let rssi: Int
        let snr: Int
        let armed: Bool

        init(channel: Int, locatorId: UInt32, deviceName: String,
             rssi: Int, snr: Int, armed: Bool) {
            self.channel = channel
            self.locatorId = locatorId
            self.deviceName = deviceName
            self.rssi = rssi
            self.snr = snr
            self.armed = armed
        }

        /// Whether the receiver is connected to this locator **on this channel**.
        ///
        /// Both halves are needed and each was got wrong on its own first.
        ///
        /// Channel alone is not connection: tuned to a channel, the app may still be
        /// waiting on an ADR-0006 password challenge, and the row claimed Connected
        /// throughout it.
        ///
        /// Identity alone is not enough either, and that is the subtler one. A locator
        /// close to the receiver is reported on more than one channel (see
        /// `Run.suspectChannels`) — and every one of those hits carries the SAME id, so
        /// an identity test marks them all Connected. Bench 2026-08-28 hit exactly that:
        /// both rows read Connected, neither offered a button, and a user sitting on the
        /// false channel had no way to reach the real one. The row is about a channel,
        /// so the test has to be too.
        func connectedOn(currentChannel: Int, connectedLocatorId: UInt32?) -> Bool {
            channel == currentChannel
                && locatorId != 0
                && locatorId == connectedLocatorId
        }
    }

    /// A run in progress or just finished.
    ///
    /// `searched` / `total` come from the firmware rather than being counted here, so the
    /// progress shown is the receiver's real position in the sweep and not the app's
    /// guess from elapsed time.
    struct Run: Equatable {
        var running: Bool
        var searched: Int = 0
        var total: Int = 0
        var hits: [Hit] = []
        /// Nil while running; the terminator's status once it ends.
        var status: Status?
        /// True for a whole-band run, so the UI can say how long this will take.
        var wholeBand: Bool = false
        /// The locator this run was told to stop on, or 0 for a census. Carried so
        /// `missed` can ask the question that actually matters — see below.
        var targetLocatorId: UInt32 = 0

        init(running: Bool, searched: Int = 0, total: Int = 0, hits: [Hit] = [],
             status: Status? = nil, wholeBand: Bool = false, targetLocatorId: UInt32 = 0) {
            self.running = running
            self.searched = searched
            self.total = total
            self.hits = hits
            self.status = status
            self.wholeBand = wholeBand
            self.targetLocatorId = targetLocatorId
        }

        /// Progress 0…1. `total` is 0 until the first result arrives; a bare division
        /// would render the bar as NaN.
        var fraction: Double { total <= 0 ? 0 : Double(searched) / Double(total) }

        /// A finished short run that did not find **what it was looking for**.
        ///
        /// With a target named, that means no hit carried its id — *whatever else*
        /// turned up. Defining a miss as "found nothing at all" reads sensibly and fails
        /// in the case this feature exists for: hunting Prometheus while Twist 0 is
        /// audible on the current channel, the run finds Twist 0, and a hit-count test
        /// calls that success. The user is then hunting a locator the app has decided it
        /// already found.
        var missed: Bool {
            guard canWiden else { return false }
            if targetLocatorId != 0 {
                return !hits.contains { $0.locatorId == targetLocatorId }
            }
            return hits.isEmpty
        }

        /// Whether widening to the whole band is a coherent next step.
        ///
        /// Any **completed** short run qualifies, not only a missed one: finding some
        /// locator is not evidence that the one you want is not out there, and gating the
        /// band sweep behind an empty result left no way to reach it at all while
        /// anything was audible.
        ///
        /// A *cancelled* run does not qualify — the user just stopped a search, and
        /// answering that by offering an 80-second one is not reading the room.
        var canWiden: Bool { !running && status == .done && !wholeBand }

        /// Channels carrying a hit that is probably **not** where that locator is.
        ///
        /// One locator cannot be on two channels, but a search reports it on two when it
        /// is close enough to the receiver to overload the front end: bench 2026-08-27
        /// found a locator on 57 also reported on 17, 8 MHz away, and only moving it
        /// 15–20 ft settled which was real. Every hit for one locator except its best is
        /// therefore suspect, and saying so is the difference between a result the user
        /// can act on and two channels to guess between.
        ///
        /// Ranked by `rssi + snr`. The two are different units and adding them is a
        /// figure of merit rather than a physical quantity — the reasoning is that both
        /// are "more is better" and that the true channel should lead on both, since an
        /// off-frequency leak reaches the demodulator attenuated by the filter it leaked
        /// through.
        ///
        /// **Measured 2026-08-28, and it holds.** The channel this rule flagged was the
        /// one that disappears when the locator is moved 15–20 ft away — i.e. the
        /// artifact. The rule picks the real channel. It would need revisiting only if an
        /// artifact were ever seen arriving *stronger* than the true channel, which that
        /// rig did not produce.
        ///
        /// Hits with no id are never grouped: id 0 means the frame did not say who, so
        /// two of them cannot be known to be the same locator.
        var suspectChannels: Set<Int> {
            var byLocator: [UInt32: [Hit]] = [:]
            for hit in hits where hit.locatorId != 0 {
                byLocator[hit.locatorId, default: []].append(hit)
            }
            var suspect: Set<Int> = []
            for (_, group) in byLocator where group.count > 1 {
                // max(by:) keeps the FIRST of equal elements, so a tie leaves the
                // earlier-heard channel unflagged rather than shuffling between sweeps.
                guard let best = group.max(by: { $0.rssi + $0.snr < $1.rssi + $1.snr })
                else { continue }
                for hit in group where hit.channel != best.channel {
                    suspect.insert(hit.channel)
                }
            }
            return suspect
        }
    }

    /// Where to look, in the order the receiver should look.
    ///
    /// Order is load-bearing only for a targeted run, and there it is worth a lot: the
    /// firmware stops on the first frame from `targetChannel`'s owner, so putting that
    /// channel first usually ends the whole thing after one dwell. Everything after it is
    /// a fallback and the ordering between those is arbitrary — the run is short enough
    /// that it does not matter.
    ///
    /// - Parameters:
    ///   - currentChannel: where the receiver is sitting now. **Last, not first**: we are
    ///     already here and hearing nothing. It is included at all because "already here"
    ///     is not proof — a locator powered on ten seconds ago has not been waited out yet.
    ///   - targetChannel: the wanted locator's last known channel, if it has one.
    ///   - knownChannels: last known channels of every other locator the app has heard —
    ///     a receiver used with several rockets has been tuned to each of them at some
    ///     point, which is exactly the memory this search exists to exploit.
    ///   - attemptedChannel: a channel a move was staged to but never confirmed; the
    ///     locator may have taken it while the receiver did not.
    static func candidates(currentChannel: Int,
                           targetChannel: Int? = nil,
                           knownChannels: [Int] = [],
                           attemptedChannel: Int? = nil,
                           max limit: Int = WireProtocol.searchMaxChannels) -> [Int] {
        var built: [Int] = []
        if let targetChannel { built.append(targetChannel) }
        built += knownChannels
        if let attemptedChannel { built.append(attemptedChannel) }
        built.append(defaultChannel)
        built.append(currentChannel)

        var seen: Set<Int> = []
        var out: [Int] = []
        for channel in built where (0..<WireProtocol.surveyChannelCount).contains(channel) {
            // The firmware dedupes too, because it must — it cannot trust a caller it
            // does not control. Doing it here as well keeps the list the user is shown
            // identical to the list that gets searched.
            if seen.insert(channel).inserted { out.append(channel) }
            if out.count == limit { break }
        }
        return out
    }
}

/// One decoded `LocatorSearchResult` frame.
///
/// A message, not a state: the run's state machine lives in `LinkViewModel`, which is
/// where the stream of these is folded into a `LocatorSearch.Run`.
struct LocatorSearchResult: Equatable {
    let status: LocatorSearch.Status
    /// The channel just searched; 0 on a terminator.
    let channel: Int
    /// 1-based position of this channel in the run.
    let searched: Int
    /// Channels in the run, so the app can show real progress.
    let total: Int
    let found: Bool
    let armed: Bool
    let rssi: Int
    let snr: Int
    let locatorId: UInt32
    let deviceName: String

    /// Decode from the receiver's `LocatorSearchResult` (`static_assert`ed at 39 —
    /// header 6 + payload 33):
    ///
    ///     6 status u8 | 7 channel u8 | 8 searched u8 | 9 total u8 | 10 found u8
    ///     11 armed u8 | 12 rssi i16 | 14 snr i8 | 15 locator_id u32 | 19 device_name[20]
    ///
    /// Every read is bounds-checked and yields nil rather than trapping. The frame has
    /// passed its CRC by the time it arrives here, but a short frame from mismatched
    /// firmware must not take the app down mid-flight.
    static func parse(_ f: [UInt8]) -> LocatorSearchResult? {
        var o = WireProtocol.headerSize
        guard let statusByte = Bytes.u8(f, o) else { return nil };  o += 1
        guard let channel = Bytes.u8(f, o) else { return nil };     o += 1
        guard let searched = Bytes.u8(f, o) else { return nil };    o += 1
        guard let total = Bytes.u8(f, o) else { return nil };       o += 1
        guard let found = Bytes.u8(f, o) else { return nil };       o += 1
        guard let armed = Bytes.u8(f, o) else { return nil };       o += 1
        guard let rssi = Bytes.i16(f, o) else { return nil };       o += 2
        guard let snr = Bytes.i8(f, o) else { return nil };         o += 1
        guard let locatorId = Bytes.u32(f, o) else { return nil };  o += 4
        guard let name = Bytes.name(f, o, length: WireProtocol.deviceNameLength)
        else { return nil }

        return LocatorSearchResult(
            status: LocatorSearch.Status.from(statusByte),
            channel: Int(channel),
            searched: Int(searched),
            total: Int(total),
            found: found != 0,
            armed: armed != 0,
            rssi: Int(rssi),
            snr: Int(snr),
            locatorId: locatorId,
            deviceName: name)
    }
}
