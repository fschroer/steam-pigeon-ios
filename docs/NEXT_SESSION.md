# Resume here — iOS port

Updated 2026-09-02. **850 tests passing**, clean build with no warnings from our own
sources.

## 2026-08-31 — Android gained a screen: App Flight Logs (NOT ported)

The first new Android screen since 2026-08-21, so the standing "every Android screen is
ported" line now carries an exception. A per-flight CSV of what the *phone* received and
announced — RSSI/SNR/noise floor per frame plus the app's own verdicts and spoken
callouts, none of which the locator's archive can hold, because they are measured or
decided on this side of the radio. See
[ADR-0030](../../steam-pigeon-locator/docs/adr/0030-app-flight-log.md) and `UI_PARITY.md`
→ the divergence table.

**Deliberately not ported yet**: it is days old and has never flown. Wait for the Android
side to record a real flight and for that CSV to be read on a PC — porting a recording
feature before its first hardware run means debugging two implementations against one
unknown.

**When it is time**, port `FlightLogRecorder` + `FlightLog` + `FlightLogRecorderTest` as a
unit. The recorder holds no clock, no Android types and no flows — same shape as
`ChannelMoveRunner` — and its `Sink` is a protocol Swift has verbatim. Do **not**
re-derive the close-signal set: landing does not close a log, and neither does a BLE
dropout, and both are exactly the rules a reimplementation "simplifies" away.

**Related, and cheaper if done together**: Android now routes all nineteen `speak()` sites
through an `Announcer` facade so callouts reach the log. The flight callouts are still
unported here; bringing the facade across in the same pass avoids touching those sites
twice.

## 2026-08-29 (latest) — changed-password recovery, and two flight-map parity items

- **A changed password no longer bricks the connection.** Reproduced first: the app went
  permanently deaf to the locator, could not prompt, and showed a conflict banner calling
  the connected locator "another locator". ~~**Android still has this**~~ — fixed on iOS
  first as an authorised exception, since there was no way out inside the app, and
  **closed on Android 2026-08-30 (`cbb3cd3`)**. See `UI_PARITY.md` → "Android notes".
- **Distance row colour** now follows the locator's GPS health, and the **coordinate map
  link** is gated on a position the app stands behind, with the underline present only
  when the tap is offered — both Android's logic.
- **The screen is held awake on the main screen**, scoped to "no sheet is up", which is
  the same set of screens Android excludes via composable disposal.

- **The released locator's configuration is cleared** when the connection is released, so
  the Locator channel field stops describing a locator the app has let go of.

~~**Android owes four fixes**~~ **Android owed four fixes and closed all four on
2026-08-30 in `cbb3cd3`** — changed-password recovery, the in-flight button gating and
stage-on-success, clearing the released locator's config, and deterministic candidate
ordering. The list, struck through with where each landed, is in `UI_PARITY.md` →
"ANDROID OWES THIS". The further defect (`ChannelOccupancy` rendering `00000000`), then
known on both and deliberately fixed on neither, was fixed on Android 2026-08-29 and
ported here 2026-09-01.

~~**What Android still owes is row 5 alone**~~ — the charge callouts consulting
deployment channels 1 and 2 only, added to the table 2026-09-02. **Closed on Android
2026-09-04** by `DeploymentCharges`, which zips all four modes against all four fired
flags, with `DeploymentChargesTest` carrying Android's copy of
`testTheMainChargeOnChannelThreeIsAnnounced`. **Both owed lists are now empty.** Not
heard on hardware on either platform.

Noted 2026-09-04, when rows 1–4 were checked against the Android source rather than
against the list: they had read "still open" for five days after they were closed. A
list of what another repo owes cannot signal its own staleness — it reads "open"
indefinitely, and only the other repo's source can contradict it.

## Flight testing spans several iOS versions

fschroer runs **16.7.16** and **18.6.2** today and expects more. Version-conditional UI
must branch on **capability, not on a device in hand**, and a fallback branch that almost
never runs is exactly the branch that rots — write it to be correct rather than pretty.
`SectionHelp` is the worked example: `.popover` + `presentationCompactAdaptation` on
16.4+, an alert below that.

