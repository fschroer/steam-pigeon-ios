# Android ⇄ iOS UI parity — inventory, audits and deliberate gaps

**Status, 2026-08-21.** The flight map, Application Settings, Receiver Settings,
Locator Settings, **Flight Profiles** and **Download maps** are ported. Everything up to
Locator Settings has been exercised on hardware; the two newest screens have been driven
on the simulator only — though Download maps has downloaded a real region there, which is
the half of it that could not be faked. **Deployment Test is the last screen.** The
flight-data transfer layer landed with Flight Profiles, which also unblocks the
archived-path map control (still to build).

**How to use this file.** The audits below are the record of what was compared against
Android and what was found — read the one for the screen you are about to touch before
writing anything, rather than re-deriving it. The **deliberate divergences** are listed
with what would close each one; there are only six, and every other difference found in
this port was a defect.

**The six deliberate divergences:**

| Divergence | Why | Closes when |
|---|---|---|
| No launch-detect altitude / deploy-signal duration controls in Locator Settings | Neither field rides in a broadcast, so a change can never be confirmed — on Android editing either reports "not acknowledged" while the locator has accepted it | the firmware carries both fields in a broadcast (three binaries, wants an ADR) |
| Icon substitutions in the map control column | Android's are Compose `Icons.Default.*`, a library with nothing to convert | never — the mapping is recorded below |
| No archived-path map control | Android offers it only once a record is downloaded | **now unblocked** — flight-data download landed 2026-08-21; the control itself is still to build |
| Flight-profile chart constants converted at a 3.0 display density | Android draws the chart in raw **pixels** (`CHART_MARGIN_X = 64f`, `textSize = 32f`), so its apparent size changes with the phone; SwiftUI's Canvas works in points | never exactly — see the chart audit below. A side-by-side screenshot would settle whether 3.0 is the right divisor |
| Download maps uses SwiftUI's `Menu` and `Slider` where Android uses `DropdownMenu` and a Material `Slider`, and an SF Symbol for the delete icon | ADR-0016's sanctioned list covers pickers and sliders outright; the delete glyph is a Compose `Icons.Filled.Delete`, a library with nothing to convert, so `trash` stands in as the map-column icons do | never — `trash` is pinned in `SFSymbolAvailabilityTests` like the rest |
| Chart legend checkboxes are SF Symbols, not a Material `Checkbox` | ADR-0016 sanctioned departure: a Material checkbox clone next to iOS type reads as broken, and `checkmark.square.fill` / `square` carry the same two states in the same two colours | never |

Everything else on these screens matches Android, including field order, widget shapes,
wording and type weights. **Silence reads as parity**, so a divergence that is not written
here will be read as a defect by the next person — correctly.



**Standing instruction (2026-08-19, fschroer):** the iOS app should mirror the Android
app in **both functionality and UI presentation**, except where a specific iOS design
rule should take precedence.

> **Resolved (2026-08-19):** ADR-0016 was amended to say this itself. The bar is now
> stated there as a test — **one user manual serves both platforms** — with six
> sanctioned iOS departures listed. Anything not on that list mirrors Android. This
> page is no longer in tension with the ADR; it is the inventory that ADR points to.

**Restated (2026-08-20, fschroer)** after four map defects that all came from assuming
rather than reading: *fully review the Android code, do not assume the functionality.*
That is now a standing rule at the top of this repo's `CLAUDE.md` Parity rules.

## Where iOS actually stands

The **link and identity layer is complete and hardware-confirmed**: wire format, auth,
framing, transport, health watchdog, recognition gate, password challenge, broadcast
decode, distance/bearing plausibility, compass trust, and a live MapLibre map.

The **UI is not a mirror of Android's — it is a bring-up harness.** Three tabs (Flight,
Map, Link) against Android's seven screens behind a navigation drawer. Honest summary:
roughly the whole presentation layer is outstanding.

## Inventory

Android UI is ~11,700 lines across `ui/`. By screen:

| Android screen | Lines | iOS today |
|---|---:|---|
| `FlightMapScreen` (Start) | 3,370 | partial — map + basic stats, none of the instrumentation |
| `FlightProfilesScreen` | 1,002 | **present** (`FlightProfilesView` + `FlightChart` + `FlightDataRepository`), 2026-08-21 — not yet exercised on hardware |
| `LocatorSettingsScreen` | 759 | absent |
| `DownloadMapScreen` | 677 | **present** (`DownloadMapView` + `Maps/`), 2026-08-21 — a real region downloaded on the simulator |
| `ReceiverSettingsScreen` | 463 | absent |
| `AppSettingsScreen` | 202 | absent |
| `DeploymentTest` | 160 | absent |
| `ExportFlightPathScreen` | — | absent |
| `LocatorPasswordDialog` | 139 | **present** (`PasswordChallengeView`) |
| `DevicePickerDialog` | 103 | absent — iOS auto-connects to the first FFE0 peripheral |
| `MapLibreCompat` | 1,042 | partial (`FlightMapView`) |

### Main screen elements not yet on iOS

From `FlightMapScreen.kt`: navigation drawer; `MapControlsColumn`; `LocatorStats` panel;
`drawVelocityGauge`; `drawRocket3D` (3D attitude render); `GenericScaleBar`;
`LinkQualityNote` with `rssiColor`/`snrColor` bands; `CameraPreviewScreen` (the AR
"point at the sky" view); `PulsingText` / `BlinkingText` alert treatments;
`FlightSpeechAnnouncer`; `ExitAppButton`; heading-up map rotation with smoothing;
auto-zoom and auto-centre with deadbands; tilt from device pitch; keep-screen-on.

### Theme and type

| | Android | iOS today |
|---|---|---|
| Colour | Material 3 scheme, dark `#141312` bg, `#E6E2DF` fg, primary `#CCC6B7`, secondary `#B4C6F2`, tertiary `#DCC48D`, error `#FFB4AB` | SwiftUI defaults, forced dark |
| Body font | **Poppins** | system |
| Display font | **Roboto** | system |
| Telemetry font | **Roboto Mono** | system monospaced |

The three font families ship as `.ttf` in `res/font/` and can be bundled on iOS
unchanged, which is the cheapest large step toward "looks like the same app".

## Flight map — line-by-line audit against `FlightMapScreen.kt` (2026-08-20)

Prompted by four defects reported from the phone, all four of which came from
**assuming** what the Android map did instead of reading it. What follows is the whole
comparison, including the parts not yet fixed, so the next pass starts from a list
rather than from a fresh guess.

**Naming trap, worth knowing before reading either file:** Android's `MapControlsColumn`
is the *status panel* (receiver/locator/RSSI rows plus the action dropdown), which iOS
calls `MapStatusPanel`. The control buttons Android draws are an unnamed `Column`
inside `MapWithOverlays`. iOS's `MapControlsColumn` is that unnamed column. The two
files use the same name for different things.

### Fixed in this pass

| # | Gap | Android | iOS before |
|---|---|---|---|
| 1 | auto-zoom default | `mutableStateOf(true)` | `false` |
| 2 | magnetic-orientation default | `mutableStateOf(true)` | `false` |
| 3 | record-track control | `FiberManualRecord`/`Stop`, red while recording | absent |
| 4 | reset-track control | `RestartAlt`, always full white | absent |
| 5 | auto-centre icon | `MyLocation`, a crosshair | `location.circle`, an arrow |
| 6 | gesture backoff | auto-camera returns early while `userGestureRecent` (5 s) | none — every camera write raced the finger |
| 7 | control tap cancels the backoff | `LaunchedEffect(...) { lastUserGestureTime = 0 }` | n/a |
| 8 | rotate/zoom/scroll gestures | set explicitly in `uiSettings` | left to SDK defaults (same values, but unstated) |

