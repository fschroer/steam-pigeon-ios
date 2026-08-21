import SwiftUI

/// Buttons that look like Android's, because on this app they are Android's.
///
/// SwiftUI's `.bordered` / `.borderedProminent` are not near-misses of Material's
/// buttons — they differ in every dimension a user can see. Reported from the phone as
/// "the buttons are still different colors and shapes":
///
/// | | Material 3 | SwiftUI's bordered styles |
/// |---|---|---|
/// | Shape | fully rounded — a stadium | rounded rectangle, much tighter radius |
/// | Filled label | `onPrimary` (dark brown, here) | white, whatever the tint |
/// | Outlined | transparent with a 1 dp `outline` ring | a filled grey capsule |
/// | Label type | `labelLarge` — Poppins 14 | the system face at ~17 |
/// | Disabled | `onSurface` at 12% / 38% | the tint, dimmed |
///
/// **This is not the "Material clone" ADR-0016 warns against.** That sanctioned
/// departure covers controls which look *broken* when imitated — a Material switch drawn
/// over iOS gestures. A button is the same object on both platforms, and the same lesson
/// already applies to `ConfigRows`: matching Android is the rule, and reaching for the
/// SwiftUI default because it is closer to hand is the failure this port keeps repeating.
///
/// Values are Material 3's own: 40 dp minimum height, 24 dp of horizontal content
/// padding, `ButtonDefaults.ContentPadding`, and the disabled alphas from
/// `ButtonDefaults.buttonColors`.
struct MaterialButtonStyle: ButtonStyle {

    enum Kind {
        /// `Button` — a filled container.
        case filled
        /// `OutlinedButton` — transparent, ringed, label in the container's colour.
        case outlined
        /// `TextButton` — label only, no container and no ring.
        case text
    }

    var kind: Kind = .filled
    /// The filled container, or the label colour for the other two kinds.
    var container: Color = SPColor.primary
    /// The label over a filled container.
    var content: Color = SPColor.onPrimary
    /// Material's default is 40; the deployment test's stop button asks for 48.
    var minHeight: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, kind: kind, container: container,
             content: content, minHeight: minHeight)
    }

    /// A `ButtonStyle` cannot read `isEnabled` directly — only a view inside it can, and
    /// the disabled colours are half of what makes these look like Material.
    ///
    /// **Not named `Body`.** That is `ButtonStyle`'s own associated type, and a nested
    /// type of that name is matched against the protocol requirement instead of the
    /// return of `makeBody` — which fails as "does not conform", naming neither.
    private struct Pill: View {
        let configuration: Configuration
        let kind: Kind
        let container: Color
        let content: Color
        let minHeight: CGFloat

        @Environment(\.isEnabled) private var isEnabled

        /// `ButtonDefaults.buttonColors`: disabled content is `onSurface` at 38%,
        /// disabled containers `onSurface` at 12%.
        private var labelColour: Color {
            guard isEnabled else { return SPColor.onSurface.opacity(0.38) }
            return kind == .filled ? content : container
        }

        private var containerColour: Color {
            guard kind == .filled else { return .clear }
            return isEnabled ? container : SPColor.onSurface.opacity(0.12)
        }

        private var ringColour: Color {
            guard kind == .outlined else { return .clear }
            return isEnabled ? SPColor.outline : SPColor.onSurface.opacity(0.12)
        }

        var body: some View {
            configuration.label
                .font(SPFont.labelLarge)
                .foregroundStyle(labelColour)
                // 24 dp each side for a container, 12 for a text button — Material gives
                // `TextButton` the narrower `ButtonDefaults.TextButtonContentPadding`.
                .padding(.horizontal, kind == .text ? 12 : 24)
                .padding(.vertical, 8)
                .frame(minHeight: minHeight)
                .background(containerColour, in: Capsule())
                .overlay(Capsule().strokeBorder(ringColour, lineWidth: 1))
                // Material's pressed state layer is the content colour at 8–12% over the
                // container. Dimming the whole control is the cheap approximation, and at
                // this size it reads the same.
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(Capsule())
        }
    }
}

extension ButtonStyle where Self == MaterialButtonStyle {
    /// Android's `Button`.
    static var materialFilled: MaterialButtonStyle { MaterialButtonStyle(kind: .filled) }

    /// Android's `OutlinedButton`.
    static var materialOutlined: MaterialButtonStyle {
        MaterialButtonStyle(kind: .outlined, container: SPColor.primary)
    }

    /// Android's `TextButton`.
    static var materialText: MaterialButtonStyle {
        MaterialButtonStyle(kind: .text, container: SPColor.primary)
    }

    /// A filled button in the error colours — the treatment Android gives the controls
    /// that make a rocket safer.
    static func materialFilled(container: Color, content: Color,
                               minHeight: CGFloat = 40) -> MaterialButtonStyle {
        MaterialButtonStyle(kind: .filled, container: container, content: content,
                            minHeight: minHeight)
    }
}