The same fault can also read three different ways by version. The sheet-presentation bug
below was **suppressed** on the 26.5 simulator, **appeared-then-vanished** on 18.6.2, and
is unverified on 16.7.16 — so "fine on my device" is not evidence about the others.

## 2026-08-29 (later) — three more from the phone, and the app now has ONE sheet

Connecting to an unauthenticated locator from a search result. Full write-up in
`UI_PARITY.md`.

1. **Connect buttons stayed live during a change**, and the view staged the channel
   before checking whether the send was accepted — so the field showed a channel the app
   never visited. `pointReceiverAtChannel` now reports whether it went out; picks are
   disabled while a change is in flight. **Android has the same defect.**
2. **The Locator channel section vanishing** with the prompt is correct and identical on
   Android — the connection is released, and that section is a locator-directed command.
   Left alone.
3. **The password prompt could not be answered from the Communication screen.** "One sheet
   per screen" was not enough: `RootView` presented the challenge while `MapScreen`, its
   own child, presented the destination — an ancestor cannot present while a descendant
   is. Reproduced on the simulator, then fixed by hoisting every presentation to
   `RootView`. **There is now exactly one `.sheet` in the app**; a second one anywhere in
   the hierarchy reintroduces this. The prompt also refuses swipe-dismissal, and a
   dismissal no longer counts as a decline — it was reverting channels behind the user.

## 2026-08-29 — the channel-change recognition cycle, reported from the phone

After a whole-band search, connecting to a *different* locator left the app showing no
locator at all — every search row read "Connect" and the Locator channel field kept the
old value, which looked like the receiver having been sent to a wrong channel. It was on
the right channel; the app was refusing to display what was on it, because
`pointReceiverAtChannel` moved the receiver without releasing the connection.

**Android was never affected** — its `pointReceiverAtChannel` calls
`beginChannelChangeRecognition` first. That is now ported (ADR-0011), along with the
`.channelChange` challenge trigger, the revert-on-cancel, and `submitPassword` taking the
connection immediately instead of waiting out `connectionHold`. `ChannelChangeRecognitionTests`
pins each reported symptom; full write-up in `UI_PARITY.md`.

Also: `LinkViewModel.init` now takes an injectable `UserDefaults`, because tests that need
an unauthorized locator were silently passing on state left by earlier runs.

## 2026-08-28 — ADR-0029 ported: locator search, Communication screen, version stamp

Against Android `b878c32..e9f93d7` (23 commits) and receiver `b9dece4..aa9edc6`, to the
brief in `../steam-pigeon-locator/docs/ios-port-brief-locator-search.md`. Full audit,
including two defects found in the Android implementation and one pre-existing iOS gap,
in `UI_PARITY.md` → "Communication screen + locator search".

- **Wire format, breaking.** `ChannelSurveyResponse` 84 → **104**; new
  `LocatorSearchRequest` 28 and `LocatorSearchResult` **39** (not 38 — it grew an
  `int8_t snr`). All three pinned in `WireLayoutTests.swift` with parts-sum cases.
  `ChannelSurveyStatus.Cancelled` decoded as itself, never as `RefusedBusy`.
- **Communication screen** owns both scans, both channel fields and the conflict banner.
  Receiver Settings keeps name + firmware; Locator Settings is flight configuration only.
  Both build the receiver message from the **last read-back**, changing only their own
  field. Menu reordered, show/hide conditions unchanged. **Find my locator** added to the
  status panel's action drawer.
- **`last_channel`** in `KnownLocatorStore`, in its own defaults key, optional so
  "never heard" ≠ "heard on channel 0".
- **Version stamp** is a bundle resource written by `Scripts/GenVersion.sh` on every
  build, never a compiled-in constant — verified on the built `.app`: zero stamps in the
  binary, one in `GitVersion.txt`, and it changes on a rebuild with no source change.

**Still owed: hardware.** No search frame has been exchanged with a receiver, and the
2026-08-28 UI changes are unverified on both platforms. The four bench procedures in
`../steam-pigeon-locator/docs/bench-locator-search.md` port as well as the code does and
are the next thing to run.

---

**Android moved on 2026-08-21, and iOS caught up with all of it.** `git -C ../rocket-flight-manager log 39559b3..origin/main` lists seven commits;
nothing on that list is still owed here:

| Android | What it is | iOS |
|---|---|---|
| `3f921a4` | the download estimate counted one zoom level fewer than it fetches | **ported 2026-08-23** |
| `b209671` | name a locator that was already armed when the app opened | already here — **closes divergence #7**, the iOS-first one |
| `ec6fb0d` | parity recovery rebuilt a packet out of the wrong bytes | already fixed here when Flight Profiles landed. Reading it back corrected one of our notes: the padding bug was **every recovery**, not only a short tail — iOS's cap on decoded sample count covered both anyway. Parity matrix updated 2026-08-24 |
| `2b54807` | the app is called SteamPigeon, on both home screens | nothing owed — closes the first "Android owes iOS" item below |
| `b878c32` | the download picker opens where you are, not on the whole world | nothing owed — closes the second |
| `5d52383` | the altitude axis was losing the first digit of its own labels | **ported 2026-08-23** — gutter 112 px, plus the left-edge clamp. Held for real flight data before it is judged |
| `b6c67ad` + locator `4ffce9c` + ADR-0028 | the app stops sending two settings it can never confirm; the fields become **reserved wire slots** | **ported 2026-08-23.** iOS's bytes did not change — it already sent 30 and 10 — but both are gone from `LocatorConfig`, and `WireLayoutTests` now pins the 35-byte body field by field. **Closes divergence #1**, and **confirmed on hardware 2026-08-24** |

The locator repo has moved too (`56b0422..origin/master`): ADR-0028, the firmware side of
the reserved fields, and a UserManual pass. **Neither sibling checkout has been merged
locally — both were only fetched**, so `git log` in either shows a stale `main`/`master`
until someone pulls.

One thing went the other way while porting `b209671`: Android names an authorized locator
it declines to connect to, because it notes the name before its `mayConnect` check. iOS
only did so on accept, so the two-rocket case lost the one broadcast carrying the second
locator's name. Fixed here 2026-08-23 — `UI_PARITY.md`, "naming a locator heard only
while armed".

**Every Android screen is now ported.** What is left is features inside screens, and
hardware time — see below.

**Confirmed on hardware 2026-08-24 (fschroer):** the ADR-0028 reserved-fields change,
with both a config change and a channel move against a real locator — the pair that
proves the locator accepts a body it no longer takes those two fields from AND that
`lora_channel` still sits where the receiver reads it — and the rocket icon's arm/disarm
tint, including the blink stopping on the locator's own acknowledgment. The widened chart
gutter is deliberately held for real flight data.

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
- **Colour on the status panel is a rule, not a palette choice.** The rocket glyph is
  green when armed and white when not (`MapStatusPanel.rocketTint`), and it is the only
  thing on the map that says so. Tinting it by GPS health looked reasonable and said
  nothing — reported off the phone 2026-08-23.
- **SF Symbols must exist on iOS 16.0.** A later symbol resolves fine on the 26.5
  simulator and is a blank box on the phone. Check against
  `CoreGlyphs.bundle/name_availability.plist` — the command is in
  `SFSymbolAvailabilityTests`.

---

## Three things Android owed iOS — all three landed 2026-08-21

**Delivered.** `2b54807` (the name), `b878c32` (the opening camera) and `b209671` (naming
an armed locator) are on `origin/main`. Nothing is owed here for any of them; the three
descriptions below are kept as the record of what was asked for and why.

**The app's name.** fschroer decided on 2026-08-21 that the app is **SteamPigeon**.
Android's `app_name` still reads "Wherezit?" — in `values/strings.xml` and in the header
comment of the bundled `launch_sites.csv` — so the two home screens print different
labels under the same icon. iOS needs no change. Details in `docs/UI_PARITY.md` under
"App icon".

**The download picker's opening camera.** fschroer asked for it on iOS first
(2026-08-21): open on the **phone's current position at a multi-state zoom (z5)**,
applied once when a fix first arrives, cancelled by picking a preset or typing a
coordinate, and no invented fallback when there is no fix. Android sets no opening camera
at all today. The full rule set is in `docs/UI_PARITY.md` under "iOS-FIRST behaviour" —
written as a description precisely so the Android change does not require reading Swift.

