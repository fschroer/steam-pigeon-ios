import SwiftUI

/// The locator password prompt (ADR-0006 Decision 6).
///
/// Presented app-wide rather than inline: it is a decision about which rocket the app
/// is talking to, not a detail of whatever screen happens to be showing.
struct PasswordChallengeView: View {
    let challenge: LocatorChallenge
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var revealed = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text(challenge.deviceName.isEmpty
                     ? String(format: "Locator %08x found.", challenge.locatorId)
                     : "\(challenge.deviceName) found.")
                    .font(SPFont.titleMedium).foregroundStyle(SPColor.onBackground)

                Text(String(format: "ID %08x — enter its password to connect.", challenge.locatorId))
                    .font(SPFont.bodySmall)
                    .foregroundStyle(SPColor.onSurfaceVariant)

                HStack {
                    Group {
                        // A locator with no password is OPEN, and a blank entry is the
                        // correct answer for it — not an empty submission to block.
                        if revealed {
                            TextField("Password (blank if none)", text: $password)
                        } else {
                            SecureField("Password (blank if none)", text: $password)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .focused($focused)
                    .onSubmit { onSubmit(password) }

                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(revealed ? "Hide password" : "Show password")
                }
                .padding(10)
                .background(SPColor.surfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if challenge.rejected {
                    Label("That password was not accepted. Try again.", systemImage: "xmark.circle")
                        .font(SPFont.bodySmall)
                        .foregroundStyle(SPColor.error)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Connect to locator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Not now", action: onCancel)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Connect") { onSubmit(password) }
                }
            }
            .onAppear { focused = true }
        }
        .navigationViewStyle(.stack)
    }
}