Items 6 and 7 are one fix, and they were reported as three separate bugs: the map
wandering under a pinch, panning that snapped back, and rotation springing back with
magnetic orientation on. `applyCamera` runs from `updateUIView`, and reporting the live
camera back into SwiftUI state re-renders the view — so each gesture frame invited a
camera write on top of the finger.

### The nine gaps — closed 2026-08-20

Seven were implemented; two needed no code, for reasons Android itself supplies.

| # | Gap | What landed |
|---|---|---|
| 1 | No camera filter | `CameraFilter` — Android's per-frame Kalman over target/zoom/tilt, gains .1/.05/.05 unchanged, driven by a `CADisplayLink` |
| 2 | Auto-zoom did nothing | The toggle now drives the fit, bounded by the App Settings closest-zoom limit **on the filter only**, so pinch stays unbounded |
| 3 | No anchor/deadband on auto-centre | `recenterDeadbandM` + `viewportLimitedDeadbandM`, latched anchor, re-latched only past the combined GPS error |
| 4 | Auto-centre targeted the rocket alone | Now a north-up, flat bounds fit over rocket AND phone, falling back to the rocket when the phone has no fix |
| 5 | Track not persisted | `TrackStore` — same `flight_path.csv` name and CSV shape as Android's, legacy three-column rows included |
| 6 | No landing freeze | `TrackRecording` + `TrackRecorder`: nothing recorded on the pad, the two fixes that end a flight still drawn, then frozen |
| 8 | No one-shot initial centre | Centres on the phone at z12 once, while the rocket has no fix. **Confirmed on the simulator** — the map used to open on null island |

**7 — archived-path control: still correctly absent.** Android offers it only when a
downloaded record exists, and flight-data download is not ported. Building the button
now would be a control with nothing to toggle. It becomes a real gap the moment
ADR-0009 lands, and is noted in the outstanding list against that item.

**9 — `showControls`: no action, and none wanted.** It is dead state on Android —
toggled by a map tap and never read — so the control column is always visible there,
which is what iOS already does. Recorded so nobody "restores" a behaviour Android does
not have.

### Found while implementing, and fixed

**The track was thinned by distance, and should not have been.** iOS dropped fixes
closer than 2 m to the last one, to stop GPS noise scribbling on the pad. Android solves
that a different way — `recordsPathPoint` records **nothing** before launch — and its own
`PathDedupTest` warns explicitly against the distance rule, because what it silently
swallows is real slow movement, "which is what a descent under canopy looks like". With
the landing freeze ported, the 2 m rule was both redundant and harmful; it is now
Android's exact-repeat rule, which exists to drop the ~5 repeated frames per fix that
5 Hz transmission of a 1 Hz payload produces.

### Third round, 2026-08-20 — three more from the phone

All three were overlays, and the audit above had not covered overlays: it compared the
control column and the camera, and stopped there. Recorded because the lesson is about
the audit, not the code — **a partial audit reads exactly like a complete one.**

| Observation | Cause | Fix |
|---|---|---|
| Rotation "very jerky" | Bearing was NOT filtered — my own decision, recorded below as a judgement to revisit | `CameraFilter.gainBearing` = .01, Android's value, with the ±540 shortest-turn wrap |
| No "Disarmed" banner | The centre banner had never been ported | `FlightBanner` + `PulsingText` |
| No escalated pad warning | Same banner, plus the snooze control | Banner escalation + a snooze button in the status dropdown |

**On the bearing, I was wrong and it is worth saying how.** The previous pass skipped
Android's bearing Kalman on the reasoning that CoreLocation already smooths
`trueHeading` and ADR-0023's trust hold gates it, so a second filter would only add lag.
The reasoning confused two different things: CoreLocation smooths the *value*, but
delivers it in discrete updates a few times a second, while the camera is written every
display frame. Holding a bearing for ~20 frames and then stepping it **is** the jerk.
Android's gain of .01 crosses most of a step in under a second.

**On the pad alert — it is not computed here, and must not be.** The locator decides,
using deployment-channel continuity, the configured primary axis and its own attitude
(ADR-0021, firmware), and sends the verdict as one byte. The app's whole job is to
display it and offer the snooze. The wire decode already existed and was correct
(`PadAlertState`, `padAlertSnoozeMinutes`, `padAlertSnoozeRequest`); only the UI was
missing, which is why this looked like a missing feature rather than a missing field.

The snooze is **locator-directed** and carries a target (ADR-0020), matching Android's
`sendMessage` routing — a snooze is a state change on one rocket, and broadcasting it
would quiet every locator on the channel. The app asks for one 5-minute step; the
locator accumulates and clamps to its own 15-minute ceiling. Nothing app-side may make a
snooze indefinite: that would be an off switch, and hands back the forgotten arm the
alert exists to catch.

