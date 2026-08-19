import SwiftUI

/// Bring-up screen for the CoreBluetooth transport.
///
/// Not the real UI — the SwiftUI app is step 3 of the ADR-0016 build order. This
/// exists to answer one question against real hardware: does the transport connect to
/// the receiver and deliver correctly framed packets? So it shows what would otherwise
/// only be visible in a debugger — what arrived, how big, and how the link is behaving.
struct LinkView: View {
    @StateObject private var model = LinkViewModel()

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle()
                        .fill(model.state == .ready ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(model.stateLabel).font(.headline)
                }

                HStack(spacing: 16) {
                    stat("frames", "\(model.frameCount)")
                    stat("bad CRC", "\(model.badFrames)")
                    stat("probes", "\(model.probesSent)")
                }

                if !model.countsByType.isEmpty {
                    Text("By message type").font(.subheadline.weight(.semibold))
                    ForEach(model.countsByType.sorted { $0.value > $1.value }, id: \.key) { type, n in
                        HStack {
                            Text(String(describing: type)).font(.caption.monospaced())
                            Spacer()
                            Text("\(n)").font(.caption.monospaced())
                        }
                    }
                }

                Text("Recent frames").font(.subheadline.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.recent.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Spacer()

                HStack {
                    Button("Scan") { model.start() }
                        .buttonStyle(.borderedProminent)
                    Button("Disconnect") { model.disconnect() }
                        .buttonStyle(.bordered)
                }
            }
            .padding()
            .navigationTitle("Steam Pigeon")
        }
        .navigationViewStyle(.stack)     // iOS 16: NavigationView, not NavigationStack
        .onAppear { model.start() }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
