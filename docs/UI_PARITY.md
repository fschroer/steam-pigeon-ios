# Android ⇄ iOS UI parity — inventory, audits and deliberate gaps

**Status, 2026-09-01. Every Android screen is ported.** The flight map,
Application Settings, Receiver Settings, Locator Settings, Flight Profiles, Download maps
and Deployment Test. Everything up to Locator Settings has been exercised on hardware; the
three newest screens have been driven on the simulator only — though Download maps has
downloaded a real region there, which is the half of it that could not be faked.

**App Flight Logs, Android's eighth screen
([ADR-0030](../../steam-pigeon-locator/docs/adr/0030-app-flight-log.md)), was ported
2026-09-01** — fschroer having exercised the Android side with simulated flight data, which
is the condition the divergence row named. See the audit below.

What otherwise remains is **features inside screens**: the flight TTS callouts, the
camera passthrough behind the heads-up gauges, the archived-path map control (unblocked
by the flight-data transfer layer), and path export. `NEXT_SESSION.md` has the list.

**Update, 2026-09-01. The "iOS OWES THIS" list is empty.** All seven items closed in one
pass against the Android source: the two `ChannelOccupancy` fixes, the armed-scan
affordance, the scan notice on the status panel, the survey section's gate,
`isFromChannelBeingLeft`, the discarded `transport.send` results, and the ADR-0011
channel-move port (`ChannelMove` + `ChannelMoveRunner` + three test suites, replacing the
revert-on-silence cut). Then the Firmware rows, and the App Flight Logs port. 730 tests pass. **None of it has been on hardware** — and the
channel-move path in particular cannot be exercised without a receiver, so it is pinned by
tests and by nothing else. The "ANDROID OWES THESE" list below is untouched and still open.

**Also 2026-09-01: the Firmware row on Locator Settings and Receiver Settings was never
populated** — both rows, the message type and the parser were all in place, and nothing
ever sent the request. Ported Android's version loop; see the Locator Settings audit.

**How to use this file.** The audits below are the record of what was compared against
Android and what was found — read the one for the screen you are about to touch before
writing anything, rather than re-deriving it. The **deliberate divergences** are listed
with what would close each one; every other difference found in this port was a defect.

**The nine deliberate divergences.** Four are now struck through.
 Three of the rows below are struck through: two
closed on the Android side on 2026-08-21 and one on iOS on 2026-08-29, and all three are
left in the table as the record of what closed them. Two were added on 2026-08-28 with the
Communication screen, one on 2026-08-29, one on 2026-08-30, and one on 2026-08-31.

The newest is of a different kind from the rest. Every other row is a **rendering** choice
where iOS idiom wins; this one is an entire Android screen with **no iOS counterpart at
all**, and it is listed here rather than left to the inventory because this table is what
gets read before someone concludes a missing screen is a defect:

| Divergence | Why | Closes when |
|---|---|---|
| ~~No launch-detect altitude / deploy-signal duration controls in Locator Settings~~ **CLOSED 2026-08-21** — Android removed both controls too (`b6c67ad`), and ADR-0028 makes both fields reserved wire slots the locator owns. Neither platform offers them; it reopens only when the firmware carries them in a broadcast | — | — |
| Icon substitutions in the map control column | Android's are Compose `Icons.Default.*`, a library with nothing to convert | never — the mapping is recorded below |
| ~~No archived-path map control~~ **CLOSED 2026-09-01** — ported once the 3D path landed, since it draws through the same layers. Left in as the record. The control appears only once a record is downloaded, on both platforms | — | — |
| Flight-profile chart constants converted at a 3.0 display density | Android draws the chart in raw **pixels** (`CHART_MARGIN_X = 64f`, `textSize = 32f`), so its apparent size changes with the phone; SwiftUI's Canvas works in points | never exactly — see the chart audit below. A side-by-side screenshot would settle whether 3.0 is the right divisor |
| Download maps uses SwiftUI's `Menu` and `Slider` where Android uses `DropdownMenu` and a Material `Slider`, and an SF Symbol for the delete icon | ADR-0016's sanctioned list covers pickers and sliders outright; the delete glyph is a Compose `Icons.Filled.Delete`, a library with nothing to convert, so `trash` stands in as the map-column icons do | never — `trash` is pinned in `SFSymbolAvailabilityTests` like the rest |
| Chart legend checkboxes are SF Symbols, not a Material `Checkbox` | ADR-0016 sanctioned departure: a Material checkbox clone next to iOS type reads as broken, and `checkmark.square.fill` / `square` carry the same two states in the same two colours | never |
| ~~Section help opens as an **alert**, where Android uses a `Popup` card anchored under the **i**~~ **CLOSED 2026-08-29 on iOS 16.4+**, which is where it matters: `SectionHelp` now branches at runtime and gives 16.4-and-up Android's anchored card (`.popover` + `presentationCompactAdaptation(.popover)` + `presentationBackground`), keeping the alert only for 16.0–16.3, where the API does not exist. Split by **capability, not device**, because flight testing spans several iOS versions | — | — |
| The password prompt refuses interactive (swipe) dismissal, where Compose's `AlertDialog` dismisses on an outside tap | Its two buttons mean different things — one connects, the other reverts the receiver to the channel it came from — and a swipe expresses neither. On iOS a swipe is far easier to trigger by accident than a scrim tap, and the consequence here is a channel revert the user did not ask for | never — the asymmetry is in the gesture, not the design |
| The search's **Looking for** picker is a SwiftUI `Menu` styled as a field, where Android uses `ExposedDropdownMenuBox` | ADR-0016's sanctioned list covers pickers outright, and Download maps already uses `Menu` for the same reason. The part that was **not** treated as sanctioned is the *appearance*: Android deliberately moved this control from a bare `TextButton` to a field showing its current value, because the value is what a user must check before starting a search that behaves differently depending on it — so the iOS label is a value plus a chevron in a 200 pt filled field, not a text button | never — but the field shape is the requirement, not the menu mechanism |
| **A dropped BLE link clears the receiver readout on iOS; Android keeps it.** `clearLiveReadouts` sets `receiverInfo = nil` with the rest; Android's link-loss release ([ADR-0011](../../steam-pigeon-locator/docs/adr/0011-locator-lora-channel-from-app.md), 2026-08-30) deliberately leaves `_remoteReceiverConfig` standing | The **locator** half matches — both platforms release the connection and blank the locator's configuration, because a section left reading channel 0 is a plausible-looking value where the truth is "nothing is connected". The receiver half cannot: Android seeds `_remoteReceiverConfig` from user preferences and saves it back, so clearing it would blank the Receiver channel field on every drop and raise that same hazard on the other field. iOS's `receiverInfo` is not persisted and has no such role | never — the difference is in where the value is stored, not in what either app wants to show |
| ~~**App Flight Logs is Android-only.**~~ **CLOSED 2026-09-01** — ported once the Android side had been exercised with simulated flight data, which is exactly what this row's *closes when* asked for. Left in as the record. Original text: A per-flight CSV of what the *phone* received and announced — the frame plus the receiver's RSSI/SNR/noise floor plus the app's own verdicts and spoken callouts, none of which exist in the locator's archive because they are measured or decided on this side of the radio | Not a divergence of taste — the feature is four days old and has never flown. Porting a recording feature before its first hardware run would mean debugging two implementations against one unknown. The **portable half is already shaped for the port**: `FlightLogRecorder` holds no clock, no Android types and no flows, exactly as `ChannelMoveRunner` does, and its 23 tests drive it through a `Sink` protocol that Swift has verbatim | when the Android side has flown at least once and the CSV has been read on a PC. Then port `FlightLogRecorder` + `FlightLog` + `FlightLogRecorderTest` **as a unit** rather than re-deriving the close-signal set — landing deliberately does NOT close a log, and a BLE dropout deliberately does not either, and both are the kind of rule that gets "simplified" back out by a reimplementation. Storage and export are genuinely platform-specific: `UIActivityViewController` for the share sheet, and app-private storage plus `LSSupportsOpeningDocumentsInPlace` / `UIFileSharingEnabled` is the Files-app question Android answers with a `FileProvider` |
| ~~iOS remembers the name of **every** locator it accepts a broadcast from; Android remembers one only for locators whose password it holds~~ **CLOSED 2026-08-21** by Android `b209671`, which stores the name from every accepted broadcast exactly as described below. The one asymmetry left — Android noted the name **before** its `mayConnect` check and iOS only on `.accepted` — was closed here 2026-08-23: `noteName` now runs on the conflict path too, so a second authorized locator heard while ours holds the link is remembered | — | — |

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

Android UI is ~14,900 lines across `ui/`. By screen:

| Android screen | Lines | iOS today |
|---|---:|---|
| `FlightMapScreen` (Start) | 3,370 | partial — map + basic stats, none of the instrumentation |
| `FlightProfilesScreen` | 1,002 | **present** (`FlightProfilesView` + `FlightChart` + `FlightDataRepository`), 2026-08-21 — not yet exercised on hardware |
| `LocatorSettingsScreen` | 759 | absent |
| `DownloadMapScreen` | 677 | **present** (`DownloadMapView` + `Maps/`), 2026-08-21 — a real region downloaded on the simulator |
| `ReceiverSettingsScreen` | 463 | absent |
| `AppSettingsScreen` | 202 | absent |
| `DeploymentTest` | 160 | **present** (`DeploymentTestView`), 2026-08-21 |
| `AppFlightLogsScreen` | 288 | **present** (`AppFlightLogsView`), 2026-09-01 — with `Protocol/FlightLog.swift` + `FlightLogRecorder.swift` (the portable half) and `Flight/FlightLogStore.swift` (the iOS-specific half). Exercised on the simulator with injected logs; never on hardware |
| `ExportFlightPathScreen` | — | absent |
| `LocatorPasswordDialog` | 139 | **present** (`PasswordChallengeView`) |
| `DevicePickerDialog` | 103 | absent — iOS auto-connects to the first FFE0 peripheral |
| `MapLibreCompat` | 1,042 | partial (`FlightMapView`) — the **flight path is complete** as of 2026-09-01: ground track, altitude curtain and one-second markers, with `PathGeometry.swift` carrying the pure builders. The marker, accuracy ring and camera work were already there |

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

⚠️ **The port target changed on 2026-08-31.** Android no longer calls the speech engine
from those nineteen sites — every one goes through an `Announcer` facade
([ADR-0030](../../steam-pigeon-locator/docs/adr/0030-app-flight-log.md)) so the App
Flight Log can record what was said and when. No callout text changed and both queue
modes map one-to-one, so the wording audit above still stands. **Bring the facade across
with the callouts, in the same pass**: retrofitting it afterwards means touching the same
nineteen sites twice, and until it exists an iOS flight log would be silent about the
half of the timeline that matters most. Note the facade's rule — it speaks *and* logs, or
does neither, so with speech off nothing is recorded. A log entry always means the
operator actually heard it.

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

### Tenth round, 2026-08-21 — the armed locator with no name, and the receiver called "Connected"

Both reported off the phone, and both the same mistake in two places: a field that only
`PreLaunchData` carries was read as though it were always there. **An armed locator sends
`TelemetryData` and nothing else** — no locator name, and no receiver name either, since
the receiver appends its own name to the pre-launch broadcast as it relays it. Open the
app with the rocket already on the pad and armed, and every name on the status panel came
up empty while the app was plainly receiving, plotting and arming that rocket.

