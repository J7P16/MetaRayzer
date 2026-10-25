import MWDATCore
import SwiftUI

struct ContentView: View {
  let model: CompanionModel
  @State private var manualHost = ""

  private var glasses: GlassesController { model.glasses }
  private var link: MacLink { model.link }

  var body: some View {
    NavigationStack {
      Form {
        macSection
        glassesSection
        streamSection
        if let image = glasses.latestPreview, glasses.isStreaming {
          Section("Preview (also shown on the Mac)") {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260)
          }
        }
        if let error = glasses.lastError {
          Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        }
        #if DEBUG
        Section {
          Toggle("Mock glasses (iPhone camera)", isOn: Binding(get: { glasses.mockEnabled }, set: { glasses.setMockEnabled($0) }))
        } header: {
          Text("Development")
        } footer: {
          Text("Uses Meta's MockDeviceKit with the iPhone's back camera instead of real glasses. The Mac labels these frames as MOCK.")
        }
        #endif
      }
      .navigationTitle("MetaRayzer Companion")
      .alert("Allow camera access?", isPresented: Binding(get: { glasses.needsPermissionConfirmation }, set: { glasses.needsPermissionConfirmation = $0 })) {
        Button("Open Meta AI") { glasses.confirmPermissionRequest() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("The Mac asked to start the glasses camera. Meta AI will open so you can allow camera access for MetaRayzer.")
      }
    }
  }

  private var macSection: some View {
    Section {
      switch link.state {
      case .idle:
        Label("Not connected", systemImage: "desktopcomputer").foregroundStyle(.secondary)
      case .connecting(let name):
        Label("Connecting to \(name)…", systemImage: "desktopcomputer")
      case .connected(let name):
        Label("Connected to \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      case .failed(let message):
        Label(message, systemImage: "xmark.octagon").foregroundStyle(.orange)
      }
      ForEach(link.discovered) { mac in
        Button { link.connect(to: mac) } label: { Label(mac.name, systemImage: "wifi") }
      }
      HStack {
        TextField("Mac IP (e.g. 192.168.1.20)", text: $manualHost)
          .keyboardType(.numbersAndPunctuation)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
        Button("Connect") { link.connect(host: manualHost) }.disabled(manualHost.isEmpty)
      }
      if link.isConnected {
        Button("Disconnect", role: .destructive) { link.disconnect() }
      }
    } header: {
      Text("Mac")
    } footer: {
      Text("Run MetaRayzer on your Mac on the same Wi-Fi. It is found automatically; otherwise enter the IP shown in the Mac app.")
    }
  }

  private var glassesSection: some View {
    Section("Glasses") {
      LabeledContent("Registration", value: "\(glasses.registrationState)")
      LabeledContent("Device", value: glasses.hasActiveDevice ? glasses.deviceDescription : "none")
      LabeledContent("Camera permission", value: glasses.permission)
      LabeledContent("Session", value: glasses.sessionState.description)
      if glasses.isRegistered {
        Button("Disconnect glasses from MetaRayzer", role: .destructive) { glasses.unregister() }
      } else {
        Button("Connect glasses (opens Meta AI)") { glasses.register() }
          .disabled(glasses.registrationState == .registering)
      }
    }
  }

  private var streamSection: some View {
    Section {
      LabeledContent("Stream", value: "\(glasses.streamState)")
      Picker("Resolution", selection: Binding(get: { glasses.resolution }, set: { glasses.resolution = $0 })) {
        ForEach(GlassesController.Resolution.allCases) { Text($0.label).tag($0) }
      }
      .disabled(glasses.streamState != .stopped)
      Picker("Frame rate", selection: Binding(get: { glasses.frameRate }, set: { glasses.frameRate = $0 })) {
        ForEach([UInt(7), 15, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
      }
      .disabled(glasses.streamState != .stopped)
      if glasses.streamState == .stopped {
        Button("Start stream") { glasses.startStream(userInitiated: true) }
      } else {
        Button("Stop stream", role: .destructive) { glasses.stopStream() }
      }
      if glasses.needsPermissionConfirmation {
        Button("Allow camera access (opens Meta AI)") { glasses.confirmPermissionRequest() }
      }
      if link.isConnected, glasses.isStreaming {
        LabeledContent("Sent to Mac", value: String(format: "%.1f fps · %d dropped", link.sentFps, link.droppedFrames))
      }
    } header: {
      Text("Camera stream")
    } footer: {
      Text("Keep this app in the foreground while streaming. Lower resolution and frame rate give better image quality over Bluetooth.")
    }
  }
}
