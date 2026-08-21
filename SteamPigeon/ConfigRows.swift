import SwiftUI

/// The settings-screen field widgets, ported from Android's `ConfigurationItemText`,
/// `ConfigurationItemNumeric` and `NudgeButton`.
///
/// **Built to look and behave like Android's, not like a SwiftUI `Form` row.** The first
/// pass used `TextField` and `Stepper` inside a grouped `Form`, which reads as a list of
/// LABELS: nothing shows that a value is editable, and a number can only be nudged, never
/// typed. Android uses a Material `OutlinedTextField` — a visible box with a floating
/// label — and puts the nudge arrows beside it, so both affordances are present at once.
///
/// ADR-0016 sanctions "SwiftUI switches, pickers and steppers rather than Material
/// clones", and this is deliberately NOT an exception to that: the sanctioned departure
/// covers controls that look broken when imitated. A bordered, labelled text box is not
/// one — it is the ordinary way to show an editable value on either platform, and here
/// it is also the fix for a real usability defect.

// MARK: - Shared chrome

/// A Material-style outlined box with its label floated onto the border.
private typealias OutlinedField = OutlinedFieldChrome

// MARK: - Text

/// Android's `ConfigurationItemText`.
struct ConfigTextRow: View {
    let title: String
    @Binding var text: String
    var enabled: Bool = true
    /// Fixed-width on the wire, so it is truncated as typed rather than silently losing
    /// the tail on send.
    var maxLength: Int = WireProtocol.deviceNameLength

    var body: some View {
        OutlinedField(title: title, enabled: enabled) {
            TextField("", text: Binding(
                get: { text },
                set: { text = String($0.prefix(maxLength)) }))
                .disabled(!enabled)
                .submitLabel(.done)
        }
    }
}

// MARK: - Numbers

/// Android's `ConfigurationItemNumeric`, integer overload: an editable field with
/// stacked nudge arrows beside it.
///
/// The bounds are applied **on commit, not on every keystroke**. Coercing as you type
/// makes a field impossible to clear and fights every intermediate value — typing "15"
/// into a field with a minimum of 10 would rewrite the "1" to "10" before the "5"
/// arrives. Android coerces in `onFocusChanged` for exactly this reason.
struct ConfigIntRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var enabled: Bool = true

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            OutlinedField(title: title, enabled: enabled) {
                TextField("", text: $text)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .disabled(!enabled)
            }
            NudgeColumn(enabled: enabled,
                        canIncrease: value < range.upperBound,
                        canDecrease: value > range.lowerBound,
                        onStep: { direction in
                            commit(value + direction)
                        })
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { new in if !focused { text = String(new) } }
        // Every keystroke reports, exactly as Android's `onValueChange` does. It is
        // what makes the Update button light up as you type rather than only once the
        // keypad is dismissed — and a user who types a value and reaches for Update
        // finding it dead has no way to know why.
        .onChange(of: text) { new in
            guard focused else { return }
            let digits = new.filter(\.isNumber)
            if digits != new { text = digits }
            value = Int(digits) ?? 0
        }
        .onChange(of: focused) { isFocused in
            // Bounds are applied HERE, not per keystroke. Coercing as you type makes a
            // field impossible to clear and fights every intermediate value: typing
            // "15" into a field with a minimum of 10 would rewrite the "1" to "10"
            // before the "5" arrived. Android coerces in `onFocusChanged` for exactly
            // this reason.
            if !isFocused { commit(Int(text) ?? value) }
        }
    }

    private func commit(_ raw: Int) {
        value = min(max(raw, range.lowerBound), range.upperBound)
        text = String(value)
    }
}

/// Android's `ConfigurationItemNumeric`, decimal overload. Steps 0.1 and shows one
/// decimal place.
///
/// The value is carried in TENTHS, because that is the wire unit — converting at the
/// edges keeps rounding out of the stored value.
struct ConfigDecimalRow: View {
    let title: String
    /// Tenths of a unit, as the wire carries it.
    @Binding var tenths: Int
    /// Also in tenths.
    let range: ClosedRange<Int>
    var enabled: Bool = true

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            OutlinedField(title: title, enabled: enabled) {
                TextField("", text: $text)
                    .keyboardType(.decimalPad)
                    .focused($focused)
                    .disabled(!enabled)
            }
            NudgeColumn(enabled: enabled,
                        canIncrease: tenths < range.upperBound,
                        canDecrease: tenths > range.lowerBound,
                        onStep: { direction in commit(tenths + direction) })
        }
        .onAppear { text = Self.format(tenths) }
        .onChange(of: tenths) { new in if !focused { text = Self.format(new) } }
        .onChange(of: text) { new in
            guard focused else { return }
            let allowed = new.filter { $0.isNumber || $0 == "." }
            if allowed != new { text = allowed }
            tenths = Int(((Double(allowed) ?? 0) * 10).rounded())
        }
        .onChange(of: focused) { isFocused in
            if !isFocused {
                commit(Int(((Double(text) ?? Double(tenths) / 10) * 10).rounded()))
            }
        }
    }

    private func commit(_ raw: Int) {
        tenths = min(max(raw, range.lowerBound), range.upperBound)
        text = Self.format(tenths)
    }

    private static func format(_ tenths: Int) -> String {
        String(format: "%.1f", Double(tenths) / 10)
    }
}