| Gap | Android | iOS before |
|---|---|---|
| Locator row | `lastMessageAge < messageTimeout -> locatorConfig.deviceName`, then `Ready -> "No Locator"`, else `""` | `prelaunch?.deviceName ?? "No Locator"` — so an armed locator, which sends no name, was reported as **absent** |
| Locator name source | `evaluateRecognition` falls back to `knownLocators[id].label` when the live name is empty | no fallback at all |
| Receiver row | `receiverDevice?.name?.takeIf { it.isNotEmpty() } ?: receiverConfig.deviceName` — the **BLE device name first** | `prelaunch?.receiverName`, so with an armed locator the row fell through to the connection state and read "Connected" |

Three things followed:

- The locator row now reports absence **only when nothing is arriving** — Android's
  three-way rule, including the blank third case that keeps this row from repeating what
  the receiver row above it already says.
- The receiver is named by its **BLE name** first (`BluetoothTransport.connectedName`,
  refreshed on `peripheralDidUpdateName`, since GAP can resolve it after the link is up),
  falling back to the configured name.
- Locator names are remembered per locator id, and that is the **divergence in the table
  above** — see below.

#### ⚠️ iOS-FIRST behaviour: naming a locator heard only while armed

**Asked for by fschroer on 2026-08-21, to be ported to Android.** Written as a
description so the Android change needs no Swift.

> A locator that is armed when the app starts should still be named on the status panel,
> whether or not it has a password.

Android already stores a name for **some** locators: `rememberLocator(id, key, label)`
writes `KnownLocator.label` when a password challenge is accepted, and
`evaluateRecognition` falls back to it. That covers a password-protected locator and
nothing else — an **open** locator is authorized without ever being challenged, so no
label is ever written for it, and its row stays blank for the whole flight. Open locators
are the default state, which makes the gap the common case rather than the edge one.

The rules, exactly as implemented here (`KnownLocatorStore.noteName`,
`LinkViewModel.adoptStoredLabel`):

- The name is stored **whenever a `PreLaunchData` is accepted** — that is, from a locator
  that passed the recognition gate. Not from broadcasts the gate rejected: a name is only
  worth keeping for a locator this app is entitled to display.
- Keyed on the 32-bit **`locator_id`**, beside the password key where there is one. An id
  may hold a name with no key; the two are independent.
- **Written only when it changes.** `PreLaunchData` arrives at 1 Hz, and re-persisting an
  unchanged name at that rate is churn.
- **An empty name never overwrites a stored one.** `TelemetryData` has no name field, so
  empty means "not known here", never "renamed to nothing".
- The stored name is used **only when the live one is empty**, and the first
  `PreLaunchData` overwrites it as soon as the locator disarms — the same precedence
  Android's label fallback has.
- Forgetting a locator forgets its name with its key.

**What this still cannot do, on either platform:** name a locator that has *never* been
heard disarmed by this install. Nothing anywhere carries that name — the only fix would
be a `locator_id`-to-name field in `TelemetryData`, which is a firmware change and wants
an ADR.

**Landed on Android 2026-08-21 (`b209671`), and one detail came back the other way.**
Android notes the name inside its `authorized` branch, **before** the `mayConnect`
check — so it names an authorized locator it declines to connect to. iOS noted it only on
`.accepted`, which lost exactly the two-rocket case: hear the second locator while the
first holds the link and the only broadcast that ever carried its name went unremembered,
so switching to it once armed left the row blank. `noteName` now runs on `.conflict` too
(2026-08-23), and not on `.unauthorized` — a name is only worth keeping for a locator this
app is entitled to display. Both halves are pinned in `ReceiverLocatorRecoveryTests`.

### Eleventh round, 2026-08-23 — the rocket icon said nothing about being armed

Reported from the phone. The status panel's rocket glyph is the **only** thing on the map
that says whether the locator is armed, and it says it in colour alone — so a wrong tint
rule is not cosmetic.

| Gap | Android | iOS before |
|---|---|---|
| Resting tint | `armedState -> Color.Green`, else `Color.White` (`FlightMapScreen.kt:2198`) | `gpsStatus == .ok ? primary : tertiary`, with `outline` for no reading — **armed and disarmed looked identical**, and the icon changed for a reason Android never changes it for |
| The green | Compose `Color.Green`, pure `#00FF00` | SwiftUI `.green` in the pending branch — the adaptive system green, `#34C759` |
| Blink easing | `tween(450, easing = LinearEasing)`, reversing 1f→0.15f | `.easeInOut(duration: 0.45)` |
| Acknowledgment | `LaunchedEffect(armedState) { armCommandPending = false }` — the locator changing what it broadcasts IS the acknowledgment, so the icon settles at once | nothing cleared it; the icon blinked out the full 2 s timeout every time, so a confirmed arm looked identical to one that was never answered |
| Satellite superscript | takes the panel's default content colour; **never** follows the rocket's tint | shared `rocketTint`, so the count would have turned green with the glyph |

The pending branch was already right — while a command is in flight the icon shows the
colour it is heading **for**, green while arming and white while disarming, so the blink
reads as *taken* rather than as the state being left. Only the three resting cases were
invented. `gpsStatus` is no longer passed to the panel at all; GPS health is reported by
`LocatorStats`, where Android reports it.

The rule is pinned by `RocketIconTintTests`, including a case that fails if the green
ever goes back to being SwiftUI's. **Confirmed on hardware 2026-08-24 (fschroer),
arming and disarming a real locator** — which is the only way to see the half a test
cannot reach: the blink running while the command is in flight, and stopping on the
locator's own change of broadcast rather than on the 2 s timeout.

**The satellite superscript is a small deliberate divergence, recorded here rather than
left silent.** Android's is Material's default `LocalContentColor`, which with no
`Surface` above it is **black** — as the radio and battery glyphs on this panel also are.
iOS themes those three against the overlay instead. Nothing about the rocket icon depends
on it, and matching Android exactly here means three black glyphs on a slate panel: worth
a side-by-side screenshot before changing, not worth changing blind.

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

### ✅ The two fields the app cannot read are RESERVED — ADR-0028

**Closed 2026-08-23**, porting Android `b6c67ad` ("reserved config fields v1"), with the
locator's half in `4ffce9c` and the decision in
`../steam-pigeon-locator/docs/adr/0028-app-does-not-transmit-unconfirmable-settings.md`.

**What it used to say, and what was wrong with it.** `LocatorCfgChgRequest` carries the
WHOLE `LocatorRocketSettings`, but `PreLaunchData` carries neither
`launch_detect_altitude` nor `deploy_signal_duration` — so the app could not learn what
the locator held, and **every config change, including a pure channel move, wrote the
app's guess over both.** `deploy_signal_duration` is pyro firing time. This page recorded
that as "a silent reset of a value configured over the USB console"; **the console never
set either field** — `UserInteraction`'s config save assigns eight fields by name and
neither is among them. The app was the only writer, and it was writing a value it had
invented.

**The decision: a setting the app cannot read back is not a setting the app transmits.**

- Both fields are gone from `LocatorConfig`, on both platforms. Nothing left in the
  confirmation comparison is a value the app invented, which is exactly what makes every
  OTHER field on the settings screen confirmable — a reported success is now a real one.
- The **slots stay on the wire as reserved**. Removing them would move `lora_channel`,
  the one byte the receiver reads by `offsetof` to follow a channel change (ADR-0011),
  and would change `sizeof(LocatorSettings)` from the 45 that three `static_assert`s and
  both apps pin. Keeping the layout is also what lets the three binaries be flashed
  independently.
