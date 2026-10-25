import Foundation
import Network
import Observation
import UIKit

/// Connection from the iPhone to the MetaRayzer Mac app.
///
/// - Discovers Macs over Bonjour (`_metarayzer._tcp`) or connects to a typed-in host.
/// - Sends frames with latest-frame-wins backpressure: at most one frame is in flight; while it
///   is being sent, newer frames replace the single pending slot and older ones are dropped.
/// - Reconnects automatically after the connection drops.
@Observable
@MainActor
final class MacLink {
  enum State: Equatable {
    case idle
    case connecting(String)
    case connected(String)
    case failed(String)
  }

  struct DiscoveredMac: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
  }

  private(set) var state: State = .idle
  private(set) var discovered: [DiscoveredMac] = []
  private(set) var sentFps: Double = 0
  private(set) var droppedFrames = 0
  /// Called on the main actor for each command from the Mac.
  var onCommand: ((String) -> Void)?
  /// Called on the main actor for each relayed sound message from the Mac.
  var onAudio: (([String: Any]) -> Void)?
  /// Provides the current glasses status to send right after connecting.
  var statusProvider: (() -> [String: Any])?

  var isConnected: Bool {
    if case .connected = state { return true }
    return false
  }

  @ObservationIgnored private let queue = DispatchQueue(label: "metarayzer.maclink", qos: .userInitiated)
  @ObservationIgnored private var browser: NWBrowser?
  @ObservationIgnored private var connection: NWConnection?
  @ObservationIgnored private var target: NWEndpoint?
  @ObservationIgnored private var targetName = ""
  /// Set when the user taps Disconnect, so Bonjour auto-connect doesn't immediately undo it.
  @ObservationIgnored private var userDisconnected = false
  @ObservationIgnored private var reconnectTask: Task<Void, Never>?
  @ObservationIgnored private let sender = FrameSender()
  @ObservationIgnored private var fpsWindow: (start: Date, count: Int) = (Date(), 0)

  init() {
    sender.onSent = { [weak self] dropped in
      Task { @MainActor in self?.frameSent(dropped: dropped) }
    }
  }

  // MARK: Discovery

  func startBrowsing() {
    guard browser == nil else { return }
    let browser = NWBrowser(for: .bonjour(type: WireProtocol.bonjourType, domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let macs = results.compactMap { result -> DiscoveredMac? in
        if case .service(let name, _, _, _) = result.endpoint { return DiscoveredMac(name: name, endpoint: result.endpoint) }
        return nil
      }.sorted { $0.name < $1.name }
      Task { @MainActor in self?.discoveredChanged(macs) }
    }
    browser.stateUpdateHandler = { [weak self] state in
      if case .failed(let error) = state {
        Task { @MainActor in
          self?.state = .failed("Bonjour browsing failed: \(error.localizedDescription). Allow Local Network access in Settings, or enter the Mac's IP.")
          self?.browser = nil
        }
      }
    }
    browser.start(queue: queue)
    self.browser = browser
  }

  private func discoveredChanged(_ macs: [DiscoveredMac]) {
    discovered = macs
    // Convenience: if exactly one Mac is advertising and we're not connected, use it.
    if target == nil, !userDisconnected, macs.count == 1, let only = macs.first {
      connect(to: only)
    }
  }

  // MARK: Connection

  func connect(to mac: DiscoveredMac) {
    connect(endpoint: mac.endpoint, name: mac.name)
  }

  func connect(host: String, port: UInt16 = WireProtocol.defaultPort) {
    let trimmed = host.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
    connect(endpoint: .hostPort(host: NWEndpoint.Host(trimmed), port: nwPort), name: trimmed)
  }

  func disconnect() {
    userDisconnected = true
    target = nil
    reconnectTask?.cancel()
    connection?.cancel()
    connection = nil
    sender.connection = nil
    state = .idle
  }

  private func connect(endpoint: NWEndpoint, name: String) {
    userDisconnected = false
    reconnectTask?.cancel()
    connection?.cancel()
    target = endpoint
    targetName = name
    state = .connecting(name)

    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.connectionTimeout = 5
    let conn = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
    connection = conn
    conn.stateUpdateHandler = { [weak self, weak conn] newState in
      Task { @MainActor in
        guard let self, let conn, conn === self.connection else { return }
        self.connectionStateChanged(conn, newState)
      }
    }
    conn.start(queue: queue)
  }

  private func connectionStateChanged(_ conn: NWConnection, _ newState: NWConnection.State) {
    switch newState {
    case .ready:
      state = .connected(targetName)
      sender.connection = conn
      conn.send(content: WireCodec.encodeJSON(type: .hello, ["protocol": WireProtocol.version, "name": deviceName()]),
                completion: .contentProcessed { _ in })
      if let status = statusProvider?() { sendStatus(status) }
      receiveHeader(on: conn)
    case .waiting(let error):
      state = .failed("Can't reach \(targetName): \(error.localizedDescription)")
      scheduleReconnect()
    case .failed(let error):
      state = .failed("Connection to \(targetName) failed: \(error.localizedDescription)")
      scheduleReconnect()
    case .cancelled:
      break
    default:
      break
    }
  }

  private func scheduleReconnect() {
    sender.connection = nil
    connection?.cancel()
    connection = nil
    guard let target else { return }
    let name = targetName
    reconnectTask?.cancel()
    reconnectTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard let self, !Task.isCancelled, self.target == target else { return }
      self.connect(endpoint: target, name: name)
    }
  }

  private func connectionLost(_ reason: String) {
    guard connection != nil else { return }
    state = .failed(reason)
    scheduleReconnect()
  }

  private nonisolated func receiveHeader(on conn: NWConnection) {
    conn.receive(minimumIncompleteLength: WireProtocol.headerBytes, maximumLength: WireProtocol.headerBytes) { [weak self] data, _, complete, error in
      guard let data, data.count == WireProtocol.headerBytes, error == nil,
            let length = try? WireCodec.bodyLength(header: data) else {
        Task { @MainActor in self?.connectionLost(complete ? "Mac closed the connection" : "Connection lost: \(error?.localizedDescription ?? "read error")") }
        return
      }
      conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, complete, error in
        guard let body, body.count == length, error == nil else {
          Task { @MainActor in self?.connectionLost(complete ? "Mac closed the connection" : "Connection lost") }
          return
        }
        switch try? WireCodec.decodeBody(body) {
        case .command(let json)?:
          if let cmd = json["cmd"] as? String { Task { @MainActor in self?.onCommand?(cmd) } }
        case .audio(let json)?:
          let message = json as NSDictionary
          Task { @MainActor in self?.onAudio?(message as? [String: Any] ?? [:]) }
        default:
          break
        }
        self?.receiveHeader(on: conn)
      }
    }
  }

  // MARK: Sending

  func sendStatus(_ status: [String: Any]) {
    guard let connection, isConnected else { return }
    connection.send(content: WireCodec.encodeJSON(type: .status, status), completion: .contentProcessed { _ in })
  }

  /// Thread-safe; called from the motion task.
  nonisolated func send(motion: MotionMessage) {
    sender.sendSmall(WireCodec.encodeMotion(motion))
  }

  /// Thread-safe; may be called from the frame-encoding queue.
  nonisolated func send(frame: FrameMessage) {
    sender.submit(WireCodec.encodeFrame(frame))
  }

  private func frameSent(dropped: Int) {
    droppedFrames += dropped
    fpsWindow.count += 1
    let elapsed = Date().timeIntervalSince(fpsWindow.start)
    if elapsed >= 1 {
      sentFps = Double(fpsWindow.count) / elapsed
      fpsWindow = (Date(), 0)
    }
  }

  private func deviceName() -> String {
    UIDevice.current.name
  }
}
