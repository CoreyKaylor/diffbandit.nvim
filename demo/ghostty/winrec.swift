// Record one window (by CGWindowID) to a .mov with ScreenCaptureKit until
// SIGINT/SIGTERM. Window-only capture: other windows overlapping it, the
// mouse pointer and the desktop never appear, on whichever display it is.
//
//   winrec <window-id> <out.mov> [fps]
import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count >= 3, let wid = UInt32(args[1]) else {
  FileHandle.standardError.write("usage: winrec <window-id> <out.mov> [fps]\n".data(using: .utf8)!)
  exit(2)
}
let outURL = URL(fileURLWithPath: args[2])
let fps = args.count > 3 ? Int32(args[3]) ?? 30 : 30
try? FileManager.default.removeItem(at: outURL)

final class Delegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
  var finished = DispatchSemaphore(value: 0)
  func recordingOutputDidFinishRecording(_ o: SCRecordingOutput) { finished.signal() }
  func recordingOutput(_ o: SCRecordingOutput, didFailWithError e: Error) {
    FileHandle.standardError.write("winrec: \(e)\n".data(using: .utf8)!)
    finished.signal()
  }
  func stream(_ s: SCStream, didStopWithError e: Error) {
    FileHandle.standardError.write("winrec: stream stopped: \(e)\n".data(using: .utf8)!)
    finished.signal()
  }
}

// ScreenCaptureKit needs a WindowServer connection; NSApplication sets one up.
_ = NSApplication.shared
let delegate = Delegate()
var stream: SCStream?

Task {
  do {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let win = content.windows.first(where: { $0.windowID == wid }) else {
      FileHandle.standardError.write("winrec: window \(wid) not found\n".data(using: .utf8)!)
      exit(1)
    }
    let filter = SCContentFilter(desktopIndependentWindow: win)
    let cfg = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    cfg.width = Int(filter.contentRect.width * scale)
    cfg.height = Int(filter.contentRect.height * scale)
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: fps)
    cfg.showsCursor = false
    cfg.capturesAudio = false
    cfg.ignoreShadowsSingleWindow = true
    let s = SCStream(filter: filter, configuration: cfg, delegate: delegate)
    let rc = SCRecordingOutputConfiguration()
    rc.outputURL = outURL
    rc.outputFileType = .mov
    rc.videoCodecType = .hevc
    let ro = SCRecordingOutput(configuration: rc, delegate: delegate)
    try s.addRecordingOutput(ro)
    try await s.startCapture()
    stream = s
    print("recording \(cfg.width)x\(cfg.height)@\(fps)")
    fflush(stdout)
  } catch {
    FileHandle.standardError.write("winrec: \(error)\n".data(using: .utf8)!)
    exit(1)
  }
}

func stop() {
  guard let s = stream else { exit(1) }
  Task {
    try? await s.stopCapture()
    // The recording output finalizes the file after the stream stops.
    DispatchQueue.global().async {
      _ = delegate.finished.wait(timeout: .now() + 5)
      exit(0)
    }
  }
}
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigs = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
  let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
  src.setEventHandler { stop() }
  src.resume()
  return src
}
// A real AppKit run loop: ScreenCaptureKit builds its menu-bar indicator on main.
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
