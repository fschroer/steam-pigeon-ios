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

/// The root view's sheet: link diagnostics, or the locator password prompt.
enum RootSheet: Identifiable, Equatable {
    /// ADR-0006 Decision 6. Outranks diagnostics because it is raised by a locator
    /// arriving rather than by the user, and it is the one of the two that has to be
    /// answered.
    case challenge(LocatorChallenge)
    case diagnostics

    var id: Int { 0 }

    /// The single sheet to show, given everything that currently wants one.
    ///
    /// A challenge can arrive at any moment, including while diagnostics is open —
    /// the latent half of the crash, and the more dangerous half for never having
    /// been seen. Answering it returns to diagnostics rather than closing it: the
    /// user did not ask to leave that screen, a locator interrupted them.
    static func active(challenge: LocatorChallenge?, showDiagnostics: Bool) -> RootSheet? {
        if let challenge { return .challenge(challenge) }
        return showDiagnostics ? .diagnostics : nil
    }
}
