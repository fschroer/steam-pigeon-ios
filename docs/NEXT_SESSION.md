# Resume here — iOS port

Updated 2026-08-20. **408 tests passing**, clean build with no warnings from our own
sources. Three pieces of work below: the sheet crash and its companion non-bug, the
flight-map parity pass, and the nine gaps that pass turned up.

---

## ⚠️ Read `../rocket-flight-manager` before touching UI. All of it, not a grep.

Four map defects were reported from the phone and **all four came from assuming what
the Android app did**. Three map controls shipped defaulting off because four lines of
`mutableStateOf(true)` went unread; two controls were simply missing; and the fifteen
lines of gesture backoff that make Android's map usable were absent, which reached the
user as three separate bugs.

This is now a standing rule at the top of `CLAUDE.md`. The full comparison is in
`docs/UI_PARITY.md` under *Flight map — line-by-line audit*; the nine gaps it opened
are now closed, and it records what was deliberately left and why. Start there rather
than re-deriving it.

---

## Flight map parity pass — DONE, needs the phone to confirm

Fixed: auto-zoom and magnetic-orientation defaults (both now ON, as Android);
record-track and reset-track controls added; auto-centre icon corrected to a crosshair;
rotate/zoom/scroll gestures stated explicitly; and the **gesture backoff** — while the
user is touching the camera, and for five seconds after, the auto-camera writes
nothing, exactly as Android's `MapCameraController` returns early on
`userGestureRecent`. A control tap cancels the window so the tap is not swallowed.

That last one is one fix for three reported symptoms — pinch wander, pan snap-back, and
rotation springing back — because `applyCamera` runs from `updateUIView` and reporting
the camera back into SwiftUI state re-renders the view, so every gesture frame invited a
camera write on top of the finger. `MapGestureBackoffTests` pins it.

**Confirmed on the simulator:** the control column now shows six buttons in Android's
order with Android's defaults and tint rules (record is RED while recording; reset is
always full white).

### Then the nine gaps that audit turned up — also DONE

