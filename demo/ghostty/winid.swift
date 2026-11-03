// Print "<window-id> <x> <y> <w> <h> <scale>" for the first on-screen window
// whose title equals argv[1] (points, top-left origin; scale = backing factor
// of the display it is on). Exit 1 when no such window exists.
//
// Window titles are only visible to processes holding Screen Recording
// permission -- the same permission screencapture/ffmpeg need anyway.
import AppKit
import CoreGraphics

guard CommandLine.arguments.count > 1 else {
  FileHandle.standardError.write("usage: winid <title>\n".data(using: .utf8)!)
  exit(2)
}
let want = CommandLine.arguments[1]
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let list = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
for w in list {
  guard (w[kCGWindowName as String] as? String) == want,
        let id = w[kCGWindowNumber as String] as? Int,
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
  let x = b["X"] ?? 0, y = b["Y"] ?? 0, wd = b["Width"] ?? 0, ht = b["Height"] ?? 0
  var scale: CGFloat = 1
  for s in NSScreen.screens {
    // NSScreen frames are bottom-left origin; compare on x only plus primary.
    if s.frame.minX <= x && x < s.frame.maxX { scale = s.backingScaleFactor; break }
  }
  print("\(id) \(Int(x)) \(Int(y)) \(Int(wd)) \(Int(ht)) \(Int(scale))")
  exit(0)
}
exit(1)