**Naming a locator that is armed at cold start.** An armed locator broadcasts
`TelemetryData`, which carries no `device_name`, so the name has to come from something
remembered. Android remembers one only as `KnownLocator.label`, written when a password
is accepted — so an **open** locator, the default state, is never named while armed; its
status row is simply blank. iOS now stores the name from every `PreLaunchData` it accepts
(`KnownLocatorStore.noteName`), which covers open locators as well. fschroer asked for
this on 2026-08-21 after seeing the blank row on the phone. Written up in
`docs/UI_PARITY.md` under "Naming a locator heard only while armed"; the Android change
is one call beside `rememberLocator`.

The download camera and this are the only behaviours in the port that landed here first,
and both were asked for. The standing rule is still Android-first.

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

**Camera passthrough — done 2026-09-02.** Reported from the phone as "the camera is not
functioning when the map screen is rotated to landscape". The heads-up view had been a
placeholder — two gauges on black — and the whole of Android's `CameraPreviewScreen` is
now ported: the camera behind it, the crosshair, the locator ring and its off-screen edge
arrow, both ±45° HUD scales, tap-to-zoom, and the two flight instruments on Android's
in-flight gate. New: `Flight/CameraPassthrough.swift` (AVFoundation session + preview),
`Flight/CameraBoresight.swift` (where the back camera points), `Flight/ARSight.swift` (the
overlay geometry), and `NSCameraUsageDescription`. `PhoneLocation`'s device-motion stream
now runs in the true-north reference frame.

**First hardware pass, same day (fschroer): the preview is upright in both landscape
orientations.** What is still unsettled is whether the marker lands on the rocket rather
than 180° opposite — that needs a locator — and how the deflection per degree compares
with Android side by side.

**Reported with it: the rotation occasionally sticks, with the map screen still partly on
screen in landscape.** A main-thread stall during the rotation animation, not a layout
fault. The camera's share of it is fixed — `RootView` owns the session and the preview
view, so a rotation starts and stops an already-built session on the capture queue instead
of building one on the main thread. **Two costs are left in that same run loop turn**, and
both are pre-existing:

- `MLNMapView` is destroyed and rebuilt, style and all, on every rotation. The largest one
  now. Same fix as the camera's if it recurs: own it above the swap.
- ~~`SpeechCoordinator` is rebuilt on every rotation~~ **fixed 2026-09-02.** `RootView`
  owns the voice now, so the pad alert, its haptic and the arm/disarm callout keep running
  in landscape as Android's do, and a rotation no longer builds a synthesiser or activates
  an audio session on the main thread. **Not on hardware** — the pad alert needs a locator
  reporting prepped-and-disarmed, and the haptic needs a device. One divergence came out of
  it and is recorded in `UI_PARITY.md`: the announcer keeps speaking while a sheet is up,
  where Android's stops on leaving the map screen. That one is a decision, not a defect.
- **The flight callouts are now ported too (2026-09-02).** `FlightAnnouncer` (pure) plus
  `FlightAnnouncerRunner` (timer + speech), owned by `RootView`: apogee, the four charges,
  100 m ascent bands, descent warnings, landing — including the dead-reckoned one when the
  link dies on the way down — telemetry lost/restored and GPS lost/restored. Android's
  `LandingCalloutTest` is ported case for case; 27 new tests in all. **Android's `Announcer`
  facade has no counterpart here on purpose**: `FlightSpeech.say` was already the single
  funnel it was introduced to create, and ADR-0030's log hook already sits inside it.
- **A defect on the Android side came out of it**, #5 in the "ANDROID OWED THESE"
  table: the charge callouts consult deployment channels 1 and 2 only, while the locator
  has four and the stock wiring puts MainPrimary on **channel 3** — so "Main charge." was
  unreachable there with the default configuration. iOS checks every channel.
  **Fixed on Android 2026-09-04**; the port earned its keep.

**Round two on the phone, same day: no stuck rotation in 15–20 tries.** Three follow-ups,
all recorded in `UI_PARITY.md` → "Heads-up sight (landscape)":

- **Marker jerkiness — fixed by rate.** The sight now samples attitude at 60 Hz while it
  is on screen; the map keeps 10 Hz. Android's ~60 ms rate was chosen against a cost
  (recomposing the map screen per sample) that does not exist on this screen.
