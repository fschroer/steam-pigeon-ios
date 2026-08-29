import Foundation

// Which sheet a screen is showing — ONE per screen, never two.
//
// SwiftUI on iOS 16 presents a single sheet per view. Two `.sheet` modifiers on one
// view that both want to present in the same update throw
// `NSInvalidArgumentException … is already being presented`, which is what crashed on
// the phone. That is not a race to be timed better: it is two presentations where the
// platform allows one. So each screen names its sheet in one place, as a value, and
// presents exactly that.
//
// The identities below are deliberately CONSTANT across a screen's cases. A changing
// id would make SwiftUI dismiss one sheet and present another — the same
// dismiss-and-present sequence, moved inside the modifier rather than removed. With a
// stable id the sheet stays up and its CONTENT changes, which is what "switching
// between them is a state change" has to mean to be worth anything.

/// The map screen's sheet: the menu, or the screen a menu item opens.
enum MapSheet: Identifiable, Equatable {
    case menu
    case destination(MenuDestination)

    /// One identity for both cases, on purpose — see the note above. Choosing a menu
    /// item swaps this sheet's content; it does not present a second sheet.
    var id: Int { 0 }
}

/// **The app's only sheet.**
///
/// One per *screen* was not enough, and the gap cost the password prompt. `MapScreen`
/// presented the menu and its destinations; `RootView`, which CONTAINS `MapScreen`,
/// presented the challenge and diagnostics. Two views, one each — and still two
/// presentations in one chain, because an ancestor cannot present while a descendant
/// already is.
///
/// Measured on the iOS 26.5 simulator 2026-08-29, with the Communication screen open and
/// a challenge raised: the prompt did not appear at all until that sheet was dismissed,
/// and then churned appear/disappear/appear inside a single tick. **On an iPhone running
/// 18.6.2 the same fault reads differently** — the prompt appears and then vanishes a few
/// seconds later, which is that churn resolving the other way. The user cannot answer a
/// prompt they cannot see, and the one place it is most likely to be raised — connecting
/// to a locator a search just found — is a menu destination, so it was raised precisely
/// where it could not be shown.
///
/// So the decision moves to the root and there is exactly one `.sheet` in the app.
/// `MapScreen` still says what it *wants* by setting a `MapSheet`; it no longer
/// presents it.
///
/// The identity is CONSTANT across every case, on purpose — see the note above. Content
/// swaps in place; nothing is dismissed and re-presented.
enum RootSheet: Identifiable, Equatable {
    /// ADR-0006 Decision 6. Outranks everything because it is raised by a locator
    /// arriving rather than by the user, and it is the one that has to be answered.
    case challenge(LocatorChallenge)
    /// What the map screen asked for: the menu, or a screen behind it.
    case map(MapSheet)
    case diagnostics

    var id: Int { 0 }

    /// The single sheet to show, given everything that currently wants one.
    ///
    /// A challenge can arrive at any moment, including over an open screen. It wins,
    /// and answering it **returns to whatever was underneath** rather than closing it:
    /// the user did not ask to leave that screen, a locator interrupted them. That was
    /// already true of diagnostics; it now holds for a menu destination too, which is
    /// what lets someone answer a prompt and carry on reading the search results that
    /// raised it.
    static func active(challenge: LocatorChallenge?,
                       map: MapSheet? = nil,
                       showDiagnostics: Bool) -> RootSheet? {
        if let challenge { return .challenge(challenge) }
        if let map { return .map(map) }
        return showDiagnostics ? .diagnostics : nil
    }
}
