# Android ⇄ iOS UI parity — inventory and plan

**Standing instruction (2026-08-19, fschroer):** the iOS app should mirror the Android
app in **both functionality and UI presentation**, except where a specific iOS design
rule should take precedence.

> ⚠️ This is a **tighter contract than ADR-0016 currently states.** That ADR says
> *"Capability parity is required; pixel parity is not. Each platform may be idiomatic
> (Material vs. HIG)."* Everything built before this date was built to the ADR. If the
> tighter rule is the real one, ADR-0016's UI/UX row should be amended to say so —
> otherwise the next person reads the ADR and reverts this on good authority.

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
