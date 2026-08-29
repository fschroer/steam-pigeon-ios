import SwiftUI

/// The app's non-map screens, mirroring Android's `NavDestination`.
enum MenuDestination: String, Identifiable, CaseIterable {
    case communication
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
        case .communication:    return "Communication"
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
        // A transmitter with signal arcs — deliberately NOT `radio`, which is the
        // receiver device. This entry is about the link.
        case .communication:    return "broadcast"
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
///
/// **The order changed with ADR-0029 and the show/hide conditions did not.**
/// Communication is first because "where is my locator" is the question that brings
/// someone to this menu, and Flight Profiles rose above Locator Settings because it is
/// reached far more often. Deployment Test moved to the bottom: it is armed-only, so it
/// never shares the list with the disarmed entries anyway, and putting the rarest and
/// most consequential entry last keeps it out from under a thumb.
enum MenuGating {
    static func destinations(linkReady: Bool,
                             locatorActive: Bool,
                             armed: Bool) -> [MenuDestination] {
        var items: [MenuDestination] = []

        if linkReady { items.append(.communication) }

        if locatorActive && !armed {
            items.append(.flightProfiles)
            items.append(.locatorSettings)
        }

        if linkReady { items.append(.receiverSettings) }

        items.append(.appSettings)
        items.append(.downloadMap)

        if locatorActive && armed {
            items.append(.deploymentTest)
        }
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
