import SwiftUI

/// Standing help, behind an **i** — Android's `SectionHelp` popup.
///
/// The prose used to sit permanently under every control, and the screen grew to the
/// point where the standing explanations outweighed the results they were explaining —
/// the thing a user actually came to read was surrounded by paragraphs they had already
/// read on every previous visit. Help that is one tap away is help that can afford to be
/// complete.
///
/// Only STATIC prose belongs here. Anything that varies with what just happened — a
/// scan's verdict, a refusal, "nothing found on those channels", the occupant of a
/// channel being typed — stays on the screen, because it is the answer rather than the
/// instructions.
///
/// # Two presentations, chosen at runtime
///
/// **iOS 16.4 and up get Android's shape**: a card anchored under the icon, floating over
/// the screen, dismissed by a tap anywhere. That needs `presentationCompactAdaptation`,
/// without which SwiftUI expands a `popover` into a full-screen sheet on iPhone — which
/// is not a popup at all, and buries the screen the help is explaining.
///
/// **iOS 16.0 to 16.3 get an alert**, because that API does not exist there and the
/// alternatives are worse: a hand-built card clips against the enclosing `ScrollView`
/// instead of floating over it, and a full-screen sheet loses the context entirely. The
/// behaviour that matters survives either way — one tap opens it, one tap dismisses it,
/// nothing on the screen moves.
///
/// The split is by **capability, not by device**. fschroer flight-tests across several
/// iOS versions (16.7.16 and 18.6.2 today, more later), so this must degrade on its own
/// rather than be tuned to whatever is in hand — and the fallback is the branch that will
/// almost never run, which is exactly the branch that rots unnoticed. It is written to be
/// correct rather than pretty.
struct SectionHelp: View {
    let help: [String]

    @State private var showing = false

    /// Android's `widthIn(max = 300.dp)`. A card sized for the longest paragraph likely
    /// to be seen rather than for the widest possible one.
    static let cardWidth: CGFloat = 300

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 18))
                .foregroundStyle(SPColor.onSurfaceVariant)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show help")
        .modifier(HelpPresentation(showing: $showing, help: help))
    }
}

/// Picks the presentation the running OS can actually do — see `SectionHelp`.
///
/// A `ViewModifier` rather than an `if #available` inside the body, because the two
/// branches return different opaque types and `@ViewBuilder` would have to erase them.
/// Here each branch is its own `some View` and neither pays for the other.
private struct HelpPresentation: ViewModifier {
    @Binding var showing: Bool
    let help: [String]

    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.popover(isPresented: $showing) {
                HelpCard(help: help) { showing = false }
                    // **The whole reason this branch exists.** Without it a popover
                    // becomes a full-screen sheet on iPhone, which is not a popup and
                    // hides the screen the help describes.
                    .presentationCompactAdaptation(.popover)
                    // The popover's own chrome, themed. The app is dark-only
                    // (`preferredColorScheme(.dark)`), so the system's default light
                    // material would read as a foreign element.
                    .presentationBackground(SPColor.surfaceContainerHigh)
            }
        } else {
            // 16.0–16.3. Same content, same two-tap interaction, different shape.
            content.alert("Help", isPresented: $showing) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(help.joined(separator: "\n\n"))
            }
        }
    }
}

/// The floating card: Android's `Surface` + `Column`, at the same metrics.
///
/// **Not scrollable, deliberately** — Android's is not either, and a scroll view inside a
/// popover reports an unbounded ideal height, so the card would size itself to the whole
/// screen for a single sentence. The longest help here is four short paragraphs.
private struct HelpCard: View {
    let help: [String]
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(help, id: \.self) { paragraph in
                Text(paragraph)
                    .font(SPFont.bodySmall)
                    .foregroundStyle(SPColor.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: SectionHelp.cardWidth, alignment: .leading)
        // Tapping the card dismisses it, as Android's does: reading it IS the whole
        // interaction, so the tap that follows means "done" wherever it lands. A tap
        // outside already dismisses — this closes the one dead spot in the middle.
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }
}