Seven implemented, two needing no code. New pure types, all unit-tested:
`CameraFraming` (deadband sizing and ground geometry), `CameraFilter` (Android's
per-frame Kalman with latched anchors, driven by a `CADisplayLink`), `TrackRecording` /
`TrackRecorder` (pad silence, landing freeze, new-flight reset), `TrackStore`
(`flight_path.csv`, Android's format including legacy rows). Auto-zoom now actually
does something; auto-centre frames rocket AND phone rather than the rocket alone.

Two were correctly no-ops: the archived-path control has nothing to toggle until
flight-data download lands, and Android's `showControls` is dead state there, so iOS
showing the column always is already right.

**One divergence found and fixed while doing it:** the track was thinned to a 2 m
minimum separation. Android does not do that, and its own dedup test warns that the
rule silently swallows the slow movement of a descent under canopy. What keeps the pad
quiet on Android is recording nothing before launch, which is now ported.

**Visibly confirmed on the simulator:** the map opens centred on the phone at z12
instead of on null island, and a pan holds instead of springing back. The rest of the
camera work needs a locator — see below.

### Third round — rotation smoothing, the "Disarmed" banner, the pad alert

Three more observations from the phone, all overlays the audit had not covered:

- **Rotation was jerky** because the bearing was not filtered. That was my judgement in
  the previous pass and it was wrong: CoreLocation smooths the heading VALUE but
  delivers it a few times a second, while the camera is written every frame. Now at
  Android's gain of .01, with the shortest-turn wrap so crossing north does not spin
  the map the long way.
- **The "Disarmed" banner had never been ported.** `FlightBanner` + `PulsingText`,
  composed exactly as Android composes it — two independent lines, escalation that
  replaces rather than adds. **Confirmed on the simulator.**
- **The pad alert (ADR-0021) had no UI.** Worth knowing: the locator computes the
  verdict from continuity, primary axis and attitude and sends it as one byte — the app
  only displays it. The wire decode was already right; only the banner escalation and
  the snooze control were missing. Snooze is locator-directed with a target (ADR-0020).

**Left as-is deliberately:** the escalated banner wraps to five lines at 57 pt and runs
under the control column. Android composes it identically, so this is believed faithful
— but that is a legibility question and wants a side-by-side screenshot, which nobody
has taken.

### Fourth round — compass control, banner font, receiver picker

- **The compass button was greyed out** under magnetic interference. Android never
  disables it: `compassUsable` gates the BEARING, not the control. Trust suppression is
  unchanged; the button is now always live, and the rose's calibration mark is what
  says the compass is doubted.
- **Banners were bold.** Android keeps Material 3's baseline weight and swaps only the
  family, and the baseline display styles are Regular. `displayLarge`/`displayMedium`
  are now Roboto-Regular. **Confirmed on the simulator.** `titleMedium`/`titleSmall`
  are a separate W500 question — see `UI_PARITY.md` before touching them.
- **Two receivers offered no choice**, because `startScan` reconnected to a remembered
  peripheral and skipped scanning. Removed; there is now a 3 s window (Android's
  `SCAN_DURATION_MS`) and the picker is always offered, for one receiver as well as two.
  Also fixed: `noDevicesFound` had no producer, so an empty scan said "Scanning" for ever.

### Fifth round — rotation under interference, and the app's voice

- **The map stopped rotating under magnetic interference.** iOS gated the camera
  heading on compass trust; ADR-0023 gates the **AR overlay** (Decision 5) and its
  Decision 6 describes the map correcting itself during the figure-eight, which it
  cannot do if frozen. Android's camera bearing has accuracy nowhere in it. Gate
  removed; the vector suppression in `updateVector` is untouched.
- **There was no voice anywhere.** `voiceEnabled`/`voiceIdentifier` were written by
  Settings and read by nothing. `FlightSpeech` now exists (AVSpeechSynthesizer,
  `.playback` session so the ring/silent switch cannot mute a launch), plus
  `PadAlertAnnouncer` — spoken warning on the rising edge and every 30 s while alerting,
  never while snoozed — and the arm/disarm announcement.
- **The pad alert now vibrates**, on Android's exact waveform (260/140/260/2400 ms,
  looping), via CoreHaptics with a two-tap fallback. NOT gated on the speech setting.

**Still missing: the flight callouts.** `FlightSpeechAnnouncer` — ascent, descent,
apogee, landing prediction, link loss — is still unported. The engine exists for it now.
Remember the ADR-0022 rule when porting it: a withheld distance must mean **silence**,
not a stale number read aloud.

### Sixth round — the half-restored receiver, and the voice list

- **A receiver connected itself with a grey icon and would not arm.** One cause:
  `willRestoreState` adopted the peripheral and never re-ran GATT discovery, so the link
  stopped at `.connected` and never reached `.ready`. iOS restores the connection, not
  the session on top of it, and `didConnect` does not fire for an already-connected
  peripheral. The scan now also seeds from `retrieveConnectedPeripherals`, so the held
  receiver appears in the picker instead of being the missing one; choosing another
  cancels the previous connection; and a duplicate `startScan` no longer discards a
  window's finds.
- **The voice list** now excludes novelty voices (`isNoveltyVoice` on iOS 17+, an
  identifier list on 16) and is a pushed checkmark list rather than a snap-back wheel.
  **Confirmed on the simulator.** Do NOT "simplify" the filter to the
  `com.apple.speech.synthesis.voice.` prefix — Fred, Junior, Kathy and Ralph share it
  and are not novelty. `VoiceSelectionTests` pins both halves.

### Seventh round — the escalation that would not clear when armed