- **Fast landscape-to-landscape flip lands upside down.** `CameraPreviewView` now re-reads
  the interface orientation on `UIDevice.orientationDidChangeNotification`, since a 180°
  flip changes neither bounds nor size class. **Unresolved until someone says whether the
  overlay flips too** — if it does, the interface itself is landing wrong and this is not
  the fix.
- **Controls reset on the way back to portrait is Android parity** (`remember` inside
  `MapWithOverlays`, portrait branch only). Hoisting the four flags into `RocketViewModel`
  is an Android-first change if it is wanted.
- **"The compass stopped working" was the camera filter, and it is the biggest thing in
  this round.** The clue was that a two-finger rotate plus the five-second timeout cured
  it: seeding the filter is what a gesture does, and `CameraFilter.tick` returns nil until
  it is seeded. All three seed sites were conditional — a gesture, a recentre tap, and the
  initial centre, which fires **only while the rocket has no fix** — so a map built while a
  locator is already reporting was never seeded, and auto-centre, auto-zoom, tilt and
  heading-up were dead together. **That also means opening the app at the pad with the
  locator already broadcasting**, which is nothing to do with the camera work and is the
  more serious half. `tickCamera` now seeds from the live camera on its first frame;
  Android needs no equivalent because its filter starts at concrete values and always
  ticks.
- **Corrected while summarising: the AR marker's gate was missing the compass term.** It
  read `vector != nil` alone, on the assumption that a suppressed vector carried ADR-0023's
  compass test too; it does not — the vector is published under an unreliable compass
  because the map only quotes a distance from it. Now `vector != nil && compassTrust !=
  .unreliable && a camera bearing`, which is Android's `bearingValid` term for term.
  **This couples to the item below**: red on the rose is `.unreliable`, so while that mark
  stays stuck the marker is correctly suppressed and will not draw on that phone at all.
- **Fixed: the permanently red figure-eight.** ADR-0023 §3b classifies field magnitude,
  and Android's source is the **calibrated** magnetometer; the iOS port read the **raw**
  one, which carries the phone's own hard-iron offset — on a MagSafe-era iPhone that alone
  pins the total above the 70 µT ceiling for the life of the device. The envelope was
  working perfectly on a number that was never the Earth's field. Now
  `CMDeviceMotion.magneticField` via `CalibratedField.classify`, with `.uncalibrated`
  voting nothing rather than unreliable (its values arrive as zeros, which the gross band
  would suppress the bearing for). **ADR-0023 §3b carries the whole account** as a dated
  addition, including the option not taken — `CMCalibratedMagneticField.accuracy` as a
  fourth source, deliberately not bundled into a change whose job was clearing a stuck
  warning.
- **Consequence worth knowing:** the calibrated field is published only under a magnetic or
  true-north reference frame, so that frame is no longer scoped to the heads-up sight — it
  is what the app runs. Only the sample *rate* is scoped (10 Hz map, 60 Hz sight). It
  replaces a raw magnetometer stream that ran continuously anyway.
- **Confirmed on the phone the same day:** the landscape-flip fix holds, and the compass
  performs in portrait after a rotation round trip.
- **Confirmed on the phone, same day:** the marker appears and **lands on the rocket
  rather than 180° opposite** — which is the gravity cross-check in `CameraBoresight`
  proving out, and the only evidence that check can ever have — and **60 Hz cures the
  stepped motion**. The ∞ mark clearing follows from the marker drawing at all, since the
  gate refuses to draw at `.unreliable`, but nobody has said so directly.
- **What the sight still owes a phone:** deflection per degree beside Android. Aiming at
  the rocket tests the zero point; the scale only shows itself with the rocket off-centre,
  so it wants a side-by-side rather than another solo run.

**Features remaining:**

- **Flight TTS callouts.** `FlightSpeech` exists and the pad alert and arm/disarm use it.
  `FlightSpeechAnnouncer`'s ascent/descent/apogee/landing/link-loss callouts are unported.
  ADR-0022 rule when porting: a withheld distance must mean **silence**, not a stale
  number read aloud.
- **Export flight path.** Android has an `ExportFlightPathScreen`; nothing here does.
- **Archived-path map control.** Now unblocked — see above.

