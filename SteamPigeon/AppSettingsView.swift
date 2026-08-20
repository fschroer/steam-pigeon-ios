import SwiftUI
import AVFoundation

/// Application settings, mirroring Android's `AppSettingsScreen`: speech on/off,
/// which voice, and how far in the map follows the rocket on its own.
struct AppSettingsView: View {
    @ObservedObject var settings: AppSettings

    private let voices = AppSettings.availableVoices()

    var body: some View {
        Form {
            Section {
                Toggle("Enable Speech", isOn: $settings.voiceEnabled)

                Picker("Voice Name", selection: Binding(
                    get: { settings.voiceIdentifier ?? voices.first?.identifier ?? "" },
                    set: { settings.voiceIdentifier = $0 })) {
                    ForEach(voices, id: \.identifier) { voice in
                        Text(voice.name).tag(voice.identifier)
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