**One thing to check side by side with Android.** The escalated banner is `displayLarge`
(57 pt on both, Material's baseline) and its two-line text wraps to five lines on a
402 pt iPhone, running under the control column. Android composes it identically on a
411 dp reference phone, so this is believed faithful rather than an iOS defect — but
"believed faithful" on a legibility question is exactly what a screenshot comparison is
for, and neither of us has looked at the two together.

### Fourth round, 2026-08-20 — three more from the phone

| Observation | Cause | Fix |
|---|---|---|
| Compass button greyed out at startup under magnetic interference | iOS disabled the CONTROL on ADR-0023 trust | Control is never disabled; trust still suppresses the bearing |
| Banners in the wrong font | `SPFont.displayLarge` used Roboto-**Bold** | Material's baseline display styles are `FontWeight.Normal` → Roboto-Regular |
| No choice offered with two receivers | `startScan` reconnected to a remembered peripheral and skipped the scan | Auto-reconnect removed; 3 s scan window then always offer the list |

**The compass control.** Android applies `compassUsable` to `bearingValid` and nowhere
near the button — the button is never disabled, and its tint follows `compassEnabled`
alone. Disabling it makes a different claim than intended: it says the MODE is
unavailable, when what is unavailable is this moment's heading. Magnetic interference at
startup is ordinary and passes, and a control that arrives dead reads as a broken app.
What tells the user the compass is doubted is the calibration mark on the rose — where
the doubted bearing is visible. The ADR-0023 suppression is unchanged and still applied
in `MapScreen`.

**The font.** Android builds its type scale as
`baseline.displayLarge.copy(fontFamily = displayFontFamily)` — it swaps the family and
keeps Material 3's baseline weight, which for the display styles is `Normal`. iOS had
`displayLarge` and `displayMedium` on Roboto-Bold, so every banner rendered heavier than
Android's. **Not verified locally:** this Mac has no Gradle cache, so the M3 baseline
table could not be read off disk; the weights are taken from the M3 type scale.
`titleMedium` / `titleSmall` are a separate question — their baseline weight is Medium
(W500) and only Regular and Bold are bundled, so what Compose actually resolves them to
wants checking on the Android box before anything here changes. Line height and letter
spacing are likewise unported.

**The receiver picker.** `startScan` preferred a direct reconnect to the last-used
`peripheral.identifier`, so the scan never ran and the second receiver was never seen.
Android has no such path: it scans for `SCAN_DURATION_MS` (3 s), then emits
`DevicesFound` with everything heard and always raises the picker — for one device as
well as two. iOS now does the same, and reports once when the window closes rather than
per device, so a receiver that advertises late still makes the list instead of appearing
under the user's thumb. The persisted identifier is gone entirely: it existed only for
the auto-reconnect, and a stored id nothing reads is a trap.

Found while doing it: **nothing ever set `TransportState.noDevicesFound`.** It had a
label on two screens and no producer, so an empty scan left the app saying "Scanning"
for ever — the one thing it had finished doing. The window now sets it, as Android emits
`NoDevicesAvailable`.

### Fifth round, 2026-08-20 — map rotation under interference, and the silent app

**The map stopped rotating under magnetic interference, and should not have.** iOS
withheld the camera heading whenever compass trust was `unreliable`. That test belongs
to two other things and not to this one:

- ADR-0023 **Decision 5** suppresses the **AR overlay** at `UNRELIABLE`, via ADR-0022's
  mechanism. iOS still does that, in `updateVector`, and it is unchanged.
- ADR-0023 **Decision 6** describes the map orientation "visibly correcting itself
  mid-gesture" during the figure-eight repair — which it cannot do if interference has
  frozen it. The map is an orientation aid, not a quoted figure, and the rose's
  calibration mark is what says the heading is doubted.
- Android agrees: its camera bearing is `hasCompass && compassEnabled`, with accuracy
  nowhere in it. `compassUsable` reaches `bearingValid` only.

**The pad alert had no voice and no haptic — and neither did anything else.**
`AppSettings.voiceEnabled` / `voiceIdentifier` were written by the settings screen and
read by nothing, so the app was silent everywhere. That is why a missing pad-alert
callout looked like a fault in that alert rather than the absence of the feature.

Now present:

| | Android | here |
|---|---|---|
| Speech engine | one shared `TextToSpeech`, `QUEUE_FLUSH` for urgent lines | `FlightSpeech` over `AVSpeechSynthesizer`, `.urgent` stops the current utterance |
| Pad-alert voice | rising edge then every 30 s while alerting; never while snoozed | same, `PadAlertAnnouncer` |
| Pad-alert haptic | 260 ms / 140 ms / 260 ms / 2.4 s waveform, looping | same cycle via `CHHapticAdvancedPatternPlayer`, with a two-tap fallback where there is no haptic engine |
| Arm/disarm | spoken on every change | same |

**One iOS-specific decision worth knowing: the audio session is `.playback`.** The
default category obeys the ring/silent switch, so on a phone with the switch flipped —
which is most phones at a launch — every callout would be generated, mixed, and thrown
away. Android's TTS goes out on `STREAM_MUSIC`, which ringer mute does not touch, so
obeying the switch would also be a divergence in the one direction that matters. Ducking
rather than interrupting, so someone's music drops under the callout.

The haptic is deliberately **not** gated on the speech setting: someone who turned
speech off is more reliant on it, not less. It is also the only channel that survives a
muted phone in a pocket on a loud flight line.

**Still not ported: the flight callouts.** `FlightSpeechAnnouncer` (~320 lines) carries
ascent, descent, apogee, landing prediction and link-loss announcements, with the
ADR-0022 rule that a withheld distance means SILENCE rather than a stale number read
aloud. The engine now exists for it; the announcer does not.

### Sixth round, 2026-08-20 — the half-restored receiver, and the voice list

**A receiver that connected itself, greyed out, and would not arm — one cause.**
`willRestoreState` adopted the peripheral iOS handed back and set the state to
`connected`, and then did nothing else. Restoration returns the CONNECTION, not the
GATT session on top of it: `didConnect` is not called for a peripheral that is already
connected, so services were never discovered, the characteristics never resolved and
notifications never subscribed. `state` therefore stopped at `.connected` and never
reached `.ready` — which is what the grey icon means, what gates the receiver menu, and
what `canSendArmCommand` requires. A manual rescan fixed it because that path runs
`didConnect` properly.

Everything else in the report follows from the same thing:

- **"Only one of two receivers is listed."** A connected peripheral does not answer a
  scan, so the receiver the app was actually holding was the one missing. The scan now
  seeds its list from `retrieveConnectedPeripherals(withServices:)`, so an already-held
  receiver is offered alongside the ones still advertising.
- **"Cancelling connects the one that wasn't listed."** Nothing connected on cancel —
  the restored link had been there all along, invisible and half-alive.
- **Choosing the other receiver** now cancels the previous connection first. Without
  that the old one stayed connected but un-referenced, holding its `bluetoothd` session
  and keeping itself out of every later scan.

Also hardened: `startScan` ignores a duplicate call while a window is open, as Android
does. It is reached twice at launch — from `centralManagerDidUpdateState` and from the
view appearing — and restarting the window discarded whatever the first had found,
which is a plausible second contributor to the one-of-two symptom.

**The voice list.** Two iOS-only problems, neither of which Android has:

1. **Novelty voices.** Apple ships Bubbles, Bells, Boing, Zarvox and a dozen more
   alongside the real ones; Android's engine offers none, so it never needed a filter.
   Filtered now — by `voiceTraits.isNoveltyVoice` on iOS 17+, and by an identifier list
   on 16, which is the deployment target.

   The list was enumerated from the device, and that mattered twice. **Names are not
   stable**: Jester ships as `…voice.Hysterical`, Superstar as `…voice.Princess`,
   Wobble as `…voice.Deranged`. And the tempting shortcut of excluding the legacy
   `com.apple.speech.synthesis.voice.` prefix is **wrong** — Fred, Junior, Kathy and
   Ralph share it and Apple does not class them as novelty, so that rule would have
   quietly removed four ordinary voices. Both halves are pinned by tests.
2. **The wheel snapped back.** A `Picker` in a Form presents a wheel, and a wheel always
   re-centres on the current selection, so anything far from the current choice was hard
   to reach. Replaced with a pushed checkmark list — the iOS pattern for a long
   single-choice list, and it stays where it is scrolled. **Confirmed on the simulator.**

### Seventh round, 2026-08-20 — the escalation that would not clear

**Arming while the pad alert was up left the escalated banner on screen; disarming
cleared it.** Backwards, and the inversion is the diagnosis: the locator stops
broadcasting `PreLaunchData` the moment it is armed and sends `TelemetryData` instead.
The banner read `model.prelaunch?.padAlert`, so arming froze the last pre-launch value —
`alerting` — and it stayed frozen. Disarming resumed `PreLaunchData`, which finally
overwrote it. The app was not reacting to the arm at all; it was showing a photograph.

Android clears it explicitly and says why:

> `TelemetryData` carries no `pad_alert` — it is an on-pad condition and this message
> means armed or in flight. Cleared explicitly because `PreLaunchData` stops arriving at
> that point, so a set flag would otherwise latch on stale data and keep warning through
> the whole flight.

iOS now holds `padAlert` and `padAlertSnoozeMinutes` as their own state on the view
model, written by BOTH branches — set from pre-launch, cleared by telemetry — rather
than read off the last `prelaunch` object. That makes the stale reading impossible
rather than merely unlikely.

**The same defect was sitting on the batteries.** They are pre-launch-only fields too,
read straight off `prelaunch` with no freshness test, so they would have shown the
charge from before the flight for the whole flight. Android ages them on a separate
`lastPreLaunchDataTime` clock precisely for this, with the note that "nothing beats a
stale battery reading for being quietly wrong". iOS now has `lastPreLaunchMessage` /
`isPreLaunchFresh` and hides the icons once they go stale.

**The general rule, worth applying to anything added later:** a field carried only by
`PreLaunchData` must never be read from the last-seen object. Either give it its own
state written by both branches, or age it on `isPreLaunchFresh`. Names are the
exception and deliberately so — a receiver does not rename itself mid-flight, and
Android keeps showing them too.

**Not unit-tested, and honestly so.** Pinning this needs a frame fed through `ingest`,
which sits behind the ADR-0006 recognition gate and its auth tag, so the test would
mostly be exercising authentication and would fail for reasons that have nothing to do
with pad alerts. The rule is recorded at both call sites instead. If a seam for
injecting decoded broadcasts is ever added for other reasons, this is the first thing
that should use it.

### Eighth round, 2026-08-20 — continuity that needed an app restart

**Deployment channels showed no continuity when a channel had it; restarting fixed it.**
"Restarting fixes it" is the tell for a latched value, and this is the MIRROR of the
seventh round: there, stale pre-launch shadowed fresh telemetry. Here, stale telemetry
shadows fresh pre-launch.

The view read `t?.deployChannelContinuity ?? p?.deployChannelContinuity` — *telemetry if
we have any*. But `telemetry` is never nil again once a flight has happened, and the
locator goes back to broadcasting `PreLaunchData` on **every disarm and after every
landing**. So the last in-flight continuity won for the rest of the session, and only a
restart cleared it.

**Android's rule is newest-wins, not telemetry-first.** It merges both messages into one
`rocketState`, so whichever arrived last owns every field it carries. iOS keeps the two
decoded messages side by side, so the same rule has to be applied where they are read —
`LinkViewModel.newest(_:_:)` now does that, and the accessors go through it.

The same `t ?? p` pattern was on **position, GPS accuracy, satellites, GPS status, RSSI,
SNR, AGL and the tilt ramp's altitude** — all latching the same way. Position is the one
that would have mattered most: after a landing the map marker would have sat at the last
in-flight fix instead of where the rocket actually is, which is the one number the whole
app exists to give.

**Three categories, and every field belongs to exactly one:**

| Carried by | Rule | Examples |
|---|---|---|
| both broadcasts | **newest wins** (`newest(_:_:)`) | position, accuracy, satellites, GPS status, RSSI, SNR, AGL, deployment continuity, armed |
| telemetry only | read from `telemetry`, keeps its last value | flight state, velocity, attitude — Android's pre-launch branch does not write them either, so a landed rocket goes on reading Landed |
| pre-launch only | age on `isPreLaunchFresh`, or clear explicitly | batteries, pad alert; device and receiver names are the deliberate exception |

Getting the category wrong is silent in both directions, and both directions have now
been reported from the phone within a day of each other.

### Ninth round, 2026-08-21 — two words on the stats panel

Both reported off the phone, both in `LocatorStats`, and both the same mistake: the row
was built from what the app knows rather than from what Android writes.

| Gap | Android | iOS before |
|---|---|---|
| Withheld distance | `dst` is a value **or** the word: `"%15d" + " m"`, else `stringResource(R.string.unknown)` = `Unknown`. No padding, no unit | `Dist:         unknown m` — padded and given a unit, so a refusal to quote a distance read as a distance in metres |
| Flight state | maps every state to display text by hand: `WaitingLaunch -> "Waiting For Launch"`, `DroguePrimaryEvent -> "Drogue Primary"`, `else -> ""` | `"\(flightState)"` — the Swift case name, so the panel said `droguePrimaryEvent` |

The flight state is where the standing note **"enum labels are Android's case names"**
misleads: that rule comes from the settings dropdowns, where Android renders
`enumValue.name`. `LocatorStats` does not — it writes the words out. The rule was
followed instead of the code, which is the same failure mode as assuming a default.

`noSignal` renders as **nothing**, matching Android's `else -> ""`. It is not a state the
locator reports; it is this app's fallback for a state byte it does not recognise, and
naming it would tell the user the rocket is in a condition the rocket never claimed.

Both are pinned by `LocatorStatsRowsTests`, including a case that fails if any label is
ever the Swift case name again.

### Receiver Settings — protocol layer and form (2026-08-20)

Staged deliberately: the three parsers and the ranking model first, then the form.

**The blocker was protocol, not UI.** iOS had the `MsgType` values and framing sizes for
`receiverInfo`, `versionInfo` and `channelSurvey` but no parsers and no ranking model,
so nothing on the screen could show real data. Offsets came from the RECEIVER firmware
header, not the Kotlin. No triad change was needed — every size was already pinned by
the 2026-08-17 session.

**The polled noise floor now reaches the classifier**, which closes an ADR-0019 gap
rather than just serving this screen: `ReceiverInfo` is the only message the receiver
sends on its own behalf, so its floor is the sole channel measurement available during
locator silence — exactly when "something is on our channel" and "the locator is off"
are hardest to separate. Three things had to come with it, and none is guessable:

1. **Its own baseline.** Polled readings come from continuous sampling and read higher
   than the safe-window figure a broadcast carries. One shared minimum-keeping baseline
   pins itself at the broadcast value and makes every polled reading afterwards look
   elevated — permanently.
2. **The absolute floor test is dropped for a polled reading.** `busyFloorDbm` is
   calibrated for the safe-window statistic; a continuous peak clears it on a channel
   with nothing on it.
3. **A liveness tick and a poll during silence.** Without the tick nothing recomputes
   when no packet arrives, so a link that simply stopped kept asserting the last
   packet's verdict. Without the poll the floor is expired most of its life — the
   ADR-0012 watchdog's ~10 s is far longer than the 3 s freshness window — and the note
   blinks between probes. Android's cadences: liveness 500 ms, poll 2 s, silence
   threshold 5 s (deliberately longer than `lossyGap`, because polling through routine
   gaps drains the receiver's peak-since-last-report and shortens the window for the
   broadcast that follows).

**Form.** Staged edits, never live, with the Update button reporting what the receiver
said — a config change that silently did nothing is indistinguishable from one that
never arrived. Confirmation compares the **channel only**: the receiver echoes its
channel in `PreLaunchData` but never its name, so the name is accepted optimistically
once the channel matches. Waiting for a value that never arrives would report every
successful rename as unacknowledged.

Two details worth keeping:

- The receiver's channel and name are read from `PreLaunchData` **outside** the ADR-0006
  recognition gate. They describe the user's own receiver, not the locator that carried
  them, and gating them would leave this screen blank in the case it is most needed — an
  unrecognised locator on the channel you are trying to move off.
- **A "Revert" button was drafted and removed.** Android pairs Update with "Return to
  main", which on iOS is the sheet's own Done. Adding a second control Android does not
  have is how the two apps stop needing the same manual.

**Channel survey section — landed.** Android's wording verbatim, because most of it
explains a measurement rather than labelling a control, and an explanation that differs
between the two apps is one the manual has to write twice.

The bars are **relative to this sweep** and deliberately carry no dBm: SX126x RSSI near
the floor is uncalibrated, so an absolute number would be a precision the reading does
not have. `Result.relativeLevel` floors the span at 1 dB — a genuinely flat band is the
uniform-floor case and therefore common on a bench, and without the floor every bar
would render as NaN.

A 15 s timeout turns silence into a stated failure. A receiver whose firmware predates
channel scanning never answers at all, so without it the button reads "Scanning…"
for ever.

**The "Move here" action is withheld while a locator is connected, and says so.** With
one connected, picking a channel has to move the WHOLE system — Android calls
`moveLocatorToChannel`, which retunes the locator and lets the receiver follow. Staging
the receiver-only half instead would point the receiver at an empty channel and strand
the locator on the old one (ADR-0011 invariant 1 vs 5). That move needs Locator
Settings, which is not ported, so the choice is withheld with an explanation rather than
quietly doing the damaging half of it. With no locator connected there is nothing to
strand, and "point receiver" is the legitimate go-look-at-that-channel case.

**Channel move — landed (ADR-0011).** "Move here" now retunes the whole system. The
request goes out on the OLD channel, the locator applies it at runtime, its next
broadcast returns on the NEW one, and the receiver follows only after its forward has
finished transmitting. There is no acknowledgement message: **confirmation is the
resumption of broadcasts carrying the new channel** (invariant 3), tested as
whole-object equality against a config rebuilt from that broadcast.

Recovery is ported too, and it is the part that matters. If the locator never appears on
the new channel it most likely missed the LoRa command while the receiver — which
forwarded it — already followed. The link is split, and the user cannot fix that from
the app because the locator is out of reach by definition. So the receiver is pulled
back over BLE, which is always reachable, and the change retried once before reporting
"not acknowledged" (invariant 4). Recovery is skipped when the BLE send itself failed:
nothing was transmitted, so nothing moved.

The progress row states every stage, because the cycle legitimately runs for several
seconds with the link DOWN and silence through that reads as a hang.

### ⚠️ A locator config change writes two fields the app cannot read

`LocatorCfgChgRequest` carries the WHOLE `LocatorRocketSettings`, but `PreLaunchData`
carries neither `launch_detect_altitude` nor `deploy_signal_duration` — so the app has
no way to learn what the locator actually holds, and **every config change, including a
pure channel move, writes them.**

Android has the same behaviour with the same two constants, 30 m and 1.0 s, and a
`// To do: remove from UI` beside them. iOS must use the identical values, and not
merely for parity: confirmation is whole-object equality against a config rebuilt from
the next broadcast using the same placeholders, so a different value would never compare
equal and every change would report as unacknowledged.

They are the firmware defaults, so on an unmodified locator this is a no-op. On one
whose values were changed over the USB console, a channel move silently restores them —
and `deploy_signal_duration` is pyro firing time. Fixing it properly means carrying both
fields in a broadcast, which is a firmware change across three binaries and belongs in
an ADR. **Recorded here rather than fixed, because it is a system decision, not an iOS
one.**

**Conflicting-locator banner — landed (ADR-0006).** Non-blocking on purpose: it is a
fact about the channel, not a modal decision, and its two actions are the point —
switch to it, or move to an uncontested channel using the survey directly below.

Two framings, because there are two situations and only one is a problem. Already
connected to a DIFFERENT locator: genuine conflicting traffic, worded as a warning and
coloured with the error tone. Not connected at all: simply a new locator to connect to,
so the wording invites.

Two rules make it usable rather than merely present, and neither is visible from the
feature description:

- **An 8 s hold.** With two locators on one channel the broadcasts INTERLEAVE, so
  clearing the banner whenever our own locator is heard made it flash on and off at the
  broadcast rate — visible, but gone again before Connect could be pressed. It clears
  when the named locator is itself accepted, or once it has been quiet for the hold.
- **Dismiss is remembered.** The conflicting locator keeps broadcasting at 1 Hz, so
  clearing the id alone put the banner back on the next packet and Dismiss did nothing
  at all. Re-entering the screen clears the dismissals, because that is the user asking
  to see conflicts again.

Connect only acts on a frame from THAT locator. Armed locators raise conflicts too, and
an armed stranger carries no identity to check a password against — verifying one
against another locator's tag is meaningless at best and a false accept at worst. It
switches when the frame authorises, and raises the password challenge when it does not.

The single `conflictLocatorId` sits alongside the existing `conflictingLocatorIds` set
rather than replacing it: the banner offers an ACTION and an action needs one subject,
while the diagnostics screen lists everything audible, which is a different question.

**Receiver Settings is complete.**

### Locator Settings — landed, minus two controls on purpose

Four deployment channels, each a mode picker plus **only** the numeric field its
selected mode needs; locator name, LoRa channel, mounting axis, firmware version, and
the staged Update row.

**The limits are interlocked, and that is the safety-relevant part.** A drogue backup
must fire AFTER its primary and a main backup BELOW its primary, so each bound is
derived from the other value rather than from a constant — it is the only thing stopping
a backup being configured to fire first. Pinned by `DeploymentLimitsTests`, including
the degenerate ends: an unconfigured locator reports zeros, and a `ClosedRange` with
lower > upper traps at construction in Swift, so an inverted bound would crash the
screen rather than merely misbehave.

### ⚠️ Launch-detect altitude and deploy-signal duration are NOT offered here

Android shows both. **On Android, editing either can never succeed**, and the chain is
worth stating because it is not obvious from any one place:

1. Both are editable on that screen.
2. Neither rides in `PreLaunchData`, so `remoteLocatorConfig` is rebuilt from every
   broadcast with hardcoded 30 and 10.
3. Confirmation is whole-object equality against that rebuilt config, and Android's
   `LocatorConfig` is a `data class`, so both fields count.

Set launch-detect altitude to 50 and press Update: the locator receives and saves it,
the comparison never matches, the app reports **"Update not acknowledged"**, and the
display reverts to 30 m on the next broadcast. The change took effect; the app says it
failed and shows the old value. That is why `// To do: remove from UI` sits beside both
constants.

**Decision (fschroer, 2026-08-20): omit both controls on iOS.** A control that can never
report success is worse than an absent one, and this is what the Android TODO intends.
The placeholder VALUES stay in `LocatorConfig`, because the confirmation comparison needs
them to match — omitting the controls is in fact what makes every other field on this
screen confirmable.

This is a **deliberate, explained divergence from Android's UI**, and the only one on
these screens. It closes when the firmware carries both fields in a broadcast, which is
a change across three binaries and wants an ADR. `DeploymentLimitsTests` fails first if a
control for either reappears.

### The settings-screen widgets — rebuilt to match Android (2026-08-20)

Reported: "text entry areas appear as labels, so it's not apparent that they are
editable" and "numeric entry fields can't be edited directly."

Both true, and the cause is the same one as the map round: **the first pass was written
in SwiftUI idiom instead of read off Android's widgets.** A grouped `Form` of `TextField`
and `Stepper` rows renders as a list of LABELS — nothing shows a value is editable, and a
number can only be nudged, never typed.

Android uses `ConfigurationItemText` and `ConfigurationItemNumeric`, which are a Material
`OutlinedTextField` — a bordered box with the label floated onto the border — with, for
numerics, two stacked nudge arrows beside it. Both affordances are present at once:
type it, or step it.

Ported now, in `ConfigRows.swift`:

| Android | here |
|---|---|
| `OutlinedTextField` with floating `label` | `OutlinedFieldChrome` — same bordered box, label cut into the border |
| directly editable, number keypad, Done | same, `.numberPad` / `.decimalPad` |
| coerce to min/max in `onFocusChanged` | same, on focus loss |
| `onValueChange` fires per keystroke | same — it is what lights the Update button as you type |
| two stacked `NudgeButton`s | `NudgeColumn`, same chevrons, same enable-at-bounds |
| hold-to-repeat, 500 ms → 100 ms, decay .25 | same constants |
| `ExposedDropdownMenuBox` | `ConfigPickerRow`, read-only field + chevron + menu |
| grouped scroll with the action row pinned below | same — `ScrollView` + pinned button, not a `Form` |

**Two rules worth keeping straight**, because they pull in opposite directions and both
came from Android's own handling:

- **Report every keystroke.** The Update button has to light as you type; a user who
  types a value and finds Update dead has no way to know why.
- **Coerce only on commit.** Clamping per keystroke makes a field impossible to clear
  and fights every intermediate value — typing "15" into a field with a minimum of 10
  would rewrite the "1" to "10" before the "5" arrived.

**Enum labels are Android's case names** — `DroguePrimary`, not "Drogue Primary". Android
renders `enumValue.name`, and that is the string the manual has to name; prettier spacing
here would be a second vocabulary.

**On ADR-0016's sanctioned departure.** That ADR permits "SwiftUI switches, pickers and
steppers rather than Material clones", and this is not an exception to it: the departure
covers controls that look BROKEN when imitated. A bordered, labelled text box is not one
— it is the ordinary way to show an editable value on either platform, and here it was
also the fix for a real usability defect. The sanctioned list is not a licence to reach
for a different control whenever one is handier.

### Fonts: nothing in this app is bold except one glyph

Reported as "more examples of bolded text where it should not be". The rule turns out
to be checkable, and it is stronger than "use the right weight per style":

1. Android's `AppTypography` copies Material 3's baseline and swaps ONLY the family —
   `baseline.titleMedium.copy(fontFamily = ...)` — so every weight comes from the M3
   type scale, which specifies Regular or Medium and never Bold.
2. Each family registers only Regular and Bold:
   `FontFamily(Font(roboto_regular), Font(roboto_bold, FontWeight.Bold))`. Compose
   resolves a Medium (W500) request by the CSS rule — for a desired weight of 400…500
   it prefers the nearest weight at or below 500 — which is **W400**. So `titleMedium`,
   `titleSmall` and every `label*` style render REGULAR on Android, despite reading as
   Medium in the scale.

Net: **the only bold text in the entire Android app is the "∞" compass-calibration
glyph**, which sets `FontWeight.Bold` explicitly at its call site. `grep -rn
"FontWeight.Bold"` over `app/src/main/java` returns four hits — three are the family
registrations, one is that glyph.

iOS had bold on `titleMedium`, `titleSmall`, `labelLarge`, `labelMedium`, `labelSmall`
and a `telemetryBold` used by the heads-up gauges. All now Regular. `TelemetryTextStyle`
is `FontWeight.Medium` on a mono family with no Medium, so it resolves to
RobotoMono-Regular too — every number on the stats panel and gauges included.

This was a steady drift of "this looks like a heading, headings are bold" rather than a
single mistake, which is why it needed a rule rather than another patch. **If something
looks like it wants emphasis, the answer is not weight** — Android reaches for size and
colour, and the type scale already encodes that.

`LinkView` is exempt and stays on system fonts: it is the bring-up diagnostics screen
with no Android counterpart.

### The channel survey is put away once a channel is picked

Reported: the "find a clean channel" information does not disappear on a successful
switch. Android calls `clearChannelSurvey()` on **both** branches of the pick.

The ranking describes the band BEFORE the move, so leaving it up next to a "now on
channel N" message invites a second pick against a picture that is out of date — and on
the receiver-only path, the channel it recommended has already been taken. Starting a
fresh sweep clears it too, so the previous ranking cannot sit there looking current
while the new one runs.

### Locator Settings field order is Android's, and it is not the obvious one

Reported: the order differs from Android. It did — iOS led with the identity fields.
Android's order is:

1. Firmware version
2. **Deployment Channel 1–4**, each a caption, a bare dropdown, and the one numeric
   field its selected mode needs
3. Locator Name
4. Locator Channel to Receive
5. Sensor Axis Along Rocket

The channels come FIRST, immediately under the firmware line, and the identity fields
come last. That reads oddly for a settings form until you notice what the screen is for:
the deployment channels are what changes between flights, and the rest is set once per
installation. Putting name and channel at the top — which is what a form usually does,
and what iOS did — buries the part being used.

Also corrected: **the dropdowns carry no floating label.** Android's `EnumDropdown`
passes no `label`, so the plain caption above it IS the field's name; iOS had invented a
"Mode" label inside each one, which Android has nowhere on that screen.

### Icon substitutions, and why they are substitutions

Android's control icons are Compose `Icons.Default.*` — a library, not drawables in the
repo — so `Tools/vd2svg.py` has nothing to convert and these are the nearest SF Symbols.
Each was checked against the deployment target using the system's own availability data
(see `SFSymbolAvailabilityTests` for the command); all are iOS 13–15, under the 16.0
floor. The one that could not be matched closely is `ZoomOutMap`: its four-arrow expand
glyph has no equivalent below iOS 17, so the two-arrow `arrow.up.left.and.arrow.down.right`
stands in.

### Flight Profiles — ported 2026-08-21, against `FlightProfilesScreen.kt`

The screen is **two screens behind one flag**, and the flag is really the locator's
transfer state: the record list until a record is opened, the chart afterwards.
`flightProfileDataDisplayState` lives in `LinkViewModel` for that reason, not in the
view. Opening a record takes the link over; leaving has to hand it back.

What was ported with it, because the screen cannot exist without it: the whole
FlightData receive path (`FlightDataRepository.swift`), the `FlightEvents` message
(MsgType 19), and the chart's geometry and event placement (`FlightChart.swift`).
Android's `ChartViewportTest` and `FlightEventsTest` are ported case for case; the
transfer path has tests Android has none of.

**Mirrored deliberately, including the parts that look like details:**

| | Android | iOS |
|---|---|---|
| Entry | `LaunchedEffect(service)` requests metadata, retries with a doubling 3 s → 12 s backoff, ends by coroutine cancellation | `.task { fetchFlightProfileMetadata() }`, same constants, ends by task cancellation on disappear |
| Attempt count | shown from attempt 2 | same — a lossy link has to read as "still trying", not as a hang |
| Exit | `onDispose` sends `DisarmRequest` so the locator resumes `PreLaunchData` | `.onDisappear` does the same. Without it the map stays blank after a visit |
| Back from the chart | app-bar up-arrow returns to the LIST and re-requests metadata, which aborts the locator's transfer immediately | the sheet's `Done` does exactly this while the chart is up (`MapScreen.destinationView`); the `Return` button does it too |
| Record list | icon, slot number, flexible gap of 1 unit, tappable detail column of 5 | same 1:5 split |
| Apogee rounding | `setScale(1, RoundingMode.UP)` — away from zero | `.awayFromZero`, so a flight never reads lower than it flew |
| A slot with no flight | still listed, "No flight data", not tappable | same |
| Chart defaults | altitude and all three accelerometer axes ON | same — four `mutableStateOf(true)` |
| No "descent" toggle | removed on Android in favour of pinch-zoom | not reintroduced |
| Event annotations | packed into free rows, flipped left near the right edge, leader line to a dot that never moves | same algorithm, line for line |
| Zoom | 1×…25×, `sqrt(zoom)` annotation growth capped at 2×, axis furniture unscaled | same |
| Gridlines | stepped over the VISIBLE window, so the count stays constant as you zoom | same |
| Colours | altitude `primary`, X red, Y yellow, Z green, apogee blue, drogue/main 50 %-alpha olive/green, indicators grey | same values |

**Gestures are UIKit recognizers, and that is a mechanism difference, not a UI one.**
Compose's `detectTransformGestures` reports centroid, pan delta and zoom delta together.
SwiftUI's `MagnificationGesture` **does not report where the pinch is**, and the focal
point is the whole behaviour here — without it a pinch zooms about the middle of the
plot and the data slides out from under the fingers. A `UIPinchGestureRecognizer` plus a
`UIPanGestureRecognizer` running simultaneously report the same three quantities, one
per callback, and the transform composes either way. Verified on the simulator: pinch
fires in both directions, one-finger pan fires, and zooming back out lands exactly on
the original fit. **Double-tap-to-reset could not be synthesised** through the
simulator's input latency and is unverified.

**The pixels-versus-points conversion, which has no exact answer.** Android's chart
constants are `DrawScope` units — raw pixels — so the gutters and labels are physically
smaller on a denser screen. `FlightChart.androidChartDensity = 3` converts them, that
being the density of the Pixel 9 Pro XL the chart was tuned on. Stroke widths and marker
radii are NOT converted, because Android writes those as `1.dp.toPx()` / `3.dp.toPx()`
and a dp is a point — which is also the check that 3.0 is self-consistent: at that
divisor the indicator circles keep exactly Android's radius-to-spacing ratio.

**⚠️ The altitude axis labels are clipped, on BOTH platforms.** The left gutter is 64 px
and a label like `900m` measures about 79 px at the 32 px axis size, so its first
character is cut off. iOS reproduces this exactly rather than quietly widening the
gutter — Android is the reference implementation, and this is a shared defect, not an
iOS one. **The fix belongs on Android first** (widen `CHART_MARGIN_X`, or shrink
`CHART_AXIS_TEXT_SIZE`), and then here in the same session. It is listed in
`NEXT_SESSION.md` as fschroer's call, since it is a legibility judgement.

**Two Android bugs fixed here rather than reproduced**, both in the parity FEC and both
silent — they corrupt flight data rather than failing:

1. **Parity recovery is order-dependent on Android.** `onFlightData` XORs every received
   payload into the same buffer that later stores the sender's parity frame, and
   recovery XORs the received members back out. That cancels only while every member
   arrives *before* the parity frame. A packet lost and **retransmitted after** it is
   XORed in once and out once against a buffer that already holds the parity, so the
   recovered packet is garbage — and `decodePayload` accepts any 48+ bytes, so it is
   inserted into the flight as real samples. iOS keeps the sender's frame untouched and
   recovers as `parity XOR (received members)`, which has no order to get wrong.
   `testParityStillRecoversWhenAMemberArrivesAfterTheParityFrame` pins it.
2. **A recovered short packet decodes the parity buffer's padding as samples.** The last
   packet of a transfer is shorter than the parity frame, so a recovered payload carries
   trailing zeros; zero deltas decode as duplicates of the final sample. iOS caps the
   decode at the sample count the transfer header implies.

Both want the same fix on Android — recorded here rather than made silently, because
"Android is the reference implementation" cuts both ways: a fix that lands here first is
a divergence until it lands there.

### Download maps — ported 2026-08-21, against `DownloadMapScreen.kt`

The screen is one square map over a scrolling column of controls, and the square is not
a style choice: **the download takes the VISIBLE bounds**, so the preview's shape becomes
the region's shape. A squat viewport silently inflates the region sideways, and a
portrait one goes blank at the edges the moment the live map swings 90° under the
compass. Ported with it: `OfflineMapManager`, `SatelliteProvider`, `LaunchSites` and the
tile arithmetic, all under `SteamPigeon/Maps/`.

**The platform pieces this screen needs, and their Android counterparts:**

| | Android | iOS |
|---|---|---|
| Offline API | `OfflineManager` + `OfflineTilePyramidRegionDefinition` | `MLNOfflineStorage` + `MLNTilePyramidOfflineRegion` — the same core, so the same model |
| Progress | `OfflineRegion.OfflineRegionObserver` | `MLNOfflinePackProgressChanged` / `…Error` / `…MaximumMapboxTilesReached` notifications |
| "Is the total real yet?" | `isRequiredResourceCountPrecise` | `maximumResourcesExpected != UINT64_MAX` — the same fact, spelled differently |
| Style for the DOWNLOADER | localhost server, `network_security_config.xml` | localhost server, `NSAllowsLocalNetworking` in the Info.plist |
| Editable preset CSV | `Android/data/<pkg>/files/launch_sites.csv`, over USB | app Documents via the Files app (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`) |
| Mapbox token | `secrets.properties` → `BuildConfig` | Info.plist value fed by a build setting — **never a literal in the repo** |

**ADR-0014's http(s)-only rule holds on iOS too, and it was worth checking rather than
assuming.** `MLNTilePyramidOfflineRegion`'s own documentation says a relative file URL
cannot be an offline style URL, and this repo already recorded the Android finding — the
downloader rejects `asset:`/`file:` and stalls at "0/1 tiles". So the localhost server is
ported as-is, including re-binding the port a resume's immutable style URL records. A
real 30-tile region downloaded successfully on the simulator, which is the evidence that
the server, the ATS exemption and the pack creation all line up.

#### ⚠️ iOS-FIRST behaviour: the picker opens on the phone's position, zoomed out

**fschroer's preference, stated 2026-08-21, to be ported to Android.** Recorded here so
the Android change can be made from a description rather than from reading Swift.

> The download picker should open centred on **the phone's current location**, at a
> **multi-state zoom** — wide enough that a launch site a state or two away is a pan
> rather than a search, close enough to place yourself.

The rules, exactly as implemented here:

- **z5**, which on a phone-sized square shows roughly 700–950 km across. (MapLibre's world
  is 512·2^z points wide.)
- Applied **once**, the first time a fix is available — including one that arrives after
  the screen is already open, since that is the first useful position rather than a
  position the user chose.
- **Never re-applied.** The picker reports its centre continuously through a gesture, so
  re-centring on every update would drag the map back under the user's finger.
- **Choosing a preset or typing a coordinate cancels it**, so a fix landing afterwards
  cannot pull the camera off the site the user just picked.
- **No fix, no move**: the map stays where MapLibre opens it. No invented default
  location — an app that opens on somebody else's launch site is worse than one that
  opens on the world.

This is the **one place in the port where behaviour landed on iOS first**, at the user's
explicit request. Until Android follows, the two apps differ here on purpose. Android
today sets no opening camera at all, so its picker starts at MapLibre's default; the
change there is `RegionPickerMap`'s factory plus a location source.

**Mirrored deliberately:**

- **Always cache down to the provider's floor** (z10), not maxZoom − N. Each lower level
  has ~4× fewer tiles, so the context pyramid is nearly free — and without it the map is
  blank offline at any zoomed-out level, which is exactly when someone is getting their
  bearings on site. `TileMathTests` pins that the levels below the maximum cost under
  half the deepest one.
- **The estimate sums per zoom**, because measured tile size swings ~5× across the range.
  A flat average badly misprices whichever end the user picks. The simulator download came
  in at 743 kB against a 690 kB estimate — 8% low, on a 30-tile region.
- **The 1 GB limit states itself in the button label.** As a separate warning line it sat
  rows away from the control it disabled, so an over-budget region read as a dead button.
- **"Offline regions", not "Downloaded regions".** The row is written when a download
  STARTS, so the list has always included partial regions; presenting them as finished is
  the one thing it must never do.
- **A download outlives the screen.** Its state lives in `OfflineDownloadRepository`,
  process-wide, so leaving and coming back re-attaches rather than showing a blank slate
  with the Download button armed for a second, overlapping region.
- **The provider is recorded in the pack's metadata**, and a resume rebuilds the style
  from that rather than from whatever is selected now — otherwise resuming a Mapbox
  region under Esri stitches two sources into one region.
- The **Lat, Lon box is a readout and an entry box at once**, with the edit buffer only
  taking over while focused; the **detail inset is a second map**, because zooming the
  picker would silently redefine the download.
- **The estimate lines wrap, never truncate.** Reported from the phone: the size — the
  number the whole screen exists to report — fell off the right edge. Compose wraps by
  default; SwiftUI needs `fixedSize(horizontal: false, vertical: true)` to grow a line
  into two rather than clip it, and these lines are long, monospaced and Dynamic
  Type-scaled, so they overflow on a narrow phone or at a large text size. Applied to
  the progress and result lines too, which are the same shape. Verified at an
  accessibility text size, where the estimate wraps to three lines intact.

**Exercised on the simulator on a large region:** the indeterminate-then-determinate
progress path, Cancel (the partial region is kept and listed as incomplete), and Resume
(picks up where it stopped without refetching). What is still unseen is whether a
downloaded region actually renders with the network down — MapLibre serves any matching
tile URL from the pack database and both sides read the same style, which is all
ADR-0014 says is needed, but "should" is not "seen".

#### ⚠️ Fixed the same day: `reloadPacks()` froze the progress readout

Reported from the phone as **"downloads appear to stop when I tap Done then return"**,
and reproduced exactly: leaving the screen and coming back pinned the percentage at
whatever it had reached, while the download itself carried on and eventually completed.
"Appear to" was the precise word.

The cause was `MLNOfflineStorage.reloadPacks()`, which the screen called on every
appearance to refresh the region list. Its own documentation is unambiguous: *"the
pointer values of the `MLNOfflinePack` objects in the `packs` property change, even if
the underlying data for these packs has not changed. If this method is called while a
pack is actively downloading, the behavior is undefined. You typically do not need to
call this method."* The progress notifications then arrived for a pack that was no longer
the object being held, and were dropped.

Two changes, because either alone would leave the failure reachable:

1. **Never call `reloadPacks()`.** MapLibre keeps `packs` current as packs are added and
   removed, and the KVO observation on that property is how the list hears about it.
2. **Identify the active download by value, not by pointer** — the metadata written on
   the pack plus its style URL, which carries the port unique to that download session.
   A notification for a pack that matches is re-adopted, so a pointer swap from any
   cause self-heals rather than silently muting the screen.

Android is not exposed to this: its `OfflineRegion` observer is attached to the region
object and it never calls the equivalent. **This is an iOS-only defect, fixed here, with
no Android counterpart to change.**

#### Three lines from the phone's runtime log, 2026-08-21

Reported together; only one was ours, and it was the quiet kind.

**1. `API MISUSE: <CBCentralManager> can only accept this command while in the powered on
state` — ours, and not merely noise.** CoreBluetooth does not queue a command issued in
any other state: it logs this and **drops it**, so an ungated call is an action the app
believes it took and did not. `startScan` was gated; `stopScan`, `connect` and
`disconnect` were not, and neither was the restore path.

The restore path is the one that mattered. `willRestoreState` runs **before** the central
reports `.poweredOn`, and it issued the service discovery that rebuilds a restored
connection's GATT session — so that discovery was liable to be dropped, restoring the
exact bug it was written to fix (a receiver that connects by itself with a grey icon,
gates the receiver menu and refuses to arm, cured only by a manual rescan). The discovery
now happens at `.poweredOn`, the first moment CoreBluetooth accepts it. Every central
command is gated on one `canCommandCentral` check; where a command is refused, the local
state it implies is still cleared, so the app's model never claims a link the radio does
not have.

**2. `MLNMapView WARNING UIViewController.automaticallyAdjustsScrollViewInsets is
deprecated…` — MapLibre's, once per launch, and not silenceable from here.** MapLibre logs
it after inspecting the hosting view controller's deprecated UIKit flag, which a SwiftUI
app does not own; setting the property the message names does not stop the log (verified).

The property is set anyway **on the download picker only**, where it is a correctness
argument rather than tidiness: the picker's visible bounds ARE the region being
downloaded, and an inset excludes part of the frame from the viewport, so every region
would be sized differently from the square the user framed. It is deliberately NOT set on
the flight map: that would change the camera geometry of a hardware-verified screen by
the safe-area inset, which nobody asked for and nobody has measured. **Open parity
question**: Android's map has no automatic inset at all, so setting it there too would be
the parity-consistent choice — it wants a look on the phone first.

**3. `nw_connection_add_timestamp_locked_on_nw_queue [C15] Hit maximum timestamp count` —
Apple's, and benign.** Network.framework records per-event timing on a connection and
says so when it stops. It fires on a long-lived connection with many requests, which
during a map download is the HTTPS connection fetching thousands of tiles. Nothing in the
app reads those timestamps. It would only be worth chasing if it coincided with a
download stalling — it did not.

#### ⚠️ The size estimate is low, on BOTH platforms — around 2× on bytes, 4× on tiles

Measured while testing the above. A 9.1 × 9.1 km region at z10–z17 estimated **2,761
tiles / ~64 MB** and actually downloaded **139 MB**; a 22 × 22 km region estimated 12,484
tiles against MapLibre's **49,155** resources — a ratio of 3.94, which is one whole zoom
level.

The likely cause is the tile-size convention: the style declares `"tileSize": 256`, and
MapLibre's logical tile grid is 512, so it fetches source tiles one level deeper than the
map zoom asked for. Android's `tileCount` does exactly the same arithmetic over the same
range, so **Android under-reports identically** — its own Mapbox note even says "MapLibre
zoom runs ~1 level deeper than Google's (512- vs 256-px tile convention)", which is the
same fact, applied to detail but not to the count.

**Deliberately NOT changed here.** Android is the reference implementation, the estimate
is shared arithmetic, and fixing one side would make the two apps quote different sizes
for the same region — which is worse than both being consistently low. It wants a
decision and a change on Android first; it is written up in `NEXT_SESSION.md` as such.
The direction of the error is at least the safe one for the 1 GB gate: real downloads are
bigger than promised, so the cap bites sooner than the estimate suggests.


## Where iOS idiom should win

Recorded so departures are deliberate rather than accidental:

1. **Navigation drawer → not a drawer.** A left drawer is a Material pattern. The HIG
   equivalent is a tab bar (few destinations) or a navigation stack from a settings
   entry point. Recommend: keep Flight/Map as tabs, move the six settings-ish
   destinations behind one "More" tab or a toolbar button pushing a grouped list.
2. **Back affordance.** iOS uses a back-swipe and a leading chevron, not an app-bar up
   arrow.
3. **Switches, pickers, steppers** should be the SwiftUI controls, not Material clones.
4. **System heading-calibration HUD** stays suppressed — ADR-0023 puts the prompt on the
   map where the doubted bearing is visible.
5. **Exit-app button is Android-only.** iOS has no sanctioned "quit" affordance and an
   app that terminates itself reads as a crash.
6. **Permission prompts** are one-shot on iOS; Android's rationale flows have no
   counterpart.

Everything not on this list should mirror Android.

## Sequence

Ordered so each step is verifiable and the highest-value gaps close first.

1. **Theme + fonts.** Bundle Poppins/Roboto/Roboto Mono, port the Material 3 dark
   palette to SwiftUI tokens. Cheap, and everything after inherits it.
2. **Main-screen instrumentation.** `LocatorStats`, link-quality colour bands, scale
   bar, velocity gauge. This is what the user looks at during a flight.
3. **Heading-up map rotation** with the smoothing Android applies, suppressed while
   compass trust is `unreliable`.
4. **Settings screens** — locator, receiver, app.
5. **Flight profiles + download + export**, which depend on the flight-data transfer.
6. **AR camera view**, largest and most platform-specific.

## Verification

UI parity cannot be self-certified the way the protocol layer could. Screenshots of
both apps side by side are the only real check, and that needs both devices in hand.