---

## Not yet exercised

- **Both 2026-08-21 connectivity fixes, which are Bluetooth and therefore phone-only.**
  1. *An armed locator now has a name, and so does the receiver.* `TelemetryData`
     carries neither, so a locator first heard while armed is named from the last name
     stored for its id (`KnownLocatorStore.noteName` → `LinkViewModel.adoptStoredLabel`),
     and the receiver is named by its **BLE device name** — Android's first source,
     which iOS was not reading at all. The locator row reports "No Locator" only when
     nothing is arriving. Confirmed on the phone 2026-08-21 that the *scan* half works;
     what is unproven is this half: **open the app with the rocket already armed and
     confirm both rows name their device.** The locator must have been heard disarmed at
     least once by this install — nothing anywhere carries the name of a locator that has
     only ever been heard armed.
  2. *The app never stops looking for a receiver.* An empty scan window starts another,
     and losing the link returns to scanning
     (`BluetoothTransport.shouldResumeScanning`). **Verified on the phone 2026-08-21**:
     started with every receiver off, switching one on brought up the picker. Still
     unwatched is the battery cost of a continuous 3 s scan loop over an afternoon —
     Android does the same from a foreground service, which iOS has no equivalent for.
- **A recorded track surviving a real restart.** Fixed 2026-08-21: `clearLiveReadouts`
  was wiping the track the launch scan away, so the array restored from
  `flight_path.csv` never reached the map and the next recorded point saved the emptied
  array back over the file. The track describes the rocket, not the receiver — Android's
  connection state does not touch `_flightPath`. Covered by `TrackRecordingTests`, but
  the phone case is worth one look: **record a track, kill the app, reopen it, and
  confirm the line is still drawn.**
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
- **The chart's widened altitude gutter** — the one 2026-08-23 parity port still open.
  fschroer is holding it for **real flight data** (2026-08-24): the question is whether
  3- and 4-digit altitude labels now read, and the gutter is space taken from the plot,
  so a fixture cannot settle it. The other two ports were confirmed on hardware
  2026-08-24 — see the top of this file.
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

## Four system-level questions, none an iOS decision — three now answered

Three of the four were decided on the Android/firmware side on 2026-08-21 and ported here
on 2026-08-23. Only the pad-alert banner is still open, and it needs an eye rather than a
decision.

1. ~~**`launch_detect_altitude` and `deploy_signal_duration` cannot be read back.**~~
   **Resolved 2026-08-21 by ADR-0028**, and ported here 2026-08-23. Both fields are now
   **reserved wire slots**: the app fills them with the firmware defaults and offers no
   control, and the locator restores its own values after copying the message. The slots
   stay occupied because removing them would move `lora_channel` and break the receiver's
   `offsetof` channel-follow (ADR-0011). **Both fields are consequently fixed at 30 m and
   1.0 s on every device** — the ADR records that as a real reduction in capability, not
   a pure fix — and it reopens when the firmware carries them in a broadcast. Note the
   premise this file had wrong: the USB-C console never set either field either.

2. ~~**The offline size estimate is low on both platforms.**~~ **Resolved 2026-08-23.**
   Android fixed it (`3f921a4`) and it is ported here: `TileMath.sourceZoom(of:)` counts
   the source tiles actually fetched, and `tileBytesCalibration` (0.68, Android's constant
   from Android's anchor) corrects a table that had been divided by the old under-count.
   Same regions now quote ~2.7× more. **The claim that low was the safe direction was
   wrong** — the 1 GB guard reads this number, so an under-estimate waves through a region
   that is over budget. Full write-up in `UI_PARITY.md`.
3. ~~**The flight-profile chart clips its altitude axis labels — on both platforms.**~~
   **Fixed on Android 2026-08-21 (`5d52383`) and ported here 2026-08-23.** The gutter,
   not the text size: `CHART_MARGIN_X` 64 → 112 px, plus a clamp so a label too wide for
   it butts against the plot instead of losing a character. Still **unseen on a device on
   either platform** — it is a legibility judgement, and the gutter is space taken from
   the plot, so it wants fschroer's eye on a flight with 3- and 4-digit altitudes.

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
