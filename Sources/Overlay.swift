// The overlay: a frosted-glass interdiction screen. The webcam photo is taken the moment the bagel
// is detected, the face in it is located with Vision, and a target lock is drawn on it. The photo is
// only ever held in memory.

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
    /// Time from detection to the message box being cleared.
    let responseMilliseconds: Int?
    let ending: Ending

    /// Slack labels the message box "Message to <channel or person>".
    static func destination(fromField field: String) -> String {
        let name = field.replacingOccurrences(of: "Message to ", with: "").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Slack" }
        // Channel names have no spaces; people's names usually do.
        return name.contains(" ") ? name : "#\(name)"
    }

    /// Turns a detector reason ("emoji image \"bagel pet emoji\"", "shortcode :bagel") into what
    /// was found.
    static func evidence(fromReason reason: String) -> String {
        if reason.hasPrefix("emoji image") {
            return reason.replacingOccurrences(of: "emoji image ", with: "").replacingOccurrences(of: "\"", with: "")
        }
        if reason.hasPrefix("shortcode ") { return reason.replacingOccurrences(of: "shortcode ", with: "") + " shortcode" }
        return "🥯 U+1F96F"
    }
}

/// A webcam frame and, if Vision found one, the face in it (image pixels, top-left origin).
struct Mugshot {
    let image: NSImage
    let face: CGRect?
    let confidence: Float
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

extension NSScreen {
    static var underMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}

// MARK: - Camera

/// Grabs one frame from the default camera as soon as its exposure has settled, and finds the face.
final class MugshotCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// Ask up front, so the permission prompt never ends up hidden behind the overlay.
    static func requestAccessIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in Log.write("camera access granted: \(granted)") }
    }

    /// The largest face Vision finds, in image pixels with a top-left origin.
    static func face(in image: CGImage) -> (CGRect, Float)? {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
        let box = face.boundingBox
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let rect = CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
        return (rect, face.confidence)
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.thomasip.bagelguard.camera")
    private var completion: ((Mugshot?) -> Void)?
    private var firstFrameAt: Date?  // only touched on `queue`
    private var grabbed = false  // only touched on `queue`

    func snap(_ completion: @escaping (Mugshot?) -> Void) {
        guard Self.isAuthorized, let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
        else { return completion(nil) }
        session.sessionPreset = .high
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return completion(nil) }
        session.addOutput(output)
        self.completion = completion
        queue.async { [session] in session.startRunning() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.deliver(nil) }
    }

    func stop() {
        completion = nil
        queue.async { [session] in session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !grabbed, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // The MacBook camera's first frame is nearly black and exposure keeps rising for a while
        // after it (isAdjustingExposure always reads false, so it can't be trusted). Measured: first
        // frame ~0.75 s after start at brightness 8/255, ~76 by 0.45 s later, ~83 after 3 s.
        let now = Date()
        if firstFrameAt == nil { firstFrameAt = now }
        guard now.timeIntervalSince(firstFrameAt!) >= 0.45 else { return }
        grabbed = true
        // Even out what exposure hasn't caught up on, then the cool, low-saturation sensor look.
        var image = CIImage(cvPixelBuffer: buffer)
        for filter in image.autoAdjustmentFilters(options: [.redEye: false]) {
            filter.setValue(image, forKey: kCIInputImageKey)
            image = filter.outputImage ?? image
        }
        image = image
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.2])
            .applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 7600, y: 0)])
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else {
            return DispatchQueue.main.async { self.deliver(nil) }
        }
        let face = Self.face(in: cgImage)
        let mugshot = Mugshot(
            image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)),
            face: face?.0, confidence: face?.1 ?? 0)
        DispatchQueue.main.async { self.deliver(mugshot) }
    }

    private func deliver(_ mugshot: Mugshot?) {
        guard let completion else { return }
        self.completion = nil
        completion(mugshot)
        queue.async { [session] in session.stopRunning() }
    }
}

// MARK: - Views

