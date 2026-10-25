// MetaRayzer link protocol, version 1.
//
// KEEP IN SYNC: an identical copy lives in
// packages/metarayzer_native/macos/metarayzer_native/Sources/metarayzer_native/WireProtocol.swift
// and the Python dev sender in tool/send_frames.py implements the same framing.
//
// Every message on the TCP connection is:
//
//   UInt32 BE  length   (number of bytes that follow, i.e. 1 + payload)
//   UInt8      type
//   [UInt8]    payload
//
// Payloads:
//   .hello   (phone -> mac)  UTF-8 JSON {"protocol":1,"name":"<device name>"}
//   .frame   (phone -> mac)  UInt32 BE seq, UInt64 BE capture time (Unix ms),
//                            UInt16 BE width, UInt16 BE height, JPEG bytes
//   .status  (phone -> mac)  UTF-8 JSON, see CompanionStatus keys
//   .command (mac -> phone)  UTF-8 JSON {"cmd":"startStream"|"stopStream"}
//   .motion  (phone -> mac)  Float32 BE qx, qy, qz, qw (glasses orientation), Int64 BE device ns
//   .audio   (mac -> phone)  UTF-8 JSON sound relay: {"op":"play","s":id,"x","y","z","g"} or
//                            {"op":"config","sfx","amb","mode","yaw","ambient"}
// Receivers ignore message types they don't know, so v1 peers stay compatible.

import Foundation

enum WireProtocol {
  static let version = 1
  static let bonjourType = "_metarayzer._tcp"
  static let defaultPort: UInt16 = 47800
  /// Upper bound for a single message; anything larger is treated as a corrupt stream.
  static let maxMessageBytes = 8 * 1024 * 1024
  static let headerBytes = 4
  static let frameHeaderBytes = 4 + 8 + 2 + 2
  static let motionBytes = 4 * 4 + 8
}

enum MessageType: UInt8 {
  case hello = 1
  case frame = 2
  case status = 3
  case command = 4
  case motion = 5
  case audio = 6
}

struct MotionMessage {
  var qx: Float
  var qy: Float
  var qz: Float
  var qw: Float
  var timestampNs: Int64
}

struct FrameMessage {
  var seq: UInt32
  var captureTimeMs: UInt64
  var width: UInt16
  var height: UInt16
  var jpeg: Data
}

enum WireError: Error, Equatable {
  case messageTooLarge(Int)
  case emptyMessage
  case unknownType(UInt8)
  case truncatedFrame
}

enum WireMessage {
  case hello([String: Any])
  case frame(FrameMessage)
  case status([String: Any])
  case command([String: Any])
  case motion(MotionMessage)
  case audio([String: Any])
}

enum WireCodec {
  static func encode(type: MessageType, payload: Data) -> Data {
    var out = Data(capacity: WireProtocol.headerBytes + 1 + payload.count)
    appendUInt32(&out, UInt32(1 + payload.count))
    out.append(type.rawValue)
    out.append(payload)
    return out
  }

  static func encodeJSON(type: MessageType, _ object: [String: Any]) -> Data {
    let payload = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    return encode(type: type, payload: payload)
  }

  static func encodeFrame(_ frame: FrameMessage) -> Data {
    var payload = Data(capacity: WireProtocol.frameHeaderBytes + frame.jpeg.count)
    appendUInt32(&payload, frame.seq)
    appendUInt64(&payload, frame.captureTimeMs)
    appendUInt16(&payload, frame.width)
    appendUInt16(&payload, frame.height)
    payload.append(frame.jpeg)
    return encode(type: .frame, payload: payload)
  }

  static func encodeMotion(_ m: MotionMessage) -> Data {
    var payload = Data(capacity: WireProtocol.motionBytes)
    for f in [m.qx, m.qy, m.qz, m.qw] { appendUInt32(&payload, f.bitPattern) }
    appendUInt64(&payload, UInt64(bitPattern: m.timestampNs))
    return encode(type: .motion, payload: payload)
  }

  /// Reads the 4-byte length prefix. Returns the body length or throws for corrupt input.
  static func bodyLength(header: Data) throws -> Int {
    let length = Int(readUInt32(header, at: header.startIndex))
    if length == 0 { throw WireError.emptyMessage }
    if length > WireProtocol.maxMessageBytes { throw WireError.messageTooLarge(length) }
    return length
  }

  /// Decodes a message body (type byte + payload, without the length prefix).
  static func decodeBody(_ body: Data) throws -> WireMessage {
    guard let typeByte = body.first else { throw WireError.emptyMessage }
    let payload = body.dropFirst()
    guard let type = MessageType(rawValue: typeByte) else { throw WireError.unknownType(typeByte) }
    switch type {
    case .frame:
      guard payload.count > WireProtocol.frameHeaderBytes else { throw WireError.truncatedFrame }
      let base = payload.startIndex
      return .frame(FrameMessage(
        seq: readUInt32(payload, at: base),
        captureTimeMs: readUInt64(payload, at: base + 4),
        width: readUInt16(payload, at: base + 12),
        height: readUInt16(payload, at: base + 14),
        jpeg: Data(payload[(base + WireProtocol.frameHeaderBytes)...])))
    case .motion:
      guard payload.count >= WireProtocol.motionBytes else { throw WireError.truncatedFrame }
      let b = payload.startIndex
      func f(_ i: Int) -> Float { Float(bitPattern: readUInt32(payload, at: b + i * 4)) }
      return .motion(MotionMessage(qx: f(0), qy: f(1), qz: f(2), qw: f(3), timestampNs: Int64(bitPattern: readUInt64(payload, at: b + 16))))
    case .audio: return .audio(decodeJSON(payload))
    case .hello: return .hello(decodeJSON(payload))
    case .status: return .status(decodeJSON(payload))
    case .command: return .command(decodeJSON(payload))
    }
  }

  private static func decodeJSON(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(data))) as? [String: Any] ?? [:]
  }

  private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
    withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
  }

  private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
    withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
  }

  private static func appendUInt64(_ data: inout Data, _ value: UInt64) {
    withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
  }

  private static func readUInt16(_ data: Data, at index: Data.Index) -> UInt16 {
    data[index..<(index + 2)].reduce(0) { ($0 << 8) | UInt16($1) }
  }

  private static func readUInt32(_ data: Data, at index: Data.Index) -> UInt32 {
    data[index..<(index + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
  }

  private static func readUInt64(_ data: Data, at index: Data.Index) -> UInt64 {
    data[index..<(index + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
  }
}
