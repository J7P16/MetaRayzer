// Loopback integration test of the phone <-> Mac link, using the real code from both sides:
//   Mac side:   FrameServer.swift + WireProtocol.swift (from the macOS plugin)
//   Phone side: FrameSender.swift (from companion_ios), plus the same Bonjour browse +
//               NWConnection setup MacLink.swift uses.
// Run with tool/link_selftest.sh. Exits non-zero on failure.

import Foundation
import Network

let port: UInt16 = 47_801  // not the app's port, so a running MetaRayzer doesn't interfere
var failures = 0

func check(_ ok: Bool, _ what: String) {
  print(ok ? "PASS  \(what)" : "FAIL  \(what)")
  if !ok { failures += 1 }
}

/// Spins the main run loop until [condition] holds or [timeout] expires.
func wait(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  }
  return condition()
}

final class Recorder: FrameServerDelegate {
  let lock = NSLock()
  var listening = false
  var connected = 0
  var disconnectReasons: [String] = []
  var frames: [FrameMessage] = []
  var hello: [String: Any]?
  var status: [String: Any]?
  var motions: [MotionMessage] = []

  func frameServer(_ server: FrameServer, listenerStateChanged state: FrameServer.ListenerState) {
    if case .listening = state { lock.withLock { listening = true } }
    if case .failed(let m) = state { print("listener failed: \(m)") }
  }
  func frameServer(_ server: FrameServer, clientConnected name: String) { lock.withLock { connected += 1 } }
  func frameServer(_ server: FrameServer, clientDisconnected reason: String?) {
    lock.withLock { disconnectReasons.append(reason ?? "closed") }
  }
  func frameServer(_ server: FrameServer, received message: WireMessage) {
    lock.withLock {
      switch message {
      case .frame(let f): frames.append(f)
      case .hello(let h): hello = h
      case .status(let s): status = s
      case .motion(let m): motions.append(m)
      case .command, .audio: break
      }
    }
  }
}

// --- Mac side ---------------------------------------------------------------------------------
let recorder = Recorder()
let server = FrameServer(port: port)
server.delegate = recorder
server.start()
check(wait(5) { recorder.lock.withLock { recorder.listening } }, "Mac listener starts on port \(port)")

// --- Phone side: discover over Bonjour like MacLink.startBrowsing() ---------------------------
let queue = DispatchQueue(label: "selftest.client")
var bonjourEndpoint: NWEndpoint?
let browser = NWBrowser(for: .bonjour(type: WireProtocol.bonjourType, domain: nil), using: .tcp)
browser.browseResultsChangedHandler = { results, _ in
  // Several MetaRayzer listeners could be advertising; any one proves discovery works.
  if bonjourEndpoint == nil { bonjourEndpoint = results.first?.endpoint }
}
browser.start(queue: queue)
check(wait(5) { bonjourEndpoint != nil }, "Bonjour discovery finds a \(WireProtocol.bonjourType) service")
browser.cancel()

// Connect by host:port (the manual-IP path) so we are sure to reach *this* test server.
func connectClient() -> NWConnection {
  let tcp = NWProtocolTCP.Options()
  tcp.noDelay = true
  let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: tcp))
  conn.start(queue: queue)
  return conn
}

var clientReady = false
var commands: [String] = []
var audioMessages: [[String: Any]] = []
let client = connectClient()
client.stateUpdateHandler = { if case .ready = $0 { clientReady = true } }
check(wait(5) { clientReady && recorder.lock.withLock { recorder.connected == 1 } }, "phone connects; Mac reports companion connected")

func receive(on conn: NWConnection) {
  conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
    guard let header, let length = try? WireCodec.bodyLength(header: header) else { return }
    conn.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, _ in
      if let body {
        switch try? WireCodec.decodeBody(body) {
        case .command(let json)?: if let cmd = json["cmd"] as? String { commands.append(cmd) }
        case .audio(let json)?: audioMessages.append(json)
        default: break
        }
      }
      receive(on: conn)
    }
  }
}
receive(on: client)

