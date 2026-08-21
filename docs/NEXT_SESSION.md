# Resume here — iOS port

Updated 2026-08-20. **408 tests passing**, clean build with no warnings from our own
sources. Branch `fix/ios-android-parity-pass`, 11 commits, pushed.

**Hardware status: everything testable has been tested on the phone except an actual
flight.** fschroer exercised the map, the settings screens, the receiver picker, the
channel move, the pad alert and the voice against real hardware. What remains unproven is
what only a flight can prove — see *Not yet exercised* below.

---

## ⚠️ The rule this port keeps failing, stated once

**Read the Kotlin for the thing you are building, all of it, before writing Swift.**
Mirror Android's functionality *and* its UI as closely as possible. Depart only where
Android's approach genuinely does not work on iOS — not where a SwiftUI control was
merely closer to hand.

Every defect fschroer reported in this session came from breaking that, and they came in
three flavours worth naming because they do not look alike from the inside:

1. **Assuming behaviour.** Three map controls shipped defaulting off because four lines
   of `mutableStateOf(true)` went unread. The gesture backoff that makes Android's map
   usable was absent and reached the user as three unrelated-looking bugs.
2. **Building to iOS idiom.** The settings screens were written as a SwiftUI `Form` of
   `TextField` and `Stepper` rows. That renders as a list of labels: nothing shows a
   value is editable and numbers cannot be typed. Android uses a Material
   `OutlinedTextField` with nudge arrows beside it. Use `ConfigRows.swift` for every
   settings screen from here.
3. **Drifting a detail at a time.** Bold crept onto five type styles because "this looks
   like a heading, headings are bold". Nothing in the Android app is bold except one
   glyph — see below.

**On ADR-0016's sanctioned departures.** That list permits "SwiftUI switches, pickers and
steppers rather than Material clones", and I leaned on it wrongly. It covers controls
that look *broken* when imitated. A bordered, labelled text box is not one. The list is
not a licence to reach for a different control whenever one is handier.

**Order matters too.** Locator Settings puts the four deployment channels first and the
identity fields last — odd for a form, correct for a screen whose channels change between
flights while the rest is set once. Walk the composable top to bottom and mirror its
structure before writing anything.

---

## Facts that are cheap to get wrong

- **Nothing is bold.** Android's `AppTypography` copies Material 3's baseline and swaps
  only the family, so weights come from the M3 scale — Regular or Medium, never Bold. Each
  family registers only Regular and Bold, so a Medium (W500) request resolves to W400.
  The only bold text in the app is the "∞" compass-calibration glyph. If something wants
  emphasis, the answer is size or colour.
- **Two broadcasts, three categories of field.** The locator stops sending `PreLaunchData`
  the moment it is armed. Before adding any field read off a broadcast, decide which it
  is: carried by BOTH (newest wins — `LinkViewModel.newest`), telemetry-only (keeps its
  last value), or pre-launch-only (age on `isPreLaunchFresh`, or clear explicitly). Both
  directions of getting this wrong were reported from the phone a day apart. Table in
  `UI_PARITY.md`.
- **Enum labels are Android's case names** — `DroguePrimary`, not "Drogue Primary".
  Android renders `enumValue.name`.
- **SF Symbols must exist on iOS 16.0.** A later symbol resolves fine on the 26.5
  simulator and is a blank box on the phone. Check against
  `CoreGlyphs.bundle/name_availability.plist` — the command is in
  `SFSymbolAvailabilityTests`.

---

## Where the port stands

**Screens done:** flight map (with the full camera model), Application Settings, Receiver
Settings, Locator Settings.

**Screens remaining:** Flight Profiles (1,002 lines), Deployment Test (160), Download maps
(677). The last two depend on flight-data download, which is unported and whose iOS
throughput ADR-0016 flags as an open unknown.

**Features remaining:**

