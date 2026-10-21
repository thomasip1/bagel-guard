// The overlay: a frosted-glass interdiction screen on every display. The webcam photo is taken the
// moment the bagel is detected, the face in it is located with Vision, and a target lock is drawn
// on it. Each caught attempt is saved to ~/Pictures/BagelGuard: the bare photo and a redrawn copy
// of the overlay.

import AVFoundation
import Cocoa
import CoreImage
import Vision

/// What the overlay says about one attempt.
struct Booking {
    enum Ending { case lock, close, preview }

    let destination: String
    let evidence: String
    let caseNumber: Int
    let date: Date
    /// Time from detection to a confirmed empty message box.
    let responseMilliseconds: Int?
    let ending: Ending

    var caseLabel: String { String(format: "%04d", caseNumber) }

    /// Used by the preview and by `--render`.
    static func sample(_ ending: Ending) -> Booking {
        Booking(
            destination: "#office-london", evidence: "bagel emoji", caseNumber: 42, date: Date(), responseMilliseconds: 38,
            ending: ending)
    }

    /// Slack labels the message box "Message to <channel or person>", or "Reply to thread in
    /// <channel>" in a thread.
    static func destination(fromField field: String) -> String {
        var name = field
        for prefix in ["Message to ", "Reply to thread in "] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        name = unescape(name.trimmingCharacters(in: .whitespaces))
        if name.isEmpty { return "Slack" }
        return name.contains(" ") ? name : "#\(name)"
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\'", with: "'")
         .replacingOccurrences(of: "\\\"", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// A face Vision found, in image pixels with a top-left origin.
struct Face {
    let rect: CGRect
    let confidence: Float
}

struct Mugshot {
    let image: NSImage
    var rawImage: CGImage?
    var face: Face?
    var match: LineupMatch?
}

enum Formats {
    static let clock = formatter("HH:mm:ss")
    static let timestamp = formatter("d MMM yyyy, HH:mm:ss", locale: "en_GB")
    static let fileStamp = formatter("yyyy-MM-dd HH.mm.ss")

    private static func formatter(_ format: String, locale: String = "en_US_POSIX") -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - Saved mugshots

enum MugshotArchive {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/BagelGuard")

    /// The overlay as it looked, drawn off-screen at the main screen's size. The frosted screen
    /// behind it becomes a dark backdrop, so no Screen Recording permission is needed and nothing
    /// behind the overlay is captured.
    static func render(_ mugshot: Mugshot?, for booking: Booking) -> NSBitmapImageRep? {
        let view = InterdictionView(booking: booking)
        view.paintsBackdrop = true
        view.frame = NSRect(origin: .zero, size: NSScreen.main?.frame.size ?? NSSize(width: 1728, height: 1117))
        view.show(mugshot)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// Writes "<time> case <n> <place> screen.jpg" (the redrawn overlay) and "… photo.jpg".
    static func save(_ mugshot: Mugshot, for booking: Booking) {
        guard let screen = render(mugshot, for: booking),
            let photo = mugshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let place = booking.destination.replacingOccurrences(of: "#", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ")).inverted).joined()
        let who = mugshot.match.map { " \($0.name)" } ?? ""
        let base = "\(Formats.fileStamp.string(from: booking.date)) case \(booking.caseLabel) \(place)\(who)"
        let files = [("\(base) screen.jpg", screen), ("\(base) photo.jpg", NSBitmapImageRep(cgImage: photo))]
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (name, bitmap) in files {
                    try bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])?.write(to: folder.appendingPathComponent(name))
                }
                Log.write("saved \(base) (screen + photo)")
            } catch {
                Log.write("could not save mugshot: \(error)")
            }
        }
    }
}

// MARK: - Palette and type

enum Glass {
    static let tint = NSColor(srgbRed: 0x05 / 255, green: 0x08 / 255, blue: 0x0D / 255, alpha: 0.62)
    static let grid = NSColor.white.withAlphaComponent(0.035)
    static let panelFill = NSColor.white.withAlphaComponent(0.055)
    static let panelEdge = NSColor.white.withAlphaComponent(0.16)
    static let primary = NSColor.white.withAlphaComponent(0.94)
    static let secondary = NSColor.white.withAlphaComponent(0.62)
    static let tertiary = NSColor.white.withAlphaComponent(0.38)
    static let hairline = NSColor.white.withAlphaComponent(0.12)
    static let lock = NSColor(srgbRed: 0xFF / 255, green: 0xB0 / 255, blue: 0x20 / 255, alpha: 1)
    static let sensor = NSColor(srgbRed: 0x10 / 255, green: 0x15 / 255, blue: 0x1C / 255, alpha: 1)

    static func display(_ size: CGFloat, _ weight: NSFont.Weight = .light) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
}

// MARK: - Camera

/// Grabs one frame from the default camera, then looks for a face in it.
final class MugshotCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// Ask up front, so the permission prompt never ends up hidden behind the overlay.
    static func requestAccessIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in Log.write("camera access granted: \(granted)") }
    }

    /// Shared, and warmed up at launch: the first render on a new context costs ~0.2 s.
    private static let context = CIContext()

    static func warmUp() {
        let pixel = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        _ = context.createCGImage(pixel.applyingFilter("CIExposureAdjust"), from: pixel.extent)
    }

    /// The largest face Vision finds.
    static func face(in image: CGImage) -> Face? {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
        let box = face.boundingBox
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return Face(
            rect: CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height),
            confidence: face.confidence)
    }

    /// The MacBook camera's first frame is nearly black, and exposure keeps rising for seconds
    /// after it (isAdjustingExposure always reads false, so it can't be trusted). Measured: first
    /// frame 0.5-0.75 s after start at brightness 8-13/255, ~62 a tenth of a second later, ~83 after
    /// 3 s. So take a frame 0.1 s in and lift its exposure towards `targetBrightness` instead of
    /// waiting. A lower resolution doesn't start any faster.
    private static let settle: TimeInterval = 0.1
    private static let targetBrightness = 105.0

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.thomasip.bagelguard.camera")
    private var onPhoto: ((Mugshot?) -> Void)?
    private var onAnalyzed: ((Face?) -> Void)?
    private var firstFrameAt: Date?  // only touched on `queue`
    private var grabbed = false  // only touched on `queue`

    /// Calls `onPhoto` as soon as there is a photo (nil if there won't be one), then `onAnalyzed`
    /// once face detection has finished.
    func snap(onPhoto: @escaping (Mugshot?) -> Void, onAnalyzed: @escaping (Face?) -> Void) {
        guard Self.isAuthorized else { return onPhoto(nil) }
        self.onPhoto = onPhoto
        self.onAnalyzed = onAnalyzed
        queue.async { [self] in
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else {
                return DispatchQueue.main.async { self.deliver(nil) }
            }
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            session.beginConfiguration()
            session.sessionPreset = .high
            let ready = session.canAddInput(input) && session.canAddOutput(output)
            if ready {
                session.addInput(input)
                session.addOutput(output)
            }
            session.commitConfiguration()
            // e.g. the camera is held by another app: say so now rather than after the timeout.
            guard ready else { return DispatchQueue.main.async { self.deliver(nil) } }
            session.startRunning()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.deliver(nil) }
    }

    func stop() {
        onPhoto = nil
        onAnalyzed = nil
        queue.async { [session] in session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !grabbed, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        if firstFrameAt == nil { firstFrameAt = now }
        guard now.timeIntervalSince(firstFrameAt!) >= Self.settle else { return }
        grabbed = true
        var image = CIImage(cvPixelBuffer: buffer)
        let lift = log2(Self.targetBrightness / max(Self.brightness(of: image), 1))
        let exposed = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: min(1.5, max(0, lift))])
        let rawCG = Self.context.createCGImage(exposed, from: exposed.extent)
        image = exposed
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.2])
            .applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 7600, y: 0)])
        guard let cgImage = Self.context.createCGImage(image, from: image.extent) else {
            return DispatchQueue.main.async { self.deliver(nil) }
        }
        let photo = Mugshot(image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)), rawImage: rawCG)
        DispatchQueue.main.async { self.deliver(photo) }
        let face = Self.face(in: cgImage)
        DispatchQueue.main.async { self.onAnalyzed?(face) }
    }

    /// Average luma, 0-255.
    private static func brightness(of image: CIImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return 0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])
    }

    private func deliver(_ mugshot: Mugshot?) {
        guard let onPhoto else { return }
        self.onPhoto = nil
        onPhoto(mugshot)
        queue.async { [session] in session.stopRunning() }
    }
}

