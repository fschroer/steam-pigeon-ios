import SwiftUI

/// The Steam Pigeon palette, ported from the Android app's Material 3 **dark** scheme.
///
/// Per ADR-0016's 2026-08-19 clarification the theme is a **shared asset, not a
/// platform decision** — these are the same values as `ui/theme/Color.kt`, so a change
/// to one wants the same change to the other. Dark only, because the Android app
/// forces dark regardless of the system setting: this is read in daylight next to a
/// launch rail, not in a browser.
enum SPColor {
    static let primary            = Color(hex: 0xCCC6B7)
    static let onPrimary          = Color(hex: 0x333026)
    static let primaryContainer   = Color(hex: 0x545044)
    static let onPrimaryContainer = Color(hex: 0xF7F0E0)

    static let secondary            = Color(hex: 0xB4C6F2)
    static let onSecondary          = Color(hex: 0x1D3053)
    static let secondaryContainer   = Color(hex: 0x44567B)
    static let onSecondaryContainer = Color(hex: 0xFCFAFF)

    static let tertiary            = Color(hex: 0xDCC48D)
    static let onTertiary          = Color(hex: 0x3D2E05)
    static let tertiaryContainer   = Color(hex: 0x867243)
    static let onTertiaryContainer = Color(hex: 0xFFFFFF)

    static let error            = Color(hex: 0xFFB4AB)
    static let onError          = Color(hex: 0x690005)
    static let errorContainer   = Color(hex: 0x93000A)
    static let onErrorContainer = Color(hex: 0xFFDAD6)

    static let background   = Color(hex: 0x141312)
    static let onBackground = Color(hex: 0xE6E2DF)
    static let surface      = Color(hex: 0x141312)
    static let onSurface    = Color(hex: 0xE6E2DF)

    static let surfaceVariant   = Color(hex: 0x49473F)
    static let onSurfaceVariant = Color(hex: 0xCBC6BB)
    static let outline          = Color(hex: 0x959087)
    static let outlineVariant   = Color(hex: 0x49473F)

    static let surfaceContainerLowest  = Color(hex: 0x0F0E0D)
    static let surfaceContainerLow     = Color(hex: 0x1C1B1A)
    static let surfaceContainer        = Color(hex: 0x201F1E)
    static let surfaceContainerHigh    = Color(hex: 0x2B2A29)
    static let surfaceContainerHighest = Color(hex: 0x363433)
}

/// Type scale, mirroring `ui/theme/Type.kt`.
///
/// Android keeps Material 3's baseline sizes and swaps only the families: **Roboto**
/// for display/headline/title, **Poppins** for body/label, **Roboto Mono** for
/// telemetry. The same three `.ttf` files are bundled here.
///
/// One deliberate iOS addition: every face is registered with `relativeTo:`, so it
/// scales with the reader's Dynamic Type setting. Android's `sp` sizes are fixed. This
/// is an accessibility affordance iOS users expect and nothing in the manual has to
/// mention, so it does not cost the one-manual test.
enum SPFont {
    private static let display = "Roboto-Regular"
    private static let displayBold = "Roboto-Bold"
    private static let body = "Poppins-Regular"
    private static let bodyBold = "Poppins-Bold"
    private static let mono = "RobotoMono-Regular"
    private static let monoBold = "RobotoMono-Bold"

    // EVERY style below is REGULAR, and that is not an oversight — it is what Android
    // renders. Two facts combine:
    //
    // 1. `AppTypography` copies Material 3's baseline and swaps ONLY the family
    //    (`baseline.titleMedium.copy(fontFamily = ...)`), so every weight comes from
    //    the M3 type scale. That scale specifies Regular or Medium, never Bold.
    // 2. Each family registers only Regular and Bold
    //    (`FontFamily(Font(roboto_regular), Font(roboto_bold, FontWeight.Bold))`), and
    //    Compose resolves a Medium (W500) request by the CSS rule — for a desired
    //    weight of 400…500 it prefers the nearest weight at or below 500, which is
    //    W400. So titleMedium, titleSmall and every label style render REGULAR.
    //
    // The net result is checkable and worth stating plainly: **the only bold text in
    // the whole Android app is the "∞" compass-calibration glyph**, which sets
    // `FontWeight.Bold` explicitly at its call site. Nothing else. Bold here was a
    // steady drift of "this looks like a heading, headings are bold" that reached the
    // user as "bolded text where it should not be".

    // Display / headline / title — Roboto
    static let displayLarge  = Font.custom(display, size: 57, relativeTo: .largeTitle)
    static let displayMedium = Font.custom(display, size: 45, relativeTo: .largeTitle)
    static let displaySmall  = Font.custom(display, size: 36, relativeTo: .title)
    static let headlineLarge = Font.custom(display, size: 32, relativeTo: .title)
    static let headlineMedium = Font.custom(display, size: 28, relativeTo: .title2)
    static let headlineSmall = Font.custom(display, size: 24, relativeTo: .title3)
    static let titleLarge    = Font.custom(display, size: 22, relativeTo: .title3)
    /// M3 says Medium; the family has no Medium, so Compose picks Regular.
    static let titleMedium   = Font.custom(display, size: 16, relativeTo: .headline)
    /// M3 says Medium; see `titleMedium`.
    static let titleSmall    = Font.custom(display, size: 14, relativeTo: .subheadline)

    // Body / label — Poppins. The label styles are Medium in the M3 scale and resolve
    // to Regular for the same reason.
    static let bodyLarge   = Font.custom(body, size: 16, relativeTo: .body)
    static let bodyMedium  = Font.custom(body, size: 14, relativeTo: .callout)
    static let bodySmall   = Font.custom(body, size: 12, relativeTo: .footnote)
    static let labelLarge  = Font.custom(body, size: 14, relativeTo: .subheadline)
    static let labelMedium = Font.custom(body, size: 12, relativeTo: .caption)
    static let labelSmall  = Font.custom(body, size: 11, relativeTo: .caption2)

    /// `TelemetryTextStyle` — Roboto Mono, 14sp. Every live number uses it, so digits
    /// keep their column as values change.
    static let telemetry = Font.custom(mono, size: 14, relativeTo: .callout)
    static func telemetry(size: CGFloat) -> Font {
        Font.custom(mono, size: size, relativeTo: .body)
    }
    /// **Not bold.** `TelemetryTextStyle` sets `FontWeight.Medium`, and `monoFontFamily`
    /// registers only Regular and Bold, so Compose resolves it to RobotoMono-Regular —
    /// every number on Android's stats panel and gauges included. Kept as a named
    /// function because the call sites read as "the big telemetry number", and a
    /// separate name is where the next person would otherwise reintroduce the bold.
    static func telemetryEmphasis(size: CGFloat) -> Font {
        Font.custom(mono, size: size, relativeTo: .body)
    }

    /// Flight-profile chart labels. Android draws these with a raw `TextPaint`, whose
    /// default family is the platform sans — Roboto, the same face as the display
    /// styles above.
    ///
    /// **Fixed size, unlike every other style here.** The chart lays itself out in its
    /// own coordinate space and measures its annotations to pack them into rows; a
    /// label that grew with the reader's Dynamic Type setting would overrun the plot
    /// and collide with the row beside it.
    static func chartLabel(size: CGFloat) -> Font { Font.custom(display, fixedSize: size) }

    /// Names as the OS knows them. Checked at launch — a font that fails to bundle
    /// falls back to the system face silently, which looks like a design choice
    /// rather than a missing file.
    static let registeredNames = [display, displayBold, body, bodyBold, mono, monoBold]
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
