import Foundation

/// Deciding what actually happened to a locator channel change, from what the receiver
/// heard rather than from what it failed to hear (ADR-0011, amendment "revert on
/// evidence, not on silence").
///
/// There is no acknowledgement message. A change is confirmed by inference — the next
/// `PreLaunchData` relayed on the new channel — so what goes missing when a move "fails"
/// is a *broadcast*, and two opposite states produce the same silence:
///
/// - the locator missed the command and stayed on the old channel, while the receiver
///   followed onto the new one (a real split), and
/// - everything moved correctly and the confirmation was merely late.
///
/// No test taken at the timeout can separate them, because the only evidence that the
/// locator moved is hearing it on the new channel — which *is* the confirmation. So the
/// app stops guessing and looks: a two-channel `LocatorSearchRequest` over the new channel
/// and the old one, and this type reads the result.
///
/// Ported from Android's `data/ChannelMove.kt`, which was bench-validated across four
/// passes that changed the design four times (issue #20, 2026-08-30). **None of it is
/// bench-validated on iOS.** Timestamps are `Date` where Android uses epoch
/// milliseconds — the arithmetic is identical, and "no receipt yet" is `nil` rather
/// than `0`.
enum ChannelMove {

    /// What the probe established.
    ///
    /// `noEvidence` is a real answer and not a failure of this function: it means the
    /// receiver heard nothing it could attribute, and the caller must then do the
    /// *non-destructive* thing — leave the receiver where it is and say so.
    enum Verdict: Equatable {
        case confirmed
        case locatorStayed
        case noEvidence

        /// The question was never asked — the receiver refused the probe.
        ///
        /// Distinct from `noEvidence` on purpose, and the distinction is the whole
        /// lesson: *a rule about the link must be able to tell a gap the app created from
        /// a gap the world created.* A refused search means the app failed to look;
        /// treating that as "heard nothing" is the app mistaking its own blindness for
        /// the locator's absence.
        ///
        /// It is reachable by construction rather than by bad luck. A channel move queues
        /// a `LocatorCfgChgRequest`, `IsOperatorCommand` counts that as an operator
        /// command, and the receiver refuses a `LocatorSearchRequest` while one is
        /// pending. If the locator is silent the forward can never leave — the forwarding
        /// window needs a recent `PreLaunchData` — so the undelivered command blocks the
        /// very probe that would explain why it was undeliverable, until the receiver's
        /// `kPendingTxStaleMs` drops it.
        case notChecked
    }

    /// Which channel the locator is on, judged from one probe run.
    ///
    /// **The ranking is the whole point, and a single hit is not enough.** A locator
    /// within a few feet of the receiver decodes on channels it is nowhere near
    /// (ADR-0029, bench 2026-08-28), and the artifact reads as *strong* — so RSSI alone
    /// cannot separate it and neither can "the first hit we got". Both dwells are
    /// therefore always run, and the two are compared by `rssi + snr`, the same figure of
    /// merit `LocatorSearch.Run.suspectChannels` uses and the same one the bench
    /// validated. This matters more here than in an ordinary search, because a channel
    /// move is something a user does with the locator in their hands.
    ///
    /// Only hits carrying `locatorId` count. A different locator sitting on the new
    /// channel is a real and useful finding — it is why the probe is a census rather than
    /// a targeted run — but it says nothing about where *ours* went, and treating it as
    /// confirmation would report success for a move that stranded the rocket.
    ///
    /// - Parameter locatorId: the connected locator, captured when the move was sent.
    ///   `nil` or 0 means the app cannot attribute a hit to anything, so no hit can be
    ///   evidence and the answer is `.noEvidence`.
    static func verdict(hits: [LocatorSearch.Hit],
                        locatorId: UInt32?,
                        newChannel: Int,
                        oldChannel: Int) -> Verdict {
        guard let locatorId, locatorId != 0 else { return .noEvidence }
        let mine = hits.filter { $0.locatorId == locatorId }
        let onNew = mine.filter { $0.channel == newChannel }.map { $0.rssi + $0.snr }.max()
        let onOld = mine.filter { $0.channel == oldChannel }.map { $0.rssi + $0.snr }.max()
        switch (onNew, onOld) {
        case let (new?, old?): 
            if new > old { return .confirmed }
            if old > new { return .locatorStayed }
            // Heard equally on both, which separates nothing. A tie is not evidence, and
            // the caller must not revert on it.
            return .noEvidence
        case (.some, .none): return .confirmed
        case (.none, .some): return .locatorStayed
        case (.none, .none): return .noEvidence
        }
    }

    /// What the caller should do about a `Verdict`.
    enum Action: Equatable {
        /// Report success and change nothing.
        case succeed
        /// Put the receiver back on the old channel and retry once.
        case revert
        /// Report the failure and move nothing.
        case stand
    }

