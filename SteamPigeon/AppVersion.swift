import Foundation

/// The build's git stamp, in the firmwares' format:
/// `YYYY.MM.DD-<git describe --tags --long --dirty --always>`, plus `.HHMMSS` when the
/// tree was dirty.
///
/// The locator and the receiver both report a stamp in this format on their own screens,
/// so the three read the same way and compare directly. That matters most across a
/// breaking wire change, where the question is exactly "are these two in step?" — and
/// ADR-0029 is one, so this landed alongside it.
///
/// **Read from a file in the bundle, never a constant in the source**, and that is the
/// whole point of the design rather than an implementation detail. Android shipped this
/// as a `BuildConfig` String first: a compile-time constant, which the compiler inlined
/// into its reader, so regenerating it updated `BuildConfig.class` and nothing else. The
/// APK contained BOTH stamps and displayed the three-hour-old one (app `206960c`). A
/// generated Swift `let` is exposed to the same class of failure by a different route —
/// the optimiser may fold it into its readers, and whether the readers are rebuilt is up
/// to incremental compilation. A file the app opens by name at runtime cannot be folded
/// into anything, and `Scripts/GenVersion.sh` rewrites it on every build.
///
/// A stamp ending in a time (`…-dirty.HHMMSS`) is a development build made from an
/// uncommitted tree; a clean one names a commit.
enum AppVersion {

    /// The stamp, or `"unknown"` when the resource is missing.
    ///
    /// **Deliberately not a fallback to some other source.** "unknown" says the build
    /// did not stamp itself, which is a real and reportable condition; inventing a
    /// plausible-looking version from `CFBundleShortVersionString` would answer the
    /// question with something that is not the answer.
    static let stamp: String = read() ?? "unknown"

    private static func read() -> String? {
        // The module's own bundle, not `Bundle.main`: under the unit-test host
        // `Bundle.main` is the test runner, and the stamp lives in the app.
        guard let url = Bundle(for: BundleToken.self)
                .url(forResource: "GitVersion", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Locates the bundle this code was compiled into. A class because `Bundle(for:)` takes
/// one; it is never instantiated.
private final class BundleToken {}
