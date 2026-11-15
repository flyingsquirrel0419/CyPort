// DownloadPiP.swift - keeps a download going when you leave the app: the download screens show a small live card
// (progress drawn into a video layer); going to the Home Screen turns it into a Picture in Picture window, and iOS
// keeps an app with a playing PiP window running. Needs UIBackgroundModes audio (app/Info.plist) and the .playback
// audio session, only while a download runs (the game itself doesn't use it).
import AVFoundation
import AVKit
import CoreMedia
import SwiftUI
import UIKit

@MainActor
final class DownloadPiP: NSObject, ObservableObject {
    static let shared = DownloadPiP()
    let layer = AVSampleBufferDisplayLayer()
    @Published private(set) var inPiP = false
    @Published private(set) var running = false
    private var controller: AVPictureInPictureController?
    private var timer: Timer?
    private var title = "", fraction = 0.0, line1 = "Starting…", line2 = ""
    private var lastDone: Int64 = 0, beatDone: Int64 = -1, beatAt = 0.0          // the 20 s heartbeat in macshim.log
    private static let size = CGSize(width: 640, height: 360)
    /// silence played while downloading: PiP alone didn't stop iOS from suspending the app for minutes at a time
    /// (macshim.log 2026-11-15: no heartbeat for 513 s, then every request timed out - likely the screen locked);
    /// an app playing audio keeps running (LiveContainer and app/Info.plist have the audio background mode)
    /// (AVAudioPlayer, not AVAudioEngine: MacShim pauses every AVAudioEngine when the app goes to the background)
    private var silence: AVAudioPlayer?

    var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    /// a download starts: the card shows it, and leaving the app opens the PiP window
    func begin(_ title: String) {
        self.title = title; fraction = 0; line1 = "Starting…"; line2 = ""; beatDone = -1
        let s = AVAudioSession.sharedInstance()
        do { try s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers]); try s.setActive(true) }
        catch { storeLog("pip: audio session: \(error.localizedDescription)") }
        if controller == nil, supported {
            let c = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self))
            c.canStartPictureInPictureAutomaticallyFromInline = true
            c.delegate = self
            controller = c
        }
        startSilence()
        running = true
        render()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in DownloadPiP.shared.render() } }
        storeLog("pip: download card on (PiP \(supported ? "supported" : "not supported"))")
    }

    func update(_ p: Downloader.Progress) {
        lastDone = p.done
        fraction = p.total > 0 ? min(1, Double(p.done) / Double(p.total)) : 0
        line1 = String(format: "%.2f of %.2f GB · %.0f%%", Double(p.done) / 1e9, Double(p.total) / 1e9, fraction * 100)
        line2 = String(format: "%.1f MB/s", p.bytesPerSecond / 1e6) + " · " + Self.timeLeft(p.secondsLeft)
    }

    /// the download ended (done, paused or failed)
    func end() {
        guard running else { return }
        running = false
        timer?.invalidate(); timer = nil
        controller?.stopPictureInPicture()
        layer.flush()
        silence?.stop(); silence = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startSilence() {
        guard silence == nil else { return }
        // one second of 16-bit mono 8 kHz zeros as a WAV file, played on a loop
        let rate = 8000, n = rate * 2
        func le(_ v: Int, _ k: Int) -> [UInt8] { (0..<k).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        var w = Array("RIFF".utf8) + le(36 + n, 4) + Array("WAVEfmt ".utf8) + le(16, 4) + le(1, 2) + le(1, 2)
        w += le(rate, 4) + le(rate * 2, 4) + le(2, 2) + le(16, 2) + Array("data".utf8) + le(n, 4)
        w += [UInt8](repeating: 0, count: n)
        do {
            let p = try AVAudioPlayer(data: Data(w))
            p.numberOfLoops = -1
            guard p.play() else { storeLog("pip: silent audio didn't start"); return }
            silence = p
            storeLog("pip: silent audio on (keeps the download going with the screen locked)")
        } catch { storeLog("pip: silent audio: \(error.localizedDescription)") }
    }

    func toggle() {
        guard let c = controller else { return }
        if c.isPictureInPictureActive { c.stopPictureInPicture() } else { c.startPictureInPicture() }
    }

    static func timeLeft(_ s: Double) -> String {
        guard s > 0, s.isFinite else { return "…" }
        let t = Int(s)
        return t >= 3600 ? "\(t / 3600) h \(t % 3600 / 60) min left" : t >= 60 ? "\(t / 60) min left" : "\(t) s left"
    }

    // MARK: drawing a frame

    /// every 20 s while downloading: is the app still running in the background (PiP), how fast is it going
    private func heartbeat() {
        let now = CFAbsoluteTimeGetCurrent()
        if beatDone < 0 { if lastDone > 0 { beatDone = lastDone; beatAt = now }; return }    // after the first progress
        guard now - beatAt >= 20 else { return }
        let app = UIApplication.shared
        let state = app.applicationState == .active ? "foreground" : app.applicationState == .background ? "background" : "inactive"
        let left = app.backgroundTimeRemaining
        storeLog(String(format: "download heartbeat: %@%@, PiP %@, %.2f MB/s over %.0f s, %.0f MB done", state,
                        app.applicationState == .background ? (left > 1e8 ? " (kept running)" : String(format: " (iOS suspends it in %.0f s)", left)) : "",
                        inPiP ? "on" : "off", Double(lastDone - beatDone) / (now - beatAt) / 1e6, now - beatAt, Double(lastDone) / 1e6))
        beatDone = lastDone; beatAt = now
    }

    fileprivate func render() {
        if running { heartbeat() }
        guard running, let pb = Self.frame(title: title, fraction: fraction, line1: line1, line2: line2) else { return }
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(att) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sb)
    }

    private static func frame(title: String, fraction: Double, line1: String, line2: String) -> CVPixelBuffer? {
        let w = Int(size.width), h = Int(size.height)
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                     kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)        // UIKit's top-left origin
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        let yellow = UIColor(red: 0.99, green: 0.93, blue: 0.04, alpha: 1), red = UIColor(red: 1, green: 0, blue: 0.24, alpha: 1)
        // background: the start screen's gradient and neon edges
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [UIColor.black.cgColor, UIColor(red: 0.08, green: 0.02, blue: 0.06, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        yellow.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w, height: 6))
        red.withAlphaComponent(0.8).setFill(); ctx.fill(CGRect(x: 0, y: h - 4, width: w, height: 4))
        func text(_ s: String, _ font: UIFont, _ color: UIColor, _ y: CGFloat, italic: Bool = false) {
            var f = font
            if italic, let d = font.fontDescriptor.withSymbolicTraits([.traitItalic, .traitBold]) { f = UIFont(descriptor: d, size: font.pointSize) }
            (s as NSString).draw(in: CGRect(x: 36, y: y, width: CGFloat(w) - 72, height: f.lineHeight + 4),
                                 withAttributes: [.font: f, .foregroundColor: color])
        }
        text("CYPORT", .systemFont(ofSize: 44, weight: .black), yellow, 34, italic: true)
        text(title.uppercased(), .monospacedSystemFont(ofSize: 20, weight: .heavy), UIColor.white.withAlphaComponent(0.85), 100)
        // progress bar
        let bar = CGRect(x: 36, y: 168, width: CGFloat(w) - 72, height: 18)
        UIColor.white.withAlphaComponent(0.12).setFill(); UIBezierPath(roundedRect: bar, cornerRadius: 6).fill()
        yellow.setFill(); UIBezierPath(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: max(12, bar.width * CGFloat(fraction)), height: bar.height), cornerRadius: 6).fill()
        text(line1, .monospacedDigitSystemFont(ofSize: 30, weight: .bold), .white, 214)
        text(line2, .monospacedDigitSystemFont(ofSize: 24, weight: .semibold), UIColor.white.withAlphaComponent(0.6), 266)
        return pb
    }
}