// MARK: - Views

/// Darkens the frosted screen and lays a faint grid over it.
class TintView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Glass.tint.setFill()
        bounds.fill()
        Glass.grid.setFill()
        let step: CGFloat = 64
        for x in stride(from: bounds.minX, through: bounds.maxX, by: step) {
            NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
        }
        for y in stride(from: bounds.minY, through: bounds.maxY, by: step) {
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
        }
    }
}

/// The glass panel: the photo with its target lock, the headline, the telemetry and the footer.
final class InterdictionView: TintView {
    enum Photo {
        case developing
        case taken(Mugshot)
        case none
    }

    let booking: Booking
    /// Off-screen renders have no frosted window behind them, so they paint their own backdrop.
    var paintsBackdrop = false
    private var photo: Photo = .developing {
        didSet { needsDisplay = true }
    }
    private var lockProgress: CGFloat = 1

    init(booking: Booking) {
        self.booking = booking
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ mugshot: Mugshot?) {
        photo = mugshot.map { .taken($0) } ?? .none
    }

    /// The one animation: the target lock closes in on the face.
    func animateLock() {
        lockProgress = 0
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let t = min(1, Date().timeIntervalSince(start) / 0.42)
            self.lockProgress = 1 - pow(1 - t, 3)
            self.needsDisplay = true
            if t >= 1 { timer.invalidate() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if paintsBackdrop {
            NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.13, blue: 0.17, alpha: 1), NSColor(srgbRed: 0.03, green: 0.04, blue: 0.06, alpha: 1)])?
                .draw(in: bounds, angle: -90)
        }
        super.draw(dirtyRect)

        let w = bounds.width
        let h = bounds.height
        let unit = h * 0.012

        // Size the panel to its content: top bar, a 4:3 sensor frame, the footer.
        let topBar = unit * 4.5
        let footer = unit * 6.5
        let panelWidth = w * 0.86
        let pad = panelWidth * 0.04
        let frameWidth = min((panelWidth - pad * 2) * 0.56, (h * 0.86 - pad * 2 - topBar - footer) * 4 / 3)
        let panelHeight = pad * 2 + topBar + frameWidth * 3 / 4 + footer
        let panel = NSRect(x: (w - panelWidth) / 2, y: (h - panelHeight) / 2, width: panelWidth, height: panelHeight)
        drawPanel(panel)
        let inner = panel.insetBy(dx: pad, dy: pad)

        mono("BAGELGUARD", Glass.mono(unit * 1.15, .medium), Glass.tertiary).draw(at: NSPoint(x: inner.minX, y: inner.minY))
        let caseLabel = mono("CASE \(booking.caseLabel)", Glass.mono(unit * 1.15, .medium), Glass.tertiary)
        caseLabel.draw(at: NSPoint(x: inner.maxX - caseLabel.size().width, y: inner.minY))

        let footerY = inner.maxY - unit * 2
        Glass.hairline.setFill()
        NSRect(x: inner.minX, y: footerY - unit * 2.2, width: inner.width, height: 1).fill()
        let next: String
        switch booking.ending {
        case .lock: next = "Click anywhere to lock this Mac."
        case .close: next = "Click anywhere to close."
        case .preview: next = "Preview. Click anywhere to close."
        }
        text(next, Glass.display(unit * 1.6, .medium), Glass.primary).draw(at: NSPoint(x: inner.minX, y: footerY - unit * 0.6))

        // Body: sensor frame on the left, readout on the right.
        let frame = NSRect(x: inner.minX, y: inner.minY + topBar, width: frameWidth, height: frameWidth * 3 / 4)
        drawSensorFrame(frame, unit: unit)
        let gap = inner.width * 0.05
        drawReadout(in: NSRect(x: frame.maxX + gap, y: frame.minY, width: inner.maxX - frame.maxX - gap, height: frame.height), unit: unit)
    }

    private func drawPanel(_ rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28)
        Glass.panelFill.setFill()
        path.fill()
        // Light catching the top edge of the glass.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: NSColor.white.withAlphaComponent(0.07), ending: NSColor.white.withAlphaComponent(0))?
            .draw(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.35), angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        Glass.panelEdge.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: Sensor frame

    private func drawSensorFrame(_ rect: NSRect, unit: CGFloat) {
        let clip = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        Glass.sensor.setFill()
        rect.fill()
        switch photo {
        case .taken(let mugshot):
            let source = aspectFillSource(mugshot.image.size, into: rect.size)
            mugshot.image.draw(in: rect, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if let face = mugshot.face {
                drawTargetLock(onFace: map(face.rect, from: source, into: rect), confidence: face.confidence, match: mugshot.match, unit: unit)
            }
        case .developing:
            centered("Acquiring image", Glass.mono(unit * 1.2), Glass.tertiary, in: rect)
        case .none:
            centered("No image", Glass.mono(unit * 1.2), Glass.tertiary, in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        Glass.panelEdge.setStroke()
        clip.lineWidth = 1
        clip.stroke()

        // Frame annotations.
        mono("CAM 01   \(Formats.clock.string(from: booking.date))", Glass.mono(unit * 1.0), Glass.secondary)
            .draw(at: NSPoint(x: rect.minX + unit * 1.4, y: rect.minY + unit * 1.2))
        let live = mono("REC", Glass.mono(unit * 1.0, .medium), Glass.secondary)
        let liveSize = live.size()
        live.draw(at: NSPoint(x: rect.maxX - unit * 1.4 - liveSize.width, y: rect.minY + unit * 1.2))
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.maxX - unit * 2.6 - liveSize.width, y: rect.minY + unit * 1.2 + liveSize.height / 2 - unit * 0.35, width: unit * 0.7, height: unit * 0.7)).fill()
    }

    private func drawTargetLock(onFace face: NSRect, confidence: Float, match: LineupMatch?, unit: CGFloat) {
        // Start wide and close in on the face.
        let spread = (1 - lockProgress) * face.width * 0.35
        let box = face.insetBy(dx: -face.width * 0.18 - spread, dy: -face.height * 0.18 - spread)
        let arm = min(box.width, box.height) * 0.18
        Glass.lock.withAlphaComponent(0.35 + 0.65 * lockProgress).setStroke()
        let corners = NSBezierPath()
        corners.lineWidth = 2
        for (corner, dx, dy) in [
            (NSPoint(x: box.minX, y: box.minY), 1.0, 1.0), (NSPoint(x: box.maxX, y: box.minY), -1.0, 1.0),
            (NSPoint(x: box.minX, y: box.maxY), 1.0, -1.0), (NSPoint(x: box.maxX, y: box.maxY), -1.0, -1.0),
        ] {
            corners.move(to: NSPoint(x: corner.x + dx * arm, y: corner.y))
            corners.line(to: corner)
            corners.line(to: NSPoint(x: corner.x, y: corner.y + dy * arm))
        }
        corners.stroke()
        guard lockProgress >= 1 else { return }

        let label: String
        if let match {
            label = "\(match.name.uppercased())   \(Int((match.similarity * 100).rounded()))%"
        } else {
            label = "SUBJECT \(booking.caseLabel)   \(Int((confidence * 100).rounded()))%"
        }
        let tag = mono(label, Glass.mono(unit * 1.0, .semibold), NSColor.black)
        let size = tag.size()
        let tagRect = NSRect(x: box.minX, y: box.minY - size.height - unit * 0.9, width: size.width + unit * 1.2, height: size.height + unit * 0.5)
        Glass.lock.setFill()
        NSBezierPath(roundedRect: tagRect, xRadius: 3, yRadius: 3).fill()
        tag.draw(at: NSPoint(x: tagRect.minX + unit * 0.6, y: tagRect.minY + unit * 0.25))
    }

    // MARK: Readout

    private func drawReadout(in column: NSRect, unit: CGFloat) {
        var y = column.minY + unit * 0.5
        let matchName: String? = if case .taken(let m) = photo { m.match?.name } else { nil }
        let headlineText = matchName.map { "Nice try \($0)." } ?? "Bagel intercepted."
        let headline = text(headlineText, Glass.display(unit * 6.4), Glass.primary, kern: -unit * 0.12)
        let headlineWidth = column.width + unit * 0.3
        let headlineRect = NSRect(x: column.minX - unit * 0.3, y: y, width: headlineWidth, height: unit * 20)
        headline.draw(with: headlineRect, options: .usesLineFragmentOrigin)
        y += headline.boundingRect(with: NSSize(width: headlineWidth, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height + unit * 0.4
        let subline = text(
            matchName != nil ? "Bagel attempt intercepted." : "Nothing was posted to \(booking.destination).",
            Glass.display(unit * 2.0, .regular), Glass.secondary)
        let sublineRect = NSRect(x: column.minX, y: y, width: column.width, height: unit * 6)
        subline.draw(in: sublineRect)
        y += subline.boundingRect(with: sublineRect.size, options: .usesLineFragmentOrigin).height + unit * 3.5

        var rows: [(String, String)] = [("CLASS", booking.evidence), ("CHANNEL", "Slack, \(booking.destination)")]
        if let ms = booking.responseMilliseconds { rows.append(("RESPONSE", "Removed from the message box in \(ms) ms")) }
        rows.append(("TIME", Formats.timestamp.string(from: booking.date)))

        // Rows share what is left, so the last row ends level with the bottom of the frame.
        let rowHeight = (column.maxY - y) / CGFloat(rows.count)
        let labelWidth = column.width * 0.24
        for (label, value) in rows {
            Glass.hairline.setFill()
            NSRect(x: column.minX, y: y, width: column.width, height: 1).fill()
            let labelText = mono(label, Glass.mono(unit * 1.05, .medium), Glass.tertiary)
            labelText.draw(at: NSPoint(x: column.minX, y: y + rowHeight / 2 - labelText.size().height / 2))
            let valueText = text(value, Glass.display(unit * 1.55, .regular), Glass.primary)
            let valueWidth = column.width - labelWidth
            let valueNatural = valueText.boundingRect(with: NSSize(width: valueWidth, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height
            let valueY = y + (rowHeight - min(valueNatural, rowHeight)) / 2
            valueText.draw(
                with: NSRect(x: column.minX + labelWidth, y: valueY, width: valueWidth, height: rowHeight),
                options: .usesLineFragmentOrigin)
            y += rowHeight
        }
    }

    // MARK: Helpers

    private func text(_ string: String, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: kern])
    }

    private func mono(_ string: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        text(string, font, color, kern: font.pointSize * 0.12)
    }

    private func centered(_ string: String, _ font: NSFont, _ color: NSColor, in rect: NSRect) {
        let label = mono(string, font, color)
        let size = label.size()
        label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    /// The largest light display size up to `size` at which `string` fits in `width`.
    private func fitted(_ string: String, size: CGFloat, width: CGFloat) -> NSFont {
        let measured = text(string, Glass.display(size), Glass.primary).size().width
        return measured > width ? Glass.display(size * width / measured) : Glass.display(size)
    }

    private func aspectFillSource(_ image: NSSize, into target: NSSize) -> NSRect {
        let scale = max(target.width / image.width, target.height / image.height)
        let size = NSSize(width: target.width / scale, height: target.height / scale)
        return NSRect(x: (image.width - size.width) / 2, y: (image.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Maps a rect in image pixels (top-left origin) to view coordinates for an aspect-fill draw.
    private func map(_ face: CGRect, from source: NSRect, into dest: NSRect) -> NSRect {
        let scale = dest.width / source.width
        return NSRect(
            x: dest.minX + (face.minX - source.minX) * scale, y: dest.minY + (face.minY - source.minY) * scale,
            width: face.width * scale, height: face.height * scale)
    }
}

// MARK: - Controller

final class OverlayWindow: NSWindow {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func keyDown(with event: NSEvent) { onDismiss?() }
}

final class OverlayController {
    private enum CameraState {
        case off
        case capturing
        /// `analyzed` once face detection has finished, with or without a face.
        case taken(Mugshot, analyzed: Bool)
        case failed
    }

    private var windows: [OverlayWindow] = []
    private var views: [InterdictionView] = []
    private var camera: MugshotCamera?
    private var state = CameraState.off
    private var prewarmTimeout: Timer?
    private var booking: Booking?
    private var savedCase: Int?
    private var shownAt = Date.distantPast
    var onClose: (() -> Void)?

    var isShowing: Bool { !windows.isEmpty }

    /// Starts the camera, unless it is already running, so the photo is of the person at the
    /// keyboard rather than of their reaction to the overlay.
    func startCamera() {
        prewarmTimeout?.invalidate()
        guard case .off = state else { return }
        state = .capturing
        let camera = MugshotCamera()
        self.camera = camera
        camera.snap(
            onPhoto: { [weak self] mugshot in
                guard let self else { return }
                self.state = mugshot.map { .taken($0, analyzed: false) } ?? .failed
                self.views.forEach { $0.show(mugshot) }
                if mugshot != nil && self.isShowing { Self.playShutter() }
            },
            onAnalyzed: { [weak self] face in
                guard let self, case .taken(var mugshot, _) = self.state else { return }
                mugshot.face = face
                if face != nil, let raw = mugshot.rawImage {
                    mugshot.match = Lineup.shared.identify(cgImage: raw)
                }
                self.state = .taken(mugshot, analyzed: true)
                for view in self.views {
                    view.show(mugshot)
                    if face != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { view.animateLock() }
                }
                self.saveIfCaught()
            })
    }

    /// Powers the camera up while a bagel is still being typed. If no bagel follows within 3 s,
    /// the camera stops and any photo it took is dropped.
    func prewarmCamera() {
        guard !isShowing, case .off = state else { return }
        startCamera()
        prewarmTimeout = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            guard let self, !self.isShowing else { return }
            self.discardCamera()
        }
    }

    /// Covers every screen. Stays up until a click or key press, then locks or just closes, as
    /// the booking says.
    func show(_ booking: Booking, takePhoto: Bool) {
        closeWindows()
        prewarmTimeout?.invalidate()
        self.booking = booking
        shownAt = Date()
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.onDismiss = { [weak self] in self?.userDismissed() }

            // Frost whatever is on screen, then draw on top.
            let frost = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            frost.material = .fullScreenUI
            frost.blendingMode = .behindWindow
            frost.state = .active
            frost.appearance = NSAppearance(named: .darkAqua)
            let view = InterdictionView(booking: booking)
            view.frame = frost.bounds
            view.autoresizingMask = [.width, .height]
            frost.addSubview(view)
            window.contentView = frost
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
            views.append(view)
        }
        NSApp.activate(ignoringOtherApps: true)

        guard takePhoto else { return views.forEach { $0.show(nil) } }
        switch state {
        case .off:
            startCamera()
        case .capturing:
            break
        case .taken(let mugshot, let analyzed):
            views.forEach { $0.show(mugshot) }
            Self.playShutter()
            if analyzed { saveIfCaught() }
        case .failed:
            views.forEach { $0.show(nil) }
        }
    }

    private static func playShutter() {
        NSSound(
            contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif",
            byReference: true)?.play()
    }

    /// Saves once per caught attempt (never for previews), when face detection has finished.
    private func saveIfCaught() {
        guard let booking, booking.ending != .preview, savedCase != booking.caseNumber, isShowing,
            case .taken(let mugshot, analyzed: true) = state
        else { return }
        savedCase = booking.caseNumber
        MugshotArchive.save(mugshot, for: booking)
    }

    private func userDismissed() {
        // Ignore the click or key that was already on its way when the overlay appeared.
        guard Date().timeIntervalSince(shownAt) > 1 else { return }
        let ending = booking?.ending
        closeWindows()
        discardCamera()
        onClose?()
        if ending == .lock { Responder.lockScreen() }
    }

    private func discardCamera() {
        camera?.stop()
        camera = nil
        state = .off
    }

    private func closeWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        views = []
    }
}
