import Foundation
import Network

/// Callbacks are delivered on the server's private network queue.
protocol FrameServerDelegate: AnyObject {
  func frameServer(_ server: FrameServer, listenerStateChanged state: FrameServer.ListenerState)
  func frameServer(_ server: FrameServer, clientConnected name: String)
  func frameServer(_ server: FrameServer, clientDisconnected reason: String?)
  func frameServer(_ server: FrameServer, received message: WireMessage)
}

/// TCP listener that the iPhone companion connects to. It advertises itself over Bonjour
/// (`_metarayzer._tcp`) and also listens on a fixed port so the phone can connect by IP when
/// Bonjour is blocked. Only one companion is served at a time; a new connection replaces the old.
final class FrameServer {
  enum ListenerState: Equatable {
    case stopped
    case starting
    case listening(port: UInt16)
    case failed(String)
  }

  weak var delegate: FrameServerDelegate?

  private let queue = DispatchQueue(label: "metarayzer.frame-server", qos: .userInitiated)
  private var listener: NWListener?
  private var connection: NWConnection?
  private let port: UInt16

  init(port: UInt16 = WireProtocol.defaultPort) {
    self.port = port
  }

  func start() {
    queue.async { self.startOnQueue() }
  }

  func stop() {
    queue.async {
      self.connection?.cancel()
      self.connection = nil
      self.listener?.cancel()
      self.listener = nil
      self.delegate?.frameServer(self, listenerStateChanged: .stopped)
    }
  }

  func send(command: [String: Any]) {
    queue.async {
      guard let connection = self.connection else { return }
      connection.send(
        content: WireCodec.encodeJSON(type: .command, command),
        completion: .contentProcessed { error in
          if let error { NSLog("[MetaRayzer] command send failed: \(error)") }
        })
    }
  }

  // MARK: - Listener

  private func startOnQueue() {
    guard listener == nil else { return }
    delegate?.frameServer(self, listenerStateChanged: .starting)

    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true  // frames are latency sensitive; don't let Nagle batch them
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.allowLocalEndpointReuse = true

    do {
      let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
      listener.service = NWListener.Service(
        name: Host.current().localizedName ?? "MetaRayzer Mac", type: WireProtocol.bonjourType)
      listener.stateUpdateHandler = { [weak self] state in self?.listenerStateChanged(state) }
      listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
      listener.start(queue: queue)
      self.listener = listener
    } catch {
      delegate?.frameServer(self, listenerStateChanged: .failed("Could not open port \(port): \(error)"))
    }
  }

  private func listenerStateChanged(_ state: NWListener.State) {
    switch state {
    case .ready:
      NSLog("[MetaRayzer] listening on port \(port) as \(WireProtocol.bonjourType)")
      delegate?.frameServer(self, listenerStateChanged: .listening(port: port))
    case .failed(let error):
      NSLog("[MetaRayzer] listener failed: \(error)")
      listener?.cancel()
      listener = nil
      let hint = error == .posix(.EADDRINUSE)
        ? "Port \(port) is already in use. Quit other MetaRayzer instances or the dev sender."
        : "Listener failed: \(error.localizedDescription)"
      delegate?.frameServer(self, listenerStateChanged: .failed(hint))
    case .waiting(let error):
      delegate?.frameServer(self, listenerStateChanged: .failed("Waiting for network: \(error)"))
    default:
      break
    }
  }

  // MARK: - Connection

  private func accept(_ newConnection: NWConnection) {
    if let old = connection {
      NSLog("[MetaRayzer] replacing existing companion connection")
      old.cancel()
    }
    connection = newConnection
    newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
      guard let self, let newConnection else { return }
      self.connectionStateChanged(newConnection, state)
    }
    newConnection.start(queue: queue)
  }

  private func connectionStateChanged(_ conn: NWConnection, _ state: NWConnection.State) {
    // Ignore events from a connection that has already been replaced.
    guard conn === connection else { return }
    switch state {
    case .ready:
      delegate?.frameServer(self, clientConnected: describe(conn.endpoint))
      receiveHeader(on: conn)
    case .failed(let error):
      dropConnection(conn, reason: "Connection failed: \(error.localizedDescription)")
    case .cancelled:
      dropConnection(conn, reason: nil)
    default:
      break
    }
  }

  private func dropConnection(_ conn: NWConnection, reason: String?) {
    guard conn === connection else { return }
    connection = nil
    conn.cancel()
    delegate?.frameServer(self, clientDisconnected: reason)
  }

  private func receiveHeader(on conn: NWConnection) {
    conn.receive(minimumIncompleteLength: WireProtocol.headerBytes,
                 maximumLength: WireProtocol.headerBytes) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let error { return self.dropConnection(conn, reason: "Receive error: \(error.localizedDescription)") }
      guard let data, data.count == WireProtocol.headerBytes else {
        return self.dropConnection(conn, reason: isComplete ? "Companion closed the connection" : "Short read")
      }
      do {
        let length = try WireCodec.bodyLength(header: data)
        self.receiveBody(on: conn, length: length)
      } catch {
        self.dropConnection(conn, reason: "Protocol error: \(error)")
      }
    }
  }

  private func receiveBody(on conn: NWConnection, length: Int) {
    conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let error { return self.dropConnection(conn, reason: "Receive error: \(error.localizedDescription)") }
      guard let data, data.count == length else {
        return self.dropConnection(conn, reason: isComplete ? "Companion closed the connection" : "Short read")
      }
      do {
        let message = try WireCodec.decodeBody(data)
        self.delegate?.frameServer(self, received: message)
      } catch {
        // A bad payload is logged and skipped; framing is still intact so keep reading.
        NSLog("[MetaRayzer] dropped malformed message: \(error)")
      }
      self.receiveHeader(on: conn)
    }
  }

  private func describe(_ endpoint: NWEndpoint) -> String {
    switch endpoint {
    case .hostPort(let host, _): return "\(host)"
    default: return "\(endpoint)"
    }
  }

  /// IPv4 addresses of active, non-loopback interfaces, for manual entry on the phone.
  static func localIPv4Addresses() -> [String] {
    var addresses: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let flags = Int32(ptr.pointee.ifa_flags)
      guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
            flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                     nil, 0, NI_NUMERICHOST) == 0 {
        addresses.append(String(cString: host))
      }
    }
    return addresses
  }
}
