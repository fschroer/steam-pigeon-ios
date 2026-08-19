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

    // Display / headline / title — Roboto
    static let displayLarge  = Font.custom(displayBold, size: 57, relativeTo: .largeTitle)
    static let displayMedium = Font.custom(displayBold, size: 45, relativeTo: .largeTitle)
    static let displaySmall  = Font.custom(display,     size: 36, relativeTo: .title)
    static let headlineLarge = Font.custom(display,     size: 32, relativeTo: .title)
    static let headlineMedium = Font.custom(display,    size: 28, relativeTo: .title2)
    static let headlineSmall = Font.custom(display,     size: 24, relativeTo: .title3)
    static let titleLarge    = Font.custom(display,     size: 22, relativeTo: .title3)
    static let titleMedium   = Font.custom(displayBold, size: 16, relativeTo: .headline)
    static let titleSmall    = Font.custom(displayBold, size: 14, relativeTo: .subheadline)

    // Body / label — Poppins
    static let bodyLarge   = Font.custom(body, size: 16, relativeTo: .body)
    static let bodyMedium  = Font.custom(body, size: 14, relativeTo: .callout)
    static let bodySmall   = Font.custom(body, size: 12, relativeTo: .footnote)
    static let labelLarge  = Font.custom(bodyBold, size: 14, relativeTo: .subheadline)
    static let labelMedium = Font.custom(bodyBold, size: 12, relativeTo: .caption)
    static let labelSmall  = Font.custom(bodyBold, size: 11, relativeTo: .caption2)

    /// `TelemetryTextStyle` — Roboto Mono, 14sp. Every live number uses it, so digits
    /// keep their column as values change.
    static let telemetry = Font.custom(mono, size: 14, relativeTo: .callout)
    static func telemetry(size: CGFloat) -> Font {
        Font.custom(mono, size: size, relativeTo: .body)
    }
    static func telemetryBold(size: CGFloat) -> Font {
        Font.custom(monoBold, size: size, relativeTo: .body)
    }

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