The locator stops sending `PreLaunchData` the moment it is armed. The banner read
`model.prelaunch?.padAlert`, so arming froze the last pre-launch value and disarming
was what finally overwrote it — hence the inverted behaviour reported. `padAlert` and
`padAlertSnoozeMinutes` are now their own view-model state, set from pre-launch and
**cleared explicitly by telemetry**, exactly as Android does.

The same latching was on the **batteries** — pre-launch-only fields read with no
freshness test, which would have shown the pre-flight charge all flight. Now aged on
`isPreLaunchFresh` / `lastPreLaunchMessage`.

**Rule for anything added later:** a field carried only by `PreLaunchData` must never be
read off the last-seen object. Give it its own state written by both branches, or age it
on `isPreLaunchFresh`. Device names are the deliberate exception.

### Eighth round — continuity that needed an app restart

The mirror of the seventh. The view read `telemetry ?? prelaunch`, but `telemetry` is
never nil again once a flight has happened and the locator returns to `PreLaunchData` on
every disarm and after every landing — so the last in-flight value won for the rest of
the session. Android's rule is **newest wins**, because it merges both messages into one
`rocketState`. `LinkViewModel.newest(_:_:)` now applies that rule, and position,
accuracy, satellites, GPS status, RSSI, SNR, AGL and the tilt altitude went through the
same fix. Position was the worst of them: after a landing the marker would have sat at
the last in-flight fix.

**Before adding any field that comes off a broadcast, decide which of three categories
it is in** — both / telemetry-only / pre-launch-only. The table is in `UI_PARITY.md`.
Getting it wrong is silent in both directions, and both directions have now been
reported from the phone.

### Receiver Settings — protocol layer and form landed

Parsers for `receiverInfo` / `versionInfo` / `channelSurvey` plus the ADR-0019 ranking
model, then the staged form with its Update button. The polled noise floor now reaches
the link classifier, which closes a real ADR-0019 gap — with its own baseline, the
absolute test dropped, a 500 ms liveness tick and a 2 s poll during silence. All four
are load-bearing; the reasoning is in `UI_PARITY.md`.

The **channel survey section** has landed too — Android's wording verbatim, relative
bars with no dBm, a 15 s timeout so a receiver too old to answer says so. "Move here" is
withheld while a locator is connected and explains why: moving the system is ADR-0011
and needs Locator Settings, and staging the receiver-only half would strand the locator
on the old channel.

The **ADR-0011 channel move** has landed: "Move here" retunes the whole system,
confirmed by broadcasts resuming on the new channel, with the split-link recovery
(pull the receiver back over BLE, retry once) and a progress row that speaks through the
seconds when the link is legitimately down.

⚠️ **Read the "A locator config change writes two fields the app cannot read" note in
`UI_PARITY.md` before touching locator config.** `PreLaunchData` carries neither
`launch_detect_altitude` nor `deploy_signal_duration`, so every config change writes
placeholders — 30 m and 1.0 s, matching Android, and they MUST match or nothing ever
confirms. One of them is pyro firing time. It is a system-level gap, not an iOS one.

The **ADR-0006 conflicting-locator banner** has landed too, which completes Receiver
Settings. Two framings (warning when already connected to another locator, invitation
when not), an 8 s hold so interleaved broadcasts cannot flash it away before Connect can
be pressed, and a remembered Dismiss — clearing the id alone put it straight back on the
next 1 Hz packet.

**Locator Settings has landed too**, minus two controls on purpose. Four deployment
channels with interlocked primary/backup limits — the only thing stopping a backup being
configured to fire before its primary — plus name, channel, mounting axis and the Update
row.

⚠️ **Launch-detect altitude and deploy-signal duration are deliberately NOT offered.** On
Android, editing either can never succeed: neither rides in `PreLaunchData`, so the
confirmation comparison can never match and it always reports "not acknowledged" while
the locator has in fact accepted the change. fschroer decided on 2026-08-20 to omit both
rather than ship a control that cannot work. The full chain, and what would close it, is
in `UI_PARITY.md`. This is the only deliberate UI divergence on these screens.

