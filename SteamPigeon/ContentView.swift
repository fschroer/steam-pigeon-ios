import SwiftUI

/// Placeholder shell. The UI is deliberately last: ADR "iOS port — CoreBluetooth
/// and platform parity" sets the build order as (1) protocol + auth in pure Swift,
/// (2) CoreBluetooth transport, (3) SwiftUI UI.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "location.north.circle")
                .font(.system(size: 48))
            Text("Steam Pigeon")
                .font(.title2.weight(.semibold))
            Text("Scaffold only — no protocol layer yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
