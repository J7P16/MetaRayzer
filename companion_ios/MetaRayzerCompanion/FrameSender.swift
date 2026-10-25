import Foundation
import Network

/// One-in-flight frame sender with a single pending slot (latest frame wins).
final class FrameSender: @unchecked Sendable {
  var onSent: ((Int) -> Void)?
  var connection: NWConnection? {
    get { lock.withLock { _connection } }
    set {
      lock.withLock {
        _connection = newValue
        pending = nil
        inFlight = false
      }
    }
  }

  private let lock = NSLock()
  private var _connection: NWConnection?
  private var pending: Data?
  private var inFlight = false
  private var dropped = 0

  func submit(_ data: Data) {
    let toSend: (NWConnection, Data)? = lock.withLock {
      guard let conn = _connection else { return nil }
      if inFlight {
        if pending != nil { dropped += 1 }
        pending = data
        return nil
      }
      inFlight = true
      return (conn, data)
    }
    if let (conn, data) = toSend { send(data, on: conn) }
  }

  private func send(_ data: Data, on conn: NWConnection) {
    conn.send(content: data, completion: .contentProcessed { [weak self] error in
      guard let self else { return }
      let next: (NWConnection, Data)?
      let droppedNow: Int
      (next, droppedNow) = self.lock.withLock {
        let d = self.dropped
        self.dropped = 0
        guard error == nil, let c = self._connection, c === conn, let p = self.pending else {
          self.inFlight = false
          self.pending = nil
          return (nil, d)
        }
        self.pending = nil
        return ((c, p), d)
      }
      if error == nil { self.onSent?(droppedNow) }
      if let (c, p) = next { self.send(p, on: c) }
    })
  }
}