**The settings widgets were then rebuilt** after "text entry areas appear as labels" and
"numeric fields can't be edited directly" — both true, and the same failure as the map
round: written in SwiftUI idiom instead of read off Android's `ConfigurationItemText` /
`ConfigurationItemNumeric`. `ConfigRows.swift` now has the outlined labelled field, the
stacked nudge arrows with Android's hold-to-repeat decay, and the dropdown. **Use those
rows for every settings screen from here** rather than reaching for `Form` + `Stepper`.

**Fonts were then audited end to end** after "more examples of bolded text where it
should not be". The rule is checkable and stronger than expected: **nothing in the
Android app is bold except the "∞" calibration glyph.** M3's baseline never specifies
Bold, and its Medium styles resolve to Regular because each family registers only
Regular and Bold. Five iOS styles and a `telemetryBold` were wrong; all now Regular. If
something looks like it wants emphasis, the answer is size or colour, not weight.

Also fixed: the channel survey now clears when a channel is picked, as Android does on
both branches — the ranking describes the band before the move.

**Remaining screens:** Flight Profiles (1,002 lines), Deployment Test (160), Download
maps (677) — the last two of which depend on flight-data download.

**NOT confirmable on the simulator, needs the phone plus a locator:**

- **Pinch wander and pan snap-back** need a rocket fix — with no locator,
  `autoCentreOn` is nil and nothing contends for the camera in the first place.
- **The greyed-out compass button** and **rotation under interference** cannot be
  reproduced there: the simulator has no magnetometer, so compass trust never leaves
  `high`.
- **The pad-alert voice and haptic** need a locator to raise the alert, and the
  simulator has no haptic engine at all — it would take the fallback path.
- **Two receivers and the restoration fix**, obviously — the simulator has no
  Bluetooth at all. The restored-link path needs a relaunch against a live receiver.
- **Rotation smoothing** cannot be judged there at all:
  `CLLocationManager.headingAvailable()` is false on the simulator, so
  `trueHeadingDeg` stays nil and heading-up never engages. Verified by the absence of
  `startUpdatingHeading` in the launch log.

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

1. **Confirm on the phone**, the only machine that can show any of it: the sheet fix
   (Bug 1), and the three map-gesture fixes with a locator powered up. Then re-measure
   the receiver-switch delay, which no longer has a candidate cause.
2. **Flight TTS callouts** — the speech engine now exists (`FlightSpeech`) and the pad
   alert and arm/disarm use it. `FlightSpeechAnnouncer`'s ascent/descent/apogee/landing
   /link-loss callouts are still unported. The ADR-0022 rule applies: a withheld
   distance must mean **silence**, not a stale number read aloud.
3. **Remaining screens:** Receiver Settings (463 lines), Locator Settings (759),
   Flight Profiles (1,002), Deployment Test (160), Download maps (677).
4. **Flight-data download** (ADR-0009) — iOS throughput is still unmeasured, which
   ADR-0016 flags as an open unknown. It also unblocks the archived-path map control,
   which is the one flight-map gap deliberately left open.
5. **Camera passthrough** behind the heads-up gauges (landscape).

## Standing instructions worth carrying over

- **Mirror Android in functionality and presentation**, per ADR-0016's 2026-08-19
  clarification: the bar is that **one user manual serves both platforms**. Six
  sanctioned iOS departures are listed there.
- **Read the Android source before implementing, and read ALL of it — not a grep.**
  This is now a rule in `CLAUDE.md` rather than a note here, because it has been the
  finding of every review so far, and on 2026-08-20 it was restated by fschroer after
  four map defects that were all the same mistake. Defaults, ordering, tint rules,
  thresholds and gesture handling are requirements, not details — and two of them were
  documented in comments sitting next to the code.
- Check call sites for placeholders (`nil`, hardcoded literals) before committing.
  Three separate defects were a placeholder left behind.
