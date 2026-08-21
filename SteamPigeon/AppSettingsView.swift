import SwiftUI
import AVFoundation

/// Application settings, mirroring Android's `AppSettingsScreen`: speech on/off,
/// which voice, and how far in the map follows the rocket on its own.
struct AppSettingsView: View {
    @ObservedObject var settings: AppSettings

    private let voices = AppSettings.availableVoices()

    /// What the row shows when collapsed. Falls back to the first voice, which is what
    /// `FlightSpeech` uses when nothing has been chosen.
    private var selectedVoiceName: String {
        let id = settings.voiceIdentifier
        return voices.first(where: { $0.identifier == id })?.name
            ?? voices.first?.name
            ?? "None"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Speech", isOn: $settings.voiceEnabled)

                // A pushed list, NOT a `Picker`.
                //
                // The default picker in a Form presents a wheel, and a wheel always
                // re-centres on the current selection: let go anywhere else and it
                // snaps back, which with thirty-odd voices makes anything far from the
                // current choice genuinely hard to reach. Reported that way from the
                // phone. A pushed list scrolls where it is put and stays there, and it
                // is what iOS Settings does for a long single-choice list.
                NavigationLink {
                    VoiceListView(voices: voices, selected: $settings.voiceIdentifier)
                } label: {
                    HStack {
                        Text("Voice Name")
                        Spacer()
                        Text(selectedVoiceName)
                            .foregroundStyle(SPColor.onSurfaceVariant)
                    }
                }
                .disabled(!settings.voiceEnabled || voices.isEmpty)

                if voices.isEmpty {
                    Text("No English voices are installed on this device.")
                        .font(SPFont.bodySmall)
                        .foregroundStyle(SPColor.onSurfaceVariant)
                }
            }

            Section {
                Text("Closest map zoom: z\(settings.mapMaxZoom)")
                    .font(SPFont.bodyLarge)

                // Discrete steps, as Android's slider has: every level between the
                // bounds and nothing in between, since a fractional zoom limit is
                // not a thing the map can honour.
                Slider(
                    value: Binding(
                        get: { Double(settings.mapMaxZoom) },
                        set: { settings.mapMaxZoom = Int($0.rounded()) }),
                    in: Double(AppSettings.zoomLimitMin)...Double(AppSettings.zoomLimitMax),
                    step: 1)
                // Keeps the thumb at maximum clear of the right screen edge, where a
                // horizontal drag is the system back gesture — otherwise dragging to
                // the top of the range is a coin toss between setting the value and
                // leaving the screen, losing the drag.
                .padding(.trailing, 24)

                Text(AppSettings.zoomDescription(for: settings.mapMaxZoom))
                    .font(SPFont.bodySmall)
                    .foregroundStyle(SPColor.onSurfaceVariant)
            }
        }
        .scrollContentBackground(.hidden)
        .background(SPColor.background)
    }
}

/// The voice list, pushed from Application Settings.
///
/// Plain rows with a checkmark — the iOS single-choice pattern. No wheel, so the list
/// stays where the user scrolls it.
struct VoiceListView: View {
    let voices: [AVSpeechSynthesisVoice]
    @Binding var selected: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(voices, id: \.identifier) { voice in
            Button {
                selected = voice.identifier
                dismiss()
            } label: {
                HStack {
                    Text(voice.name).foregroundStyle(SPColor.onBackground)
                    Spacer()
                    if voice.identifier == selected {
                        Image(systemName: "checkmark").foregroundStyle(SPColor.primary)
                    }
                }
                .contentShape(Rectangle())
            }
            .listRowBackground(SPColor.surfaceContainer)
        }
        .scrollContentBackground(.hidden)
        .background(SPColor.background)
        .navigationTitle("Voice Name")
        .navigationBarTitleDisplayMode(.inline)
    }
}
