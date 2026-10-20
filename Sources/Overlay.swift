// The overlay: a police booking record for whoever tried to post the bagel, with a webcam photo
// taken the moment the bagel was detected. The photo is only ever held in memory.

import AVFoundation
import Cocoa
import CoreImage

/// What the overlay says about one attempt.
struct Booking {
    enum Ending { case lock, close, preview }

    let destination: String
    let caseNumber: Int
    let date: Date
    let ending: Ending

    /// Slack labels the message box "Message to <channel or person>".
    static func destination(fromField field: String) -> String {
        let name = field.replacingOccurrences(of: "Message to ", with: "").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Slack" }
        // Channel names have no spaces; people's names usually do.
        return name.contains(" ") ? name : "#\(name)"
    }
}

// MARK: - Palette and type

enum Record {
    static let paper = NSColor(srgbRed: 0xF4 / 255, green: 0xF6 / 255, blue: 0xF8 / 255, alpha: 1)
    static let navy = NSColor(srgbRed: 0x13 / 255, green: 0x29 / 255, blue: 0x4B / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 0x0E / 255, green: 0x1A / 255, blue: 0x2B / 255, alpha: 1)
    static let label = NSColor(srgbRed: 0x5B / 255, green: 0x66 / 255, blue: 0x75 / 255, alpha: 1)
    static let rule = NSColor(srgbRed: 0xC9 / 255, green: 0xCE / 255, blue: 0xD6 / 255, alpha: 1)
    static let footer = NSColor(srgbRed: 0xE4 / 255, green: 0xE8 / 255, blue: 0xED / 255, alpha: 1)
    static let alert = NSColor(srgbRed: 0xB3 / 255, green: 0x12 / 255, blue: 0x2E / 255, alpha: 1)
    static let darkroom = NSColor(srgbRed: 0x2B / 255, green: 0x35 / 255, blue: 0x42 / 255, alpha: 1)

    /// DIN ships with macOS and reads as official signage.
    static func dinCondensed(_ size: CGFloat) -> NSFont {
        NSFont(name: "DINCondensed-Bold", size: size) ?? .systemFont(ofSize: size, weight: .heavy)
    }

    static func din(_ size: CGFloat) -> NSFont {
        NSFont(name: "DINAlternate-Bold", size: size) ?? .systemFont(ofSize: size, weight: .bold)
    }

    static func text(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
}

extension NSScreen {
    static var underMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}

// MARK: - Camera

/// Grabs one frame from the default camera as soon as its exposure has settled.
final class MugshotCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// Ask up front, so the permission prompt never ends up hidden behind the overlay.
    static func requestAccessIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in Log.write("camera access granted: \(granted)") }
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.thomasip.bagelguard.camera")
    private var device: AVCaptureDevice?
    private var completion: ((NSImage?) -> Void)?
    private var startedAt = Date()
    private var grabbed = false  // only touched on `queue`

    func snap(_ completion: @escaping (NSImage?) -> Void) {
        guard Self.isAuthorized, let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
        else { return completion(nil) }
        self.device = device
        session.sessionPreset = .high
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return completion(nil) }
        session.addOutput(output)
        self.completion = completion
        queue.async { [self] in
            startedAt = Date()
            session.startRunning()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.deliver(nil) }
    }

    func stop() {
        completion = nil
        queue.async { [session] in session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !grabbed, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // The first frames come out dark while auto-exposure catches up. Take the first frame after
        // it settles, and never wait longer than about a second.
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 1.1 || (elapsed > 0.25 && device?.isAdjustingExposure == false) else { return }
        grabbed = true
        // Booking photos are flat and slightly washed out.
        let image = CIImage(cvPixelBuffer: buffer).applyingFilter(
            "CIColorControls", parameters: [kCIInputSaturationKey: 0.35, kCIInputContrastKey: 1.08])
        let cgImage = CIContext().createCGImage(image, from: image.extent)
        let photo = cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        DispatchQueue.main.async { self.deliver(photo) }
    }

    private func deliver(_ photo: NSImage?) {
        guard let completion else { return }
        self.completion = nil
        completion(photo)
        queue.async { [session] in session.stopRunning() }
    }
}

// MARK: - Views

/// Plain navy, for screens other than the one showing the record.
final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Record.navy.setFill()
        bounds.fill()
    }
}

/// The booking record: header bar, front-view photo with a height ruler, the charge, the details
/// and a footer saying what happens next.
final class BookingView: NSView {
    enum Photo {
        case developing
        case taken(NSImage)
        case none
    }