extension DownloadPiP: AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)          // live: no seek bar
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize s: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval i: CMTime, completion: @escaping () -> Void) { completion() }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in DownloadPiP.shared.inPiP = true; storeLog("pip: started") }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in DownloadPiP.shared.inPiP = false; storeLog("pip: stopped") }
    }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError e: Error) {
        Task { @MainActor in storeLog("pip: failed to start: \(e.localizedDescription)") }
    }
}

/// the live card on the download screens; leaving the app turns it into the PiP window
struct DownloadPiPCard: View {
    @ObservedObject private var pip = DownloadPiP.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PiPLayerView(layer: pip.layer)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15)))
                .opacity(pip.inPiP ? 0.3 : 1)
            if pip.supported {
                HStack(alignment: .top, spacing: 12) {
                    Text(pip.inPiP ? "Downloading in Picture in Picture. You can use other apps."
                                   : "Go to the Home Screen or another app: the download keeps going in a small window.")
                        .font(.caption).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { pip.toggle() } label: { Image(systemName: pip.inPiP ? "pip.exit" : "pip.enter") }
                        .buttonStyle(CySecondaryButtonStyle())
                }
            } else {
                Text("Keep CyPort open while it downloads (this device has no Picture in Picture).").cyNote()
            }
        }
    }
}

private struct PiPLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    final class Host: UIView {
        var hosted: CALayer?
        override func layoutSubviews() { super.layoutSubviews(); hosted?.frame = bounds }
    }
    func makeUIView(context: Context) -> Host {
        let v = Host(); v.backgroundColor = .black
        layer.removeFromSuperlayer(); v.layer.addSublayer(layer); v.hosted = layer
        return v
    }
    func updateUIView(_ v: Host, context: Context) {
        if layer.superlayer !== v.layer { layer.removeFromSuperlayer(); v.layer.addSublayer(layer); v.hosted = layer; v.setNeedsLayout() }
    }
}
