# Resume here — iOS port

Updated 2026-08-21. **483 tests passing**, clean build with no warnings from our own
sources.

**Every Android screen is now ported.** What is left is features inside screens, and
hardware time — see below.

**Hardware status: everything testable has been tested on the phone except an actual
flight — and except the three screens that landed 2026-08-21 (Flight Profiles, Download
maps, Deployment Test), which have only been driven on the simulator.** Download maps did
download a real region there, which is the half of it a fixture could not fake; the other
two ran against fixtures only.

**Deployment Test deserves its own line: it fires a pyro channel, and nothing about it
has touched hardware.** The state machine is tested and the four screen states were
driven on the simulator, but the frames have never been sent, and ADR-0027's sharp edge —
that the stop path is one unacknowledged LoRa frame through a receiver whose transmit
window the locator's own silence can close — is exactly the kind of thing a bench test
finds and a unit test cannot. Bench it with an e-match nobody is standing over. fschroer exercised the map, the settings screens,
the receiver picker, the channel move, the pad alert and the voice against real hardware.
What remains unproven is what only a flight can prove, plus a real archived-record
download — see *Not yet exercised* below.

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

## One thing Android owes iOS

**The download picker's opening camera.** fschroer asked for it on iOS first
(2026-08-21): open on the **phone's current position at a multi-state zoom (z5)**,
applied once when a fix first arrives, cancelled by picking a preset or typing a
coordinate, and no invented fallback when there is no fix. Android sets no opening camera
at all today. The full rule set is in `docs/UI_PARITY.md` under "iOS-FIRST behaviour" —
written as a description precisely so the Android change does not require reading Swift.

This is the only behaviour in the port that landed here first, and it was asked for. The
standing rule is still Android-first.

## Where the port stands

**Screens done: all seven.** Flight map (with the full camera model), Application
Settings, Receiver Settings, Locator Settings, Flight Profiles (the record list and the
chart), Download maps (region picker, estimate, offline pack download, region management)
and Deployment Test.

**No screens remain.** Deployment Test landed 2026-08-21, and with it the placeholder
view for unbuilt destinations is gone — every menu entry opens something real.

**Read `docs/UI_PARITY.md` § "Deployment Test" before touching it.** The rule that shapes
the whole screen is that the display follows the LOCATOR, never the app's own hope, and
Android's comments record what it cost to learn: an early cancel-clears-state made the app
deaf to the countdown that was still running, so the button read "start" while the locator
counted down and fired.

**The flight-data transfer layer landed with Flight Profiles** —
`FlightDataRepository.swift` (bitmap ack, XOR parity FEC, the delta codec),
`FlightEvents.swift` (MsgType 19), and the request/exit handshake in `LinkViewModel`. iOS
throughput over a real transfer is still the open unknown ADR-0016 named; nothing has
downloaded a record from hardware yet.

**The offline map path landed with Download maps** — `SteamPigeon/Maps/`, including the
localhost style server ADR-0014 requires (`NSAllowsLocalNetworking` in the Info.plist is
its enabler, exactly as `network_security_config.xml` is on Android). A 30-tile region
downloaded and listed as complete on the simulator.

**Also unblocked, and still to build: the archived-path map control.** Android offers it
only once a record is downloaded, which is now possible here. It needs Android's
`archivedPathPoints` and the control itself.

**Read `docs/UI_PARITY.md` §§ "Flight Profiles" and "Download maps" before touching
either screen.** It records
what was mirrored deliberately, the two Android FEC bugs fixed here rather than
reproduced, and the one number in the chart with no exact answer.

**Features remaining:**

- **Flight TTS callouts.** `FlightSpeech` exists and the pad alert and arm/disarm use it.
  `FlightSpeechAnnouncer`'s ascent/descent/apogee/landing/link-loss callouts are unported.
  ADR-0022 rule when porting: a withheld distance must mean **silence**, not a stale
  number read aloud.
- **Camera passthrough** behind the heads-up gauges (landscape).
- **Export flight path.** Android has an `ExportFlightPathScreen`; nothing here does.
- **Archived-path map control.** Now unblocked — see above.

---

## Not yet exercised

- **A real archived-record download.** The whole Flight Profiles path — metadata retry,
  the sample burst, the bitmap acks, parity recovery, the locator's return to Disarmed on
  exit — has only run against fixtures. The simulator has no Bluetooth, so this is a
  phone job, and it is the first thing to try when one is next in hand.
- **Offline maps with the network actually down.** A region downloaded and listed as
  complete on the simulator, but "renders offline" was never watched happening. MapLibre
  serves any matching tile URL from the pack database and both sides read the same style,
  which is all ADR-0014 says is needed — but that is a claim, not an observation. Turn
  off wi-fi and cellular at a downloaded site, or in Airplane Mode with a region cached.
- **Double-tap to reset the chart zoom.** The recognizer is wired and pinch/pan were both
  verified on the simulator; a synthesized double-tap could not be delivered inside the
  tap window, so this one gesture is unproven.
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

## Four system-level questions, none an iOS decision

1. **`launch_detect_altitude` and `deploy_signal_duration` cannot be read back.** Neither
   rides in `PreLaunchData`, so every locator config change writes placeholders (30 m,
   1.0 s — matching Android, and they MUST match or nothing ever confirms). On Android
   both are editable and editing either can never succeed: it reports "not acknowledged"
   while the locator has in fact accepted the change. fschroer decided on 2026-08-20 to
   omit both controls on iOS. Closing it properly means carrying both fields in a
   broadcast — a change across three binaries, and an ADR.
2. **The offline size estimate is low on both platforms — ~2× on bytes, ~4× on tiles.**
   Measured 2026-08-21: a 9.1 km region estimated ~64 MB and downloaded 139 MB; a 22 km
   region estimated 12,484 tiles against MapLibre's 49,155. The ratio is one zoom level,
   and the likely cause is the 256-px source against MapLibre's 512-px logical tile grid,
   so the downloader fetches a level deeper than the estimate counts. **Android's
   estimator is the same arithmetic and is low by the same factor**, so this was NOT
   changed on iOS alone — quoting different sizes for the same region on the two phones
   would be worse than both being consistently low. Needs a decision and a change on
   Android first. The error is at least in the safe direction for the 1 GB gate.
3. **The flight-profile chart clips its altitude axis labels — on both platforms.**
   Android's left gutter is 64 px and `900m` measures about 79 px at the 32 px axis text
   size, so the first character is cut. iOS reproduces this exactly rather than quietly
   widening the gutter, because Android is the reference implementation and a silent
   divergence is worse than a shared defect. **The fix is one constant** (widen
   `CHART_MARGIN_X`, or drop `CHART_AXIS_TEXT_SIZE`), and it lands on Android first, then
   here in the same session. It needs fschroer's eye on the phone: it is a legibility
   judgement, and the gutter is space taken from the plot.
4. **The escalated pad-alert banner** wraps to five lines at 57 pt and runs under the
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
