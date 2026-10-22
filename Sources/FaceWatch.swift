// Watches the camera while a Slack message box has focus, so every message can be checked against
// who was at the keyboard: a message only goes out if the owner's face was seen moments before.

import AVFoundation
import Cocoa

final class FaceWatch: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Whose face may send: the Mac's owner, by their macOS full name, matched against the lineup
    /// photo of the same name.
    static let ownerName = NSFullUserName()
    /// A send is judged on the frames from this long before it up to a fresh one just after: any
    /// of them showing the owner passes, so a blurry frame or a glance down doesn't block it.
    static let lookBack: TimeInterval = 1.0
    /// Seconds between checked frames (frames arriving while one is being checked are dropped).
    private static let checkInterval: TimeInterval = 0.15
    /// Below this similarity to the owner's photo a face is clearly someone else. Between it and
    /// the match threshold it's ambiguous (an odd angle, poor light) and counts as neither.
    private static let strangerBelow = 0.30
    /// Stranger frames in a row before acting on them while someone types.
    private static let strangerFrames = 3

    enum Seen: Equatable {
        case owner(Double)
        case stranger(String?)
        case unclear
        case noFace
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.thomasip.bagelguard.facewatch")
    private var configured = false
    private var running = false
    private var stopWork: DispatchWorkItem?
    private var lastCheckAt = Date.distantPast  // only touched on `queue`
    private var checkNextFrame = false  // only touched on `queue`
    private var startedAt = Date.distantPast
    private static let context = CIContext()

    // Main thread only.
    /// Every checked frame from the last few seconds, oldest first.
    private var history: [(time: Date, seen: Seen)] = []
    private var strangerStreak = 0
    /// Someone other than the owner is at the camera, and the owner isn't.
    var onStranger: ((String?) -> Void)?

    // MARK: Decisions

    /// The face check for a send that went out at `sentAt`: takes a fresh frame, then judges the
    /// frames from `lookBack` before the send to that one. Calls back with nil if the owner was in
    /// any of them, otherwise with why not.
    func verdict(forSendAt sentAt: Date, completion: @escaping (_ refusal: String?, _ summary: String) -> Void) {
        let asked = Date()
        requestFreshFrame()
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let fresh = self.history.last.map { $0.time > asked } ?? false
            guard fresh || Date().timeIntervalSince(asked) > 1 else { return }
            timer.invalidate()
            let frames = self.frames(from: sentAt.addingTimeInterval(-Self.lookBack))
            completion(self.refusal(for: frames), Self.summary(of: frames))
        }
    }

    /// Genuine cold start: the camera has only just come on and produced nothing yet. A send then is
    /// left to the after-send check (which grabs a fresh frame), so the owner isn't blocked while the
    /// sensor warms up. Rare, because the camera runs the whole time Slack is in front plus a grace.
    private var isColdStart: Bool {
        running && Date().timeIntervalSince(startedAt) < 1.5 && history.isEmpty
    }

    /// For a send about to happen (when the event tap can see it): fails closed — anything that
    /// isn't the owner in a recent frame is refused — except during a genuine cold start.
    var refusalBeforeSend: String? {
        if isColdStart { return nil }
        return refusal(for: frames(from: Date().addingTimeInterval(-Self.lookBack)))
    }

    private func frames(from start: Date) -> [Seen] {
        history.filter { $0.time >= start }.map(\.seen)
    }

    private func refusal(for frames: [Seen]) -> String? {
        if frames.contains(where: { if case .owner = $0 { true } else { false } }) { return nil }
        if !MugshotCamera.isAuthorized { return "no camera access to check who's sending" }
        if frames.isEmpty { return "camera not seeing anyone" }
        for case .stranger(let name) in frames.reversed() {
            return name.map { "face is \($0), not \(Self.ownerName)" } ?? "face isn't \(Self.ownerName)"
        }
        return "\(Self.ownerName)'s face not seen"
    }

    /// For the log, e.g. "7 frames: owner 5 (best 0.52), stranger 0, unclear 1, no face 1".
    private static func summary(of frames: [Seen]) -> String {
        var owner = 0, stranger = 0, unclear = 0, none = 0, best = 0.0
        for seen in frames {
            switch seen {
            case .owner(let similarity): owner += 1; best = max(best, similarity)
            case .stranger: stranger += 1
            case .unclear: unclear += 1
            case .noFace: none += 1
            }
        }
        let bestText = owner > 0 ? String(format: " (best %.2f)", best) : ""
        return "\(frames.count) frames: owner \(owner)\(bestText), stranger \(stranger), unclear \(unclear), no face \(none)"
    }

    // MARK: Camera

    /// Starts the camera (if it isn't running) and cancels any pending stop.
    func start() {
        stopWork?.cancel()
        stopWork = nil
        guard !running, MugshotCamera.isAuthorized else { return }
        running = true
        startedAt = Date()
        queue.async { [self] in
            if !configured {
                guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else {
                    return Log.write("face watch: no camera")
                }
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                session.beginConfiguration()
                session.sessionPreset = .medium
                if session.canAddInput(input), session.canAddOutput(output) {
                    session.addInput(input)
                    session.addOutput(output)
                    configured = true
                }
                session.commitConfiguration()
                guard configured else { return Log.write("face watch: camera busy") }
            }
            session.startRunning()
        }
        Log.write("face watch: camera on")
    }

    /// Stops the camera after `delay`, unless `start` is called again first, so hopping between
    /// apps doesn't restart it.
    func stop(after delay: TimeInterval = 60) {
        guard running, stopWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.stopNow() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func stopNow() {
        stopWork?.cancel()
        stopWork = nil
        // Frames from before the camera stopped (a screen lock, the overlay) prove nothing now.
        history.removeAll()
        strangerStreak = 0
        guard running else { return }
        running = false
        queue.async { [session] in session.stopRunning() }
        Log.write("face watch: camera off")
    }

    /// Checks the next frame as soon as it arrives, rather than waiting out the interval.
    private func requestFreshFrame() {
        queue.async { self.checkNextFrame = true }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard checkNextFrame || now.timeIntervalSince(lastCheckAt) >= Self.checkInterval,
            let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        checkNextFrame = false
        lastCheckAt = now
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = Self.context.createCGImage(image, from: image.extent) else { return }
        let seen: Seen
        switch Lineup.shared.check(cgImage: cgImage, owner: Self.ownerName) {
        case .noFace: seen = .noFace
        case .face(let ownerSimilarity, _) where ownerSimilarity > Lineup.matchThreshold: seen = .owner(ownerSimilarity)
        case .face(let ownerSimilarity, let best) where ownerSimilarity < Self.strangerBelow: seen = .stranger(best?.name)
        case .face: seen = .unclear
        }
        DispatchQueue.main.async { self.record(seen, at: now) }
    }

    private func record(_ seen: Seen, at time: Date) {
        history.append((time, seen))
        history.removeAll { time.timeIntervalSince($0.time) > 5 }
        guard case .stranger(let name) = seen else {
            strangerStreak = 0
            return
        }
        strangerStreak += 1
        if strangerStreak == Self.strangerFrames {
            Log.write("face watch: stranger \(name ?? "(not in lineup)")")
            onStranger?(name)
        }
    }
}