    let booking: Booking
    private(set) var photo: Photo = .developing {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    init(booking: Booking) {
        self.booking = booking
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(photo image: NSImage?, quietly: Bool = false) {
        guard let image else {
            photo = .none
            return
        }
        photo = .taken(image)
        guard !quietly else { return }
        NSSound(
            contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif",
            byReference: true)?.play()
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let h = bounds.height
        let margin = w * 0.055

        Record.paper.setFill()
        bounds.fill()

        // Header.
        let header = NSRect(x: 0, y: 0, width: w, height: h * 0.1)
        Record.navy.setFill()
        header.fill()
        let title = attributed("Scale PD", Record.din(h * 0.034), .white)
        let subtitle = attributed("Booking record", Record.text(h * 0.02), NSColor.white.withAlphaComponent(0.72))
        let titleY = header.midY - title.size().height / 2
        title.draw(at: NSPoint(x: margin, y: titleY))
        subtitle.draw(at: NSPoint(x: margin + title.size().width + h * 0.02, y: header.midY - subtitle.size().height / 2))
        let caseText = attributed("Case \(String(format: "%04d", booking.caseNumber))", Record.din(h * 0.034), .white)
        caseText.draw(at: NSPoint(x: w - margin - caseText.size().width, y: titleY))

        // Footer.
        let footer = NSRect(x: 0, y: h * 0.91, width: w, height: h * 0.09)
        Record.footer.setFill()
        footer.fill()
        let next: String
        switch booking.ending {
        case .lock: next = "Click anywhere to lock this Mac."
        case .close: next = "Click anywhere to close."
        case .preview: next = "Preview. Click anywhere to close."
        }
        let nextText = attributed(next, Record.text(h * 0.022, weight: .semibold), Record.ink)
        nextText.draw(at: NSPoint(x: margin, y: footer.midY - nextText.size().height / 2))
        let privacy = attributed("The photo is shown here only and is never saved.", Record.text(h * 0.017), Record.label)
        privacy.draw(at: NSPoint(x: w - margin - privacy.size().width, y: footer.midY - privacy.size().height / 2))

        // Photo with a height ruler on its left edge.
        let bodyTop = header.maxY + h * 0.065
        let bodyBottom = footer.minY - h * 0.065
        let rulerWidth = h * 0.055
        let photoHeight = bodyBottom - bodyTop - h * 0.04
        let photoRect = NSRect(x: margin + rulerWidth, y: bodyTop, width: photoHeight * 0.8, height: photoHeight)
        drawPhoto(in: photoRect)
        drawRuler(beside: photoRect, width: rulerWidth)
        attributed("Front view", Record.text(h * 0.016), Record.label)
            .draw(at: NSPoint(x: photoRect.minX, y: photoRect.maxY + h * 0.012))

        // Charge and details.
        let gap = w * 0.05
        let column = NSRect(
            x: photoRect.maxX + gap, y: bodyTop, width: w - margin - photoRect.maxX - gap, height: photoRect.height)
        drawDetails(in: column)
    }

    private func drawPhoto(in rect: NSRect) {
        switch photo {
        case .taken(let image):
            image.draw(
                in: rect, from: aspectFillSource(image.size, into: rect.size), operation: .copy, fraction: 1,
                respectFlipped: true, hints: nil)
        case .developing, .none:
            Record.darkroom.setFill()
            rect.fill()
            let note: String
            if case .none = photo { note = "No photo" } else { note = "Taking photo…" }
            let text = attributed(note, Record.text(rect.width * 0.045, weight: .medium), NSColor.white.withAlphaComponent(0.7))
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
        Record.ink.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        border.stroke()
    }

    /// Booking-photo height scale, 4′6″ at the bottom of the frame to 6′6″ at the top.
    private func drawRuler(beside photo: NSRect, width: CGFloat) {
        let bottomInches = 54
        let topInches = 78
        let font = Record.din(width * 0.3)
        for inches in bottomInches...topInches {
            let y = photo.maxY - CGFloat(inches - bottomInches) / CGFloat(topInches - bottomInches) * photo.height
            let tick: CGFloat = inches % 6 == 0 ? width * 0.45 : (inches % 2 == 0 ? width * 0.25 : width * 0.14)
            Record.ink.setFill()
            NSRect(x: photo.minX - tick, y: y - 0.75, width: tick, height: 1.5).fill()
            guard inches % 6 == 0 else { continue }
            let rest = inches % 12
            let label = attributed(rest == 0 ? "\(inches / 12)′" : "\(inches / 12)′\(rest)″", font, Record.ink)
            let size = label.size()
            label.draw(at: NSPoint(x: photo.minX - tick - size.width - 6, y: y - size.height / 2))
        }
    }

    private func drawDetails(in column: NSRect) {
        let h = bounds.height
        var y = column.minY

        attributed("Charge", Record.text(h * 0.019), Record.label).draw(at: NSPoint(x: column.minX, y: y))
        y += h * 0.042
        let chargeFont = fitted("Attempted bagel", Record.dinCondensed, size: h * 0.15, width: column.width)
        let charge = attributed("Attempted bagel", chargeFont, Record.ink)
        charge.draw(at: NSPoint(x: column.minX - chargeFont.pointSize * 0.03, y: y))
        y += charge.size().height + h * 0.02

        let date = DateFormatter()
        date.locale = Locale(identifier: "en_GB")
        date.dateFormat = "d MMM yyyy, HH:mm"
        let rows: [(String, String, NSColor)] = [
            ("Location", booking.destination, Record.ink),
            ("Date and time", date.string(from: booking.date), Record.ink),
            ("Evidence", "1 bagel emoji 🥯", Record.ink),
            ("Outcome", "Removed before sending. Nothing was posted.", Record.alert),
        ]
        // Rows share what is left, so the last rule lines up with the bottom of the photo.
        let rowHeight = (column.maxY - y) / CGFloat(rows.count)
        let labelWidth = column.width * 0.26
        for (label, value, color) in rows {
            Record.rule.setFill()
            NSRect(x: column.minX, y: y, width: column.width, height: 1).fill()
            let labelText = attributed(label, Record.text(h * 0.019), Record.label)
            labelText.draw(at: NSPoint(x: column.minX, y: y + rowHeight / 2 - labelText.size().height / 2))
            let valueFont = fitted(value, Record.din, size: h * 0.03, width: column.width - labelWidth)
            let valueText = attributed(value, valueFont, color)
            valueText.draw(at: NSPoint(x: column.minX + labelWidth, y: y + rowHeight / 2 - valueText.size().height / 2))
            y += rowHeight
        }
        Record.rule.setFill()
        NSRect(x: column.minX, y: y, width: column.width, height: 1).fill()
    }

    // MARK: Helpers

    private func attributed(_ string: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    /// The largest size up to `size` at which `string` fits in `width`.
    private func fitted(_ string: String, _ font: (CGFloat) -> NSFont, size: CGFloat, width: CGFloat) -> NSFont {
        let measured = attributed(string, font(size), Record.ink).size().width
        return measured > width ? font(size * width / measured) : font(size)
    }

    private func aspectFillSource(_ image: NSSize, into target: NSSize) -> NSRect {
        let scale = max(target.width / image.width, target.height / image.height)
        let size = NSSize(width: target.width / scale, height: target.height / scale)
        return NSRect(x: (image.width - size.width) / 2, y: (image.height - size.height) / 2, width: size.width, height: size.height)
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
    /// Set once the camera has answered: a photo, or nil when there is none.
    private var capturedPhoto: NSImage??
    private weak var bookingView: BookingView?
    private var booking: Booking?
    private var shownAt = Date.distantPast

    var isShowing: Bool { !windows.isEmpty }

    /// Starts the camera straight away, so the photo is of the person at the keyboard rather than of
    /// their reaction to the overlay.
    func startCamera() {
        camera?.stop()
        capturedPhoto = nil
        let camera = MugshotCamera()
        self.camera = camera
        camera.snap { [weak self] image in
            self?.capturedPhoto = .some(image)
            self?.bookingView?.show(photo: image)
        }
    }

    /// Stays up until a click or key press, then locks or just closes, as the booking says.
    func show(_ booking: Booking, takePhoto: Bool) {
        closeWindows()
        self.booking = booking
        shownAt = Date()
        let recordScreen = NSScreen.underMouse
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.onDismiss = { [weak self] in self?.userDismissed() }
            if screen == recordScreen {
                let view = BookingView(booking: booking)
                bookingView = view
                window.contentView = view
            } else {
                window.contentView = BackdropView()
            }
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)

        if !takePhoto {
            bookingView?.show(photo: nil)
        } else if let capturedPhoto {
            bookingView?.show(photo: capturedPhoto)
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
        capturedPhoto = nil
        if ending == .lock { Responder.lockScreen() }
    }

    private func closeWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}
