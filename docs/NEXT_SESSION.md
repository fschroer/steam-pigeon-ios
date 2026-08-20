# Resume here — iOS port

Updated 2026-08-20. The two bugs the previous handoff opened are closed: one was real
and is fixed, one did not reproduce and is explained below. Repo state: **256 tests
passing**, clean build with no warnings from our own sources.

---

## Bug 1 — CRASH: two sheets presented at once — FIXED (not yet confirmed on the phone)

**Was:** two `.sheet` modifiers on one view, which iOS 16 refuses.

```
*** Terminating app due to uncaught exception 'NSInvalidArgumentException',
reason: 'Application tried to present modally a view controller … that is already
being presented by …'
```

**Fixed by** giving each screen ONE sheet, named by a value in
`SteamPigeon/SheetRouting.swift`:

| File | Was | Now |
|---|---|---|
| `MapScreen.swift` | `.sheet(isPresented: $showMenu)` + `.sheet(item: $openDestination)` | one `.sheet(item: $sheet)` over `MapSheet.menu` / `.destination(_)` |
| `LinkView.swift` (`RootView`) | `.sheet(isPresented: $showDiagnostics)` + `.sheet(item:)` for the challenge | one `.sheet(item: activeSheet)` over `RootSheet.challenge(_)` / `.diagnostics` |

**The part that is easy to get wrong.** Collapsing to one `.sheet(item:)` is not enough
on its own: if the item's `id` changes when the user picks a menu item, SwiftUI
dismisses one sheet and presents another, which is the same sequence moved inside the
modifier rather than removed. So **`MapSheet.id` and `RootSheet.id` are constant across
their cases** on purpose, and the sheet's CONTENT changes instead. `SheetRoutingTests`
pins this — it is the invariant, not a detail.

Behaviour that falls out of it, and is intended:

- A password challenge arriving while diagnostics is open **replaces the content** and
  answering it **returns to diagnostics** (`RootSheet.active` decides; the challenge
  outranks). This was the latent, more dangerous half — nothing about the user's
  timing could have avoided it, because a locator raises it.
- A rejected password changes the challenge VALUE but not its id, so the prompt shows
  its error without being dismissed and re-presented.
- Dismissing by swipe clears both reasons a sheet could be open, so nothing
  re-presents itself while the sheet is going away.

**Verified:** menu → Application Settings → Done, menu → Download maps → Done,
diagnostics open, and swipe-to-dismiss, all on the iOS 26.5 simulator with no
exception in the log and the app still alive.

**Still to confirm on the phone**, and this is the only place it can be confirmed: an
iOS 26 simulator **does not reproduce this crash** — the pre-fix build performs the
menu → destination transition there quite happily, and only iOS 16 throws. Only iOS
26.5 runtimes are installed on this Mac. So run `Tools/devicelog.sh 60` against
Frank's iPhone (16.7.16) while tapping a menu item, and confirm the exception is gone.

---

## Bug 2 — `LinkViewModel` constructed more than once — DID NOT REPRODUCE

**It is constructed once.** Measured on 2026-08-20 by logging `LinkViewModel.init`
directly (iOS 26.5 simulator, the same environment the original observation came
from): **one** call at launch, and still one after opening the menu, opening a
destination, closing it, and opening the diagnostics sheet.

**The evidence in the previous handoff was misread.** The two `CLLocationManager`s in
the launch log are real, but only one of them is ours:

| instance | what it does | whose |
|---|---|---|
| first | `setDesiredAccuracy`, `setDistanceFilter`, then `requestWhenInUseAuthorization` + `startUpdatingLocation` | **ours** — exactly what `PhoneLocation.init` and `.start()` do |
| second | `setDelegate` only, then `stopUpdatingLocation` + `stopUpdatingHeading` when authorization changes | **MapLibre's** |

That is the quoted "one starting updates and a *different* one stopping them": it is
the map's own location manager reacting to the authorization prompt, not an abandoned
copy of ours. Our `PhoneLocation` never has `stop()` called on it — nothing in the app
calls it.

**The premise was also wrong about SwiftUI.** `@StateObject` wraps its initial value in
an `@autoclosure` and evaluates it at most once per view lifetime. The wart where the
expression re-runs on every `init` belongs to `@ObservedObject var x = X()`, which is a
different declaration.

**Nothing was changed for this** beyond a note in `BluetoothTransport.init` recording
the measurement — and recording why the suggested fix (create the `CBCentralManager`
lazily on first scan) **must not be applied**: restoration requires the central to
exist by the time launch finishes, because iOS calls `willRestoreState` on it during
launch. Deferring it to the first scan, which a view drives, would work in the
foreground and silently drop every background wake — the one case State Preservation &
Restoration exists for.

**Still worth re-measuring separately:** the "much longer delay than Android" when
switching receivers was only ever *suspected* to be related to this. With this cause
eliminated it is an open question with no candidate cause, and it needs the phone.

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

1. **Confirm the sheet fix on the phone** (Bug 1 above) — the only outstanding piece of
   it, and the only machine that can show it. Then re-measure the receiver-switch
   delay, which no longer has a candidate cause.
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
