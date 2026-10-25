// DEVELOPMENT TOOL: runs the app's exact native hand detector (HandDetector.swift) on image files
// and prints the detections as JSON, plus timing. Use it to check the model independently of the
// glasses link and the Flutter UI. Build and run with tool/vision_probe.sh.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

var paths = Array(CommandLine.arguments.dropFirst())
var annotateDir: String?
let dumpLandmarks = paths.contains("--landmarks")
paths.removeAll { $0 == "--landmarks" }
if let i = paths.firstIndex(of: "--annotate"), i + 1 < paths.count {
  annotateDir = paths[i + 1]
  paths.removeSubrange(i...(i + 1))
}
guard !paths.isEmpty else {
  FileHandle.standardError.write("usage: vision_probe [--landmarks] [--annotate <out-dir>] <image.jpg> [...]\n".data(using: .utf8)!)
  exit(2)
}

/// Writes a PNG with the frame-center crosshair, landmarks and palm-center dot drawn in image
/// coordinates (top-left origin), so detection placement can be checked by eye.
func annotate(_ image: CGImage, _ hands: [DetectedHand], palmCenters: [(Double, Double)?], to path: String) {
  let w = image.width, h = image.height
  guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  // CoreGraphics has a bottom-left origin; flip so we can draw in image coordinates.
  ctx.translateBy(x: 0, y: CGFloat(h))
  ctx.scaleBy(x: 1, y: -1)
  ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  ctx.setLineWidth(2)
  let cx = CGFloat(w) / 2, cy = CGFloat(h) / 2
  ctx.strokeLineSegments(between: [CGPoint(x: cx - 15, y: cy), CGPoint(x: cx + 15, y: cy),
                                   CGPoint(x: cx, y: cy - 15), CGPoint(x: cx, y: cy + 15)])
  let colors = [CGColor(red: 0, green: 0.9, blue: 1, alpha: 1), CGColor(red: 1, green: 0.57, blue: 0, alpha: 1)]
  for (i, hand) in hands.enumerated() {
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    for p in hand.landmarks where p.confidence >= 0.3 {
      ctx.fillEllipse(in: CGRect(x: p.x * Double(w) - 3, y: p.y * Double(h) - 3, width: 6, height: 6))
    }
    if let (xn, yn) = palmCenters[i] {
      let p = CGPoint(x: xn * Double(w), y: yn * Double(h))
      ctx.setStrokeColor(colors[i % colors.count])
      ctx.strokeLineSegments(between: [CGPoint(x: cx, y: cy), p])
      ctx.setFillColor(colors[i % colors.count])
      ctx.fillEllipse(in: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20))
    }
  }
  guard let out = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { return }
  CGImageDestinationAddImage(dest, out, nil)
  CGImageDestinationFinalize(dest)
}

let detector = VisionHandDetector(maximumHandCount: 2)
let palmJoints: [HandJoint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]

for path in paths {
  guard let data = FileManager.default.contents(atPath: path), let image = FramePipeline.decode(data) else {
    print("{\"file\": \"\(path)\", \"error\": \"cannot decode\"}")
    continue
  }
  // Warm-up run: the first Vision call loads the model.
  _ = try? detector.detect(in: image)
  let runs = 10
  var hands: [DetectedHand] = []
  let t0 = CFAbsoluteTimeGetCurrent()
  for _ in 0..<runs { hands = (try? detector.detect(in: image)) ?? [] }
  let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(runs)

  let w = Double(image.width), h = Double(image.height)
  let palmCenters = hands.map { hand -> (Double, Double)? in
    let palm = palmJoints.map { hand.landmarks[$0.rawValue] }.filter { $0.confidence >= 0.3 }
    guard palm.count >= 3 else { return nil }
    return (palm.map(\.x).reduce(0, +) / Double(palm.count), palm.map(\.y).reduce(0, +) / Double(palm.count))
  }
  if let dir = annotateDir {
    let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    annotate(image, hands, palmCenters: palmCenters, to: (dir as NSString).appendingPathComponent("\(name)_annotated.png"))
  }
  let handJSON = hands.map { hand -> [String: Any] in
    let palm = palmJoints.map { hand.landmarks[$0.rawValue] }.filter { $0.confidence >= 0.3 }
    var out: [String: Any] = [
      "confidence": hand.confidence,
      "chirality": hand.chirality,
      "confidentJoints": hand.landmarks.filter { $0.confidence >= 0.3 }.count,
    ]
    if dumpLandmarks { out["landmarks"] = hand.landmarks.flatMap { [$0.x, $0.y, $0.confidence] } }
    if palm.count >= 3 {
      let xn = palm.map(\.x).reduce(0, +) / Double(palm.count)
      let yn = palm.map(\.y).reduce(0, +) / Double(palm.count)
      out["palmCenter"] = [
        "xn": xn, "yn": yn,
        "offsetPx": [xn * w - w / 2, yn * h - h / 2],
        "xr": (xn * w - w / 2) / (w / 2), "yr": (yn * h - h / 2) / (h / 2),
      ]
    }
    return out
  }
  let result: [String: Any] = [
    "file": (path as NSString).lastPathComponent, "width": image.width, "height": image.height,
    "detectMsAvg": (ms * 10).rounded() / 10, "hands": handJSON,
  ]
  let json = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
  print(String(data: json, encoding: .utf8)!)
}
