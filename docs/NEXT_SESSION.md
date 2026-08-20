# Resume here — iOS port

Written 2026-08-19 to hand off to a fresh conversation. Two known bugs to fix first,
then the outstanding work. Repo state at iOS `99d269d`, **248 tests passing**, clean
build with no warnings from our own sources.

---

## Bug 1 — CRASH: two sheets presented at once

**Symptom (on the physical iPhone, from the runtime log):**

```
*** Terminating app due to uncaught exception 'NSInvalidArgumentException',
reason: 'Application tried to present modally a view controller
<PresentationHostingController: 0x10e118400> that is already being presented by
<UIHostingController<ModifiedContent<AnyView, RootModifier>>: 0x10e01de00>.'
```

**Cause.** Two `.sheet` modifiers are attached to the same view, and both try to
present in the same update. SwiftUI on iOS 16 supports **one** sheet per view; the
second presentation throws.

It happens in **two places**, and the second is the more dangerous:

| File | Lines | Sheets | Trigger |
|---|---|---|---|
| `SteamPigeon/MapScreen.swift` | 129, 141 | menu, menu destination | **Reproducible**: tapping a menu item sets `showMenu = false` and `openDestination = …` in the same tick, so the destination sheet presents while the menu is still dismissing. |
| `SteamPigeon/LinkView.swift` | 49, 56 | diagnostics, password challenge | **Latent but live**: a locator challenge can arrive at any moment, including while the diagnostics sheet is open. Not yet observed, same failure. |

**Suggested fix.** Collapse each pair into a **single** sheet driven by one enum-typed
`@State` — e.g. `enum ActiveSheet: Identifiable { case menu, destination(MenuDestination) }`
— so only one presentation exists and switching between them is a state change rather
than a dismiss-and-present race. If two sheets must coexist, the second has to be
presented only after the first has finished dismissing, which is fragile; one sheet is
the honest structure.

**Verify with:** `Tools/devicelog.sh 60` while tapping a menu item, or drive the
simulator (see *Tooling* below). The crash is immediate and unmissable.

---

## Bug 2 — `LinkViewModel` is constructed more than once

**Symptom (found in the simulator log during a menu interaction):** two
`CLLocationManager` instances in one session, one starting updates and a *different*
one stopping them.

```
0x103e38ac0  startUpdatingLocation
0x103e391c0  stopUpdatingLocation, stopUpdatingHeading
```

**Cause.** `SteamPigeon/LinkView.swift:14`

```swift
@StateObject private var model = LinkViewModel()
```

The expression `LinkViewModel()` is evaluated **every time the `RootView` struct is
initialised**. `@StateObject` keeps only the first instance and discards the rest — a
well-known SwiftUI wart, and usually harmless.

It is not harmless here, because `LinkViewModel.init` has side effects: it constructs
a `BluetoothTransport`, whose `init` immediately creates a **`CBCentralManager`** (with
a restore identifier), and a `PhoneLocation`, which creates a `CLLocationManager` and
starts CoreMotion. Every discarded instance therefore opens hardware sessions and
abandons them. Abandoned centrals still hold sessions with `bluetoothd`.

**Plausibly related:** the "much longer delay than Android" when switching receivers.
Worth re-measuring after the fix rather than assuming.

**Suggested fix.** Make construction cheap and open hardware on first real use:
create the `CBCentralManager` lazily (on `startScan`) rather than in `init`, and the
same for the location/motion managers. Alternatively hold the model as a singleton
owned by the `App`, but lazy resources is the smaller and more honest change — the
model should be safe to construct.

**Verify with:** capture the simulator log during launch and count distinct
`"self":"0x…"` values in the CoreLocation lines; there should be one.

---

## Tooling added this session — use it

Runtime logs were a blind spot for most of this port. Every bug that could not be
reproduced from a description was runtime-only. Both are now reachable:

- **`Tools/devicelog.sh [seconds] [all]`** — streams the physical iPhone's console via
  `idevicesyslog` (installed via `brew install libimobiledevice`). Xcode cannot do
  this for iOS 16: `log stream` has no `--device` flag on current macOS and
  `devicectl` needs iOS 17+. Defaults to 30 s, filtered to lines naming the app,
  SwiftUI or CoreBluetooth — **SwiftUI warnings name no process**, so a naive
  `grep SteamPigeon` misses them.
- **Simulator** — can be driven directly (tap/screenshot) and its log captured with
  `xcrun simctl spawn booted log stream --predicate 'processImagePath CONTAINS "SteamPigeon"'`.
  Note the screenshot is ~2.29× the tap coordinate space; tap in **points**.
- **`Tools/vd2svg.py`** — converts Android VectorDrawables to iOS SVG assets.
- **Clean builds matter.** Warnings are only emitted for files the compiler revisits,
  so incremental builds hid two real ones for several commits. Build with a fresh
  `-derivedDataPath` before trusting a clean log.

---

## Where the port stands

**Done and hardware-confirmed:** wire format (the third leg of the test triad, pinned
against compiled firmware), auth, framing, CoreBluetooth transport, ADR-0012 health
watchdog, ADR-0006 recognition gate and password challenge, broadcast decode, ADR-0022
distance/bearing plausibility, ADR-0023 compass trust, live MapLibre map, ADR-0019 link
classifier, status and telemetry panels, map controls column with heading-up rotation,
the menu, and Application Settings.

**Parity matrix rows marked for iOS:** BLE receiver link, connection-health probe,
locator password gate. Others remain open.

**Outstanding, roughly in value order:**

1. The two bugs above.
2. **Auto-zoom deadband** — the toggle exists, the behaviour does not. Port
   `recenterDeadbandM`, `autoZoomDeadbandLevels`, `viewportLimitedDeadbandM` from
   `FlightMapScreen.kt`; approximating it produces a camera that hunts.
3. **TTS callouts** — `AppSettings.voiceEnabled` / `voiceIdentifier` already exist and
   are unconsumed. See `FlightSpeechAnnouncer` and the ADR-0022 rule that a withheld
   distance must mean **silence**, not a stale number read aloud.
4. **Remaining screens:** Receiver Settings (463 lines), Locator Settings (759),
   Flight Profiles (1,002), Deployment Test (160), Download maps (677).
5. **Flight-data download** (ADR-0009) — iOS throughput is still unmeasured, which
   ADR-0016 flags as an open unknown.
6. **Camera passthrough** behind the heads-up gauges (landscape).

## Standing instructions worth carrying over

- **Mirror Android in functionality and presentation**, per ADR-0016's 2026-08-19
  clarification: the bar is that **one user manual serves both platforms**. Six
  sanctioned iOS departures are listed there.
- **Read the Android source before implementing**, not just grep it. Most defects this
  session came from inferring a value or a style instead of reading what the widget
  specifies — including two documented in comments right next to the code.
- Check call sites for placeholders (`nil`, hardcoded literals) before committing.
  Three separate defects were a placeholder left behind.
