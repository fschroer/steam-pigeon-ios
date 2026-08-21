# Android ⇄ iOS UI parity — inventory, audits and deliberate gaps

**Status, 2026-08-20.** The flight map, Application Settings, Receiver Settings and
Locator Settings are ported and have been exercised on hardware. Flight Profiles,
Deployment Test and Download maps remain; the last two depend on flight-data download.

**How to use this file.** The audits below are the record of what was compared against
Android and what was found — read the one for the screen you are about to touch before
writing anything, rather than re-deriving it. The **deliberate divergences** are listed
with what would close each one; there are only three, and every other difference found in
this port was a defect.

**The three deliberate divergences:**

| Divergence | Why | Closes when |
|---|---|---|
| No launch-detect altitude / deploy-signal duration controls in Locator Settings | Neither field rides in a broadcast, so a change can never be confirmed — on Android editing either reports "not acknowledged" while the locator has accepted it | the firmware carries both fields in a broadcast (three binaries, wants an ADR) |
| Icon substitutions in the map control column | Android's are Compose `Icons.Default.*`, a library with nothing to convert | never — the mapping is recorded below |
| No archived-path map control | Android offers it only once a record is downloaded | flight-data download lands |

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
| `FlightProfilesScreen` | 1,002 | absent |
| `LocatorSettingsScreen` | 759 | absent |
| `DownloadMapScreen` | 677 | absent |
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
