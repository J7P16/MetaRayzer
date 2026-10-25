# MetaRayzer

A **Flutter macOS** hand-gesture game platform driven by the camera of **Ray-Ban Meta (Gen 2)**
glasses. Its first minigame is **Wizard's Stand**, a first-person wizard shooter. You hold a staff
in your left hand: close the hand into a fist to ready a spell, then snap it open to cast. The
spells are a homing **Fireball** and, once unlocked, an aimed **Chain Lightning**. A **Shield** is
always available: raise your forearm upright in front of your face to block arrows and bolts for
0.5 s.

Version 4 adds:
- a fix for **glasses audio** through the iPhone, with *requested* vs. *confirmed* output shown
  separately
- the live **glasses camera feed behind every menu**
- polished **enemy art** and **health bars** on every enemy
- the base-kit **Shield** and a gesture recognizer for it
- a **Skeleton Archer** that repositions, settles, telegraphs, then fires one aimed arrow
- an interactive, replayable **Tutorial**
- **background music** for menus, daytime and the boss
- a **day-night cycle** with a night **boss** (the Bone Lich)
- **Chain Lightning** now unlocked by defeating your first boss
- **reduced enemy auto-aim**: projectiles aim once and fly straight

See the [Version 4 checklist](#version-4-checklist) for what is tested, what is only implemented,
and what is blocked by the platform.

Version 3 adds:
- a staff that follows your hand and aims
- head movement (glasses orientation) that turns the view
- spatial sound with routing to the glasses
- a deeper, animated arena
- stronger difficulty progression
- the **Splitting Slime** enemy
- the permanently unlockable **Chain Lightning**

Under the game is the real-time hand-tracking pipeline. It detects and tracks up to two hands,
computes each hand's position relative to the center of the camera frame, and classifies the hand
pose (fist / open palm). The original tracking view is still available as the *Glasses & tracking
setup* screen.

```
Ray-Ban Meta ──Bluetooth/Wi-Fi──▶ iPhone companion ──local Wi-Fi (TCP)──▶ Mac: Flutter app
 (camera)                          (Meta's official toolkit)               (Apple Vision hand
                                                                            detection + tracking + UI)
```

> **Why there's an iPhone in the middle.** Meta's *Wearables Device Access Toolkit* (DAT) is the
> only official way to read the glasses camera. It ships only for **iOS 17.2+ and Android 10+**,
> and it needs the **Meta AI** phone app for registration and permissions. It has no macOS build,
> and an iOS SDK can't be imported into a macOS Flutter app. So a small iPhone app receives the
> stream through the official SDK and forwards frames to the Mac over the local network. See
> [Platform constraints](#platform-constraints-and-verification).

---

## Contents

0. [Version 4 checklist](#version-4-checklist)
1. [Status: what is verified](#status-what-is-verified)
2. [Prerequisites](#prerequisites)
3. [Meta developer and glasses setup (manual)](#meta-developer-and-glasses-setup-manual)
4. [Install and run](#install-and-run)
5. [Playing Wizard's Stand](#playing-wizards-stand)
6. [Spells](#spells)
7. [Game rules and tuning](#game-rules-and-tuning)
8. [Head movement](#head-movement)
9. [Audio](#audio)
10. [Settings and persistence](#settings-and-persistence)
11. [Game platform architecture](#game-platform-architecture)
12. [Using the tracking setup screen](#using-the-tracking-setup-screen)
13. [Verifying hand detection](#verifying-hand-detection)
14. [Architecture](#architecture)
15. [Coordinate system](#coordinate-system)
16. [Hand-detection model](#hand-detection-model)
17. [Tracking](#tracking)
18. [Testing](#testing)
19. [Troubleshooting](#troubleshooting)
20. [Known limitations and future work](#known-limitations-and-future-work)
21. [Platform constraints and verification](#platform-constraints-and-verification)

---

## Version 4 checklist

Built and checked on macOS 26 (Darwin 25.6) with Flutter 3.47.8. **This machine had no Xcode and no
phone or glasses**, so neither the macOS app nor the iPhone companion was built or run for v4. All
Dart code is covered by `flutter test` and `flutter analyze`. The shared Swift audio code was
compiled and run offline with the Command Line Tools (`tool/audio_probe.sh`, `tool/link_selftest.sh`,
and a `swiftc -typecheck` of the Mac `AudioController`).

**Implemented and tested (automated, no hardware):**
- Shield state machine: exactly 0.5 s, expiry, no extension or retrigger while held, re-arm after
  release, arc coverage (`test/games/wizard_v4_test.dart`).
- Projectiles: blocked vs. unblocked damage, block wins over hit, too-early shield, out-of-arc
  arrows not blocked, melee never blocked, fixed velocity after launch, misses removed, each
  resolved once.
- Shield gesture metrics on **real Apple Vision landmarks** (upright close palm accepted; far
  hand, sideways hand, fist and off-center hand rejected; mirroring), plus the temporal
  recognizer (confirmation, noise, re-delivery, low confidence, dropout) (`test/input/shield_gesture_test.dart`).
- Skeleton cycle: telegraph always precedes exactly one arrow, phases repeat, no skipped
  telegraph at the longest frame step, nothing fired after death, reaction-time budget.
- Reduced auto-aim: a statistical miss rate that stays above zero at full difficulty, with a
  per-projectile floor.
- Health bars (`HealthBarModel`): damage, damage trail, defeat, chain partial damage, split
  slimes, boss segments.
- Day-night cycle and boss: phase order and events, one boss per night even with long frames,
  spawning paused at night, tougher later bosses, boss volleys (aimed + fan, fan side bolts
  miss), one summon.
- Chain Lightning: unlocked only by a boss defeat, exactly once, never by score, never in the
  tutorial; v3 saves keep it; it persists across simulated restarts.
- Tutorial: the step logic; a full widget run with simulated input (look, cast, timed shield
  block); and that score, lives, leaderboard and progression stay untouched; exit and replay.
- Menu camera feed: shown on the Start Menu and Settings with one shared preview, no stream
  commands sent by navigation, stalled feed shown as *paused*, setting turns it off; mouse
  clicks work over it.
- Audio settings: master × channel volumes, disabled channels, music dedup, persistence.
  Route verification: glasses confirmed only from an OS-reported route.
- Offline audio engine (`tool/audio_probe.sh`): all 34 sounds, three seamless music loops, music
  volume, same-track requests ignored.
- Rendering was inspected by rendering the real painter offscreen: day, dusk with the shield, night
  boss, every enemy type with bars, Start Menu over a camera frame, tutorial cards.

**Implemented, not hardware-tested:**
- Glasses audio via the iPhone (companion session fix, route report, route picker). The companion
  **has not been compiled** for v4 (no Xcode here). Its changes (`CompanionAudio.swift`,
  `CompanionApp.swift`, `ContentView.swift`) need an Xcode build.
- The macOS plugin changes (`MetarayzerNativePlugin.swift`: music method, phone audio status) are
  **not compiled** here (FlutterMacOS needs Xcode). `AudioController.swift` was type-checked.
- The shield pose seen through the **glasses' own camera**. Thresholds were validated on real
  Vision landmarks from photos and on simulated input, not on first-person glasses footage. Tune
  them in `ShieldGestureConfig`.
- Music and all sounds heard through the glasses (either route).
- Live camera behind the menus with real glasses frames. It is the same `CameraPreview` widget and
  controller as the gameplay inset, but it hasn't been run with the real stream.

**Partially implemented:**
- *Avoiding attacks by movement.* The game tracks head **orientation** only (DAT Motion has no
  position), and the player stands at a fixed point. So arrows can be dodged only by their own aim
  error, by facing the threat so the shield's arc covers it, and by timing. Physical sidestepping
  is not tracked.
- Melee enemies keep their v3 behavior (a telegraphed strike that always lands unless you kill the
  enemy first). They have no aim to reduce; the auto-aim reduction applies to projectiles.

**Blocked or limited by the platform:**
- **Forcing audio onto the glasses.** Meta's toolkit has no audio API, and iOS doesn't let an app
  pick a Bluetooth output device. The app can request the documented `.playback` session, show
  iOS's route picker, and report the actual route. It cannot select the glasses itself.
- Proving that a person *hears* the sound. Software can confirm only what the OS reports as the
  active output.

---

## Status: what is verified

| Piece | Status |
|---|---|
| macOS app builds and launches (Flutter 3.47.8, Xcode 27.1, macOS 27.0.1, M4 Pro) | ✅ verified |
| Mac listener, Bonjour advertisement, frame link, disconnect detection | ✅ verified (loopback self-test + dev sender against the running app) |
| Hand detection on real photos (Apple Vision), 1 and 2 hands, 21 landmarks each | ✅ verified (`tool/vision_probe.sh` on MediaPipe's Apache-2.0 test images) |
| Overlay mapping on real frames: letterboxed, cropped and mirrored, and rotated views | ✅ verified (rendered the real UI widget with a real frame and inspected the output) |
| Full Mac pipeline throughput (two hands, 638×1000 frames) | ✅ 24.0 fps in, 24.0 fps processed, 0 dropped, ~11 ms detection |
| Coordinate math, view mapping, tracker, smoothing, controller | ✅ unit tests |
| **Wizard's Stand**: game rules, all enemy types, fireball targeting, scoring, lives, difficulty | ✅ unit tests (`test/games/`) |
| Fist / open-palm classifier on **real Apple Vision landmarks** (open palms, fist, pointing, victory) | ✅ `test/input/pose_classifier_test.dart` with `test/fixtures/real_hand_landmarks.json` |
| Cast gesture: one fist→open = one fireball, no repeat while open, re-arm on fist, no casts from dropouts | ✅ unit tests + app-level widget test |
| Start Menu → Play → Game Over → Play Again / Start Menu, mouse and hand-dwell selection, leaderboard | ✅ widget tests (`test/app/app_flow_test.dart`) |
| **Built release app, end to end with real frames**: native Vision → classifier → dwell-select PLAY → two fist→open transitions = exactly two fireballs → run ends → Game Over → score persisted and reloaded after restart | ✅ verified (`send_frames.py` streaming composited real hand photos into the running app) |
| **v3** difficulty controller, Splitting Slime (split, limits, family scoring), Chain Lightning (aim path, range, chain radius, falloff, once-per-enemy, cooldown), unlock event, spell switching | ✅ unit tests (`test/games/wizard_v3_test.dart`) |
| **v3** ✌ (V sign) pose on real Vision landmarks; spell-switch hold/release; head tracker baseline, dropout and recenter with no jumps; sensitivity math; staff mapping, clamping and smoothing | ✅ unit tests (`test/input/`) |
| **v3** mouse + hand navigation together; a click and a dwell on the same button fire once | ✅ widget test (`test/ui/dwell_guard_test.dart`) |
| **v3** unlock reached in a run is persisted, and Q switches spells | ✅ widget test (`test/app/app_flow_test.dart`) |
| **v3** settings (head sensitivity, volumes, spatial mode, output) persist; reset keeps unlocks | ✅ unit tests |
| **v3** camera-stream indicator states (connected / live / stalled / stopped / dev) | ✅ unit tests (`test/ui/camera_stream_indicator_test.dart`) |
| **v3** spatial audio: all 22 synthesized sounds, left/right placement (stereo and binaural), distance falloff, listener turning, volume | ✅ verified offline by rendering the real engine (`tool/audio_probe.sh`). Not listened to by a person. |
| **v3** built release app end to end: hand-dwell starts the game, exactly one cast per fist→open, relayed glasses orientation → `head tracking: tracking` → `lost` on disconnect, audio on the Mac speakers, **"Glasses via iPhone" relay** sends positioned sound events to the phone side and falls back to the Mac when it disconnects | ✅ verified with `send_frames.py --motion-yaw` standing in for the companion |
| **v3** companion compiles with `MWDATMotion` + audio playback; motion and audio messages round-trip | ✅ build + `tool/link_selftest.sh` |
| Full test suite | ✅ 179 Dart tests, `flutter analyze` clean, link self-test, audio probe |
| **v4** full test suite | ✅ **243** Dart tests, `flutter analyze` clean, link self-test, audio probe (34 sounds + 3 music loops). Run with Flutter 3.47.8 on macOS 26. The macOS app and the companion were **not built** for v4 (no Xcode on the build machine). |
| iPhone companion compiles against Meta DAT **1.0.1** (Debug and Release, `generic/platform=iOS`) | ✅ verified |
| Companion ↔ Mac protocol (the companion's own `FrameSender` against the Mac's `FrameServer`) | ✅ verified (`tool/link_selftest.sh`) |
| **Companion running on a physical iPhone with physical Ray-Ban Meta Gen 2 glasses** | ⚠️ **not verified.** No phone or glasses were available while building this. Needs the manual steps below. |
| MockDeviceKit (iPhone-camera) mode on a physical iPhone | ⚠️ not verified (same reason) |
| **Left-hand casting seen through the glasses' own camera** (first-person view, fingers up) | ⚠️ **not verified on glasses**. Validated on photos and the Mac webcam path only. See [limitations](#known-limitations-and-future-work). |
| **Head tracking from real glasses** (DAT Motion, experimental) | ⚠️ **not verified**. Implemented against DAT 1.0.1's `MWDATMotion`; the quaternion axis convention is undocumented (there's an *Invert head direction* setting). |
| **Audio actually heard through the glasses** (via the iPhone relay, or the glasses as a Mac audio device) | ⚠️ **not verified**. See [Audio](#audio). |

The parts that need hardware use Meta's official API exactly as Meta's `CameraAccess` sample does
(DAT 1.0.1). The first run on real hardware is still the remaining acceptance step. See
[Troubleshooting](#troubleshooting) for what to check if it doesn't connect.

---

## Prerequisites

### Mac
- macOS 12 or later (developed on macOS 27.0.1). Apple silicon recommended (Vision runs on the Neural Engine).
- **Xcode 26.4+** (DAT requirement; developed with Xcode 27.1) with the macOS and iOS platforms installed.
- **Flutter 3.47+ stable** (Dart 3.13+). Install with `brew install --cask flutter`.
- Optional: **XcodeGen**, only needed if you change `companion_ios/project.yml` (`brew install xcodegen`).
- Python 3 (stdlib only) for the developer tools.

### Phone and glasses
- **iPhone running iOS 17.2+**, on the **same Wi-Fi network** as the Mac (a network that allows device-to-device traffic, not a "client isolation" guest network).
- **Meta AI** app on the iPhone, with the glasses paired.
- **Ray-Ban Meta (Gen 1 or Gen 2)** glasses, also supported: Ray-Ban Meta Optics, Oakley Meta HSTN and Vanguard, Meta Ray-Ban Display. Glasses firmware and Meta AI app must meet Meta's [version dependencies](https://wearables.developer.meta.com/docs/develop/dat).
- An **Apple Developer account** (Team ID) for signing the companion onto your iPhone.

### Accounts and credentials
| What | Needed for | Where |
|---|---|---|
| Apple Team ID | Installing the companion on an iPhone | Xcode > Settings > Accounts |
| Meta AI **Developer Mode** | Running an unpublished DAT app (no Meta credentials needed) | Meta AI app (steps below) |
| Meta App ID + Client Token | Only for release-channel distribution, not for development | [Wearables Developer Center](https://wearables.developer.meta.com/) |
| **Motion** capability enabled for the app | Head tracking (optional; the game works without it) | Wearables Developer Center (Motion is experimental in DAT 1.0.x) |

---

## Meta developer and glasses setup (manual)

These steps need the physical glasses and phone. They can't be automated.

1. **Update** the Meta AI app and the glasses firmware (Meta AI > Devices > ⚙ > General > About > Version).
2. **Pair** the glasses with the Meta AI app.
3. **Enable Developer Mode**: Meta AI > Settings > App Info > tap the **App version** number **5 times** > turn on **Developer Mode** > confirm.
   Unpublished apps then appear under Meta AI settings > App connections > Developer mode apps.
4. *(Only for distributing to testers through a release channel)* Create an organization and project in the
   [Wearables Developer Center](https://wearables.developer.meta.com/), then put the App ID and Client Token into
   `companion_ios/Config.xcconfig` (`META_APP_ID`, `CLIENT_TOKEN`). In Developer Mode leave them empty: the SDK
   skips attestation when `MetaAppID` is empty or `0`.
5. *(Optional, for head tracking)* Enable the experimental **Motion** capability for the app in the Wearables Developer
   Center. Experimental capabilities can be built and tested but not published. Without it, the companion shows
   *Head motion: unavailable* and the game aims with the hand only.

---

## Install and run

### 1. Clone and fetch dependencies

```bash
git clone https://github.com/pspolikepati/MetaRayzer.git
```

```bash
cd MetaRayzer && flutter pub get
```

### 2. Run the Mac app

```bash
flutter run -d macos
```

The app opens on the **Wizard's Stand** Start Menu. Press **PLAY** with the mouse to try it right
away; without glasses, use **Simulated input (dev)** or the Mac webcam source (see
[Playing Wizard's Stand](#playing-wizards-stand)).

or build a release app at `build/macos/Build/Products/Release/metarayzer.app`:

```bash
flutter build macos --release
```

On first launch macOS may ask to allow **incoming network connections** (allow it, so the phone
can connect) and, the first time you pick the webcam source, **camera access**.

The right-hand panel shows **Mac listener: Listening · `<Mac IP>` : 47800**. Note that IP; you
only need it if Bonjour discovery doesn't work on your network.

### 3. Configure and install the iPhone companion

1. Edit `companion_ios/Config.xcconfig` and set `DEVELOPMENT_TEAM` to your Apple Team ID. Change
   `COMPANION_BUNDLE_ID` if Xcode says the ID is taken.
2. Open the project and run it on your iPhone (Xcode resolves Meta's SDK package from
   `https://github.com/facebook/meta-wearables-dat-ios`, pinned to **1.0.1**):

```bash
open companion_ios/MetaRayzerCompanion.xcodeproj
```

   Select your iPhone as the run destination and press **Run**. Or build from the command line
   (signing still needs your team):

```bash
xcodebuild -project companion_ios/MetaRayzerCompanion.xcodeproj -scheme MetaRayzerCompanion -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

3. The entitlements match Meta's sample (keychain group, *Hotspot Configuration*, *Access Wi-Fi
   Information*). With automatic signing on a paid team, Xcode adds these capabilities to the App ID.
   If a personal (free) team rejects the Wi-Fi capabilities, remove those two keys from
   `MetaRayzerCompanion.entitlements`. The camera stream runs over Bluetooth Classic and doesn't need them.

### 4. Connect glasses and start the stream

On the **iPhone** (MetaRayzer Companion):
1. Allow **Local Network** and **Bluetooth** when iOS asks.
2. **Mac** section: the Mac appears automatically (Bonjour) and connects. If it doesn't, type the
   Mac IP from step 2 and tap **Connect**.
3. **Glasses** section: tap **Connect glasses (opens Meta AI)** and approve MetaRayzer in Meta AI.
   You return to the companion with *Registration: registered*.
4. Make sure the glasses are on, unfolded and worn. *Device* shows the glasses' name.
5. Tap **Start stream** (or press **Start glasses stream** on the Mac). The first time, Meta AI
   opens to grant **camera permission**: choose *Allow once* or *Allow always*. If the request came
   from the Mac, the phone first shows a confirmation, because switching to Meta AI needs your tap.
6. Keep the companion **in the foreground** while streaming.

The Mac now shows the live glasses feed with hand dots. Its panel mirrors the phone's state:
registration, device, permission and stream.

---

## Playing Wizard's Stand

### Flow

```
Start Menu ──PLAY──▶ Wizard's Stand ──3 hits──▶ Game Over ──PLAY AGAIN──▶ Wizard's Stand
    │  ▲                   │ Esc (quit, not recorded)        └──START MENU──▶ Start Menu
    │  └───────────────────┘
    ├──Tutorial (replay any time; Esc / Exit returns; PLAY from its last page)
    └──Settings / Glasses & tracking setup (Esc or Back returns)
```

**Camera feed behind the menus (v4).** While the glasses stream is live, every navigation
screen shows the live glasses view behind its panels:
- Start Menu, Settings, Game Over and the tutorial's first and last pages
- dimmed so text stays readable, with the hand-dot overlay
- a dashed outline of the **hand-pointer area**, the camera region that maps to the whole window
  for the hand cursor and the staff

It uses the same `CameraPreview`, controller, fit, mirroring and rotation as the in-game inset, so
coordinates match gameplay. It is one widget under all menu screens (`MenuBackdropHost` in
`AppShell`), so navigating never creates a second preview or restarts the stream.

States:
- A stalled stream is dimmed and labeled *STREAM PAUSED · showing the last frame*.
- With no stream, the normal night-sky background shows.
- The setting **Camera view behind menus** turns it off.
- The tracking-setup screen, the game and the tutorial's practice steps show the camera themselves.

The **Start Menu** shows:
- the title, **PLAY** and **Settings**
- glasses and hand-detection status
- the spellbook, including Chain Lightning's lock state
- the top-3 leaderboard

A **camera-stream indicator** (top-right of every screen) shows:
- **LIVE · Glasses camera streaming to MetaRayzer** while frames arrive
- *Glasses connected · camera off* when the phone is connected but the stream is stopped
- *stalled* when the stream should be running but no frames come
- *DEV camera feed* for the webcam or mock feeds

Nothing is shown with no device. It reflects **this app's** camera stream only. It doesn't
read or control the glasses' own capture LED, which Meta manages on the device; the toolkit has
no API for it.

### Navigating menus: mouse and hand, both always on

- **Mouse/keyboard:** click as usual.
- **Hand:** a glowing cursor follows your hand. Hold it over a button until the ring fills (hover
  time 1.0 s by default, adjustable in Settings). Moving off resets it, and one continuous hover
  activates a button only once.

Both inputs go through one activation guard. A button activated by either input is locked
against the hand for the rest of that hover, and any activation blocks all others for 0.4 s. So a
click and a dwell landing together fire **once**, and a screen transition can't be
double-triggered. Hand navigation pauses during gameplay, where your hand casts spells instead.

### The staff and aiming

You hold a **staff in your left hand** at the lower-left of the view (the left hand is the only
casting hand). Its tip follows your tracked hand continuously:
- One-Euro smoothing (tunable in `AimConfig`) removes jitter without noticeable lag.
- Movement is clamped to the lower-left region, so the staff never leaves the screen.
- With no hand, it holds for 0.5 s and then sinks to a rest pose.

The crystal shows the selected spell's color, glows as your hand opens (charge), and flashes and
recoils when a cast fires. Damage tints and shakes it.

**Aim** goes through the same coordinate chain as the menu cursor, so "hand in the middle"
means the same thing everywhere:

display-normalized hand position → central interaction box (0–1, clamped) → hand yaw = ±32° across the box

**world aim yaw = head view yaw + hand yaw.** The scene turns by the head view yaw, so the aim
stays attached to the staff whichever way you look.
- **Fireball** mode: a faint aim mark, and an orange reticle on the auto-target.
- **Chain Lightning** mode: a dashed cyan beam from the staff, and a reticle on the exact enemy the
  cast would hit (computed by the same function the cast uses).

### Casting (left hand, fingers pointing up)

1. **Fist** → the spell is ready (crystal glows; *"Ready: open your palm to cast"*).
2. **Open palm** → one cast of the selected spell.
3. Holding the palm open does nothing more. Close your fist to re-arm.
4. Hold a **V sign** (index + middle up, ring + little curled) for about 0.45 s to **switch spells**.
   It's neither fist nor open, so it can never cast. After a switch, a fresh fist is required.

Labels under the staff show the gesture state and **seen: fist/open/victory/unknown**.

### The shield (base kit, v4)

Raise your forearm **upright, close in front of your face** ("a vertical line" in the camera). The
shield then blocks **projectiles only** (skeleton arrows, boss bolts) for **0.5 s**.
- Holding the pose does **not** extend or retrigger it. Lower your hand and raise it again for
  the next one (re-arm takes 0.15 s).
- It never protects against melee blows or contact damage.
- It covers a ±35° arc around where you aim and look, so face the threat.
- Raising it cancels a readied spell, so a blocking hand never casts by accident.
- Feedback: a cyan shield wall drawn exactly where it blocks, with its remaining time along the
  bottom edge; a flash and a glassy clang on each block; a status chip (*ready / up / lower your
  hand to re-arm*) with a pip that fills as your hand approaches the pose; and an
  *INCOMING · RAISE SHIELD* prompt when a projectile on a hitting course is under 0.9 s away.

**How the pose is detected** (`ShieldGestureRecognizer`, all thresholds in `ShieldGestureConfig`):
from the tracked hand's geometry (`HandShape`: joint bounds, wrist→middle-knuckle axis), never a
single landmark.
- **Coverage:** the hand must span ≥ 45% of the *height* of a central shield region (x 0.30–0.70,
  y 0.15–0.85 of the view), and its center must be inside the region horizontally.
- **Closeness:** wrist→knuckle length ≥ 13% of the frame height.
- **Upright:** within 35° of vertical, fingers up.
- **Extended:** the hand reaches ≥ 1.5 palm lengths vertically, which rejects a fist.
  Height/width doesn't work for this: a real upright palm with a spread thumb is about as wide
  as it is tall.
- **Stability:** coverage is smoothed. The pose must hold for 2 new frames to count, and looser
  exit thresholds plus 2 failing frames release it.
- **Fails safe:** low-confidence frames are ignored, a dropout under 250 ms changes nothing, and
  a dropout never activates.

These values are validated on real Vision landmarks and simulated input, **not yet on glasses
footage**.

**Keys:** `Q`/`Tab` switch spells · `R` recenter the head · `Esc` leave the run (not recorded).

### Playing without glasses (development)

| Option | What it is |
|---|---|
| **Simulated input (dev)** (Start Menu) | Mouse = hand position; hold the mouse button or **Space/F** = fist; hold **V** = V sign; hold **B** = shield blocking pose; **arrow keys** = head turn. It goes through the same input interfaces, recognizers and game as the real inputs, is labeled **SIMULATED INPUT (dev)** on screen, and is never re-enabled on launch. |
| **Mac webcam** (Glasses & tracking setup → Source) | The real camera pipeline (Vision → classifier) on the Mac camera, badged *DEV*. |
| `tool/send_frames.py` | Streams JPEGs into the running app over the real link. `--motion-yaw 20` also sends glasses-style orientation, to exercise head tracking. Relayed audio events are printed. |

---

## Spells

The **spell book** in `WizardGame` lists the spells; adding a spell means adding an id in
`SpellIds`, its spec in `wizard_config.dart`, and a cast method. The gesture recognizers don't
change.

| Spell | How it targets | Damage | Unlock |
|---|---|---|---|
| **Shield** (base kit) | Not a spell slot: always available, whatever spell is selected. Blocks projectiles in a ±35° arc for 0.5 s. | — | always |
| **Fireball** (default) | **Unchanged from v2:** homes in on the nearest living enemy within 20 u, skipping enemies already doomed by fireballs in flight. Ignores the aim (with no target it flies out along the aim and fizzles). | 1 | always |
| **Chain Lightning** | **Aimed:** the first living enemy whose distance from the aim ray is ≤ 1.4 u, within 24 u. Then it arcs to the nearest not-yet-hit enemy within **5 u** of the previous one. | 2.0, then ×0.6 per link (2.0 → 1.2 → 0.72 → 0.43); up to 4 targets / 3 jumps; 1.5 s cooldown | Defeat your **first night boss**, **permanently** (v4) |

Chain Lightning resolves its damage instantly, exactly once per enemy per cast (a visited set).
Slimes split by the cast can't be chained to in the same cast. Score is awarded only for enemies
actually defeated. The visuals and sounds (jagged arcs appearing link by link, impact flashes,
staggered zaps that follow the chain) are driven by an event describing the already-resolved
outcome, so effects can never apply damage. With no enemy on the path, nothing is damaged and the
bolt fizzles along the aim.

**Unlock (v4):** score no longer unlocks anything. The game emits *SpellUnlocked* once, when a
real run's night boss (the Bone Lich) is defeated and the spell isn't already owned. The screen
shows the **CHAIN LIGHTNING UNLOCKED** banner, plays a fanfare, and writes the unlock to local
storage (`progression.v1`). Later runs start with it.
- Players who unlocked it in v3 keep it: the saved unlock is loaded as before and never removed.
- The tutorial runs in `GameMode.tutorial`, which can never emit an unlock, and its screen never
  touches progression.
- There is no debug path that grants it.

Chain damage goes through the normal damage pipeline, so health bars, scoring and the boss's
health all update the usual way. The shield stays in the base kit whichever spell is selected.

**Switching:** hold a V sign, press **Q**/**Tab**, or click a card in the spell bar
(bottom-center: selected spell, lock state, cooldown ring, and switch progress).

---

## Game rules and tuning

All numbers are in **`lib/src/games/wizard/wizard_config.dart`**. Nothing gameplay-related is
hard-coded elsewhere.

**World:** the player stands at the origin facing +z. Enemies spawn **32 u** away (lateral offset up
to ±5) and walk straight toward the player. Every distance (fireball and lightning range, melee
reach, archer stand-off, chain radius) is the same Euclidean distance √(x² + z²). The renderer
projects those same coordinates, so on-screen distance always matches gameplay distance.

| Enemy | Movement | Attack | Score | Spawn weight (start → full difficulty) |
|---|---|---|---|---|
| **Troll** | Slow steady walk, 1.9 u/s | Club wind-up (red "!" telegraph), strikes at 2.4 u | **10** | 0.50 → 0.16 |
| **Goblin** | Fast run with a weave, 5.2 u/s | Quick wind-up at 1.9 u | **25** | 0.12 → 0.28 |
| **Hopping Frog** | Moves only while airborne (0.45 s hops, 0.55 s rests), random sideways shift per hop | Wind-up at 1.9 u | **20** | 0.22 → 0.18 |
| **Skeleton Archer** *(v4: 2 health)* | Slow walk, **stops at 14 u** (inside fireball range) | Cycle (see below): sidestep, settle, telegraph, **one** aimed arrow, recover | **30** | 0.06 → 0.20 |
| **Splitting Slime** | Pulsing ooze (fast stretch, slow gather), 2.2 u/s average | Wind-up at 1.9 u | **60 family bonus** | 0.10 → 0.18 |
| **Bone Lich** *(v4 boss, night only)* | Glides in to **15 u**, hovers sideways | Telegraphed bolt volleys, alternating one aimed bolt / a fan of three; summons 2 goblins once below 50% health | **250** | never spawned by day |

**Skeleton Archer cycle (`ArcherSpec`)**, a readable loop that teaches the shield:
1. **Reposition:** a short sidestep (≤ 1.6 u, 0.9 s).
2. **Settle:** stands still for 0.45 s.
3. **Telegraph:** 1.1 s (shrinks with difficulty, never below 0.75 s). A distinct warning
   sound ("incoming" pips over a bone rattle), a bow draw, glowing red eye sockets, a dashed
   line toward you and a filling ring over its head.
4. **Fire:** exactly **one** arrow, aimed at that moment.
5. **Recover:** 1.3 s (scaled by difficulty), then back to step 1.

Each update makes at most one phase change, so a long frame can't skip the telegraph. An arrow is
released only on the telegraph→recover transition, and dying mid-draw fires nothing. An arrow from
14 u reaches the shield in about 1.3 s (about 1.05 s at full difficulty, where arrows fly 1.25×
faster), so you can see it coming and time the 0.5 s window. A test keeps telegraph + flight
above 1.5 s at full difficulty.

**Projectiles and reduced auto-aim (v4).** In v3, arrows re-steered toward the player every
frame and always hit. Now every projectile (`ProjectileSpec`):
- Aims **once, at release**, at your position plus a random lateral error of up to ± `aimSpread`
  (skeleton 1.3 u, boss bolt 0.45 u).
- The error shrinks with difficulty (× 0.8 at most) but never goes below `minAimSpread`, so later
  waves don't return to perfect aim.
- Flies in a **straight line** with a fixed velocity and never homes.
- Hits only if its path passes within 0.7 u (+ its own radius) of you. Otherwise it flies past
  and is removed.
- Is blocked if the shield is up and the projectile reaches 2.2 u inside the shield's arc. A
  block always wins over a hit in the same step, and each projectile resolves exactly once.

Accuracy is configurable per enemy type: `ArcherSpec.arrow` and `BossSpec.bolt`.

**Health bars (v4).** Every damageable enemy has a bar above its head. It is drawn after all
enemies and the mist, so it isn't hidden, and kept on screen.
- The bar is segmented per point of health. The missing part shows as an empty, outlined track
  and a white damage trail drains after each hit, so it doesn't rely on color.
- Full-health bars are quieter, and the bar disappears on defeat.
- Split slimes each get their own bar.
- The boss has a large top-of-screen bar with its name, `health / max` and coarser segments.
- All bars use one model (`HealthBarModel`) and painter (`view/health_bar.dart`).
- Telegraph icons stack above the bars.

**Enemy art (v4).** Same style, more depth:
- Gradient shading lit from the upper left, dark outlines for clear silhouettes, soft contact
  shadows, and a rim light that turns warm by day and moonlit by night.
- A white hit flash with a small knock-back.
- Squash and lean during wind-ups, a raised goblin dagger, and frog spots.
- The skeleton has a quiver, a jaw and glowing eye sockets; the slime has inner bubbles.
- The new lich has a crown, a hood, a tattered robe and a soul orb that swells while charging.

**Day-night cycle and boss (`DayNightCycle`, `DayNightSpec`, `BossSpec`).** The cycle is a state
machine inside the simulation, so it pauses, ends and resets with the run.

| Phase | Duration | What happens |
|---|---|---|
| **Day** | 75 s | Normal spawning under the difficulty controller. Bright sky with a sun and clouds, sunlit stone. HUD: *Day N · night in … s*. |
| **Dusk** | 4 s | No new ordinary enemies, and existing ones keep fighting. The light fades, then *NIGHT FALLS* plus a low horn. |
| **Night** | until the boss falls | One Bone Lich appears (*BONE LICH* banner, boss stinger, boss music). Ordinary spawning is suspended, apart from its one summon. |
| **Dawn** | 5 s | *BONE LICH DEFEATED · Dawn breaks*, 250 points, a dawn chime, day music. Day resumes, and the encounter is cleared when the day starts. |

The cycle repeats while you survive. Each later night's boss has +35% of its base health (18 → 24.3
→ 30.6 …). Exactly one boss can exist per night, because the boss slot is only cleared when the
next day starts, and long frames can't skip a phase. The difficulty ramp keeps running by day.

**Splitting Slime rules (`SlimeSpec`):**
- **Split:** any hit (fireball or lightning) on a big slime splits it into **2 smaller slimes**
  (0.6× size, 1.35× faster). They land slightly farther back and spread apart, and each is an
  independent enemy.
- **Limits:**
  - `maxSplitDepth` = 1: the small ones die normally when hit.
  - `maxActiveSlimes` = 8: a hit that would exceed the cap kills the slime outright instead of
    splitting it.
  - The spawner won't add a big slime if its children could exceed the cap.
- **Scoring rule:** the slime family (the original slime plus everything split from it) awards its
  **60 points once, when its last member is defeated** by the player. Splitting awards nothing.
  If any family member reaches you and strikes, the family awards nothing. Repeated hits or state
  changes can't award twice, because a family has a one-time `awarded` flag and each enemy has a
  `scored` flag. Small slimes still count toward "enemies defeated".

**Lives:** 3. A melee enemy strikes **once** and is then removed; arrows hit once. Other hits within
**0.6 s** of losing a life still resolve but don't cost another life. At 0 lives the simulation
freezes and the results screen opens.

**Difficulty (`DifficultyController`, the only place difficulty is computed).**

progress = smoothstep(max(elapsed / **210 s**, score / **1500**))

It's monotonic: it never decreases within a run. Every value below is interpolated start → end,
and capped at its end value:

| Parameter | Start | End (cap) |
|---|---|---|
| Spawn interval | 2.4 s | 0.7 s |
| Max simultaneous enemies | 3 | 9 |
| Enemy speed multiplier | 1.0× | 1.55× |
| Attack wind-up (reaction time) | 1.0× | 0.75×, **never below 0.35 s** |
| Archer shot interval | 1.0× | 0.65× |
| Arrow speed | 1.0× | 1.25× |
| Spawn mix | trolls/frogs | more goblins, archers, slimes |

The game is endless until all three lives are lost. The HUD shows *threat %* = progress.

**Leaderboard:** unchanged from v2: top 3 completed runs, persisted locally.

---

## Head movement

**Source:** the glasses' orientation from Meta's **experimental Motion capability**
(`MWDATMotion`, DAT 1.0.1). The companion starts it with the glasses session (30 Hz) and relays
each orientation quaternion to the Mac (`motion` wire message). If Motion isn't enabled or
available, the companion shows *Head motion: unavailable*. The game then aims with the hand only.
Hand movement is never substituted for head movement.

**Processing (`HeadPoseTracker`):**
- **Baseline:** the first sample after head tracking starts or reconnects becomes "straight
  ahead". Yaw and pitch are measured relative to it (an angular transform on quaternions; never
  degrees as pixels).
- **No jumps:**
  - On re-acquisition, a continuity offset keeps the output where it was and then fades out
    (time constant 2.5 s).
  - While samples are missing (> 300 ms), the view eases back to center (time constant 0.8 s).
  - **R** or **Recenter head** in Settings makes the current pose straight ahead, smoothly.
- One-Euro smoothing on yaw and pitch.
- **Sensitivity:** effective angle = measured angle × **Head movement sensitivity**. The range is
  0–2, default **1.0×**, and 0 turns head movement off. The result is clamped to ±40° yaw and
  ±12° pitch. It applies immediately and is saved.

**What head movement does:**
- It turns the in-game view (the world is rotated by the view yaw, and the horizon shifts with
  pitch). That gives real parallax between the distant ridges, the world-placed ruins and torches,
  and the enemies.
- It turns the aim reference: world aim yaw = view yaw + hand yaw.
- It turns the audio listener: sounds stay anchored to the enemies as you look around.

**Unverified:** the Motion quaternion's axis convention isn't documented. The tracker assumes the
common right-handed frame (x right, y up, z backward). If turning right moves the view left, set
**Invert head direction** in Settings. Real glasses data has not been tested.

---

## Audio

**Engine:** Apple's `AVAudioEngine` with an `AVAudioEnvironmentNode`, in the macOS plugin. There
are no new packages. All 22 sound effects and the ambient loop are **synthesized procedurally**
in Swift at startup (`SoundSynth.swift`): oscillators, noise, envelopes and filters, so there are
no audio files and no licensing questions. The same engine code runs in the iPhone companion.

**Sounds:**
- menu hover and select
- game start and restart
- fireball cast, impact and fizzle
- per-enemy defeat sounds
- slime split
- portal spawn shimmer
- attack telegraphs (growl, bow draw) and arrow release
- player hurt
- lightning cast, plus one zap per chain target staggered along the chain
- unlock fanfare, spell switch, game over

There is also an ambient loop of wind, a low drone and ember crackle.

**No duplicates:**
- Every sound comes from a single simulation event, and casts are already one-per-gesture.
- `AudioService` also blocks the same sound id from restarting within 40 ms (UI hover: 120 ms), so
  repeated detections can't stack copies.

**Positional audio.** Every enemy-related sound is placed at the enemy's game-world position. The
listener sits at the player and turns with the head-driven view. Near sounds are louder (inverse
distance falloff, reference 1.5 m, max 30 m, world scale 0.6 m/u), and a straight-ahead enemy is
centered. Two modes are available in Settings:

| Mode | What it is | Use for |
|---|---|---|
| **Stereo panning** (default) | Equal-power left/right panning plus distance attenuation. A stereo **simulation**, not true 3D. | Laptop speakers, the glasses' open-ear speakers |
| **Binaural 3D** | Apple's HRTF rendering (`HRTFHQ`): direction via timing and spectral cues. | Headphones |

Neither mode is surround sound. Neither is head-tracked by the operating system: the listener
turns only with the in-game view (glasses Motion × sensitivity). `tool/audio_probe.sh` checks
the engine offline by rendering it without speakers:
- left/right placement and centering in both modes
- distance falloff
- the listener-turn direction
- SFX volume

**Glasses audio via the iPhone: diagnosis and fix (v4).** In v3, choosing *Glasses via iPhone
companion* did switch the Mac to relay mode. But nothing on the phone ensured, or reported, that
the audio actually reached the glasses:
- The companion created its audio session **lazily on the first relayed sound**, with
  `.playback` + `.mixWithOthers`. Meta's *Use device microphones and speakers* guide asks for
  `.playback` with **no options** and says to check the route before assuming output is on the
  glasses.
- Nothing restarted audio after an **interruption**. Meta AI comes to the foreground for camera
  permission, which interrupts the companion's session.
- The Mac showed *"Playing on the iPhone…"* as soon as the preference was set. That was a
  requested preference displayed as if it were a fact.

v4 changes:
- The companion configures `.playback` exactly as documented and activates it as soon as the Mac
  starts relaying.
- It resumes after interruptions and media-server resets.
- It reports `AVAudioSession.currentRoute` outputs (port names and types) and a played-sound count
  in its status. The Mac passes this to Settings.
- The companion shows **Game audio (Mac → iPhone → glasses)** with *Playing on …* and iOS's own
  **audio output picker** (`AVRoutePickerView`). Picking the output is the user's step; no app can
  force a Bluetooth device.
- Settings shows **Requested** (your choice) separately from the verdict. *Confirmed by the OS:
  playing on the glasses* appears only when iOS (or macOS, for a Mac device) reports a Bluetooth
  output that is recognizably the glasses. Otherwise you see *Playing, but not on the glasses*,
  *Requested, not confirmed* or *Unavailable: fell back to this Mac*, with a hint.

Every sound, the ambient bed, the menu and tutorial sounds and the music go through the same
route. Disconnecting the phone falls back to the Mac's default output, and the music follows.
Hardware status: **not verified** (no phone, glasses or Xcode were available for v4). See the
[checklist](#version-4-checklist).

**Music (v4).** Three procedurally synthesized, seamlessly looping tracks (`MusicSynth` in
`SoundSynth.swift`), so there are no audio files or licensing questions:
- **menu:** calm, 72 bpm, for every non-game screen, including the tutorial.
- **day:** driving, 104 bpm, with light drums.
- **night:** a tense boss ostinato, 128 bpm.

How it plays:
- Two crossfaded players (1.2 s), with stingers for nightfall, boss arrival, boss defeat and dawn.
- Requesting the track that is already playing does nothing, both in Dart and natively, so
  rapid state changes can't stack copies.
- Navigating between menus doesn't restart the music. Game over fades it out, then menu music
  returns.

**Volumes (Settings → Audio):** master, music, sound effects, ambient, **Music on/off** and
**Sound effects on/off**. The engine receives master × channel volume, and 0 for a channel that
is off. These apply to both routes.

**Output routing (Settings → Audio → Output).** Meta's camera toolkit has **no audio playback
API**. Per Meta's docs, the glasses' speakers are reached through the **phone's** standard
Bluetooth audio. So there are two supported ways to hear the game on the glasses:

| Choice | Behavior |
|---|---|
| **Auto** (default) | If a Mac output device whose name looks like the glasses (Ray-Ban / Meta / Oakley) is connected to the Mac, use it; otherwise the Mac's default output. |
| **Glasses via iPhone companion** | The Mac plays nothing and relays each sound event (id, world position, gain, listener yaw, volumes) to the companion. The companion plays it with the same spatial engine on the iPhone's current audio route, which is the glasses when they are the phone's connected Bluetooth audio device. Falls back to the Mac automatically while no phone is connected. |
| **Mac system default** / a specific device | Plays on that macOS output. Devices are listed live and follow plug and unplug. A missing device falls back to the default. |

**Manual macOS step (only for direct-to-Mac playback):** the glasses must be paired with the Mac as
a Bluetooth audio device (System Settings → Bluetooth), and then selected in Settings or left on
Auto. Whether a given pair of glasses accepts a Mac audio connection while it streams its camera
through the phone is **not verified**; the iPhone relay is the path aligned with Meta's guidance.
Settings shows the active route, and has **Test: left / right / far ahead** buttons to check
direction by ear.

**Not verified:** audio heard through actual glasses, by either path. Also unverified: whether
iOS plays relayed audio through the glasses while DAT camera streaming is active. Meta's docs say
camera streaming doesn't use HFP, so A2DP output should remain available.

---

## Settings and persistence

Settings (Start Menu → **Settings**) apply immediately and are stored locally (`shared_preferences`,
key `settings.v1`):
- head movement sensitivity and *Invert head direction*
- master, music, SFX and ambient volumes; music and sound effects on/off (v4)
- positional mode (stereo or binaural) and output
- hand hover-to-select time
- camera inset, and the camera view behind menus (v4)

Every slider also has **− / +** buttons, so it can be adjusted by hand-hover. **Reset settings to
defaults** affects only these.

**Permanent progression** (unlocked spells) is stored separately (`progression.v1`), and the
leaderboard per game (`leaderboard.<gameId>`). Resetting settings never touches either. v2 settings
(menu-control mode, casting hand) are ignored on load: both navigation methods are always on, and
the left hand is the only casting hand.

---

## Game platform architecture

```
            ┌─────────────────────── camera pipeline (unchanged from v1) ───────────────────────┐
glasses ──▶ │ iPhone companion → FrameServer → FramePipeline → Vision → TrackingController(tracker) │
            └───────────────────────────────────────────┬───────────────────────────────────────┘
                                                        │ TrackedHand (landmarks, smoothed center)
lib/src/input/          CameraHandInput ── PoseClassifier (fist/open/victory from landmarks)
                        HeadInput ── HeadPoseTracker (glasses Motion quaternion → baseline-relative yaw/pitch)
                        SimulatedHandInput (dev)            │
                        HandInputHub  ── HandInputFrame {status, position, pose, confidence, frameId, simulated}
                                 │                                      │
lib/src/ui/dwell/        DwellScope + DwellSelector             lib/src/games/wizard/
                         (menus: hover-to-select)               CastGestureRecognizer (fist→open state machine)
                                                                WizardGame (pure-Dart simulation)
lib/src/platform/        AppNavigator (routes) · MinigameDefinition/Host · RunResult      │
lib/src/ui/menu/         StartMenu · GameOverScreen · fantasy theme             view/: projection, painter, effects
lib/src/leaderboard/     Leaderboard (top 3, persisted)   lib/src/app/: AppServices, AppSettings, AppShell
```

- **One small input interface.** Games and menus see only `HandInputFrame`: tracking status (with a
  reason when unavailable), a display-normalized position, the classified pose and its confidence,
  a frame id, and a `simulated` flag. They never touch camera frames or the native layer.
  `CameraHandInput` is the only adapter from the camera pipeline, and it reuses the v1 tracker
  (sticky ids, smoothing, hold/expire) unchanged.
- **Independent consumers:**
  - UI: `DwellScope`/`DwellSelector` use the position only.
  - Game: `CastGestureRecognizer` (fist→open) and `SpellSwitchRecognizer` (held V sign) use pose and
    status.
  - Aiming: `StaffAim` uses the position, plus the head view from `HeadInput`.

  None depends on another.
- **v3 modules:**

  | Module | Role |
  |---|---|
  | `games/wizard/difficulty.dart` | Central difficulty controller |
  | `aim.dart` | Hand + head → staff pose and aim |
  | `spell_switch.dart` | Held V-sign spell switching |
  | `wizard_audio.dart` | Game events → positioned sounds |
  | `audio/audio_service.dart` | Settings, dedup, route |
  | `app/progression.dart` | Permanent unlocks |
  | `ui/camera_stream_indicator.dart` | Camera-stream indicator |
  | `ui/menu/settings_screen.dart` | Settings screen |

- **v4 modules:**

  | Module | Role |
  |---|---|
  | `games/wizard/shield.dart` | Shield state machine (0.5 s window, release/re-arm, arc) |
  | `games/wizard/shield_gesture.dart` | Blocking-pose metrics and temporal recognizer |
  | `games/wizard/day_night.dart` | Day → dusk → night → dawn state machine |
  | `games/wizard/enemies.dart` | `SkeletonArcher` cycle, `BoneLich` boss, per-enemy health |
  | `games/wizard/wizard_game.dart` | Projectiles (aim once, straight flight, segment collision), boss lifecycle, boss-defeat unlock, `GameMode.tutorial` |
  | `games/wizard/wizard_session.dart` | Input → gameplay glue shared by the run and the tutorial |
  | `games/wizard/view/health_bar.dart` | Shared health-bar model and painter |
  | `games/wizard/tutorial/` | Tutorial flow, screen, pose illustrations |
  | `ui/menu_camera_backdrop.dart` | Live camera behind menus |
  | `input/hand_input.dart` (`HandShape`) | Hand geometry for gestures, without exposing landmarks |
  | `audio/audio_service.dart` | Music, effective volumes, `AudioRouteStatus` (requested vs. verified) |

- **Native (Swift) additions:**

  | File | Role |
  |---|---|
  | `SpatialAudioEngine.swift` | 3D voices, ambient loop, macOS device selection |
  | `SoundSynth.swift` | Procedural sounds |
  | `AudioController.swift` | Mac route choice and iPhone relay |

  Two new wire messages: `motion` (phone→Mac) and `audio` (Mac→phone). Older peers ignore unknown
  message types. The three shared Swift files exist in identical copies in the plugin and the
  companion; `tool/link_selftest.sh` fails if they diverge.
- **Pose classification** (`PoseClassifier`): for each finger (thumb ignored), it computes the ratio of the
  wrist→tip distance to the wrist→knuckle distance. On real Vision output, extended fingers measure 1.65–2.07
  and curled fingers 0.65–0.83. ≥3 extended and none curled = **open**; ≥3 curled and none
  extended = **fist**; anything else (half-open, pointing, victory) = **unknown**. The classifier is
  scale/rotation invariant and needs no extra model.
- **Cast recognizer:**
  - A pose counts only after **2 consecutive frames** at ≥0.45 confidence.
  - A confirmed fist arms the spell; a confirmed open palm while armed casts **once**.
  - Losing the hand never casts. Losing it for more than **350 ms** disarms.
  - Status-only re-deliveries of a frame aren't double-counted.
- **Game model** (`WizardGame`) is pure Dart: time only advances via `update(dt)` (clamped to 0.1 s),
  with seeded randomness and events for effects. `Enemy` is an abstract base class:
  - subclasses implement `move()` and optionally `attackUpdate()`
  - a new enemy type = a subclass + an `EnemySpec` + one line in `createEnemy`
- **Rendering**: one `CustomPainter` repainted from a `Ticker`. It does pseudo-3D projection
  (`ArenaProjection`, the only world→screen math, now with a view yaw/pitch) and draws all art
  procedurally: no image assets and no game engine. Flame was considered and not needed.

  v3 layers, back to front:
  1. sky with drifting nebulae, twinkling stars and the moon (all turn with the view)
  2. two mountain ridges at infinity
  3. world-placed ruined pillars and an arch
  4. flagstone grid in world space, with flickering torch light pools
  5. drifting mist banks in front of and behind the enemies
  6. stateless ember and mote particles
  7. enemies sorted by camera depth, each with a ground shadow
  8. effects
  9. the staff in the foreground
  10. HUD

  Effects:
  - **Fireball:** layered flickering core, ember trail particles, staff-tip cast flash and sparks,
    impact (ground light, shockwave, core, sparks), a distinct per-enemy defeat ring with rising
    soul wisps, fizzle smoke.
  - **Chain Lightning:** jagged flickering arcs with branches, primary and chain target rings,
    impact flashes, a brief sky flash.

  Particles are capped (450 per kind). All effects are view-only state built from game events.
- **Navigation**: `AppNavigator` holds a single route. Leaving the game route disposes the game widget
  and its ticker, so nothing runs behind the results screen. `finishRun` ignores stale or duplicate reports.
- **Adding a minigame**: write a widget that takes a `MinigameHost` (hand input, settings,
  `onFinished(RunResult)`, `onQuit`) and add a `MinigameDefinition` to `kMinigames` in `lib/main.dart`.
  Leaderboards and the results screen work per game id. A **Game Select** screen only needs a new
  `GameSelectRoute` and screen, with `playDefault()` pointed at it. The route list already anticipates it.

New dependency: **`shared_preferences`** (official Flutter package; macOS supported; no setup).

---

## Using the tracking setup screen

Start Menu → **Glasses & tracking setup** opens the original v1 view (live preview, dots, debug
panel). `Esc` or **Back to menu** returns.


| Control (setup screen side panel) | What it does |
|---|---|
| **Source**: Glasses (iPhone) / Mac webcam (dev) | Real path vs. **development fallback** (the Mac's own camera, clearly badged *DEV FALLBACK*). |
| **Start glasses stream / Stop** | Sends `startStream` / `stopStream` to the companion. |
| **Fit**: Contain / Cover | Letterbox the whole frame, or fill the view and crop. Dots in a cropped-away area are hidden. |
| **Hand center**: Palm / Box | Palm centroid (default, most stable) or bounding-box center. |
| **Mirror preview** | Horizontal flip (selfie view). Dots flip with the image. |
| **Rotation** | Rotates preview and dots 90° clockwise per tap. |
| **Hand detection** | Turn inference off (preview only). |
| **Show landmarks** | Draws the 21-joint skeleton (useful to validate the detector). |
| **Debug info** | Frame size, fps, detection time, latency, and for each hand: id, status, confidence, left/right, normalized, center-relative and pixel-offset coordinates. |

On the preview: the **white crosshair** is the frame center. Each hand gets a **colored dot**
with its tracking id (`#1`, `#2`) and a faint line from the center. A **hollow ring with "lost"**
means the hand just disappeared; it is removed after 300 ms. `#n?` means the identity is
uncertain (hands crossing or overlapping). A red **Stream stalled** badge appears if no frame has
arrived for 1 s, and all dots are removed.

---

## Verifying hand detection

1. **Without hardware: Mac webcam.** Choose *Mac webcam (dev)* in **Source**, hold one or two hands in
   front of the Mac, and turn on **Show landmarks**. Dots should follow your palms and the debug
   panel should show `#1`/`#2` with `rel x/y` near `0, 0` when a hand is at the crosshair.
   Turn on **Mirror preview** for a selfie view; dots must stay on the hands.
2. **Without hardware: recorded or still frames.** Stream JPEGs into the running app over the
   real network path (the app labels them as mock):

```bash
python3 tool/send_frames.py --fps 24 --loop path/to/hand_photo.jpg
```

3. **Detector only:** run the exact native detector on images and print JSON (normalized,
   center-relative and pixel-offset palm centers plus timing). `--annotate DIR` writes PNGs with
   the dots drawn on:

```bash
tool/vision_probe.sh --annotate /tmp/annotated path/to/hand_photo.jpg
```

4. **With glasses:** look at your hands. Move one hand to the image center: `rel` should approach
   `(0, 0)`. Move it right: `rel x` grows positive. Move it down: `rel y` grows positive. Take a
   hand out of view: its dot turns into a "lost" ring and disappears within ~0.3 s.

---

## Architecture

```
┌──────────────── iPhone: companion_ios (Swift, SwiftUI) ───────────────┐
│ GlassesController (DAT SDK)                                           │
│   Wearables.configure → startRegistration (Meta AI) → devicesStream   │
│   → createSession(AutoDeviceSelector) → checkPermission/request       │
│   → session.addCamera(StreamConfiguration(.raw, .medium, 24fps))      │
│   → stream.videoFramePublisher ── VideoFrame.makeUIImage()            │
│ FrameEncoder (bg queue, latest-wins) ── upright JPEG q=0.6            │
│ MacLink + FrameSender ── NWBrowser(_metarayzer._tcp) → NWConnection   │
│   one frame in flight, single pending slot (older frames dropped)     │
│   sends hello / frames / glasses status;  receives start/stop         │
└───────────────────────────────────┬───────────────────────────────────┘
                                    │ TCP :47800, length-prefixed messages
┌───────────────────────────────────▼──── Mac: Flutter app ─────────────┐
│ packages/metarayzer_native (Swift plugin, macOS)                      │
│   FrameServer   NWListener + Bonjour, single client, framing checks    │
│   FramePipeline latest-frame-wins: 1 pending slot, ≤2 frames awaiting │
│                 UI ack; JPEG decode (ImageIO) → HandDetector           │
│   HandDetector  protocol; VisionHandDetector (VNDetectHumanHandPose)   │
│   WebcamSource  DEV fallback (AVCapture → same JPEG path)             │
│   Plugin        MethodChannel metarayzer_native/control                │
│                 EventChannel  metarayzer_native/events                 │
├───────────────────────────────────────────────────────────────────────┤
│ lib/ (Dart)                                                           │
│   app/tracking_controller   state, stats, ack-after-render, timeouts  │
│   geometry/hand_geometry    palm centroid / bbox from 21 landmarks    │
│   geometry/hand_position    pixel, offset, normalized, relative       │
│   geometry/view_mapping     fit/crop/mirror/rotate frame → widget     │
│   tracking/hand_tracker     association, ids, hold/expire, ambiguity  │
│   tracking/one_euro_filter  jitter smoothing                          │
│   ui/                       preview, overlay painter, side panel      │
└───────────────────────────────────────────────────────────────────────┘
```

**Separation of concerns** (as requested): glasses connection and authorization
(`GlassesController`), camera-stream management (`GlassesController` + Mac commands), frame
acquisition and preprocessing (`FrameEncoder`, `FrameServer`, `FramePipeline`), detection
(`HandDetector`), tracking (`hand_tracker.dart`), coordinate transformation (`geometry/`), and UI
and state (`ui/`, `tracking_controller.dart`).

**Threading and memory.** Network IO, JPEG decode and Vision inference run on dedicated
background queues in Swift. The Dart UI isolate only receives finished results. No queue in the
system is unbounded:
- phone encoder: 1 pending frame
- phone sender: 1 in flight + 1 pending
- Mac pipeline: 1 pending + at most 2 processed frames awaiting UI acknowledgement
- Flutter image decode: 1 pending

When something is slow, the **oldest frames are dropped**, never the newest. Dropped counts appear
on both the phone and the Mac. Decoded `ui.Image`s are disposed immediately and never enter
Flutter's image cache.

**Wire protocol (v1)**, documented in `WireProtocol.swift`: `UInt32 BE length | UInt8 type | payload`.
Types: `hello` (JSON), `frame` (`seq u32, captureTimeMs u64, width u16, height u16, JPEG`), `status`
(JSON), `command` (JSON, Mac→phone). Messages over 8 MB are rejected as corrupt. The Swift file
exists in two identical copies (Mac plugin and companion), and `tool/link_selftest.sh` fails if
they diverge.

**Why JPEG over TCP?** The glasses deliver ≤720p at ≤30 fps over Bluetooth, so the phone→Mac Wi-Fi
hop is not the bottleneck. A 504×896 JPEG at q=0.6 is ~40–70 KB, about 1–1.7 MB/s at 24 fps.
JPEG keeps both ends simple (ImageIO decode in ~2 ms) and every frame is independently decodable,
which is what latest-frame-wins dropping requires. A codec with inter-frame dependencies (HEVC)
can't simply drop frames.

---

## Coordinate system

One convention everywhere: **image coordinates**, origin at the **top-left** of the frame,
**+x = right, +y = down**. For a frame of width *W* and height *H*, and a hand center at pixel *(x, y)*:

| Quantity | Formula | Range | In code |
|---|---|---|---|
| Frame center | (W/2, H/2) | | `FrameViewMapping.frameCenterInView` |
| Offset from center (px) | (x − W/2, y − H/2) | ±W/2, ±H/2 | `HandPosition.offsetX/offsetY` |
| Normalized | (x/W, y/H) | 0…1 | `HandPosition.xn/yn` |
| Center-relative | ((x − W/2)/(W/2), (y − H/2)/(H/2)) | −1…1, (0, 0) = center | `HandPosition.xr/yr` |

- **Hand center**: the mean of the wrist and the four finger knuckles (index, middle, ring and little MCP joints). It stays
  put while fingers move. If fewer than 3 of those joints are confident (≥ 0.3), the center
  falls back to the bounding-box center of all confident joints. Switch with **Hand center: Box**.
- **Vision → image coordinates**: Vision reports normalized points with a bottom-left origin, and
  `VisionHandDetector` converts with `y = 1 − y_vision`.
- **Orientation**: the companion bakes any EXIF orientation into the pixels before encoding, so
  the Mac always receives upright frames.
- **Screen mapping** (`lib/src/geometry/view_mapping.dart`): normalized frame point → rotate
  (quarter turns) → mirror → scale by the `contain`/`cover` factor → offset into the letterboxed or
  cropped image rectangle. The preview places the picture at exactly that rectangle with the same
  rotate and mirror transforms, so image and dots can't drift apart. Points that `cover` crops away
  are not drawn. `toFrameNormalized` is the exact inverse; tests check the round trip for every
  combination of fit, mirror and rotation.
- Positions stay in **camera-frame space** (not screen space), so they mean the same thing at any
  window size or stream resolution (360×640, 504×896 or 720×1280).

---

## Hand-detection model

### Choice: Apple Vision `VNDetectHumanHandPoseRequest`

| | Apple Vision hand pose (**chosen**) | MediaPipe Hand Landmarker | OpenCV only |
|---|---|---|---|
| Runs natively on macOS | ✅ system framework, nothing to install | ⚠️ Tasks API has no macOS Swift/C++ build; only via the Python package or a custom Bazel build | ✅ |
| Pretrained hand detector | ✅ 21 landmarks, up to N hands, chirality | ✅ 21 landmarks + handedness | ❌ none (needs skin-color heuristics or a separate DNN) |
| Hardware acceleration | Neural Engine / GPU | CPU/GPU (XNNPACK, Metal in some builds) | n/a |
| Measured here | **~4–6 ms (1 hand), ~10–11 ms (2 hands)** on M4 Pro | not measured | n/a |
| Model files and licensing | none to ship; part of macOS | `hand_landmarker.task` (Apache-2.0) to bundle | BSD/Apache |
| Integration cost from Flutter macOS | small Swift plugin | Python sidecar process or custom native build | similar, plus a detector |

Vision gives MediaPipe-class landmarks with no model download, no extra runtime, and the lowest
latency on a MacBook. All inference is local; camera frames never leave the phone↔Mac LAN link.
OpenCV alone has no reliable pretrained hand detector, so it would add work without adding accuracy.

- **Docs:** [VNDetectHumanHandPoseRequest](https://developer.apple.com/documentation/vision/vndetecthumanhandposerequest),
  [VNHumanHandPoseObservation](https://developer.apple.com/documentation/vision/vnhumanhandposeobservation),
  WWDC20 "Detect Body and Hand Pose with Vision".
- **Architecture and capabilities:** Apple's on-device hand-pose network. For each hand it returns 21
  joints (wrist, 4 thumb, 4 joints for each finger), per-joint confidence, an overall confidence, and
  chirality (left/right). `maximumHandCount = 2`.
- **Where the model comes from:** built into macOS (Vision.framework, macOS 11+, chirality on macOS 12+).
  Nothing to download, bundle or update separately; it updates with the OS.
- **Runtime dependencies:** Vision, CoreGraphics and ImageIO (system frameworks).
- **Input:** a `CGImage` decoded from the JPEG frame (any size; Vision resizes internally),
  orientation `.up`, sRGB.
- **Output → positions:** `HandDetector.swift` maps Vision joints into **MediaPipe's 21-joint order**
  (0 = wrist, 1–4 thumb, 5–8 index, 9–12 middle, 13–16 ring, 17–20 little) as flat
  `[x, y, confidence] × 21` in normalized top-left coordinates. Dart computes the center
  ([Coordinate system](#coordinate-system)) and passes it to the tracker.
- **Loading and invocation from Flutter:** `MetarayzerNativePlugin` (registered automatically
  through Flutter's Swift Package Manager plugin integration) creates one `VisionHandDetector`. The
  pipeline's background queue calls `detect(in:)` for each frame and sends results to Dart on
  `EventChannel("metarayzer_native/events")` as `{type: "frame", jpeg, width, height, hands: [{landmarks: Float64List, confidence, chirality}], …}`.
- **Licensing:** Vision is part of macOS and is covered by the macOS SDK license. No third-party
  model is distributed.
- **Limitations:** Vision can confuse left/right for back-of-hand views, so chirality is used only
  as a weak tie-breaker. Very small or heavily occluded hands, gloves, and strong motion blur
  (common in low-light Bluetooth-compressed frames) reduce recall.

### Replacing the model

Implement the `HandDetector` protocol (`HandDetector.swift`) and pass your detector to
`FramePipeline(detector:)` in `MetarayzerNativePlugin.swift`:

```swift
protocol HandDetector {
  var name: String { get }
  func detect(in image: CGImage) throws -> [DetectedHand]  // 21 landmarks, MediaPipe order, top-left normalized
}
```

Nothing else changes: the glasses link, tracker and UI only see the 21-landmark format. For
example, a Core ML conversion of MediaPipe's hand landmark model (Apache-2.0) would go into
`Sources/metarayzer_native/` as a resource (uncomment the `resources` entry in `Package.swift`).
Its pre-processing (palm detection → crop → 224×224 RGB) would live inside that detector.

---

## Tracking

`lib/src/tracking/hand_tracker.dart` is pure Dart and unit-tested.

- **Filtering:** detections below confidence 0.5 are ignored. Near-duplicate detections
  (box IoU > 0.6) are merged, and at most 2 hands are kept (highest confidence first).
- **Association:** globally optimal matching of tracks to detections (exhaustive; trivial for ≤2 hands),
  gated at 0.2 × frame diagonal (aspect-corrected, so portrait frames behave correctly). A small
  left/right mismatch penalty breaks near-ties.
- **Temporary ids:** new hands get the next id. An id persists while the hand stays matched, and
  for up to 300 ms of not being seen.
- **Anti-flicker:** a new hand must be seen in **2 consecutive frames** before it's shown, which
  suppresses one-frame false positives. Positions are smoothed with a **One Euro filter**: heavy
  smoothing at rest, light smoothing during fast motion.
- **Entering and leaving:** an unmatched hand **coasts** (hollow "lost" ring) for **300 ms** and is
  then removed. Every track is also removed after **1 s** without updates, even if frames stop
  arriving entirely (a UI timer runs this every 100 ms). No stale dots remain.
- **Crossing and overlap:** if swapping the two identities would cost almost the same, or the hands
  are within 6% of the diagonal, both tracks are flagged `identityUncertain` (shown as `#n?`) for
  the next 6 frames. Ids aren't swapped arbitrarily, but they also aren't claimed reliable while the
  detector can't tell the hands apart.

All thresholds are in `HandTrackerConfig`.

---

## Testing

| What | Command |
|---|---|
| Dart tests: coordinates, view mapping (incl. inverse for all fit/mirror/rotation combos), geometry, One Euro filter, tracker, controller with a fake native layer, event parsing | `flutter test` |
| Game tests: pose classifier (synthetic + real Vision landmarks), cast state machine, all game rules, dwell selection, leaderboard/settings persistence, navigation, camera-input adapter, full app flow widget tests | `flutter test test/games test/input test/ui test/platform test/app` |
| v3 tests: difficulty, slime, Chain Lightning, unlock, spell switch, head tracker, staff/aim, settings/progression persistence, audio dedup and event→sound positions, dwell guard, stream indicator | `flutter test test/games/wizard_v3_test.dart test/input/head_and_staff_test.dart test/audio test/ui` |
| v4 tests: shield, projectiles, skeleton cycle, auto-aim, health bars, day-night and boss, boss unlock, tutorial mode (`test/games/wizard_v4_test.dart`); shield gesture on real landmarks (`test/input/shield_gesture_test.dart`); volumes, music, route verification, progression (`test/audio/audio_v4_test.dart`); tutorial and menu camera widget tests (`test/app/tutorial_and_menus_test.dart`) | `flutter test test/games/wizard_v4_test.dart test/input/shield_gesture_test.dart test/audio/audio_v4_test.dart test/app/tutorial_and_menus_test.dart` |
| Spatial audio engine, offline (no speakers): all sounds synthesize, L/R placement in stereo and binaural, distance falloff, listener turn direction, volume, and (v4) three seamless music loops, music volume, track dedup | `tool/audio_probe.sh` |
| Static analysis | `flutter analyze` |
| Link integration: real Mac `FrameServer` + real companion `FrameSender` over loopback; Bonjour, framing, backpressure, commands, disconnect, reconnect, corrupt input | `tool/link_selftest.sh` |
| Detector on images (+ `--annotate DIR` overlay PNGs, `--landmarks` raw output) | `tool/vision_probe.sh img.jpg` |
| End-to-end Mac app without a phone (impersonates the companion) | `python3 tool/send_frames.py --loop img.jpg` |
| Companion compile check | `xcodebuild -project companion_ios/MetaRayzerCompanion.xcodeproj -scheme MetaRayzerCompanion -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` |

**Real-app gesture check without glasses:** composite a fist photo and an open-palm photo into
504×896 frames, with the hand where you want the cursor (hand navigation is always on), then
stream e.g. 4 s of fist frames followed by 1 s of open-palm frames with `send_frames.py`. The app
logs `[metarayzer] screen: PlayingRoute` and one `[metarayzer] fireball cast: …` per fist→open
transition. Keep the MetaRayzer window **visible**: macOS pauses rendering (and with it the game and
dwell timers) for hidden windows.

The Mac app logs a stats line every 5 s (`[MetaRayzer] stats: … fps processed, … dropped, avg … ms
detect, … hands/frame`). See it with `flutter run -d macos`, or in Console.app filtered by
`MetaRayzer`. The companion logs `[MetaRayzerCompanion] …` (Xcode console).

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Mac panel: **Port 47800 is already in use** | Another MetaRayzer instance or `send_frames.py` is running. Quit it and relaunch. |
| Phone never finds the Mac | Same Wi-Fi? Guest or "client isolation" networks block device-to-device traffic. On the iPhone: Settings > Privacy & Security > Local Network > MetaRayzer **on**. On the Mac: System Settings > Network > Firewall > allow incoming connections for `metarayzer`. Otherwise type the Mac IP shown in the Mac panel. |
| *Registration* stays `available` / Meta AI doesn't come back | Meta AI installed and up to date? Developer Mode on? Check the URL scheme `metarayzer://` in `Info.plist` → `MWDAT.AppLinkURLScheme`. |
| `No glasses available …` (`noEligibleDevice`) | Glasses on, unfolded, worn, and connected in Meta AI. Developer Mode enabled. Closing the hinges stops the session. Unfold and press Start again (a new session is created). |
| *Camera permission* `denied` | Meta AI > App connections > MetaRayzer > allow camera, then Start again. |
| Stream stuck at `waitingForDevice` / `paused` | The glasses paused the session (another experience, "Hey Meta", or removed from face). It resumes on its own. Don't restart while paused. |
| Low fps / blocky image | Expected over Bluetooth. Choose **360×640** or **15 fps** in the companion for better per-frame quality. The SDK lowers resolution, then fps (never below 15), when bandwidth is short. |
| `The glasses need an update` | The companion opens Meta AI's glasses-app update (`openDATGlassesAppUpdate`). Finish it there. |
| Mac shows *Stream stalled* | The phone was locked or backgrounded, or Wi-Fi dropped. Bring the companion to the foreground. It reconnects automatically every 2 s. |
| Dots offset from hands | Check **Fit/Mirror/Rotation**. Use **Show landmarks**: if the skeleton is on the hand but the dot isn't where you expect, switch **Hand center** to Palm. |
| Webcam source shows nothing | System Settings > Privacy & Security > Camera > allow `metarayzer`. |
| Mac fps drops when the window is hidden | By design: macOS pauses rendering for occluded windows, and the pipeline then drops frames instead of queueing. It recovers instantly when the window is visible. |
| Companion signing errors about Hotspot / Wi-Fi Info | See [step 3.3](#3-configure-and-install-the-iphone-companion). |
| Fireballs don't fire | Watch **seen:** under the orb. Fist must read `fist`, then `open`. Point your fingers **up**, not toward the camera (foreshortened fingers look curled), keep the hand inside the camera inset, and make a full fist (all four fingers). |
| Fires while I don't mean to | Every fist→open fires once by design. Keep the hand closed (or out of view) between casts. |
| Hand cursor never selects anything | The status must say *Left hand detected*. Hold still for the hover time; leave the button and come back to re-trigger it. Mouse clicks always work. |
| Game or menu freezes when another window covers it | macOS pauses rendering for hidden windows. Keep the game window visible. |
| No sound | Settings → Audio: check the volumes and the route line (*Playing on …*). Use **Test: left/right**. With *Glasses via iPhone*, the companion must be connected and in the foreground, and the iPhone's own volume up. |
| Sound comes from the wrong side when I turn my head | Settings → **Invert head direction** (the glasses' Motion axes are undocumented). Press **R** to recenter. |
| The view drifts or turns on its own | Press **R** (recenter), or lower the head sensitivity (0 = off). |
| Companion shows *Head motion: unavailable* | Enable the experimental Motion capability for the app in the Wearables Developer Center, and update the glasses and Meta AI. The game still works with hand aim only. |
| V sign doesn't switch spells | Chain Lightning must be unlocked (defeat your first night boss). Hold index + middle fingers up with the others curled for about half a second; **seen: victory** should show. Q/Tab and clicking work too. |
| Settings says *Requested: Glasses via iPhone* but *not on the glasses* | Open the companion: **Game audio** shows what iOS is playing on. Use its audio output picker (or Control Center → AirPlay) to choose the glasses. Keep the companion in the foreground. |
| Shield never comes up | Raise the forearm **upright and close** so the hand fills the middle of the view; watch the shield chip's pip fill. Tune `ShieldGestureConfig` if your camera framing differs. In simulated input, hold **B**. |
| Shield comes up when I just want to cast | Cast with the hand lower or farther from the face. A large, upright hand in the middle counts as blocking (and cancels the readied spell). |
| No music | Settings → Audio: *Music: On*, music and master volume up. |
| Reset the leaderboard / settings | `defaults delete ~/Library/Containers/com.metarayzer.metarayzer/Data/Library/Preferences/com.metarayzer.metarayzer` |

---

## Known limitations and future work

- **v4 hardware status:** see the [Version 4 checklist](#version-4-checklist). The companion and the
  Mac plugin's v4 Swift changes still need an Xcode build. Glasses audio, the shield pose through
  the glasses camera, and the menu feed with real frames need a run on real hardware.
- **No physical dodging:** the glasses report orientation, not position, so the player stands at
  a fixed point. Projectiles can be avoided by their aim error, by facing them with the shield, and
  by timing.

- **Gestures through the glasses' own camera are unverified.** The fist/open classifier is
  validated on real Vision landmarks from photos and works end to end in the built app, but not yet
  with the first-person view from the glasses:
  - The glasses camera sits at the **left hinge**, which helps the left hand.
  - Fingers pointing *at or away from* the camera are foreshortened and may read as a fist; cast
    with fingers pointing **up**.
  - Vision's left/right label for your own hands seen from behind is untested (*Either* is the fallback).
  - Thresholds live in `PoseClassifierConfig` if real footage needs tuning.
- **Head tracking** uses an experimental DAT capability with an undocumented axis convention, and
  hasn't been tested with real glasses (see [Head movement](#head-movement)).
- **Audio through the glasses** hasn't been heard or tested by either path; the stereo mode is a
  panning simulation, the binaural mode is HRTF, and neither is OS head-tracked (see [Audio](#audio)).
- **Gesture latency** is the camera path plus ~80 ms of confirmation (2 frames at 24 fps).
  Lowering `CastGestureConfig.confirmFrames` to 1 makes it snappier, at the cost of more false casts.
- **Hardware-dependent steps aren't verified yet.** The full phone + glasses path is implemented
  against DAT 1.0.1 and compiles, but hasn't been run on physical devices. See the
  [status table](#status-what-is-verified).
- **The companion must stay in the foreground.** iOS suspends networking for background apps, and
  Meta's sample also stops the session when the app is backgrounded.
- **Latency:** glasses → phone (Bluetooth, SDK-managed) is the largest and least controllable part.
  On the Mac, receive → decode → detect takes ~10–15 ms. The debug panel's `phone→mac` number is
  only accurate when both clocks are NTP-synced.
- **DAT is in developer preview.** It works in Developer Mode and Meta release channels; public App
  Store distribution of DAT apps depends on Meta's terms ([Meta Wearables Developer Terms](https://wearables.developer.meta.com/terms)).
- **Android companion** is not implemented. The Mac side is protocol-compatible: an Android app using
  `meta-wearables-dat-android` only needs to implement the 4-message protocol.
- **Future:** Game Select screen and more minigames, more spells and power-ups (the spell book,
  enemy health and damage falloff are already modeled), recorded sound assets, H.264/HEVC transport,
  a `Texture`-based preview, and detection on the phone.

---

## Platform constraints and verification

Checked on 2026-10-25 against Meta's official sources:

- [Device Access Toolkit docs](https://wearables.developer.meta.com/docs/develop/dat): supported platforms
  **iOS 17.2+ and Android 10+** (Xcode 26.4+). Supported devices include **Ray-Ban Meta (Gen 1 and Gen 2)**.
  macOS isn't listed, and no macOS or Mac Catalyst build exists in
  [facebook/meta-wearables-dat-ios](https://github.com/facebook/meta-wearables-dat-ios) (v1.0.1).
- Registration and permissions go through the **Meta AI iOS/Android app**, which doesn't exist on macOS.
  Even an "iPhone app on Apple-silicon Mac" build couldn't complete registration.
- Camera stream: max **720×1280 @ 30 fps** over Bluetooth Classic. Options: 360×640, 504×896, 720×1280 at
  2/7/15/24/30 fps, codec `.raw` (decoded) or `.hvc1`. The SDK lowers quality automatically under bandwidth pressure.
- Third-party Flutter wrappers for DAT exist on pub.dev, but they target iOS/Android Flutter apps,
  not macOS. This project uses Meta's official Swift SDK directly in a native companion.

**Smallest viable change if a direct Mac path appears:** if Meta ships a macOS DAT, add a third
frame source in `metarayzer_native` that feeds `FramePipeline.submit()`. That source would replace
`FrameServer`. The detector, tracker, coordinate math and UI need no changes.

### Repository layout

```
lib/src/app/                 app services, settings, root shell (navigation + dwell + dev input)
lib/src/input/               hand/head input, camera adapter, pose classifier, head tracker, simulated input
lib/src/audio/               AudioService (settings, dedup, route) over the native spatial engine
lib/src/games/wizard/        Wizard's Stand: config, difficulty, enemies, game model, spells, aim, recognizers, audio, view/
lib/src/platform/            navigator, minigame definition/host, run results
lib/src/ui/                  menus (fantasy theme), dwell selection, v1 tracking views
lib/src/leaderboard/         persisted top-3 scores
lib/src/{geometry,tracking}/ v1 coordinate math, tracker, One Euro filter
packages/metarayzer_native/  macOS Swift plugin: frame link, pipeline, Vision detector, webcam
companion_ios/               iPhone companion (Swift/SwiftUI, Meta DAT 1.0.1, XcodeGen project.yml)
test/                        Dart tests (fixtures/: real Vision landmarks)
tool/                        send_frames.py, vision_probe.sh, link_selftest.sh, audio_probe.sh
macos/                       Flutter macOS runner (entitlements: network server/client, camera)
```
