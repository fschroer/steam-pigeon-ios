import SwiftUI

/// The app's non-map screens, mirroring Android's `NavDestination`.
enum MenuDestination: String, Identifiable, CaseIterable {
    case appSettings
    case receiverSettings
    case locatorSettings
    case flightProfiles
    case deploymentTest
    case downloadMap

    var id: String { rawValue }

    /// Android's exact labels.
    var title: String {
        switch self {
        case .appSettings:      return "Application Settings"
        case .receiverSettings: return "Receiver Settings"
        case .locatorSettings:  return "Locator Settings"
        case .flightProfiles:   return "Flight Profiles"
        case .deploymentTest:   return "Deployment Test"
        case .downloadMap:      return "Download maps"
        }
    }

    /// The app's own glyphs, matching Android's drawer icons.
    var iconName: String {
        switch self {
        case .appSettings:      return "settings_applications"
        case .receiverSettings: return "radio"
        case .locatorSettings:  return "navigation"
        case .flightProfiles:   return "u_turn_right"
        case .deploymentTest:   return "bomb"
        case .downloadMap:      return "navigation"
        }
    }
}

/// Which destinations are offered, given what is connected and armed.
///
/// Pure, because the gating is the part with rules rather than layout — and the
/// rules are not guessable. **Deployment test appears only while ARMED**, which
/// reads backwards until you notice that testing a deployment channel is exactly
/// what arming enables; and locator settings and flight profiles appear only while
/// DISARMED, because the locator refuses configuration changes in any other state.
enum MenuGating {
    static func destinations(linkReady: Bool,
                             locatorActive: Bool,
                             armed: Bool) -> [MenuDestination] {
        var items: [MenuDestination] = [.appSettings]

        if linkReady { items.append(.receiverSettings) }

        if locatorActive && !armed {
            items.append(.locatorSettings)
            items.append(.flightProfiles)
        }
        if locatorActive && armed {
            items.append(.deploymentTest)
        }

        // Last on purpose: site prep is done at home on Wi-Fi, not reached for at the
        // pad, so it sits below the entries that track what is connected and armed.
        items.append(.downloadMap)
        return items
    }
}

/// The menu itself. A list pushed from a toolbar button rather than a left drawer —
/// ADR-0016's sanctioned divergence, since a drawer is a Material pattern with no HIG
/// equivalent, and "go to Settings" reads correctly on both platforms.
struct MenuView: View {
    let destinations: [MenuDestination]
    let onSelect: (MenuDestination) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationView {
            List(destinations) { item in
                Button { onSelect(item) } label: {
                    HStack(spacing: 16) {
                        Image(item.iconName)
                            .renderingMode(.template)
                            .resizable().scaledToFit()
                            .frame(width: 24, height: 24)
                            .foregroundStyle(SPColor.primary)
                        Text(item.title)
                            .font(SPFont.titleLarge)
                            .foregroundStyle(SPColor.onBackground)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .listRowBackground(SPColor.surfaceContainer)
            }
            .scrollContentBackground(.hidden)
            .background(SPColor.background)
            .navigationTitle("Steam Pigeon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// Placeholder for a destination that has not been built.
///
/// Deliberately explicit rather than a blank screen: a menu entry that opens
/// nothing is indistinguishable from one that is broken, and this app is used in a
/// field where "is it working?" is an expensive question.
struct NotYetBuiltView: View {
    let destination: MenuDestination

    var body: some View {
        VStack(spacing: 12) {
            Image(destination.iconName)
                .renderingMode(.template)
                .resizable().scaledToFit()
                .frame(width: 48, height: 48)
                .foregroundStyle(SPColor.outline)
            Text(destination.title).font(SPFont.titleLarge)
            Text("Not built yet on iOS.")
                .font(SPFont.bodyMedium)
                .foregroundStyle(SPColor.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SPColor.background)
    }
}