client.send(content: WireCodec.encodeJSON(type: .hello, ["protocol": 1, "name": "selftest phone"]), completion: .contentProcessed { _ in })
client.send(content: WireCodec.encodeJSON(type: .status, ["stream": "streaming", "mock": true]), completion: .contentProcessed { _ in })
check(wait(3) { recorder.lock.withLock { recorder.hello?["name"] as? String == "selftest phone" && recorder.status?["stream"] as? String == "streaming" } },
      "hello and status messages arrive intact")

// --- Frames through the companion's FrameSender (latest-frame-wins backpressure) --------------
let sender = FrameSender()
var sentCount = 0
var droppedCount = 0
let counterLock = NSLock()
sender.onSent = { dropped in counterLock.withLock { sentCount += 1; droppedCount += dropped } }
sender.connection = client

let jpegish = Data(repeating: 0xAB, count: 60_000)  // payload size of a typical 504x896 JPEG
let total = 300
for seq in 1...total {
  sender.submit(WireCodec.encodeFrame(FrameMessage(seq: UInt32(seq), captureTimeMs: UInt64(seq), width: 504, height: 896, jpeg: jpegish)))
}
_ = wait(5) { recorder.lock.withLock { recorder.frames.last?.seq == UInt32(total) } }
let received = recorder.lock.withLock { recorder.frames }
check(received.last?.seq == UInt32(total), "newest frame (#\(total)) always gets through (got #\(received.last?.seq ?? 0))")
check(received.allSatisfy { $0.width == 504 && $0.height == 896 && $0.jpeg == jpegish }, "frame header and payload decode intact")
check(zip(received, received.dropFirst()).allSatisfy { $0.seq < $1.seq }, "frames arrive in order, never duplicated")
_ = wait(1) { counterLock.withLock { sentCount } == received.count }
let (sent, dropped) = counterLock.withLock { (sentCount, droppedCount) }
check(sent + dropped == total, "every frame is either sent or counted as dropped (sent \(sent) + dropped \(dropped) = \(total))")
print("      burst of \(total) frames: \(received.count) delivered, \(dropped) superseded by newer frames")

// --- Commands Mac -> phone ------------------------------------------------------------------
server.send(command: ["cmd": "startStream"])
server.send(command: ["cmd": "stopStream"])
check(wait(3) { commands == ["startStream", "stopStream"] }, "stream commands reach the phone in order")

// --- Head motion phone -> Mac (companion's FrameSender.sendSmall) and audio relay Mac -> phone ---
sender.sendSmall(WireCodec.encodeMotion(MotionMessage(qx: 0.1, qy: -0.2, qz: 0.3, qw: 0.927, timestampNs: 123_456_789_012)))
check(wait(3) { recorder.lock.withLock { recorder.motions.count == 1 } }, "motion (orientation quaternion) messages arrive")
let m = recorder.lock.withLock { recorder.motions.first }
check(m.map { $0.qx == 0.1 && $0.qy == -0.2 && $0.qz == 0.3 && $0.qw == 0.927 && $0.timestampNs == 123_456_789_012 } ?? false, "motion quaternion and timestamp decode exactly")
server.send(json: ["op": "play", "s": "zap", "x": 1.5, "z": 6], type: .audio)
check(wait(3) { audioMessages.first?["s"] as? String == "zap" }, "audio relay messages reach the phone")

// --- Disconnect detection ---------------------------------------------------------------------
client.cancel()
check(wait(3) { recorder.lock.withLock { recorder.disconnectReasons.count == 1 } }, "Mac notices the phone disconnecting")

// --- Reconnect, then a corrupt stream is rejected -----------------------------------------------
var client2Ready = false
let client2 = connectClient()
client2.stateUpdateHandler = { if case .ready = $0 { client2Ready = true } }
check(wait(5) { client2Ready && recorder.lock.withLock { recorder.connected == 2 } }, "phone can reconnect after a drop")
var bogus = Data([0xFF, 0xFF, 0xFF, 0xFF])  // 4 GB length prefix
bogus.append(contentsOf: [2, 0, 0])
client2.send(content: bogus, completion: .contentProcessed { _ in })
check(wait(3) { recorder.lock.withLock { recorder.disconnectReasons.count == 2 && recorder.disconnectReasons[1].contains("Protocol error") } },
      "oversized/corrupt message drops the connection instead of allocating")
client2.cancel()
server.stop()

print(failures == 0 ? "\nALL LINK TESTS PASSED" : "\n\(failures) LINK TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
