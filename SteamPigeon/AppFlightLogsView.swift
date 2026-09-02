import SwiftUI
import UIKit

/// App Flight Logs. Lists the logs the app recorded for itself — one per detected launch —
/// and lets one be read on the phone, sent to a PC, or deleted.
///
/// **What these are NOT: the locator's flight archive**, which is downloaded on the Flight
/// Profiles screen and is the authority on what the rocket did. These record what the PHONE
/// saw — the same 1 Hz frames plus the receiver's RSSI, SNR and noise floor for each one,
/// and what the app announced about them. That information exists nowhere else once the app
/// is closed, and during a flight nobody can watch it.
///
/// Ported from Android's `AppFlightLogsScreen.kt` (ADR-0030). The share sheet is a
/// `UIActivityViewController` where Android uses `Intent.ACTION_SEND` through a
/// `FileProvider`; it reaches the same places — AirDrop, Mail, Files, Drive — with nothing
/// installed at the far end, which is the whole reason decision 5 chose a share sheet over
/// a serial protocol.
struct AppFlightLogsView: View {
    @ObservedObject var model: LinkViewModel
    let onCancel: () -> Void

    @State private var viewing: FlightLogFile?
    @State private var deleting: FlightLogFile?
    /// A share that cannot find its file must say so. Silently doing nothing is the one
    /// outcome a user reads as the app being broken rather than the file being missing,
    /// and it is the same tap either way.
    @State private var shareFailed = false
    @State private var sharing: SharedLog?

    var body: some View {
        VStack(spacing: 0) {
            if model.flightLogRecordingName != nil {
                Text("Recording a flight now")
                    .font(SPFont.bodyMedium)
                    .foregroundStyle(SPColor.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

            if model.flightLogs.isEmpty {
                // The empty state takes the same space the list would, so Cancel sits at
                // the bottom either way. Without that the button moved down the screen the
                // moment a first log existed — the same control in two places depending on
                // state nobody chose.
                Text("No flight logs yet. One is recorded automatically when the app sees a "
                     + "rocket leave the pad, starting two seconds before launch detection. "
                     + "Nothing is recorded for a flight the app was not already receiving "
                     + "telemetry for.")
                    .font(SPFont.bodyMedium)
                    .foregroundStyle(SPColor.onBackground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.flightLogs) { log in
                            FlightLogRow(log: log,
                                         stillOpen: log.name == model.flightLogRecordingName,
                                         onView: { viewing = log },
                                         onShare: { share(log) },
                                         onDelete: { deleting = log })
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: .infinity)
            }

            Divider()
            Button("Cancel", action: onCancel)
                .buttonStyle(.materialOutlined)
                .frame(maxWidth: .infinity)
                .padding(16)
        }
        .background(SPColor.background)
        // Re-listed on entry rather than relied on to be current: the recorder writes from
        // the packet handler while this screen is nowhere near the view tree, so arriving
        // here after a flight must show the file that flight produced.
        .onAppear { model.refreshFlightLogs() }
        .sheet(item: $viewing) { log in
            FlightLogViewer(log: log, contents: model.readFlightLog(log.name)) {
                viewing = nil
            }
        }
        .sheet(item: $sharing) { shared in
            ShareSheet(items: [shared.url])
        }
        .alert("Could not prepare the log for sharing.", isPresented: $shareFailed) {
            Button("Close", role: .cancel) {}
        }
        .alert("Delete this log?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let name = deleting?.name { model.deleteFlightLog(name) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("\(deleting?.name ?? "") will be removed from the phone. Anything already "
                 + "shared or saved elsewhere is unaffected.")
        }
    }

    private func share(_ log: FlightLogFile) {
        if let url = model.flightLogStore.url(for: log.name) {
            sharing = SharedLog(url: url)
        } else {
            shareFailed = true
        }
    }
}

/// What `.sheet(item:)` needs to identify the file being shared.
///
/// A wrapper rather than `extension URL: Identifiable`: a retroactive conformance on a
/// Foundation type applies app-wide and would collide with the SDK if `URL` ever gains one.
private struct SharedLog: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct FlightLogRow: View {
    let log: FlightLogFile
    let stillOpen: Bool
    let onView: () -> Void
    let onShare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(log.locatorName).font(SPFont.titleMedium)
            Text("\(log.capturedAt) • \(sizeKb) kB").font(SPFont.bodySmall)
            if stillOpen {
                Text("This log is still being written. It can be shared now; more rows "
                     + "will follow.")
                    .font(SPFont.bodySmall)
                    .foregroundStyle(SPColor.primary)
            }
            HStack(spacing: 8) {
                Button("View", action: onView)
                Button("Share", action: onShare)
                Button("Delete", action: onDelete)
                Spacer()
            }
            .buttonStyle(.materialText)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(SPColor.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Rounded UP: a log that exists must never read as 0 kB, which is the one number that
    /// would make it look like a failed recording rather than a short one.
    private var sizeKb: Int { max(1, Int((log.sizeBytes + 1023) / 1024)) }
}

/// Reads a log on the phone.
///
/// Monospaced and horizontally scrolled, showing the CSV as it actually is rather than as a
/// table: the file is the deliverable, and a prettified view would hide exactly the
/// formatting problems worth catching before the log reaches a PC.
private struct FlightLogViewer: View {
    let log: FlightLogFile
    let contents: FlightLogContents
    let onDismiss: () -> Void

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                if contents.truncated {
                    Text("Showing the first \(contents.rows.count) of \(contents.totalRows) "
                         + "rows. Share or save the log to read all of it.")
                        .font(SPFont.bodySmall)
                        .foregroundStyle(SPColor.primary)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                }
                ScrollView(.horizontal) {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(contents.rows.enumerated()), id: \.offset) { row in
                                Text(row.element)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SPColor.background)
            .navigationTitle(log.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close", action: onDismiss)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// The share sheet. This is the export mechanism, exactly as on Android: it reaches a
/// paired laptop over AirDrop, a cloud drive, or mail, and "Save to Files" puts the CSV
/// where a cable finds it — none of which needs anything installed on the PC.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
