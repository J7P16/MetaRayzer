# MetaRayzer

Real-time hand tracking on the camera feed of **Ray-Ban Meta (Gen 2)** glasses, displayed in a
**Flutter macOS** app. Up to two hands are detected and tracked. Each hand's position is computed
relative to the center of the camera frame and drawn as a dot over the live preview.

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

1. [Status: what is verified](#status-what-is-verified)
2. [Prerequisites](#prerequisites)
3. [Meta developer and glasses setup (manual)](#meta-developer-and-glasses-setup-manual)
4. [Install and run](#install-and-run)
5. [Using the app](#using-the-app)
6. [Verifying hand detection](#verifying-hand-detection)
7. [Architecture](#architecture)
8. [Coordinate system](#coordinate-system)
9. [Hand-detection model](#hand-detection-model)
10. [Tracking](#tracking)
11. [Testing](#testing)
12. [Troubleshooting](#troubleshooting)
13. [Known limitations and future work](#known-limitations-and-future-work)
14. [Platform constraints and verification](#platform-constraints-and-verification)

---

## Status: what is verified

| Piece | Status |
|---|---|
| macOS app builds and launches (Flutter 3.47.8, Xcode 27.1, macOS 27.0.1, M4 Pro) | ✅ verified |
| Mac listener, Bonjour advertisement, frame link, disconnect detection | ✅ verified (loopback self-test + dev sender against the running app) |
| Hand detection on real photos (Apple Vision), 1 and 2 hands, 21 landmarks each | ✅ verified (`tool/vision_probe.sh` on MediaPipe's Apache-2.0 test images) |
| Overlay mapping on real frames: letterboxed, cropped and mirrored, and rotated views | ✅ verified (rendered the real UI widget with a real frame and inspected the output) |
| Full Mac pipeline throughput (two hands, 638×1000 frames) | ✅ 24.0 fps in, 24.0 fps processed, 0 dropped, ~11 ms detection |
| Coordinate math, view mapping, tracker, smoothing, controller | ✅ 52 unit tests |
| iPhone companion compiles against Meta DAT **1.0.1** (Debug and Release, `generic/platform=iOS`) | ✅ verified |
| Companion ↔ Mac protocol (the companion's own `FrameSender` against the Mac's `FrameServer`) | ✅ verified (`tool/link_selftest.sh`) |
| **Companion running on a physical iPhone with physical Ray-Ban Meta Gen 2 glasses** | ⚠️ **not verified.** No phone or glasses were available while building this. Needs the manual steps below. |
| MockDeviceKit (iPhone-camera) mode on a physical iPhone | ⚠️ not verified (same reason) |

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

## Using the app

| Control (Mac side panel) | What it does |
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
| Dart unit tests: coordinates, view mapping (incl. inverse for all fit/mirror/rotation combos), geometry, One Euro filter, tracker, controller with a fake native layer, event parsing | `flutter test` |
| Static analysis | `flutter analyze` |
| Link integration: real Mac `FrameServer` + real companion `FrameSender` over loopback; Bonjour, framing, backpressure, commands, disconnect, reconnect, corrupt input | `tool/link_selftest.sh` |
| Detector on images (+ `--annotate DIR` overlay PNGs, `--landmarks` raw output) | `tool/vision_probe.sh img.jpg` |
| End-to-end Mac app without a phone (impersonates the companion) | `python3 tool/send_frames.py --loop img.jpg` |
| Companion compile check | `xcodebuild -project companion_ios/MetaRayzerCompanion.xcodeproj -scheme MetaRayzerCompanion -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` |

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

---

## Known limitations and future work

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
- **Future:** H.264/HEVC transport for higher resolutions, a Flutter `Texture`-based preview (zero-copy
  `CVPixelBuffer`), 3D hand pose, gesture recognition, and running detection on the phone to save Wi-Fi bandwidth.

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
lib/                         Flutter app (Dart): state, geometry, tracking, UI
packages/metarayzer_native/  macOS Swift plugin: frame link, pipeline, Vision detector, webcam
companion_ios/               iPhone companion (Swift/SwiftUI, Meta DAT 1.0.1, XcodeGen project.yml)
test/                        Dart unit tests
tool/                        send_frames.py, vision_probe.sh, link_selftest.sh
macos/                       Flutter macOS runner (entitlements: network server/client, camera)
```
