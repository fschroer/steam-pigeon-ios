import Foundation

/// The order in which an unconfirmed channel move is resolved (ADR-0011, amendment
/// "revert on evidence, not on silence").
///
/// `ChannelMove` holds the individual decisions and is pinned separately. This holds the
/// **sequence** — how many times to look, when to wait, what may move and in what order —
/// which is where the rest of that amendment's defects were, and which was unreachable by
/// any test while it sat inside a coroutine holding a `BluetoothService` on Android, and
/// inside `LinkViewModel` here.
///
/// All side effects and observations go through `Ops` so the sequence can be driven
/// against a script. The runner holds no state of its own beyond the call stack, and
/// deliberately contains no timing, no published properties and no platform types.
///
/// Ported from Android's `data/ChannelMoveRunner.kt`.
struct ChannelMoveRunner {

    /// One finished probe run, as the caller's search layer reports it.
    struct ProbeRun: Equatable {
        /// The run reached a `done` terminator. False for a refusal or a timeout.
        let completed: Bool
        /// Meaningless unless `completed`.
        let verdict: ChannelMove.Verdict

        init(completed: Bool, verdict: ChannelMove.Verdict) {
            self.completed = completed
            self.verdict = verdict
        }
    }

    /// Every operation is `async`, including the two that only read.
    ///
    /// Not decoration: the live implementation is `@MainActor` (it reads published state
    /// on `LinkViewModel`) while `resolve` is nonisolated and therefore runs off the main
    /// actor. A synchronous requirement would force that implementation to assert an actor
    /// it is not on, which traps at runtime on a path no test reaches — the fake ops in
    /// `ChannelMoveRunnerTests` are actor-free and would never show it.
    protocol Ops {
        /// A search is already streaming, and it is not an answer to our question.
        func probeInProgress() async -> Bool

        /// Start one two-channel census and wait for its terminator; nil if none came.
        func runProbe(newChannel: Int, oldChannel: Int) async -> ProbeRun?

        func pause(_ interval: TimeInterval) async

        func now() async -> Date

        /// Receiver-only channel change over BLE.
        func pointReceiverAt(_ channel: Int) async

        /// Wait for a frame admitted after `since` with both ends reading `oldChannel`.
        func awaitRelink(oldChannel: Int, since: Date) async -> Bool

        /// Re-send the locator config; false if the send itself failed.
        func resendLocatorConfig() async -> Bool

        /// Wait for the locator to echo the staged config back.
        func awaitConfirmation() async -> Bool

        /// Publish a verdict for the UI. Called for every verdict the runner acts on.
        func onVerdict(_ verdict: ChannelMove.Verdict) async
    }

    private let ops: any Ops
    private let refusedRetry: TimeInterval

    init(ops: any Ops, refusedRetry: TimeInterval) {
        self.ops = ops
        self.refusedRetry = refusedRetry
    }

    /// Resolve the move. True if the locator ended up on `newChannel`.
    ///
    /// **Silence is asked for twice.** ADR-0029's *zero frames proves nothing* applies
    /// directly — one 1.4 s dwell can miss a 1 Hz burst — and `.noEvidence` is the branch
    /// that ends with the receiver on a channel nothing has been heard on, so it is the
    /// one worth another probe to avoid entering by accident.
    ///
    /// **A refusal is not.** `probe` already re-asks a refused run once; a third ask would
    /// be pestering a receiver that has twice declined.
    func resolve(newChannel: Int, oldChannel: Int) async -> Bool {
        var verdict = await probe(newChannel: newChannel, oldChannel: oldChannel)
        if verdict == .noEvidence {
            verdict = await probe(newChannel: newChannel, oldChannel: oldChannel)
        }
        await ops.onVerdict(verdict)
        switch ChannelMove.action(verdict) {
        case .succeed: return true
        case .revert:  return await recover(newChannel: newChannel, oldChannel: oldChannel)
        case .stand:   return false
        }
    }

    /// One verdict, with the refusal retry folded in.
    ///
    /// The receiver turns a search down while an operator command is queued, and after a
    /// move to a locator that has gone silent the queued command is **our own
    /// undeliverable one** — so the probe is blocked by exactly the situation it was sent
    /// to diagnose, until the receiver's stale-drop clears it. `refusedRetry` is sized to
    /// outlast that.
    private func probe(newChannel: Int, oldChannel: Int) async -> ChannelMove.Verdict {
        if await ops.probeInProgress() { return .notChecked }
        guard let first = await ops.runProbe(newChannel: newChannel, oldChannel: oldChannel)
        else { return .notChecked }

        let settled: ProbeRun?
        if first.completed {
            settled = first
        } else {
            await ops.pause(refusedRetry)
            settled = await ops.runProbe(newChannel: newChannel, oldChannel: oldChannel)
        }
        guard let settled, settled.completed else { return .notChecked }
        return settled.verdict
    }

    /// Put the receiver back, retry once, and look again if the retry goes unanswered.
    ///
    /// Reached only from an evidenced `.locatorStayed`.
    ///
    /// **The retry is not exempt from the rule the amendment establishes.** It is itself a
    /// single unacknowledged frame on the channel being left, and the receiver follows it
    /// whether or not the locator hears it — so losing it reproduces the split one layer
    /// down. Measured at ~1 run in 8 before the second look was added. The invariant that
    /// closes it: *a failed move never ends with the receiver on a channel the probe did
    /// not confirm.*
    ///
    /// Bounded by construction: `probe` cannot recurse, there is no second retry, and the
    /// only action available after the second look is putting the receiver back where the
    /// evidence already points.
    private func recover(newChannel: Int, oldChannel: Int) async -> Bool {
        let askedAt = await ops.now()
        await ops.pointReceiverAt(oldChannel)
        guard await ops.awaitRelink(oldChannel: oldChannel, since: askedAt) else { return false }
        guard await ops.resendLocatorConfig() else { return false }
        if await ops.awaitConfirmation() { return true }

        let after = await probe(newChannel: newChannel, oldChannel: oldChannel)
        await ops.onVerdict(after)
        if after == .confirmed {
            return true   // the retry landed after all; only its confirmation was late
        }
        if after == .locatorStayed {
            await ops.pointReceiverAt(oldChannel)   // end together rather than split
        }
        return false
    }
}