- The filler is the **firmware defaults, deliberately not zero**
  (`LocatorConfig.reservedLaunchDetectAltitudeM` / `reservedDeploySignalDurationTenths`,
  byte for byte Android's `LocatorConfigWire.RESERVED_*`). A locator on older firmware
  still adopts whatever arrives there, and for it zero would mean launch detected at 0 m
  AGL — true on the pad — and a pyro signal held for 0 s, a charge that never fires.
- The locator restores its own values for both after copying the message, so an app
  predating the change stops being able to reset them the moment the firmware is flashed.

**The cost, recorded as a cost:** both fields are now fixed at their defaults, 30 m and
1.0 s, on every device. Nothing can change them — not the app, not the console. It closes
when the firmware carries them in a broadcast, at which point the controls can come back.

The 35-byte body is now pinned field by field in `WireLayoutTests` — including that
`lora_channel` sits at offset 13 and that the two reserved slots carry 30 and 10 rather
than zeros — mirroring the cases Android added in the same commit. **iOS's bytes did not
change**; it was already sending these exact values as "placeholders". What changed is
that they are no longer fields anyone can set, and that the third leg of the triad now
covers this body at all.

**Confirmed on hardware 2026-08-24 (fschroer): a config change and a channel move both
against a real locator.** That is the pair this needed — the change proves the locator
accepts and confirms a body it no longer takes those two fields from, and the move proves
`lora_channel` is still at the offset the RECEIVER reads it by out of the relayed frame
(ADR-0011). A drift in either is silent: the message is length-validated and dropped, or
the receiver retunes to the wrong byte and the link splits with the locator out of reach.

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

#### ✅ FIXED 2026-09-01 — the Firmware row on both settings screens was never populated

Reported by fschroer as version information missing from Locator Settings and Receiver
Settings. **The rows were there all along**: `LocatorSettingsView` and
`ReceiverSettingsView` have carried Android's `Text("Firmware: …")` in Android's position
since they were ported, and `MsgType.versionRequest` / `.versionInfo`, `VersionInfo.parse`
and the framer entry were all in place. **Nothing ever sent the request.** `versionInfo`
stayed nil for the life of the process, and because both screens hide the row while it is
empty, the gap was invisible — the screens looked finished.

An unusually good illustration of *silence reads as parity*: every individual piece
matched Android and the feature did not exist.

What landed, ported from Android's `versionJob` / `connectionJob` and
`BluetoothService.requestVersionInfo`:

- `LinkViewModel.versionTick`, a 1 s timer beside the channel watch. The request is
  **locator-directed** (ADR-0020) — absent from Android's `isReceiverDirected` list — so it
  carries the connected locator's id and cannot go out with nothing connected. One request
  fills BOTH rows: the receiver forwards it, the locator answers, and the receiver appends
  its own version before relaying.
- `versionInfoStale`, kept separate from the version strings exactly as Android keeps it.
  A rising edge on the LoRa link means the locator may have been reflashed (flashing takes
  it off the air); a BLE drop means the receiver may have been. The strings are **not**
  blanked on either — both screens hide the row while empty, so blanking would flicker it
  on every brief dropout. The stale stamp stands until a newer one replaces it.
- The steady state is silent: it transmits only while stale, so a version loop cannot
  become a request every few seconds forever.

Pinned by `FirmwareVersionTests` (7). The one seam worth naming is
`setLastLocatorMessageForTesting`: the silence window and the request back-off are both
5 s, so a test of either has to hold the other still.

**One divergence found and closed in passing.** Both rows were `bodyMedium` in
`onSurfaceVariant` — muted, and a size down from Android, which draws a plain `Text` and
therefore gets the default body style and content colour, the same mapping every other bare
caption on these two screens already uses. Nothing recorded the difference, so it was drift
rather than a decision. Now `bodyLarge` with the default foreground.

**The limits are interlocked, and that is the safety-relevant part.** A drogue backup
must fire AFTER its primary and a main backup BELOW its primary, so each bound is
derived from the other value rather than from a constant — it is the only thing stopping
a backup being configured to fire first. Pinned by `DeploymentLimitsTests`, including
the degenerate ends: an unconfigured locator reports zeros, and a `ClosedRange` with
lower > upper traps at construction in Swift, so an inverted bound would crash the
screen rather than merely misbehave.

### ✅ Launch-detect altitude and deploy-signal duration are not offered on EITHER platform

Omitted here on 2026-08-20 as this port's one deliberate UI divergence; **Android removed
both controls on 2026-08-21** (`b6c67ad`) and ADR-0028 makes it the system's decision. The
divergence closes because Android moved, not because iOS did.

The chain that made the controls impossible is worth keeping, because it is not obvious
from any one place:

1. Both were editable on Android's screen.
2. Neither rides in `PreLaunchData`, so `remoteLocatorConfig` is rebuilt from every
   broadcast with hardcoded 30 and 10.
3. Confirmation is whole-object equality against that rebuilt config, and Android's
   `LocatorConfig` is a `data class`, so both fields counted.

Set launch-detect altitude to 50 and press Update: the locator receives and saves it, the
comparison never matches, the app reports **"Update not acknowledged"**, and the display
reverts to 30 m on the next broadcast. The change took effect; the app said it failed and
showed the old value. A `// To do: remove from UI` had sat beside both constants for
months.

Both fields are now **reserved wire slots** rather than app-settable values — see "The
two fields the app cannot read are RESERVED" above for the layout and the reasoning.
`DeploymentLimitsTests` fails first if a control for either reappears, and
`WireLayoutTests` fails if the reserved bytes stop being the firmware defaults.

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

**✅ The altitude axis labels were clipped, on BOTH platforms — fixed 2026-08-23.** The
left gutter was 64 px and a label like `900m` measures about 79 px at the 32 px axis
size, so a label is right-aligned to `gutter − width − 8` and lands at **x = −23**: the
altitude axis of an altitude chart was cutting the first digit off its own labels. iOS
reproduced it exactly rather than quietly widening the gutter, because Android is the
reference implementation and a shared defect is better than a silent divergence — so it
was fixed on Android first (`5d52383`) and ported here in this session.

**112 px**, of the two available levers. Roboto digits advance ~0.556 em and `m` ~0.86 em,
so a four-digit `1234m` is ~99 px plus the 8 px gap, and four digits is the practical
ceiling at 9999 m = 32,800 ft. The text size was the other lever and is the wrong one:
these are raw pixels, so 32 px is already only ~11 sp on a 3× phone, and shrinking type
to fix a legibility bug reads badly.

The draw also **clamps the label's left edge to zero**, because deep zoom can still
produce a decimal label (`900.5m`, ~124 px) that does not fit: it butts against the plot
rather than losing a character, which is the failure worth having. Android clamps `tx`;
iOS anchors trailing, so the clamp is on the anchor minus the measured width
(`drawAltitudeLabel`). `ChartViewportTests` measures the real face at the real size and
fails if a four-digit label stops fitting — or if the gutter goes back to something that
could not fit three digits. **Still unseen on a device, on either platform, and
deliberately so:** fschroer is holding the judgement until there is real flight data to
draw (2026-08-24). It is a legibility question with 3- and 4-digit altitudes on screen,
and the gutter is space taken from the plot, so a fixture would not settle it.

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
2. **A recovered packet decodes the parity buffer's padding as samples.** A recovered
   payload carries trailing zeros, and zero deltas decode as duplicates of the last real
   sample. iOS caps the decode at the sample count the transfer header implies.

   ⚠️ **This entry said "a recovered SHORT packet", and that understated it.** Reading
   Android's fix back (`ec6fb0d`, 2026-08-21) shows it is **every recovery**: the parity
   frame carries the full 239-byte payload capacity while a full data packet is 216, so
   there is padding to misread even when nothing is short. iOS was already right in both
   cases — the cap is on sample count, not on a short tail — but the reasoning written
   here was not, and the two platforms fix it differently: Android trims the recovered
   payload to the missing packet's real length via `compressedPayloadBytes`.

**Both landed on Android 2026-08-21 (`ec6fb0d`)**, so the divergence is closed and the
platforms agree. They were recorded here rather than fixed silently, because "Android is
the reference implementation" cuts both ways: a fix that lands here first is a divergence
until it lands there. **Neither platform has run the FEC path against a real lossy
transfer**, which is what would actually trust it.

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
  A flat average badly misprices whichever end the user picks. It also sums over the
  **source** zooms actually fetched, one level deeper than the map zoom — see the section
  below, which is where that 8%-low simulator reading (743 kB against a 690 kB estimate,
  on a 30-tile region) turned out to be the small end of a ~2.7× error.
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

#### The size estimate was ~2.7× low on BOTH platforms — fixed on Android first, then here

**Closed 2026-08-23**, porting Android `3f921a4` (`fix(maps): the download estimate
counted one zoom level fewer than it fetches`). It was found here on 2026-08-21 and
deliberately left alone, because the arithmetic is shared and fixing one side would have
had the two apps quote different sizes for the same region. Android is the reference
implementation, so it landed there and then here — unchanged, including the constant.

**Two errors that partly cancelled**, which is why the total read as ~2.7× rather than 4×:

1. **The count was one zoom level short.** The style declares `"tileSize": 256` against
   MapLibre's 512-point logical grid, so it fetches source tiles one level deeper than the
   map zoom asks for — four tiles where `TileMath.tileCount` counted one. A 22 × 22 km
   region estimated 12,484 tiles against MapLibre's own 49,155 resources: a ratio of 3.94,
   which is one whole level. `TileMath.sourceZoom(of:)` is now the one place that says so.
2. **`avgTileBytes` was ~1.5× high**, because those per-zoom figures were derived by
   dividing a real download by that same under-count. Fixing the count alone would have
   flipped the estimate from 2.7× low to 1.46× **high**, so both halves land together.

Rather than rewrite five numbers that would then read as measurements, Android kept the
historical table and named the one factor reconciling it with reality —
`TILE_BYTES_CALIBRATION = 0.68`, here `TileMath.tileBytesCalibration`, the same value from
the same anchor: the 9.1 × 9.1 km z10–z17 region that downloaded **139 MB** where the
corrected count and the untouched table predict ~205 MB. It is a calibration, not a
measurement — one anchor at one depth, inheriting the shape of everything else — and both
providers carry it, since both tables were built the same way in the same commit.

**The download is unaffected.** It is defined by the map-zoom range handed to
`MLNTilePyramidOfflineRegion` (Android: `OfflineTilePyramidRegionDefinition`) and always
fetched these tiles. Only the estimate was wrong.

**Correcting what this page used to say: low is NOT the safe direction.** The 1 GB guard
reads this number, so an under-estimate waves through a region that is really over budget
rather than refusing one that would have fit.

User-visible: the same regions now quote ~2.7× more, because that is what they cost. The
20 × 20 km BALLS region at z17 goes from ~230 MB to ~635 MB here (Android quotes 289 → 790
MB for its own slightly larger box). `TileMathTests` gained Android's six cases —
the convention, the ~3.9 ratio, the pyramid shape, the estimate against that 139 MB
download within 15%, and the direction guard that fails if either half of the fix is
reverted — and three existing tests changed, because they asserted the old arithmetic.


### Deployment Test — ported 2026-08-21, against `DeploymentTest.kt`

The smallest screen and the one with the least room for error: it fires a pyro channel.
**ADR-0027 is the whole design** — the USB-C console path was removed because it put the
operator's hand a metre from the e-match, so the radio path is the only way to fire a
channel, and everything on this screen follows from being the only path.

**The rule that shapes every line of it: the display follows the LOCATOR, never the app's
own hope.** Both frames involved are unacknowledged. The countdown arriving is the only
evidence a charge is live; the countdown going quiet is the only evidence a test has
ended, and canceled, fired and link-lost are indistinguishable from here — which is why
one silence watchdog covers all three.

Android learned this the expensive way, and the comment in its view model says so:
pressing cancel used to clear `active` immediately, which gated the countdown handler and
made the app **deaf to the countdown still running**. The button read "start" while the
locator counted down and fired, and nothing on screen disagreed. Ported deliberately:

| | Behaviour |
|---|---|
| Cancel | Marks itself pending and changes **nothing** else. The countdown stands until the locator stops sending one |
| A countdown arriving after a cancel | Keeps the test live and leaves the pending flag alone — a frame that crossed the cancel in flight is not the cancel being refused |
| Countdown value | Written only by the locator's frames and by the watchdog. There is deliberately **no setter** |
| An unsolicited countdown | Ignored — it belongs to a test this app did not start |
| Silence | 3 s, restarted by every countdown, ends the test whatever the reason |
| Leaving the screen | Sends a cancel and **does not clear the state** — a cancel lost on the way out would otherwise leave the operator walking off with a live charge and an app that had forgotten about it |
| Start button | Start **only**. It used to be the cancel too, which is why Android's manual had to warn that a press landing just after the countdown lapsed would start a FRESH test |
| Stop button | Present from the moment the screen opens, greyed until there is something to stop, so the way out is known BEFORE the countdown starts |
| Reachability | Armed only (`MenuGating`), because that is when the outputs are live — ADR-0021 |
| Channel labels | `Channel1`, not "Channel 1" — Android renders the enum's case names |
| Wire | **0 is not "nothing selected", it is CANCEL.** Both the stop control and the exit path send a channel byte rather than a different message |

**One difference found while testing, and fixed to match Android:** the start and cancel
actions were gated on being able to build the frame, so with no addressable locator
pressing STOP did nothing at all — no label change, no feedback. Android marks the state
regardless of whether the frame left the phone, and it is right: a lost frame and an
unbuildable one are indistinguishable from here, the watchdog recovers from both, and
"press STOP and watch nothing happen" is the worst answer this screen can give.

`DeploymentTestTests` pins all of it, including the watchdog, through two seams — the
silence interval and a frame-injection entry point — because reaching those rules the
real way would need three-second waits and a live radio, which would make the tests about
neither.

**Buttons are Android's, and it took two rounds of being told.** First the geometry, then
— reported as "the buttons are still different colors and shapes" — everything else.
`MaterialButtonStyle` now carries all of it, and every ported screen uses it; the
SwiftUI defaults were not near-misses of Material's buttons but different in every
dimension a user can see:

| | Material 3 | SwiftUI's bordered styles |
|---|---|---|
| Shape | fully rounded — a stadium | rounded rectangle, much tighter radius |
| Filled label | `onPrimary`, dark brown here | white, whatever the tint |
| Outlined | transparent with a 1 dp `outline` ring | a filled grey capsule |
| Label type | `labelLarge` — Poppins 14 | the system face at ~17 |
| Disabled | `onSurface` at 12% container / 38% label | the tint, dimmed |

The `Return` button is the clearest of these: Android's is a transparent outlined pill
and iOS was drawing a solid grey one. Three kinds are covered — `Button`,
`OutlinedButton` and `TextButton` — because Android uses all three, and Cancel, Dismiss
and Resume on the download screen are text buttons rather than the bordered controls they
had been.

**This is not the "Material clone" ADR-0016 warns against**, and the distinction is the
same one `ConfigRows` was built on: the sanctioned departure covers controls that look
*broken* when imitated — a Material switch drawn over iOS gestures. A button is the same
object on both platforms.

The geometry, which was the first round:

| | Android | iOS, measured |
|---|---:|---:|
| Start button height | 40 dp (M3 default) | 39.7 pt |
| Stop button height | 48 dp (set explicitly) | 48.1 pt |
| Gap above the stop button | 12 dp | ~14 pt |
| Gap below the dropdown | 16 dp (`EnumDropdown` carries it) | 16 pt |
| Horizontal content padding | 24 dp (`ButtonDefaults.ContentPadding`) | 24 pt |
| Control column inset | 16 dp screen + 40 dp start | 56 pt |
| Return button | `weight(1f)`, so full width, 40 dp | full width, 40 pt |

**Two traps worth recording**, both of which look correct in code and are not:

1. **`frame(height:)` on a SwiftUI `Button` sizes its layout box** and leaves the pill
   hugging the label inside it — the control claimed 40 pt of space and drew a 31 pt
   shape. Moot now that `MaterialButtonStyle` pads the label itself, which is the right
   place for it.
2. **A nested type named `Body` inside a `ButtonStyle` is matched against the protocol's
   own associated type**, and the compiler reports it as "does not conform", naming
   neither. It is called `Pill`.

**Deliberate divergence: none.** The only iOS-specific choice is the picker, which is
`ConfigPickerRow` — already the sanctioned substitute for Android's `EnumDropdown`, and
the same one Locator Settings uses.


### App icon — matched 2026-08-21

iOS shipped with **no icon at all**: `AppIcon.appiconset` held a `Contents.json` and
nothing else, so the home screen showed the blank placeholder. It now carries Android's,
generated by `Tools/make_app_icon.swift` from
`rocket-flight-manager/app/src/main/steam_pigeon-playstore.png`.

**The trap, which caught this first time round: `ic_launcher` is still in the Android
repo and is NOT the app's icon.** It is the Android Studio template — the green bugdroid
on `#3DDC84` — left behind when the real icon landed. The manifest points at
`@mipmap/steam_pigeon` (and `@mipmap/steam_pigeon_round`), whose adaptive definition is a
rocket foreground over a `#000000` background from `values/steam_pigeon_background.xml`.
The two look nothing alike, and the leftover is the one with the obvious name. Had it
shipped, the iOS app would have worn Google's robot — which is also a trademark problem
on Apple's platform, quite apart from being the wrong picture.

**Why the Play Store asset is the source.** Three candidates, and the choice is about
resampling:

| Source | Size | To reach 1024 |
|---|---:|---|
| `steam_pigeon-playstore.png` | 512 | 2× — **chosen** |
| `mipmap-xxxhdpi/steam_pigeon_foreground.webp` | 432, of which only the central 72/108 is visible | 3.6× from an effective 288 |
| `mipmap-xxxhdpi/steam_pigeon.webp` (legacy) | 192 | 5.3× |

The adaptive foreground cropped to its safe zone and the Play Store square were compared
side by side: same composition, nothing important cut, so the sharper source wins.

**Two things the generator does that copying the file would not.** It composites onto
`#000000`, the adaptive icon's background colour — the Play Store art carries alpha and
an iOS icon must not, since Xcode warns and the App Store refuses one outright — and it
resamples once, at high interpolation quality.

**The adaptive-icon safe zone has no iOS equivalent**, and that is the real difference
between the platforms here. Android reserves the outer 18 dp of a 108 dp canvas for mask
and parallax; iOS fills the square and rounds the corners itself. Checked on the
simulator home screen: the superellipse trims only background, and the rocket, its
exhaust and the stars all survive.

**The name under the icon: SteamPigeon. Decided by fschroer, 2026-08-21.**

The two home screens disagreed — Android's `app_name` is **"Wherezit?"**, iOS's bundle is
`SteamPigeon` — and since that is the label printed under the icon, it is the other half
of making them match. Asked, and answered: **SteamPigeon is the name.**

So iOS is already right, and this is the second thing **Android owes iOS**: `app_name` in
`app/src/main/res/values/strings.xml` still reads "Wherezit?", and so does the header
comment in the bundled `launch_sites.csv` template. Nothing on iOS changes.

One detail left over, small and worth deciding once rather than drifting: the app is
**"SteamPigeon"** under the icon (the bundle name) and **"Steam Pigeon"** in the nav bar,
the docs and both repo names. Neither is wrong, but they are two spellings of one name,
and the home screen is the more public of the two.

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

### Communication screen + locator search — ported 2026-08-28, against `CommunicationScreen.kt`

Ported from Android `b878c32..e9f93d7` (23 commits) and receiver `b9dece4..aa9edc6`, to
[ADR-0029](../../steam-pigeon-locator/docs/adr/0029-locator-search-candidate-channels.md)
and the port brief `docs/ios-port-brief-locator-search.md`. **The brief's first
instruction is the one that mattered**: several decisions were reversed after first
shipping, most of them because hardware disagreed, and the reversals are what had to be
implemented. Each is carried into a comment at the site it governs, so the next reader
does not re-derive the version that failed:

- a scan pick **applies** on the tap; it does not stage;
- "Connected" needs the **channel and the identity**, not either alone;
- occupancy excludes the connected locator **by identity**, not by channel;
- a **miss is target-aware** — with a target named, finding somebody else is still a miss;
- **widening is offered after any *completed* short run**, not only a missed one, and
  never after a cancelled one;
- a queued command **ends** a sweep rather than waiting behind it, which is why
  `ChannelSurveyStatus.Cancelled` exists and must not be folded into `RefusedBusy`;
- the version stamp is a **resource**, not a compile-time constant.

**Wire format.** `ChannelSurveyResponse` 84 → **104** (payload 78 → 98) from a new
`confirmed_locator_id[5]`; `LocatorSearchRequest` 28 / 22 and `LocatorSearchResult`
**39** / 33 are new. `WireLayoutTests.swift` pins all three with **parts-sum** cases as
Android's `WireLayoutTest.kt` does — a total-size assertion cannot catch a field-order
mistake, and both new messages carry adjacent same-width fields where one could hide.
The survey change is **breaking in both directions**, because the app frames that message
by exact length before checking its CRC: an app on 84 desynchronises against new firmware
and an app on 104 desynchronises against old firmware. A decode test builds the 104-byte
frame at the firmware's offsets and a second one truncates it to 84 to prove an older
receiver still reads, with the ids simply absent.

**What is NOT ported, deliberately.** ADR-0029 decision 7's flag-based mid-run abort. It
is unreachable in the firmware — `locator_armed_` is assigned only in `ProcessRadioRx`
branches a sweep returns before reaching — and beneath that sits a physical limit:
parked on another channel the receiver cannot hear a locator arm. The start gate (refuse
while armed or in flight) is the receiver's, and the command-path abort is the receiver's
too; the app's share is decoding `Cancelled` and saying what happened, which it does.

**`last_channel`.** Stored in a **third** `UserDefaults` key beside the password keys and
the labels, so an existing install keeps both. Held as `[UInt32: Int]` rather than an
`Int` defaulting to 0 — channel 0 is the factory default (ADR-0025), so "never heard" and
"heard on channel 0" have to stay distinguishable, which is the same reason Android's
proto field is `optional`. Written from the channel carried by **that frame** where the
message has one (`PreLaunchData` does; `TelemetryData` has no room and falls back to the
cached config), and written from the same two branches as the name — `.accepted` and
`.conflict`, never `.unauthorized`, since seeding a search with a stranger's channel
spends a dwell looking somewhere you have no reason to look.

Android's merge hazard does not arise here in the same shape: the three maps are separate
dictionaries and `persist()` rewrites all three from memory, so no writer can drop a field
it does not know about. The hazard is recorded anyway, because the next field added is
where it would come back.

#### Found in the Android implementation

The brief asks for this explicitly, and two of the three are real.

**1. `ChannelOccupancy.occupantOf` reports `00000000` down the search path where the
survey path deliberately reports nothing.** The survey branch ends with
`occupied.locatorId.takeIf { it != 0L }?.let { "%08X".format(it) }`, and
`ChannelOccupancyTest`'s "an occupied channel with no id reports nothing rather than zero"
pins that: a frame that decoded but carried no id gives occupancy without identity, and
naming it `00000000` would be a lie. The search branch above it has no such guard —
`hit.deviceName.takeIf { it.isNotEmpty() } ?: labelOf(...) ?: "%08X".format(hit.locatorId)`
— so a hit with `found = 1` and `locator_id = 0` renders as "00000000 was last heard on
channel 12". Reachable: `LocatorSearchResult.locator_id` is documented as 0 "when the
frame carried no id", exactly as the survey's is.

**Mirrored rather than fixed here**, per "Android is the reference implementation": the
iOS `ChannelOccupancy` has the same asymmetry, so the two apps still say the same thing.
It should be fixed on Android first — the survey branch's `takeIf { it != 0 }` applied to
the search branch too — and ported back.

**2. The candidate list's middle is order-unstable across runs.**
`RocketViewModel.searchCandidates` builds `knownChannels` from
`known.filterKeys { … }.values`, where `known` is a protobuf map whose iteration order is
not specified. The target channel is first and the default and current channels are
appended last, so the *load-bearing* positions are fixed — but which of several remembered
channels survive the 16-channel cap, and in what order, can differ between two runs with
identical stored state. With more than 14 remembered locators that changes which channels
are actually searched. **iOS diverges here**: `searchCandidates` sorts the other locators'
channels by id, so the list is reproducible. This is a small, deliberate divergence in
favour of determinism and it is recorded here rather than left silent.

**3. Not a bug, checked and cleared.** `Run.suspectChannels` filters the non-best hits
with `!==` (reference identity) rather than `!=`. That reads like a mistake and is not:
two hits for one locator that are equal by value would both be dropped by `!=`, leaving
neither channel offered. Swift has no reference identity for a struct, so the port
compares `channel` instead — which is equivalent given the firmware reports each channel
at most once per run, and that assumption is now written at the call site.

#### ⚠️ ANDROID OWES THESE — iOS-first fixes not yet on Android

**The canonical list.** Recorded at fschroer's instruction (2026-08-29). Each is an
explicit, authorised exception to "Android is the reference implementation", taken because
the defect was reached from the phone during flight-test prep. Every claim below was
re-verified against the Android source on 2026-08-29 at the line cited.

| # | Defect | Android evidence | iOS fix |
|---|---|---|---|
| 1 | **A changed password permanently bricks the connection.** Once connected, a locator whose password is changed on the device can never be re-authenticated: its frames stop authenticating so nothing is admitted, `connectedLocatorId` goes on naming it because nothing releases a connection on an auth failure, and the passive challenge refuses to prompt while anything is connected. The only things on screen are a conflict banner calling the connected locator "another locator" and a panel reading "No Locator" over the last good RSSI. **No recovery inside the app** short of dropping the BLE link | `RocketViewModel.kt:1232` — `_connectedLocatorId.value == null` gates the passive challenge | `ChallengePolicy.Trigger.credentialsChanged`: an unauthorized frame **from the holder itself** releases the connection (a stale belief, not something to protect) and prompts, asking even though something was connected and even if that locator was declined before. A *stranger* still cannot knock out a standing connection |
| 2 | **Connect / pick buttons stay live while a change is in flight, and the channel is staged before the send is accepted.** The second tap is refused by the in-flight guard and does nothing at all; meanwhile the Receiver channel field shows a channel the app never visited, with an enabled Update button offering to apply it | `CommunicationScreen.kt:1043` — hit-row `Button` with no `enabled`; `:307-309` and `:352-354` — `stagedReceiverChannel` written *before* the guarded `pointReceiverAtChannel` | `pointReceiverAtChannel` returns whether the change was **accepted for sending** — i.e. whether the in-flight guard passed, not whether the write reached the receiver (see the iOS gap below); callers stage only on success. Search Connect and survey pick are disabled while the change they would make is in flight |
| 3 | **The released locator's configuration is left on screen.** After a receiver-only channel change the Locator channel field goes on showing the *previous* locator's channel, and corrects only when a `PreLaunchData` from the new one is admitted — so a locator that is never admitted leaves it wrong indefinitely. Reported 2026-08-29: receiver reading 48, locator field reading 34, two real locators on two real channels | `RocketViewModel.kt:1245-1263` — `beginChannelChangeRecognition` clears ten fields and **not** `_remoteLocatorConfig` | `remoteLocatorConfig = LocatorConfig()` on release, matching what `clearLiveReadouts` already does when the link drops |
| 4 | **The candidate list's middle is order-unstable between runs.** `knownChannels` comes from a protobuf map whose iteration order is unspecified, so which remembered channels survive the 16-channel cap — and in what order — can differ between two runs with identical stored state. With more than 14 remembered locators it changes which channels are actually searched | `RocketViewModel.kt:903` — `.values.mapNotNull { … }` over `knownLocatorsMap` | `searchCandidates` sorts the other locators' channels by id, so the list is reproducible |

#### ✅ Known on both platforms — fixed on Android 2026-08-29, **ported to iOS 2026-09-01**

**`ChannelOccupancy.occupantOf` renders `00000000` down the search path** where the survey
path deliberately reports nothing — full description in the ADR-0029 audit above. It was
mirrored rather than fixed here, per "Android is the reference implementation"; Android has
now moved, and both changes have landed on iOS in `ChannelOccupancy.swift` and
`ChannelOccupancyTests.swift` (three new cases, mirroring Android's three). The
`unrecognizedLabel` parameter is a constant with a default rather than a resource lookup,
because this app's strings are inline; the hit row already said the same words. What was
owed:

1. **An anonymous search hit is named, not hexed, and does not swallow the survey.** The
   two scans part company deliberately. The **survey** still reports nothing: its
   `locator_id` slots are also zero against pre-ADR-0029 firmware (an 84-byte response
   carried no ids), so "id 0" there cannot be told from "this receiver does not report
   ids". The **search** cannot be ambiguous — `LocatorSearchResult` is new and has always
   carried the field — so a zero means precisely "the frame that was heard carried no id",
   and the answer is `An unrecognized locator` (`R.string.channels_occupant_unrecognized`,
   matching what the hit row itself already says). Reachability is much better than this
   file first claimed: receiver `Communication.cpp` captures a hit for **any** frame that
   clears `ParseLoraFrame` and fills `sender_id` only from `PreLaunchData` and
   `TelemetryData`, so a dwell landing on a flight-data transfer, a deployment test or an
   arm command scores a hit with no id — routine at a launch. The naive fix is wrong: both
   ports `return` from inside the search branch, so making it yield nothing **skips the
   survey fallback**, and answering "nobody knows" over an answer the app already holds is
   worse than the `00000000` it replaced. Fall through instead, and use the label only when
   the survey has nothing either.
2. **A hit the run itself calls suspect is not an occupant.** Neither platform consulted
   `Run.suspectChannels` here, so a near-field phantom — the 57-reported-on-17 artifact the
   `snr` field exists for — was named as the occupant of a channel that is free, in **red**,
   under the words "moving here would put two locators on one channel" — while the hit row
   three inches above flagged that same row `· likely false hit`. The screen contradicted
   itself and talked the user out of a good channel. The firmware reports at most one hit
   per channel per run, so dropping the suspect one leaves the channel to the survey rather
   than to a second hit.

Android side: `ChannelOccupancy.kt`, `CommunicationScreen.kt` (both call sites pass
`unrecognizedLabel`), `strings.xml`, and three new cases in `ChannelOccupancyTest.kt`.

#### ✅ CLOSED 2026-09-01 — the armed refusal was only reachable by pressing

Android greys both scan buttons while the locator is armed or flying and shows the reason
above them (2026-08-30); iOS offered the buttons and surfaced the refusal only after a
press. `LinkViewModel.locatorArmedOrFlying` now carries the receiver's condition and sits
directly beside `isInFlight`, which is the only way the difference between them stays
visible. Mirror the **receiver's** condition — armed, or a flight state that is neither
`waitingLaunch` nor `landed` — not the flight panel's "in flight", which counts `landed` as
flying and would grey out a scan the receiver would have run. The receiver's gate stays the
real one; this is an affordance.

#### ✅ CLOSED 2026-09-01 — a scan's silence read as a missing locator

**`MapStatusPanel.locatorText` returned "No Locator" while a scan was running**, the same
way Android did until 2026-08-30. It now takes a `scanInProgress` string and reports it as
a fourth case, ahead of the freshness test, with two cases in the panel's tests. Its three documented cases have no fourth for "the receiver is
parked on another channel because the user asked it to be", and a whole-band search is up to
~90 s of that.

It contradicts the arm control, which stays live throughout — correctly, since ADR-0029
decision 7 has a queued command end the sweep so an operator's Arm is never silently
delayed. The panel therefore invites pressing Arm in the belief that nothing can happen, and
then it happens. That is the inverse of the hazard decision 7 fixed, and worse at a pad.

Android's fix: the locator row reports the scan — `Searching…` for a locator search,
`Scanning…` for a survey — before it considers reporting an absence. `locatorText` is
already static "so the rule can be tested without a view"; the scan state belongs in it as a
fourth case, ahead of the freshness test, with a case in the panel's tests.

**Do not "fix" the arm gate instead.** Gating arm/disarm on freshness rather than on the
connection would put back an Arm that appears to do nothing during a sweep.

#### ✅ CLOSED 2026-09-01 — the survey section hid its own scan

**`CommunicationView` gated the survey section on `hearingLocator` alone**, the same way
Android did until 2026-08-30. It now reads
`hearingLocator || model.surveyInProgress || model.channelSurvey != nil`. A sweep leaves the receiver deaf for ~7.8 s, which
is longer than the 5 s silence window that gate is judged on, so the section hides itself
about five seconds into its own scan — taking the *"Scanning…"* indicator with it — and
reappears with the results once broadcasts resume. Reported from the Android bench as the
indicator vanishing and results arriving three or four seconds later; nothing was slow, the
screen had stopped saying what it was doing.

Android now reads `hearingLocator || surveyInProgress || channelSurvey != null`. The third
term is load-bearing, not cautious: without it the section hides again at the instant the
results land — the sweep has ended, so in-progress is false, while the locator's next
broadcast is still up to a second away — and flickers back a moment later. Results do not
outlive the visit on either platform; the entry-time clear drops them, with the same
*except one still running* exception.

> **Do not narrow this gate again — since 2026-09-02 it holds a control, not just an
> indicator.** Both apps gained a **Stop** button on the sweep that day (ADR-0019 tier 3
> item 5, `MsgType` 25), and on both it lives inside this section. Had this fix landed a
> day later, the button would have vanished about five seconds into an ~8 s sweep, taking
> itself away for exactly the stretch someone reaching for it is in. The feature is
> matched on both platforms — same message, same wording, same `cancelledByUser`
> substitution — and it is matched partly *because* this closed first. The cost of
> reintroducing the narrow gate is no longer a missing "Scanning…" label; it is a scan
> that cannot be called off.

The rule the gate encodes (ADR-0029: the sweep is offered only while a locator is heard) is
unchanged. It is about **offering** a scan, and was being applied to one already under way
— the same mistake, in the same file, that clearing the scans unconditionally on entry made
in the other direction.

#### ✅ PORTED 2026-09-01 — a channel move reverted the receiver on silence, not on evidence

**`LinkViewModel.recoverLocatorChannel` fires on the absence of a confirmation, and that
condition does not distinguish two opposite failures.** Landed on Android and in the
receiver firmware 2026-08-30 and then **bench-validated across four passes, which changed
the design four times** — read [ADR-0011](../../Locator/docs/adr/0011-locator-lora-channel-from-app.md)'s
amendment *"revert on evidence, not on silence"* before writing anything. This is a
behaviour change, not a transliteration, and every correction below came from hardware
rather than from review.

**Updated 2026-08-30 after issue #20 closed.** An earlier version of this entry described
the first cut. Do not port that; port what is here.

The short form. There is no acknowledgement message — a move is confirmed by inference from
the next `PreLaunchData` relayed on the new channel. So what goes missing on a "failed" move
is a *broadcast*, and two states produce the same silence: the locator missed the command
and stayed behind while the receiver followed (a real split), or everything moved and the
confirmation was late. Reverting is correct for the first and **manufactures** the split for
the second, in the direction that strands the rocket, because the locator's move is
flash-persistent.

##### What to port, in dependency order

1. **A transmit receipt re-bases the confirm window — and is LATCHED.** The receiver now
   emits a `ReceiverInfo` when it follows a locator change on its own initiative (it always
   answered a `ReceiverCfgChgRequest`; the follow was silent). Reaching that code proves the
   forward *transmitted*. Start the confirm window from it rather than from the BLE write.
   Match on the channel — a receipt carrying the *old* channel is the recovery revert
   answering and must not re-base.

   **Latch it: only the FIRST match may re-base, and cap the wait absolutely.** iOS has the
   same 2 s `ReceiverInfo` poll while the locator is silent, which is exactly the state an
   unconfirmed move is in. Re-basing on every reply pushed the deadline out 5 s each time,
   and 2 s < 5 s meant **the window never closed** — banner stuck on "Moving to channel N…",
   probe never ran, receiver left on the new channel with the locator on the old one. A lost
   locator, reintroduced by the fix for lost locators. Port `ChannelMove.confirmDeadline`
   and its tests; the cap is the second guard because the latch should not have to be right
   alone.

   **Use the receipt only to re-base, never to short-circuit.** Its absence is ambiguous
   against a receiver predating it.

2. **Probe before reverting, as a census.** On timeout, one `LocatorSearchRequest` over
   exactly two channels — new first, then old — with `target_locator_id = 0` so **both**
   1.4 s dwells always run. Never a targeted run that stops on the first hit: a locator a
   few feet from the receiver decodes on channels it is nowhere near and the artifact reads
   as *strong* (ADR-0029, bench 2026-08-28), so the decision must compare two dwells by
   `rssi + snr`. A tie is `NoEvidence`, never a revert. This probe runs while the user is
   holding the locator, which is exactly the range that produces the artifact.

3. **A refused probe is not an empty one.** The receiver refuses a `LocatorSearchRequest`
   while an operator command is queued, and `IsOperatorCommand` counts a
   `LocatorCfgChgRequest` as one. With the locator silent the forward can never leave, so
   **the undelivered command blocks the very probe that would explain why it was
   undeliverable**, until `kPendingTxStaleMs` (10 s) drops it — and the first probe lands
   ~5 s in. Return a distinct **`NotChecked`** verdict and re-ask once after ~6 s, sized to
   outlast that drop. Treating the refusal as "heard nothing" is the app mistaking its own
   blindness for the locator's absence.

4. **Ask silence twice.** A `NoEvidence` verdict re-probes once before it is accepted —
   ADR-0029's *zero frames proves nothing* applies directly, since one 1.4 s dwell can miss
   a 1 Hz burst, and `NoEvidence` is the branch that ends with the receiver on a channel
   nothing has been heard on.

5. **Act on the verdict.** `Confirmed` → success, revert nothing. `LocatorStayed` → revert
   and retry once. `NoEvidence` / `NotChecked` → report and move nothing.

6. **The retry is not exempt from the rule.** The retried `LocatorCfgChgRequest` is itself a
   single unacknowledged frame on the channel being left, and the receiver follows it
   regardless — so losing it reproduces the split one layer down. Measured at **~1 run in 8**
   before it was fixed. After the retry's timeout, probe **once more**; on `LocatorStayed`
   put the receiver back so the run ends together rather than split. The invariant: *a failed
   move never ends with the receiver on a channel the probe did not confirm.* Bounded — no
   recursion, no second retry.

7. **Relink on evidence.** The wait after a revert must require a frame admitted *after* the
   revert was asked for. Both channel readings are updated only by a relayed `PreLaunchData`,
   so testing them alone passes on the first poll having verified nothing.

##### The messages, which is where three of the six defects were

Port `ChannelMove.message` and its tests rather than branching inline. **No sentence may
claim the receiver is somewhere the app has not read.**

- *"left on its previous channel"* — true after an evidenced revert, false on the path that
  leaves the receiver on the new channel.
- *"the receiver is on channel N"* — must name the channel actually **reported**, not the one
  aimed at. When the forward never transmitted the receiver never left, and the message named
  the wrong one.
- **"Nothing moved" deserves its own sentence, in ordinary text and not error colour**:
  *"The locator did not respond, so nothing was moved. The receiver is still on channel N —
  power the locator up and the link should resume."* That is a much smaller problem than a
  stranded locator and the user should not have to work out which they have.
- **The banner must outlive the state that produced it.** The terminal state resets to Idle
  on a 2 s timer, so the outcome of a cycle that can run ~23 s was legible for two. Hold it
  until dismissed or superseded.
- **Dismissing the banner must not discard the staged channel.** It is what puts the
  unconfirmed move into the ADR-0029 search candidates, so clearing the error threw away the
  one channel worth searching. Keep the banner's channel and the search-candidate channel as
  two separate things — conflating them also made a *successful* move clear its own "Now on
  channel N" in the same instant.

##### Reference and status

Android, in the order to port them:

- **`ChannelMove.kt`** — the individual decisions, all pure: `verdict` / `action` /
  `confirmDeadline` / `relinked` / `message` / `probeChannels`. Pinned by
  `ChannelMoveTest` (11) and `ChannelMoveOrchestrationTest` (16).
- **`ChannelMoveRunner.kt`** — the **sequence**: how many times to look, what may move,
  in what order. Holds no state, no timing, no flows and no platform types; every side
  effect goes through its `Ops` interface. Pinned by `ChannelMoveRunnerTest` (17), which
  drives it against a scripted fake and asserts the exact call order.
- **`RocketViewModel.channelMoveOps`** — the live side: the search, the two BLE writes,
  the two waits, the clock. This is the only part with a service in scope, and the only
  part still uncovered.

**Port the two data files and all three test suites first.** Every one of the six defects
was found by hand on a bench because the sequence sat inside a coroutine holding a service
and nothing could reach it. On iOS the same logic is inside `LinkViewModel`; splitting it
the same way is most of the work, and the tests are what stop iOS rediscovering the
sequence one bench run at a time.

Issue #20 is closed: criteria 1, 2, 3, 5 pass on hardware; 4 was retired as unreachable.

**Ported 2026-09-01.** `ChannelMove.swift` and `ChannelMoveRunner.swift` carry the two data
files, with all three test suites ported case for case — `ChannelMoveTests` (12),
`ChannelMoveOrchestrationTests` (14) and `ChannelMoveRunnerTests` (18), the last driving
the sequence against a scripted fake and asserting the same call order Android's does. The
live side is `ChannelMoveLiveOps` in `LinkViewModel`, which replaced `recoverLocatorChannel`
— the revert-on-silence cut this amendment exists to remove. The receipt latch
(`channelMoveReceipt`), the hard deadline in `waitForLocatorConfig`, the separated banner
channel and the five `ChannelMove.message` sentences all landed with it.

Two mapping notes, neither a behaviour change: times are `Date`/`TimeInterval` where
Android uses epoch milliseconds, so "no receipt" is `nil` rather than `0`; and iOS polls
for the probe's terminator on a 100 ms loop where Android suspends on
`locatorSearch.first { … }`, because there is no flow to await.

**Still not bench-validated on iOS** — nor on the simulator in any meaningful sense, since
none of this path exists without a receiver. It is pinned by 44 tests and by nothing else.

#### ✅ CLOSED 2026-09-01 — the channel being left reclaimed the connection mid-move

**`admit`'s `.accepted` branch cleared `awaitingChannelRecognition` and took the
connection with no test on which channel the frame was relayed from.** Reported on
Android 2026-08-29 and fixed there; iOS had the identical hole.

`LocatorConnection.isFromChannelBeingLeft` is ported with Android's five cases in
`ChannelChangeRecognitionTests`, plus two end-to-end ones. **One shape difference worth
knowing:** Android calls the guard between `noteLocatorChannel` and `mayConnect`, which
are separate steps there. iOS's `gate.evaluate` authorizes and takes the connection in one
mutating step, so the guard is asked *before* `evaluate`, using `gate.isAuthorized` — the
name and last-heard channel are still recorded first, exactly as Android records them.

`beginChannelChangeRecognition` releases the connection *before* the change goes out, so
between the BLE write and the receiver's retune the slot is empty and **the locator being
left is still broadcasting on the old channel at 1 Hz**. Those frames are authorized,
`gate.evaluate` accepts them into the empty slot, and `.accepted` switches off the very
recognition cycle the move armed. The frame that then arrives from the new channel finds
nothing armed and gets the passive treatment — a conflict banner, and **no password
prompt**, for a locator whose password the app does not hold.

Reported sequence: four locators on four channels, connected to Twist 0 on 34, Connect
tapped on Twist Lock 5's search hit on 60. Receiver channel reads 60, Locator channel
still reads 34 (repopulated from the old locator's own broadcast), conflict banner up,
no prompt — and the banner's own Connect action raises the prompt and works, which is
what makes it look like one route works and the other is broken. **Intermittent**, because
it is a race against a 1 Hz broadcast landing in a window of a few hundred milliseconds.

Android's fix is `LocatorConnection.isFromChannelBeingLeft(frameChannel:previousChannel:
awaitingRecognition:moveInFlight:)` — pure, five cases in `LocatorConnectionTest`, called
from the authorized branch after the name and last-heard channel are recorded (those are
true facts about a locator we are authorized for, and the search runs on them) and before
`mayConnect`. Three details the port must keep:

- **The discriminator is the receiver's channel stamp** (ADR-0011 invariant 3), which iOS
  already threads into `admit` as `receiverChannel`. A frame stamped with the channel
  being left says nothing about the one being moved to.
- **A frame with no stamp waits too.** `TelemetryData` cannot be placed during the window,
  and guessing is the bug. An armed locator on the new channel is admitted a few seconds
  later when the move resolves, and could not have raised a challenge meanwhile anyway.
- **The window is bounded by the config exchange, not by the recognition flag.** The flag
  may never resolve — a move onto an empty channel — and suppressing on it alone would
  leave the app deaf to the locator it still has. Android uses
  `receiverConfigMessageState != Idle`, which always returns to idle whether the move is
  acknowledged or times out; `ChannelChangeRecognitionTests` is where the iOS equivalent
  belongs.

Full account in ADR-0011, "The channel being left keeps broadcasting into the slot the
move just opened".

#### ✅ CLOSED 2026-09-01 — a gap found while auditing the "Android owes" list

**Every `transport.send` result was discarded, so a failed write was reported as `Sent`.**
`BluetoothTransport.send` returns `Bool` — false when the peripheral, the write
characteristic or the `.ready` state is missing — and is marked `@discardableResult`, so
the compiler never complains. All 17 call sites in `LinkViewModel.swift` ignore it, and
`changeReceiverConfig` sets `receiverConfigMessageState = .sent` unconditionally on the
line after the call.

**Android does check.** `RocketViewModel.pointReceiverAtChannel` reads
`if (service?.changeReceiverConfig(target) == true) Sent else SendFailure`, so a write that
never left surfaces immediately. On iOS the same failure is invisible for five seconds and
then arrives as a generic read-back timeout, which names the wrong cause: "the receiver did
not acknowledge" rather than "nothing was sent".

This is **pre-existing, not introduced by the Communication screen** — it predates the
ADR-0029 port and touches every outbound message, not only the channel change. It is
recorded here because it is what makes the "Android owes #2" row above an overstatement:
iOS's `pointReceiverAtChannel` reports that the in-flight guard passed, which is a weaker
claim than "the change went out". The user-visible half of that fix — staging only after
the guard — is real and Android genuinely owed it.

**Closed 2026-09-01.** `send`'s result is now read at the five sites that have a failure
state to set — `changeReceiverConfig`, `changeLocatorConfig`, `openFlightProfile`,
`requestFlightProfileMetadata` (which returns it, for the retry loop that already branched
on it) and `toggleArmed`. `@discardableResult` stays only on the fire-and-forget sends that
have nowhere to report to.

`transport` is now a `LocatorTransport` behind an injected default, which is what made this
testable: `SendFailureTests` drives a transport that accepts nothing and asserts each site
reports the failure rather than `Sent`. The protocol deliberately does **not** mark `send`
`@discardableResult` — the compiler never complained about the 17 discards, and this is the
one place that can.

**Arm/disarm departs from Android's shape, not its behaviour.** Android sets
`locatorArmedMessageState = SendFailure`; iOS carries arm state as `armCommandPending`, so
the equivalent is to not blink for an acknowledgement that cannot come, and to say so via
`transientMessage`.

**The deployment-test path was left alone, deliberately.** The list above named it, but
Android discards that result too (`DeploymentTest.kt:62`, `:92` — bare
`service?.deploymentTest(…)`), so checking it on iOS would be a divergence rather than a
port. If it should be checked, it is Android's change to make first.

#### iOS-only, nothing owed to Android

Platform mechanics with no Android counterpart, listed so they are not mistaken for
divergences Android should adopt:

- **One `.sheet` for the whole app** (`RootSheet`). An ancestor cannot present while a
  descendant is presenting; Compose's dialogs and `NavHost` have no such constraint.
- **`interactiveDismissDisabled()` on the password prompt.** Compose's `AlertDialog`
  dismisses on an outside tap; on iOS a swipe is far easier to trigger by accident, and
  the consequence here is a channel revert. In the divergence table above.
- **`SectionHelp`'s 16.4 availability branch.** Restores Android's shape where the API
  exists; Android has nothing to change.

#### An iOS gap this port did not close at first — **closed 2026-08-29**

Android arms a **channel-change recognition cycle** before a receiver-only channel move
(`beginChannelChangeRecognition`, ADR-0011): the next `PreLaunchData` on the new channel
is recognised, challenged for a password, or the channel is reverted. That is what makes
applying a pick immediately safe rather than reckless, and it also feeds
`searchCandidates`'s `attemptedChannel` with `channelChangePreviousChannel`.

**iOS had never had it**, and fschroer hit it from the phone the same day: after a
whole-band search, tapping Connect on a *different* locator's hit left every row reading
"Connect", the Receiver channel field following the new channel while the Locator channel
did not, and the main screen showing no locator at all — "as if the receiver was set to
another channel entirely".

The receiver was on the right channel throughout. **The app was refusing to display what
was on it.** `pointReceiverAtChannel` moved the receiver without releasing the connection,
so the old holder stayed in the slot while off-channel and silent, and the locator on the
new channel was refused — as `conflict` for the 15 s `connectionHold` if it was
authorized, and **permanently** if it was not, because `ChallengePolicy`'s passive trigger
only prompts while nothing is connected. Every reported symptom follows from that: no row
can satisfy `connectedOn`'s two halves when `currentChannel` has moved and
`connectedLocatorId` has not, and `remoteLocatorConfig` is only rebuilt from admitted
broadcasts, so the Locator channel field kept showing the locator that had been left
behind.

**Ported 2026-08-29** from Android's `beginChannelChangeRecognition`, which is why Android
never showed this:

- `pointReceiverAtChannel` arms the cycle **before** the change goes out, releasing the
  connection and dropping the old channel's link measurements — they are wrong
  immediately, not gradually;
- an unauthorized locator on the new channel is challenged with the `.channelChange`
  trigger, which asks even while something is connected and even for a locator declined
  before, and does **not** also raise the conflict banner — the user chose this channel;
- cancelling that challenge **reverts** the receiver, since it is the only way back;
  `PasswordChallengeView` labels it "Cancel" rather than "Not now" in that case, mirroring
  Android's `cancel`/`dismiss` split;
- `searchCandidates` feeds the channel we came from as the attempted channel while the
  move is unresolved, as Android does.

One more divergence closed on the way, in `submitPassword`: iOS remembered the key and
left the connection to the next broadcast, which works only when the slot is free — with a
previous holder inside `connectionHold`, a *correct* password bought 15 s of blank screen.
Android connects immediately on accept; iOS now does too.

`ChannelChangeRecognitionTests` pins each symptom in the report. Writing them surfaced a
latent fragility worth naming: `KnownLocatorStore` persists to `UserDefaults.standard`,
which on the simulator outlives the whole suite, so any test needing an *unauthorized*
locator silently stops testing that once some earlier run has stored a password for the
same id — and it fails open, because the polluted path is the one where everything appears
to work. `LinkViewModel.init` now takes an injectable `defaults` and these tests use a
per-case suite.

#### Three more from the phone, 2026-08-29 — connecting to an unauthenticated locator

**1. The Connect buttons stayed live while a change was under way.** Tapping a second
one did nothing at all: `pointReceiverAtChannel` refuses while
`receiverConfigMessageState` is not idle, so the send was dropped — the "a control that
silently did nothing" failure this screen exists to avoid. Worse, the *view* staged the
channel **before** asking, so the Receiver channel field showed a channel the app had
never visited, with an enabled Update button offering to apply it.

`pointReceiverAtChannel` now returns whether the change was accepted for sending — the
in-flight guard passed — and the callers stage only on success; the search's Connect and the survey's pick are disabled while the
change they would make is in flight. **Android has the same defect** — its
`LocatorSearchSection` hit row is a bare `Button` with no `enabled`, and its `onPick`
stages `stagedReceiverChannel` before calling a `pointReceiverAtChannel` with the same
guard. Worth fixing there.

**2. The Locator channel section disappeared when the prompt appeared.** Expected, and
**identical on Android**: `beginChannelChangeRecognition` releases the connection, and
both platforms gate that section on `connectedLocatorId != null`. It is mechanically
right — the locator channel is a locator-directed command (ADR-0020), so with nothing
connected there is no locator to address and the control would be inert. Left as Android
has it; if the vanish is to be softened, that is a change to make on Android first.

**3. The password prompt could not be answered from this screen.** The deep one.

`SheetRouting.swift` enforced "one sheet per screen" and that was not enough. `MapScreen`
presented the menu and its destinations; `RootView`, which *contains* `MapScreen`,
presented the challenge and diagnostics — one each, and still two presentations in one
chain, because an ancestor cannot present while a descendant already is.

Measured on the simulator with the Communication screen open and a challenge raised:

```
challenge set        ← nothing appears
prompt appeared      ← only after the Communication sheet was dismissed
prompt disappeared      …then churns, all inside one tick
prompt appeared
```

**The same fault manifests differently by iOS version, which is worth knowing before
anyone tries to reproduce it.** On the iOS 26.5 simulator the prompt is suppressed
outright until the covering sheet closes. The report came from an **iPhone on 18.6.2**,
where it appeared and then vanished after a few seconds — the churn above resolving the
other way. Neither is a timing problem to be waited out: the prompt was raised exactly
where it could not be answered, since connecting to a locator a search just found *is* a
menu destination.

fschroer flies two phones — **16.7.16** (the deployment floor, and the one the SF Symbol
availability notes are written against) and **18.6.2** (where this was seen). A
presentation fault that shows up as "suppressed" on one, "appears then vanishes" on
another, and is invisible on a third is exactly the class this file exists to record, and
"it looked fine on my device" is not evidence about the others.

**There is now exactly one `.sheet` in the app.** `RootSheet` gained `.map(MapSheet)`,
`MapScreen` takes its sheet as a `@Binding` and no longer presents, and `RootView` decides
between challenge, map sheet and diagnostics in one place. The challenge outranks
everything and answering it **returns to the screen underneath**, so the search results
that raised the prompt are still there afterwards. Verified on the simulator: the prompt
now appears immediately over the Communication screen, and answering returns to it.

Two smaller changes went with it, both because a revert is destructive:

- the prompt is `interactiveDismissDisabled()`. Its two buttons mean different things —
  one connects, the other puts the receiver back — and a swipe cannot express either. A
  **deliberate divergence**: Compose's `AlertDialog` dismisses on an outside tap, but on
  iOS a swipe is far easier to trigger by accident and the consequence here is an
  unexplained channel revert;
- the sheet binding's `set(nil)` no longer calls `declineChallenge()`. A dismissal the app
  did not initiate must never revert a channel behind the user's back — which is what the
  churn above would have done.

#### Flight-map parity closed 2026-08-29, at fschroer's request

**The distance row is coloured by the locator's GPS health**, as Android colours it —
`gpsStatus == Ok ? default : error`. The colour tracks the **sensor, not the value**,
which is why it applies to "Unknown" exactly as to a number: "Unknown" in the normal
colour is the app declining to quote a figure from a healthy receiver, and "Unknown" in
red is the GPS itself being unwell. Nil reads as healthy, matching Android's
`RocketState.gpsStatus` default of `Ok` before any broadcast.

**The coordinate row's map link is gated the way Android gates it.** It was previously
always drawn in the secondary colour with a tap that silently no-opped at 0,0. Now it is
rendered only for a valid coordinate (`validCoordinate`, Android's `validLatLng`:
finite, in range, not the 0,0 a locator reports before it has a fix), it is tappable only
when the position is one the app stands behind — ADR-0022/0023, `vector != nil`, Android's
`locatorDistancePlausible` — and the underline that says so is **absent when the tap is
not offered**, so it never invites a press that does nothing. Handing an implausible
position to a navigation app would walk straight past the judgement that refused to quote
a distance for it, literally. The row is drawn in the panel's normal colour either way,
as Android leaves it, signalling with the underline alone.

One deliberate simplification: Android probes `PackageManager` for a `geo:` handler and
toasts when there is none. On iOS `https://maps.apple.com/…` resolves to Apple Maps when
installed and still opens somewhere useful when it has been deleted, so there is no
equivalent dead end to guard against.

**The screen is held awake on the main screen**, as Android does with
`FLAG_KEEP_SCREEN_ON`: watching the map and listening to callouts is exactly the
input-idle the system timeout is built to catch, and it was blanking the display
mid-flight.

The **scoping** is the part that does not port literally, and it matters — Android is
explicit that holding it app-wide would also cover settings, flight profiles and map
download, where the phone is in use or grinding through a long download and the display
is the largest single draw on the device. On Android a destination *replaces* the map, so
the flag disposes with it. Here every destination is a sheet presented **over** a map that
stays alive, so scoping to `MapScreen` would hold the screen lit through exactly the cases
Android excluded. The condition is therefore "no sheet is up", which selects the same set
of screens by the route this app's navigation actually takes.

#### Not reachable from a test, on either platform

The 2026-08-28 UI changes — help popups, the button layout, the centred Connected label,
the dropdown — are unverified beyond fschroer's own passes on Android, where three layout
regressions were caught by eye rather than by any test. The iOS screen was driven on the
simulator against a seeded run (a locator reported on two channels, one flagged, plus a
second rocket) and the wrapping search row, the aligned Connect column, the RSSI/SNR
colour scales, the false-hit marker and the help alert all render correctly. **No frame
has been exchanged with hardware**, and per `steam-pigeon-ios` practice the simulator
cannot speak for iOS 16 or for Bluetooth.

Everything not on this list should mirror Android.

### App Flight Logs — ported 2026-09-01, against `AppFlightLogsScreen.kt`

Ported to [ADR-0030](../../steam-pigeon-locator/docs/adr/0030-app-flight-log.md) on
fschroer's word that the Android side had been exercised with simulated flight data — the
condition the divergence row named. `FlightLogRecorder` + `FlightLog` + the recorder's tests
came across **as a unit**, as the porting note asked, rather than re-deriving the
close-signal set: landing deliberately does NOT close a log, a BLE dropout deliberately does
not either, and both are the kind of rule a reimplementation quietly simplifies back out.
24 recorder cases and 13 store cases pin them.

**What is faithful, and checkable.** `FlightLog.fileName` produces Android's exact bytes —
`Kestrel_2025-08-24_014640.csv` from the same epoch and zone is asserted on both platforms —
and every row renders `FlightLog.COLUMN_COUNT` columns with the same blank-not-zero rules:
a non-finite AGL and the receiver's unknown-noise-floor sentinel both go out empty, because
`NaN` in a numeric column turns it into strings and `-32768` reads as a measurement.

**Three places iOS differs, all in the platform half:**

| | Android | iOS |
|---|---|---|
| Storage | `filesDir/flight_logs` | **Application Support**, and deliberately NOT `Documents` with `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` — that pair is the exact iOS spelling of the shared-storage alternative ADR-0030 rejected, and it would give the same stale-list hazard |
| Export | `Intent.ACTION_SEND` through a `FileProvider` | `UIActivityViewController`. Same reach — AirDrop, Mail, Files, Drive — with nothing installed at the far end, which is the whole reason decision 5 chose a share sheet over a serial protocol |
| Announcement capture | An `Announcer` facade, built because ~19 sites called `TextToSpeech.speak` directly | **None needed.** `FlightSpeech.say` was already the single funnel, voice-enabled check included, so the `onSpoken` hook sits inside it and every present and future callout is carried by construction. The rule still holds: it fires only when speech actually went out, so a log entry always means the operator heard it |

**The watchers are `didSet` rather than flow collectors**, which is the shape difference that
carries the most risk of drift: Android collects `armedState`, `remoteReceiverConfig`,
`connectedLocatorId` and the BLE state as four coroutines. Each is edge-triggered here on
the same value, with the same asymmetry on the locator — a release is ignored, a reconnect
to the same locator resumes the file, and only a *different* non-null locator ends it,
because a dropout mid-recovery is the case this log exists to capture.

#### ✅ FIXED ON BOTH 2026-09-01 — the log list was not "newest first" with more than one locator

Found on the iOS simulator with two injected logs, and **it was Android's behaviour, not a
port defect**: `FlightLogStore.list` sorted `sortedByDescending { it.name }`, and the name is
`<locator>_<date>_<time>`, so the sort was locator-major. `Twist_Lock_5` from yesterday
listed above `Kestrel` from today. The Kotlin doc comment directly above it claimed ordering
"by the timestamp in the name", which was true only within a single locator — so the comment
was right about the intent and the code was what disagreed.

It matters for the question the screen exists to answer: *which of these six was the flight
after lunch.*

**Why it survived four days on Android:** a single-locator directory sorts identically under
either rule, so nothing looked wrong until two airframes shared a screen. That is also why
it surfaced on the port rather than on the platform that wrote it — the iOS port mirrored the
sort faithfully, including the defect, and the injected fixture happened to have two locators
in it.

**Fixed on Android first**, per "Android is the reference implementation", then mirrored:

- `FlightLogFile.captureKey` — the `YYYY-MM-DD_HHmmss` half of the name, or null when it does
  not parse. Deliberately **not** `capturedAt`: that falls back to the raw stem so the screen
  always has something to show, and a stem starting with a letter sorts *above* every real
  date in a descending order, so reusing it would put unparseable files first — the opposite
  of what the fallback is for. Fixed-width and zero-padded, so lexicographic order is
  chronological order and nothing has to parse a date to sort.
- `FlightLogStore.ordered` (Kotlin, in the companion) and `[FlightLogFile].sortedNewestFirst`
  (Swift) — **pure and lifted out of `list()` on both sides**, because this is the part that
  was wrong while the directory listing around it was fine, and Android had no way to test
  the ordering without a `Context`. New: `FlightLogFileTest` (10) on Android, four more cases
  in `FlightLogStoreTests` here.
- Unparseable names sort last, ordered by name for stability; two logs captured in the same
  second tie-break on name so the order does not depend on the order the directory listing
  returned them in.

Verified on the iOS simulator against the same two logs that exposed it. **The Android side
is written but not compiled or run** — there is no JDK on this machine, so `gradlew` cannot
start.

#### Not yet verified

The screen, the empty state, the row, the CSV viewer and the list were exercised on the
simulator against **injected** logs, which is what proves the reading half. Nothing has
written a log from real telemetry: that needs a receiver, a locator and a launch, and the
recorder's own decisions — the 2 s pre-roll, landing-does-not-close, disarm-closes — are
pinned only by tests until then.

### ⚠️ The 3D path's memory cost, and one divergence it forced (2026-09-02)

Reported as a jetsam kill: *"Debug session ended with code 9: Terminated due to memory
issue."* Two things came out of measuring it, and they are not the same thing.

**A defect introduced with the 3D path, now fixed.** `FlightPathGeometry.build` was called
from `draw`, which runs from `updateUIView` — so the whole curtain was rebuilt on every
SwiftUI update: every telemetry fix at 1 Hz, every marker-state change, every camera
control, for a track that had not changed. Android hit exactly this and its fix was already
written down in `MapLibreCompat` — sources keyed on the **path alone** and built off the
main thread — and the iOS port did not carry it across. It now does: `rebuildPathIfNeeded`
compares the track, hops to a queue, and re-reads the style after the hop because it may
have been torn down or reloaded meanwhile. A reloaded style clears the cached track, since
its layers are gone.

**Honest limit on that claim:** the growth pattern was NOT reproduced. With no locator
connected nothing drives repeated updates, so a pre-fix build measured just as flat as the
fixed one. The fix is correct and matches Android; whether it is what killed the process is
unproven.

**What the numbers actually say.** Release build, simulator, same camera throughout, with a
no-track control run last to confirm the deltas are attributable:

| | resident |
|---|---:|
| no track | 222 MB |
| 60-point live track | 268 MB (+46) |
| 2000-point archived record, ~17 000 quads | 452 MB (+230) |
| no track again (control) | 223 MB |

That is ~11 KB per quad for 80 bytes of coordinates. The cost is not the geometry, it is
per-**feature** overhead: `MLNPolygonFeature`, its attribute dictionary, and MapLibre's own
bookkeeping, none of which scales with what is inside the feature.

#### Divergence — iOS groups curtain quads by height; Android emits one feature per quad

`upsertExtrusions` now builds one `MLNMultiPolygonFeature` per distinct height rather than
one feature per quad, which took the archived case from +230 MB to **+149 MB** (452 → 371).

It is free of visual consequence, and that is checkable rather than hopeful:
`fill-extrusion-height` is constant per feature, so the wall's top edge is **already** a
staircase quantised to the riser — quads sharing a rounded height were always going to draw
at the same height. Rounding to `curtainTargetRiserM` is the conservative choice, never
coarser than the step the curtain already took. Confirmed by eye against the ungrouped
build: identical.

*Closes when* Android adopts the same grouping, if it wants it — its per-feature costs are
its own and may not justify the change.

**Confirmed trigger, unconfirmed cause (fschroer, 2026-09-02).** The kill happened on a
**device** with an **archived record loaded** — which is the combination these numbers point
at, and the one the simulator understates, since a device's jetsam ceiling is far below what
a Mac will let the simulator have. It has **not reproduced since**, so no further change is
being made until it does: the two fixes above are worth having on their own merits, and
anything beyond them would be tuning against a number nobody has measured on the hardware
that actually killed the process.

**What would settle it.** A jetsam report is written automatically on the device — Settings
▸ Privacy & Security ▸ Analytics & Improvements ▸ Analytics Data, `JetsamEvent-….ips` —
and names both the app's footprint at kill time and the limit it crossed. That single file
turns this from an inference into a measurement, and it needs no change to the app.

**Still open.** 371 MB for a large archived record, on a 222 MB baseline, is not comfortable
for an app whose deployment target is iOS 16 and which is flown on older hardware. The
remaining lever is the quad count itself — `curtainTargetRiserM` at 0.25 m produces ~17 000
quads for a 450 m flight — and moving it changes how the wall looks, which is a fidelity
decision for fschroer rather than an optimisation to take unilaterally.

### The archived flight path on the map — ported 2026-09-01

Reported as a question: does the record loaded through the charting screen get drawn on the
map, as Android's does? It did not — the download and the chart worked, and nothing carried
the record to the map. `grep` for `archivedPath|showArchived|toggleArchived` across the app
and suite returned nothing.

Four pieces came across: `FlightPathGeometry.archivedPathPoints`, `LinkViewModel`'s
`archivedTrack` / `showArchivedPath` / `toggleArchivedPath`, the `mapTrack` selector, and a
control-column button that appears only once a record exists — cyan when engaged, matching
Android's `COLOR_ARCHIVED_ACTIVE`, which is the same cyan the one-second markers use because
both mean "this came off the archive". The archived track **substitutes** for the live one
rather than overlaying it: they are the same quantity measured two ways (EKF vs raw GPS), so
drawing both in one colour would read as a single noisy path rather than two estimates.

**The conversion is the part that fails silently.** The archive stores position in radians
and the live path is in degrees; treating one as the other puts a Seattle-area flight at
0.83°N 2.14°W — in the Atlantic, ~5000 km off — with nothing raising an error. Samples with
no fix are dropped rather than plotted, because a zero coordinate is "no fix" rather than a
position on the Gulf of Guinea, and a record starts before GPS necessarily has a lock.
Android's `ArchivedPathTest` is ported whole (8 cases) and covers both.

**The lifetime is the part that fails silently in a different way**, and it is why this is
not simply a button. Android's snapshot is deliberately not derived from the transfer
buffer, and `clearFlightProfileData` deliberately does not clear it — that method runs when
you navigate back from the chart, which is precisely the moment you would be heading to the
map to look at the track. iOS follows both rules, with seven cases pinning them.

**One hazard Android's comments do not name, found while writing those tests.**
`publishFlightSamples` runs on *every absorbed packet*, so publishing unconditionally would
let a single late packet arriving after `clearFlightProfileData` blank the snapshot with an
empty buffer — reintroducing the trap one layer down. Android is safe by way of its
`samples.isNotEmpty()` guard at the call site; iOS now guards inside `publishArchivedPath`,
which is the more robust place given it has one caller and Android has two.

**Verification.** 15 unit cases, plus the simulator: with no record the control is absent;
with one seeded, it appears dimmed, turns cyan on tap, and the drawn track visibly switches
to the archived geometry. The seeding hook was temporary and is not in the tree. Not on
hardware — that needs a real transfer from a locator.

### The 3D flight path — ported 2026-09-01, against `MapLibreCompat.kt`

Reported from the phone: *"iOS only draws a flat green line instead of orange stacked
columns, and there are no 1s lines."* All three observations were one gap — iOS drew the
ground track and nothing else — plus a colour that was wrong on its own.

**What was actually there.** `upsertLine(… colour: RocketMarkerState.live.color, width: 2)`.
That is the *marker's* green, so the track was drawn in the colour that means "the fix is
live" — Android's path is `COLOR_PATH`, orange `#FF6600`, at width 8 with round caps and
joins. Neither the altitude curtain nor the one-second markers existed at all.

**Why it could not simply be styled.** `MapScreen` passed `model.trackCoordinates`, which
is `track.map(\.coordinate)` — altitude and capture time were discarded before the map saw
them, and those are exactly what the curtain and the markers are built from. The view now
takes `[TrackPoint]`. Worth noting that `TrackPoint` has carried both fields since it was
written, with a comment saying they were persisted so the curtain and markers would not
need a file-format change when they landed; that turned out to be right.

**What came across**, in `Flight/PathGeometry.swift`, pure and off the map:

- `PathSpline` — cubic Hermite with **different tangent rules for altitude and position**,
  which is the load-bearing detail. Altitude uses Fritsch–Carlson monotone tangents because
  a plain Catmull-Rom overshoots at a sharp extremum, and the sharpest feature in a flight
  profile is apogee: it would draw the rocket higher than it ever flew, and a reader
  measuring apogee off the curtain would get a number no sensor produced. Position uses
  ordinary Catmull-Rom, where overshoot is sub-metre and monotone limiting would flatten
  genuine curvature in a turn.
- `altitudeCurtain` — one extruded quad per sub-segment, split by **altitude change** rather
  than a fixed count, with Android's 0.25 m target riser and its deliberately-high 20 000
  quad backstop. That ceiling is high on purpose: the term driving it is summed |altitude
  change|, which cannot tell signal from sensor noise, and a low ceiling coarsened the wall
  precisely on the densest data.
- `secondMarkers` — posts at real elapsed seconds, interpolated between the samples that
  bracket each boundary, so they hold through a dropped packet or a variable radio interval.

**A latent bug this surfaced and fixed.** Second markers must not be stood on placeholder
times, so `TrackPoint` gained Android's `timeSynthetic`. `TrackStore` already *generated*
synthetic timestamps for legacy three-column rows — but `save` wrote four columns
unconditionally, promoting those placeholders to look like real capture times on the next
load. The note on `legacyPlaceholderIntervalMs` claimed the opposite. Harmless while nothing
read the time axis; the markers read it, so `save` now round-trips a synthetic point as the
three-column row it came from.

**Verification.** Android's three geometry suites ported case for case — `PathSplineTests`
(10), `AltitudeCurtainTests` (15), `SecondMarkersTests` (15) — including the two that hold
the important lines: the curve never rises above recorded apogee, and the wall is
perpendicular to its segment in metres rather than degrees. Then exercised on the simulator
against an injected 450 m flight: the orange curtain, the orange ground line and the cyan
posts all render, tilted. **Not yet seen on hardware, and not yet compared side by side with
Android** — which per the note at the foot of this file is the only real check on
appearance.

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