    /// Only an evidenced `.locatorStayed` may move the receiver.
    ///
    /// Trivial, and pinned anyway: reverting on anything else is the entire defect this
    /// amendment exists to remove, and `.notChecked` in particular is a refusal — the app
    /// failing to look — which must never be mistaken for a reason to act.
    static func action(_ verdict: Verdict) -> Action {
        switch verdict {
        case .confirmed:              return .succeed
        case .locatorStayed:          return .revert
        case .noEvidence, .notChecked: return .stand
        }
    }

    /// The confirm window's deadline, given a transmit receipt.
    ///
    /// The receipt tells the app the command has only just gone on air, so the window so
    /// far has been measuring the wait for a forwarding window rather than the locator's
    /// answer. Re-basing from it is right; re-basing **repeatedly** is what hung the move.
    ///
    /// `ReceiverInfo` is not only the unsolicited receipt — the channel watch polls one
    /// every 2 s while the locator is silent, which is exactly the state an unconfirmed
    /// move is in. Every reply matched, every reply pushed the deadline out 5 s, and
    /// 2 s < 5 s meant the window never closed: the banner sat on "Moving to channel N…"
    /// forever, the probe never ran, and the receiver was left on the new channel with the
    /// locator on the old one. A lost locator.
    ///
    /// Two independent guards, because one of them should not have to be right: the caller
    /// latches the receipt so only the first is offered here, and `hardDeadline` caps the
    /// result whatever it is offered.
    ///
    /// - Parameter receipt: `nil` when no receipt has arrived, which leaves `deadline`
    ///   alone.
    static func confirmDeadline(started: Date,
                                deadline: Date,
                                receipt: Date?,
                                window: TimeInterval,
                                hardDeadline: Date) -> Date {
        guard let receipt, receipt > started else { return deadline }
        return min(max(deadline, receipt.addingTimeInterval(window)), hardDeadline)
    }

    /// Whether the link has demonstrably come back on `oldChannel` after a revert.
    ///
    /// **The frame test is the load-bearing half.** Both channel readings are updated only
    /// by a relayed `PreLaunchData`, so after a move whose confirmation never arrived they
    /// were BOTH still reading the old channel — and a test on the two alone passed on its
    /// first 100 ms poll having verified nothing, sending the retry to a channel with
    /// nothing on it.
    ///
    /// - Parameters:
    ///   - lastFrame: when a frame was last admitted from the connected locator.
    ///   - askedAt: when the revert was requested; a frame must be newer than this.
    static func relinked(receiverChannel: Int,
                         locatorChannel: Int,
                         oldChannel: Int,
                         lastFrame: Date?,
                         askedAt: Date) -> Bool {
        guard let lastFrame else { return false }
        return receiverChannel == oldChannel
            && locatorChannel == oldChannel
            && lastFrame > askedAt
    }

    /// Which failure sentence a finished move has earned.
    enum Message: Equatable {
        case succeeded, leftOnPrevious, nothingMoved, unresolved, notChecked
    }

    /// The message a finished move has earned, from what is actually true of the hardware
    /// rather than from what was requested.
    ///
    /// Three of this amendment's defects were sentences rather than logic, which is why
    /// the choice is here and pinned rather than inline in a view:
    ///
    /// - "left on its previous channel" was written for the evidenced revert and was false
    ///   on the path that leaves the receiver on the new channel;
    /// - "the receiver is on channel N" named the channel the app **aimed at**, on a path
    ///   where the forward never transmitted and the receiver never left;
    /// - and the difference between "nothing moved, power the locator up" and "your
    ///   locator may be stranded" is the difference between a shrug and a search.
    ///
    /// - Parameters:
    ///   - attemptedChannel: the channel the move was aimed at.
    ///   - receiverChannel: where the receiver actually is now.
    static func message(verdict: Verdict?,
                        attemptedChannel: Int,
                        receiverChannel: Int) -> Message {
        switch verdict {
        case .confirmed:  return .succeeded
        case .notChecked: return .notChecked
        case .noEvidence:
            // The receiver never left, so nothing moved and nothing is stranded.
            return receiverChannel != attemptedChannel ? .nothingMoved : .unresolved
        // `.locatorStayed`, or no probe ran at all: the revert put both devices back.
        default: return .leftOnPrevious
        }
    }

    /// The two channels to probe, in the order the receiver should dwell on them.
    ///
    /// New first. Not for an early exit — the run is a census and always dwells on both —
    /// but because results stream, so if the run is cut short by its silence timeout the
    /// more probable answer is already in hand.
    static func probeChannels(newChannel: Int, oldChannel: Int) -> [Int] {
        newChannel == oldChannel ? [newChannel] : [newChannel, oldChannel]
    }
}