- **Flight TTS callouts.** `FlightSpeech` exists and the pad alert and arm/disarm use it.
  `FlightSpeechAnnouncer`'s ascent/descent/apogee/landing/link-loss callouts are unported.
  ADR-0022 rule when porting: a withheld distance must mean **silence**, not a stale
  number read aloud.
- **Camera passthrough** behind the heads-up gauges (landscape).
- **Archived-path map control.** Correctly absent — Android offers it only once a record
  is downloaded, so it unblocks with flight-data download.

---

## Not yet exercised

- **An actual flight.** Everything downstream of launch detection: the landing freeze,
  the new-flight track reset, auto-zoom through a real ascent, the camera filter under
  fast movement, telemetry-only fields.
- **The ADR-0011 channel-move recovery path**, under a forced miss. That ADR lists it as
  not bench-validated on Android either (#20), so there are now two implementations of it
  that have never run.
- **The iOS 16 sheet crash**, in the sense that the fix cannot be proven absent — only
  that it no longer reproduces. An iOS 26 simulator does not reproduce it even before the
  fix.

---

## Two system-level questions, neither an iOS decision

1. **`launch_detect_altitude` and `deploy_signal_duration` cannot be read back.** Neither
   rides in `PreLaunchData`, so every locator config change writes placeholders (30 m,
   1.0 s — matching Android, and they MUST match or nothing ever confirms). On Android
   both are editable and editing either can never succeed: it reports "not acknowledged"
   while the locator has in fact accepted the change. fschroer decided on 2026-08-20 to
   omit both controls on iOS. Closing it properly means carrying both fields in a
   broadcast — a change across three binaries, and an ADR.
2. **The escalated pad-alert banner** wraps to five lines at 57 pt and runs under the
   control column. Android composes it identically at the same size on a near-identical
   screen width, so this is believed faithful — but it is a legibility question and wants
   a side-by-side screenshot that nobody has taken.

---

## Recorded so it is not re-chased

**"`LinkViewModel` is constructed more than once" was a misdiagnosis** (2026-08-19
handoff). It is constructed once, measured by logging the initialiser. The two
`CLLocationManager`s in a launch log are ours plus **MapLibre's** — MapLibre's is the one
that never gets `setDesiredAccuracy`/`setDistanceFilter` and calls `stopUpdatingLocation`
when authorization changes. `@StateObject` evaluates its autoclosure at most once; the
wart belongs to `@ObservedObject var x = X()`.

**Do not make the `CBCentralManager` lazy.** It looks like the obvious cure for "the
initialiser opens hardware" and it breaks State Preservation & Restoration, which needs
the central to exist by the time launch finishes.

**Do not simplify the novelty-voice filter to the `com.apple.speech.synthesis.voice.`
prefix.** Fred, Junior, Kathy and Ralph share it and are not novelty voices.

---

## Tooling

- **`Tools/devicelog.sh [seconds] [all]`** — streams the phone's console via
  `idevicesyslog`. Xcode cannot do this for iOS 16: `log stream` has no `--device` flag
  and `devicectl` needs iOS 17+. Filtered to lines naming the app, SwiftUI or
  CoreBluetooth — **SwiftUI warnings name no process**, so a naive `grep SteamPigeon`
  misses them.
- **Simulator** — drivable (tap/screenshot) with its log captured via
  `xcrun simctl spawn booted log stream --predicate 'processImagePath CONTAINS "SteamPigeon"'`.
  It has **no Bluetooth, no magnetometer and no haptic engine**, and only iOS 26.5
  runtimes are installed, so it cannot show: the iOS 16 crash, anything locator-driven,
  compass trust, the pad-alert haptic, or the receiver picker. Menu gates can be forced
  temporarily to check a screen's layout.
- **`Tools/vd2svg.py`** — converts Android VectorDrawables to iOS SVG assets.
- **Clean builds matter.** Warnings are only emitted for files the compiler revisits, so
  incremental builds hid two real ones for several commits. Build with a fresh
  `-derivedDataPath` before trusting a clean log.
