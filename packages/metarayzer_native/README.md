# metarayzer_native

macOS-only local plugin used by the MetaRayzer app. See the root README for the architecture.

- `FrameServer.swift` – TCP listener + Bonjour (`_metarayzer._tcp`, port 47800) for the iPhone companion
- `WireProtocol.swift` – message framing (shared with `companion_ios/`)
- `FramePipeline.swift` – latest-frame-wins decode + detect loop with UI backpressure
- `HandDetector.swift` – `HandDetector` protocol and the Apple Vision implementation
- `WebcamSource.swift` – development fallback using the Mac camera
- `MetarayzerNativePlugin.swift` – method/event channels