// MARK: - Nudge

/// Two stacked arrows, as Android puts beside every numeric field.
///
/// **Hold to repeat, accelerating.** Android's `NudgeButton` waits 500 ms, then repeats
/// with the delay decaying by a quarter each time down to 100 ms — which is what makes a
/// 500 m altitude reachable without 500 taps. A plain repeat at one rate is either too
/// slow to be useful or too fast to stop on a value.
struct NudgeColumn: View {
    var enabled: Bool
    var canIncrease: Bool
    var canDecrease: Bool
    /// +1 or −1.
    var onStep: (Int) -> Void

    /// Android's `maxDelayMillis`, `minDelayMillis` and `delayDecayFactor`.
    static let initialDelay: Duration = .milliseconds(500)
    static let minimumDelay: Duration = .milliseconds(100)
    static let decayFactor = 0.25

    var body: some View {
        VStack(spacing: 0) {
            NudgeButton(systemName: "chevron.up", enabled: enabled && canIncrease) { onStep(1) }
            NudgeButton(systemName: "chevron.down", enabled: enabled && canDecrease) { onStep(-1) }
        }
        .frame(width: 44)
    }
}

private struct NudgeButton: View {
    let systemName: String
    let enabled: Bool
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(enabled ? SPColor.primary : SPColor.onSurfaceVariant.opacity(0.4))
            .frame(width: 44, height: 28)
            .contentShape(Rectangle())
            // A DragGesture with no minimum distance is how a press-and-hold is
            // observed in SwiftUI: `Button` reports only the completed tap, which
            // cannot drive a repeat.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if repeatTask == nil { start() } }
                    .onEnded { _ in stop() })
            .disabled(!enabled)
    }

    private func start() {
        guard enabled else { return }
        action()                                   // the single tap, immediately
        repeatTask = Task { @MainActor in
            // The first repeat waits the full delay, so a quick tap does not
            // double-increment — Android notes the same hazard.
            try? await Task.sleep(for: NudgeColumn.initialDelay)
            var delay = NudgeColumn.initialDelay
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: delay)
                let next = delay - (delay * NudgeColumn.decayFactor)
                delay = max(next, NudgeColumn.minimumDelay)
            }
        }
    }

    private func stop() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

// MARK: - Picker

/// Android's `EnumDropdown`: a read-only field with a trailing chevron that opens a
/// menu of every case.
///
/// The labels are Android's enum NAMES — `DroguePrimary`, not "Drogue Primary" — because
/// that is the string a user reads on the other platform and the one the manual has to
/// name. Prettier spacing here would be a second vocabulary.
struct ConfigPickerRow<T: Hashable>: View {
    let title: String
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    var enabled: Bool = true

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(label(option)) { selection = option }
            }
        } label: {
            OutlinedFieldChrome(title: title, enabled: enabled) {
                HStack {
                    Text(label(selection))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SPColor.onSurfaceVariant)
                }
            }
        }
        .disabled(!enabled)
    }
}

/// The same chrome as `OutlinedField`, exposed for the picker.
struct OutlinedFieldChrome<Content: View>: View {
    let title: String
    let enabled: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(SPFont.bodyLarge)
            .foregroundStyle(enabled ? SPColor.onBackground : SPColor.onSurfaceVariant)
            .padding(.horizontal, 12)
            .frame(height: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(enabled ? SPColor.outline : SPColor.outline.opacity(0.4), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(SPFont.bodySmall)
                    .foregroundStyle(enabled ? SPColor.primary : SPColor.onSurfaceVariant)
                    .padding(.horizontal, 4)
                    .background(SPColor.background)
                    .padding(.leading, 8)
                    .offset(y: -8)
            }
            .padding(.top, 8)
    }
}