/// Darkens the frosted screen and lays a faint grid over it. Shown on every screen.
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
    private(set) var photo: Photo = .developing {
        didSet { needsDisplay = true }
    }
    private var lockProgress: CGFloat = 1
    private var lockTimer: Timer?

    init(booking: Booking) {
        self.booking = booking
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ mugshot: Mugshot?, quietly: Bool = false) {
        guard let mugshot else {
            photo = .none
            return
        }
        photo = .taken(mugshot)
        guard !quietly else { return }
        NSSound(
            contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif",
            byReference: true)?.play()
        guard mugshot.face != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // The one animation: the target lock closes in on the face.
        lockProgress = 0
        let start = Date()
        lockTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
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
        let panelWidth = w * 0.86
        let pad = panelWidth * 0.04
        let innerWidth = panelWidth - pad * 2
        var frameWidth = innerWidth * 0.56
        let chrome = unit * 4.5 + unit * 4.5 + unit * 2
        frameWidth = min(frameWidth, (h * 0.86 - pad * 2 - chrome) * 4 / 3)
        let panelHeight = pad * 2 + chrome + frameWidth * 3 / 4
        let panel = NSRect(x: (w - panelWidth) / 2, y: (h - panelHeight) / 2, width: panelWidth, height: panelHeight)
        drawPanel(panel)
        let inner = panel.insetBy(dx: pad, dy: pad)

        // Top bar.
        let topBar = mono("BAGELGUARD", Glass.mono(unit * 1.15, .medium), Glass.tertiary)
        topBar.draw(at: NSPoint(x: inner.minX, y: inner.minY))
        let caseLabel = mono("CASE \(String(format: "%04d", booking.caseNumber))", Glass.mono(unit * 1.15, .medium), Glass.tertiary)
        caseLabel.draw(at: NSPoint(x: inner.maxX - caseLabel.size().width, y: inner.minY))

        // Footer.
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
        let bodyTop = inner.minY + unit * 4.5
        let frame = NSRect(x: inner.minX, y: bodyTop, width: frameWidth, height: frameWidth * 3 / 4)
        drawSensorFrame(frame, unit: unit)

        let gap = inner.width * 0.05
        let column = NSRect(x: frame.maxX + gap, y: bodyTop, width: inner.maxX - frame.maxX - gap, height: frame.height)
        drawReadout(in: column, unit: unit)
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
                drawTargetLock(onFace: map(face, from: source, into: rect), confidence: mugshot.confidence, unit: unit)
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
        let timeFormat = DateFormatter()
        timeFormat.dateFormat = "HH:mm:ss"
        mono("CAM 01   \(timeFormat.string(from: booking.date))", Glass.mono(unit * 1.0), Glass.secondary)
            .draw(at: NSPoint(x: rect.minX + unit * 1.4, y: rect.minY + unit * 1.2))
        let live = mono("REC", Glass.mono(unit * 1.0, .medium), Glass.secondary)
        let liveSize = live.size()
        live.draw(at: NSPoint(x: rect.maxX - unit * 1.4 - liveSize.width, y: rect.minY + unit * 1.2))
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.maxX - unit * 2.6 - liveSize.width, y: rect.minY + unit * 1.2 + liveSize.height / 2 - unit * 0.35, width: unit * 0.7, height: unit * 0.7)).fill()
    }

    private func drawTargetLock(onFace face: NSRect, confidence: Float, unit: CGFloat) {
        // Start wide and close in on the face.
        let spread = (1 - lockProgress) * face.width * 0.35
        let box = face.insetBy(dx: -face.width * 0.18 - spread, dy: -face.height * 0.18 - spread)
        let arm = min(box.width, box.height) * 0.18
        let alpha = 0.35 + 0.65 * lockProgress
        Glass.lock.withAlphaComponent(alpha).setStroke()
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

        let tag = mono(
            "SUBJECT \(String(format: "%04d", booking.caseNumber))   \(Int((confidence * 100).rounded()))%",
            Glass.mono(unit * 1.0, .semibold), NSColor.black)
        let size = tag.size()
        let tagRect = NSRect(x: box.minX, y: box.minY - size.height - unit * 0.9, width: size.width + unit * 1.2, height: size.height + unit * 0.5)
        Glass.lock.setFill()
        NSBezierPath(roundedRect: tagRect, xRadius: 3, yRadius: 3).fill()
        tag.draw(at: NSPoint(x: tagRect.minX + unit * 0.6, y: tagRect.minY + unit * 0.25))
    }

    // MARK: Readout

    private func drawReadout(in column: NSRect, unit: CGFloat) {
        var y = column.minY + unit * 0.5
        let headline = text("Bagel intercepted.", fitted("Bagel intercepted.", size: unit * 6.4, width: column.width), Glass.primary, kern: -unit * 0.12)
        headline.draw(at: NSPoint(x: column.minX - unit * 0.3, y: y))
        y += headline.size().height + unit * 0.4
        let subline = text("Nothing was posted to \(booking.destination).", Glass.display(unit * 2.0, .regular), Glass.secondary)
        subline.draw(in: NSRect(x: column.minX, y: y, width: column.width, height: unit * 6))
        y += subline.boundingRect(with: NSSize(width: column.width, height: unit * 6), options: .usesLineFragmentOrigin).height + unit * 3.5

        let timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_GB")
        timestamp.dateFormat = "d MMM yyyy, HH:mm:ss"
        var rows: [(String, String)] = [
            ("CLASS", booking.evidence),
            ("CHANNEL", "Slack, \(booking.destination)"),
        ]
        if let ms = booking.responseMilliseconds { rows.append(("RESPONSE", "Removed from the message box in \(ms) ms")) }
        rows.append(("TIME", timestamp.string(from: booking.date)))

        // Rows share what is left, so the last rule lines up with the bottom of the frame.
        let rowHeight = (column.maxY - y) / CGFloat(rows.count)
        let labelWidth = column.width * 0.24
        for (label, value) in rows {
            Glass.hairline.setFill()
            NSRect(x: column.minX, y: y, width: column.width, height: 1).fill()
            let labelText = mono(label, Glass.mono(unit * 1.05, .medium), Glass.tertiary)
            labelText.draw(at: NSPoint(x: column.minX, y: y + rowHeight / 2 - labelText.size().height / 2))
            let valueText = text(value, Glass.display(unit * 1.55, .regular), Glass.primary)
            valueText.draw(
                with: NSRect(x: column.minX + labelWidth, y: y + rowHeight / 2 - valueText.size().height / 2, width: column.width - labelWidth, height: valueText.size().height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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
    private var windows: [OverlayWindow] = []
    private var camera: MugshotCamera?
    /// Set once the camera has answered: a mugshot, or nil when there is none.
    private var captured: Mugshot??
    private weak var interdiction: InterdictionView?
    private var booking: Booking?
    private var shownAt = Date.distantPast

    var isShowing: Bool { !windows.isEmpty }

    /// Starts the camera straight away, so the photo is of the person at the keyboard rather than of
    /// their reaction to the overlay.
    func startCamera() {
        camera?.stop()
        captured = nil
        let camera = MugshotCamera()
        self.camera = camera
        camera.snap { [weak self] mugshot in
            self?.captured = .some(mugshot)
            self?.interdiction?.show(mugshot)
        }
    }

    /// Stays up until a click or key press, then locks or just closes, as the booking says.
    func show(_ booking: Booking, takePhoto: Bool) {
        closeWindows()
        self.booking = booking
        shownAt = Date()
        let mainScreen = NSScreen.underMouse
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.onDismiss = { [weak self] in self?.userDismissed() }

            // Frost whatever is on screen, then draw on top.
            let frost = NSVisualEffectView()
            frost.material = .fullScreenUI
            frost.blendingMode = .behindWindow
            frost.state = .active
            frost.appearance = NSAppearance(named: .darkAqua)
            let content: TintView
            if screen == mainScreen {
                let view = InterdictionView(booking: booking)
                interdiction = view
                content = view
            } else {
                content = TintView()
            }
            content.autoresizingMask = [.width, .height]
            frost.addSubview(content)
            window.contentView = frost
            window.setFrame(screen.frame, display: false)
            content.frame = frost.bounds
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)

        if !takePhoto {
            interdiction?.show(nil)
        } else if let captured {
            interdiction?.show(captured)
        } else if camera == nil {
            startCamera()
        }
    }

    private func userDismissed() {
        // Ignore the click or key that was already on its way when the overlay appeared.
        guard Date().timeIntervalSince(shownAt) > 1 else { return }
        let ending = booking?.ending
        closeWindows()
        camera?.stop()
        camera = nil
        captured = nil
        if ending == .lock { Responder.lockScreen() }
    }

    private func closeWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}
