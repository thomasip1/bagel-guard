// The "booked" overlay: a mugshot of whoever tried to post the bagel, taken with the webcam and
// shown in front of a police height chart, with a felt letterboard placard and the bagel bagged as
// evidence. The photo is only ever held in memory.

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

enum Booth {
    static let wall = NSColor(srgbRed: 0xBC / 255, green: 0xC5 / 255, blue: 0xCC / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 0x1E / 255, green: 0x23 / 255, blue: 0x28 / 255, alpha: 1)
    static let felt = NSColor(srgbRed: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255, alpha: 1)
    static let groove = NSColor(srgbRed: 0x2A / 255, green: 0x2A / 255, blue: 0x2A / 255, alpha: 1)
    static let oak = NSColor(srgbRed: 0x4A / 255, green: 0x36 / 255, blue: 0x28 / 255, alpha: 1)
    static let letter = NSColor(srgbRed: 0xF0 / 255, green: 0xEF / 255, blue: 0xEA / 255, alpha: 1)
    static let print = NSColor(srgbRed: 0xF7 / 255, green: 0xF6 / 255, blue: 0xF2 / 255, alpha: 1)
    static let evidence = NSColor(srgbRed: 0xC8 / 255, green: 0x10 / 255, blue: 0x2E / 255, alpha: 1)
    static let silhouette = NSColor(srgbRed: 0x6B / 255, green: 0x75 / 255, blue: 0x7D / 255, alpha: 1)
    static let darkroom = NSColor(srgbRed: 0x8D / 255, green: 0x97 / 255, blue: 0x9F / 255, alpha: 1)

    /// DIN Condensed ships with macOS; it is close to the plastic letters on a booking board.
    static func din(_ size: CGFloat) -> NSFont {
        NSFont(name: "DINCondensed-Bold", size: size) ?? .systemFont(ofSize: size, weight: .heavy)
    }
}

extension NSScreen {
    static var underMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}

// MARK: - Camera

/// Grabs one frame from the default camera once its exposure has settled.
final class MugshotCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// Ask up front, so the permission prompt never ends up hidden behind the overlay.
    static func requestAccessIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in Log.write("camera access granted: \(granted)") }
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.thomasip.bagelguard.camera")
    private var completion: ((NSImage?) -> Void)?
    private var startedAt = Date()
    private var grabbed = false  // only touched on `queue`

    func snap(_ completion: @escaping (NSImage?) -> Void) {
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
        guard !grabbed, Date().timeIntervalSince(startedAt) > 0.9,
            let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        grabbed = true
        // Booking photos are flat and slightly washed out.
        let image = CIImage(cvPixelBuffer: buffer).applyingFilter(
            "CIColorControls", parameters: [kCIInputSaturationKey: 0.3, kCIInputContrastKey: 1.12])
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

/// The booking-room wall with its height chart. Shown on every screen.
class WallView: NSView {
    override var isFlipped: Bool { true }

    /// Height chart from 7′0″ at the top to 4′0″ at the bottom.
    private let topInches: CGFloat = 84
    private let bottomInches: CGFloat = 48

    override func draw(_ dirtyRect: NSRect) {
        Booth.wall.setFill()
        bounds.fill()
        drawHeightChart()
    }

    private func drawHeightChart() {
        let top = bounds.height * 0.04
        let span = bounds.height * 0.92
        let labelFont = Booth.din(max(22, bounds.height * 0.026))
        for inches in stride(from: bottomInches, through: topInches, by: 2) {
            let y = top + (topInches - inches) / (topInches - bottomInches) * span
            let major = Int(inches) % 6 == 0
            Booth.ink.withAlphaComponent(major ? 0.85 : 0.45).setFill()
            NSRect(x: 0, y: y - (major ? 1.5 : 0.75), width: bounds.width, height: major ? 3 : 1.5).fill()
            guard major else { continue }
            let feet = Int(inches) / 12
            let rest = Int(inches) % 12
            let label = rest == 0 ? "\(feet)′" : "\(feet)′\(rest)″"
            let text = NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: Booth.ink])
            let size = text.size()
            text.draw(at: NSPoint(x: 28, y: y - size.height - 2))
            text.draw(at: NSPoint(x: bounds.width - 28 - size.width, y: y - size.height - 2))
        }
    }
}

/// The wall plus the mugshot print, the letterboard placard, the evidence bag and the footer.
final class MugshotView: WallView {
    enum Photo {
        case developing
        case taken(NSImage)
        case none
    }

    let booking: Booking
    private(set) var photo: Photo = .developing {
        didSet { needsDisplay = true }
    }
    private let flash = CALayer()

    init(booking: Booking) {
        self.booking = booking
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        if flash.superlayer == nil { layer?.addSublayer(flash) }
        flash.frame = bounds
    }

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
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        fade.duration = 0.45
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flash.add(fade, forKey: "flash")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let printRect = drawPrint(ctx)
        drawPlacard(ctx, below: printRect)
        drawEvidenceBag(ctx)
        drawFooter()
    }

    // MARK: Print

    private func drawPrint(_ ctx: CGContext) -> NSRect {
        let height = bounds.height * 0.58
        let width = height * 0.8
        let rect = NSRect(x: bounds.midX - width / 2, y: bounds.height * 0.07, width: width, height: height)
        rotated(ctx, around: NSPoint(x: rect.midX, y: rect.midY), degrees: -1.2) {
            NSShadow.with(blur: 18, offset: 6, alpha: 0.25) {
                Booth.print.setFill()
                rect.fill()
            }
            let photoRect = rect.insetBy(dx: 16, dy: 16)
            switch photo {
            case .taken(let image):
                image.draw(
                    in: photoRect, from: aspectFillSource(image.size, into: photoRect.size), operation: .sourceOver,
                    fraction: 1, respectFlipped: true, hints: nil)
            case .developing, .none:
                drawSilhouette(in: photoRect)
            }
            for (corner, angle) in [(NSPoint(x: rect.minX + 30, y: rect.minY + 4), -32.0), (NSPoint(x: rect.maxX - 30, y: rect.minY + 4), 32.0)] {
                rotated(ctx, around: corner, degrees: angle) {
                    NSColor.white.withAlphaComponent(0.55).setFill()
                    NSRect(x: corner.x - 60, y: corner.y - 17, width: 120, height: 34).fill()
                }
            }
        }
        return rect
    }

    private func drawSilhouette(in rect: NSRect) {
        Booth.darkroom.setFill()
        rect.fill()
        Booth.silhouette.setFill()
        let head = rect.width * 0.36
        NSBezierPath(ovalIn: NSRect(x: rect.midX - head / 2, y: rect.minY + rect.height * 0.2, width: head, height: head * 1.18)).fill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.62, width: rect.width * 0.76, height: rect.height * 0.6),
            xRadius: rect.width * 0.3, yRadius: rect.width * 0.3
        ).fill()
        if case .none = photo {
            let text = NSAttributedString(
                string: "NO PHOTO ON FILE", attributes: [.font: Booth.din(rect.width * 0.08), .foregroundColor: Booth.print])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.minY + rect.height * 0.06))
        }
    }

    private func aspectFillSource(_ image: NSSize, into target: NSSize) -> NSRect {
        let scale = max(target.width / image.width, target.height / image.height)
        let size = NSSize(width: target.width / scale, height: target.height / scale)
        return NSRect(x: (image.width - size.width) / 2, y: (image.height - size.height) / 2, width: size.width, height: size.height)
    }

    // MARK: Placard

    private func drawPlacard(_ ctx: CGContext, below print: NSRect) {
        let width = min(bounds.width * 0.42, 820)
        let height = width * 0.42
        let rect = NSRect(x: bounds.midX - width / 2, y: print.maxY - height * 0.38, width: width, height: height)
        NSShadow.with(blur: 14, offset: 5, alpha: 0.3) {
            Booth.oak.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        }
        let felt = rect.insetBy(dx: 12, dy: 12)
        Booth.felt.setFill()
        felt.fill()
        Booth.groove.setFill()
        for y in stride(from: felt.minY + 7, to: felt.maxY, by: 14) {
            NSRect(x: felt.minX, y: y, width: felt.width, height: 1).fill()
        }

        let date = DateFormatter()
        date.locale = Locale(identifier: "en_GB")
        date.dateFormat = "dd MMM yyyy  HH:mm"
        let lines: [(String, CGFloat)] = [
            ("SCALE PD", 0.62),
            ("ATTEMPTED BAGEL", 1.2),
            ("TO \(booking.destination)".uppercased(), 0.82),
            ("\(date.string(from: booking.date).uppercased())     CASE \(String(format: "%04d", booking.caseNumber))", 0.62),
        ]
        let unit = felt.height / 4.4
        let fonts = lines.map { text, scale -> NSFont in
            let font = Booth.din(unit * scale)
            let measured = NSAttributedString(string: text, attributes: [.font: font]).size().width + CGFloat(text.count) * 3
            return measured > felt.width * 0.92 ? Booth.din(unit * scale * felt.width * 0.92 / measured) : font
        }
        let blockHeight = fonts.reduce(0) { $0 + Self.lineHeight($1) }
        var y = felt.midY - blockHeight / 2
        for (index, (text, _)) in lines.enumerated() {
            drawLetterboardLine(ctx, text, font: fonts[index], centeredIn: felt, top: y, seed: index * 97 + booking.caseNumber)
            y += Self.lineHeight(fonts[index])
        }
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        NSAttributedString(string: "A", attributes: [.font: font]).size().height * 0.98
    }

    /// Draws each plastic letter on its own, slightly crooked, the way they sit in felt grooves.
    private func drawLetterboardLine(_ ctx: CGContext, _ text: String, font: NSFont, centeredIn rect: NSRect, top: CGFloat, seed: Int) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Booth.letter]
        let gap: CGFloat = 3
        let glyphs = text.map { NSAttributedString(string: String($0), attributes: attributes) }
        let width = glyphs.reduce(0) { $0 + $1.size().width + gap } - gap
        var x = rect.midX - width / 2
        for (i, glyph) in glyphs.enumerated() {
            let size = glyph.size()
            if glyph.string != " " {
                let jitter = Self.jitter(seed &+ i)
                rotated(ctx, around: NSPoint(x: x + size.width / 2, y: top + size.height / 2), degrees: jitter * 4.5) {
                    glyph.draw(at: NSPoint(x: x, y: top + Self.jitter(seed &+ i &* 31) * 3.5))
                }
            }
            x += size.width + gap
        }
    }

    /// Deterministic noise in -1...1, so a booking looks the same on every redraw.
    private static func jitter(_ n: Int) -> CGFloat {
        var x = UInt32(truncatingIfNeeded: n &* 2_654_435_761)
        x ^= x >> 13
        x = x &* 1_274_126_177
        x ^= x >> 16
        return CGFloat(x % 2001) / 1000 - 1
    }

    // MARK: Evidence bag

    private func drawEvidenceBag(_ ctx: CGContext) {
        let width = min(bounds.width * 0.19, 380)
        let height = width * 1.3
        let rect = NSRect(x: bounds.width * 0.07, y: bounds.height * 0.92 - height, width: width, height: height)
        rotated(ctx, around: NSPoint(x: rect.midX, y: rect.midY), degrees: 5) {
            let body = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            NSShadow.with(blur: 12, offset: 4, alpha: 0.18) {
                NSColor.white.withAlphaComponent(0.3).setFill()
                body.fill()
            }
            NSColor.white.withAlphaComponent(0.8).setStroke()
            body.lineWidth = 2
            body.stroke()

            // Zip seal.
            for (offset, alpha) in [(14.0, 0.9), (20.0, 0.5)] {
                NSColor.white.withAlphaComponent(alpha).setFill()
                NSRect(x: rect.minX + 6, y: rect.minY + offset, width: rect.width - 12, height: 3).fill()
            }

            let band = NSRect(x: rect.minX, y: rect.minY + 32, width: rect.width, height: height * 0.14)
            Booth.evidence.setFill()
            band.fill()
            drawCentered("EVIDENCE", font: Booth.din(band.height * 0.72), color: .white, in: band)

            let label = NSRect(x: rect.minX + 12, y: rect.maxY - height * 0.3, width: rect.width - 24, height: height * 0.3 - 12)
            Booth.print.setFill()
            label.fill()
            let rows = ["EXHIBIT A", "1 BAGEL EMOJI", "RECOVERED FROM \(booking.destination.uppercased())"]
            let rowHeight = label.height / CGFloat(rows.count)
            for (i, row) in rows.enumerated() {
                let rowRect = NSRect(x: label.minX + 10, y: label.minY + CGFloat(i) * rowHeight, width: label.width - 20, height: rowHeight)
                var font = Booth.din(rowHeight * 0.62)
                let measured = NSAttributedString(string: row, attributes: [.font: font]).size().width
                if measured > rowRect.width { font = Booth.din(rowHeight * 0.62 * rowRect.width / measured) }
                let text = NSAttributedString(string: row, attributes: [.font: font, .foregroundColor: Booth.ink])
                text.draw(at: NSPoint(x: rowRect.minX, y: rowRect.midY - text.size().height / 2 + 2))
                Booth.ink.withAlphaComponent(0.35).setFill()
                NSRect(x: rowRect.minX, y: rowRect.maxY - 3, width: rowRect.width, height: 1).fill()
            }

            let pocket = NSRect(x: rect.minX, y: band.maxY, width: rect.width, height: label.minY - band.maxY)
            let bagel = NSAttributedString(
                string: "🥯", attributes: [.font: NSFont(name: "Apple Color Emoji", size: pocket.height * 0.8) ?? .systemFont(ofSize: 120)])
            rotated(ctx, around: NSPoint(x: pocket.midX, y: pocket.midY), degrees: -14) {
                let size = bagel.size()
                bagel.draw(at: NSPoint(x: pocket.midX - size.width / 2, y: pocket.midY - size.height / 2))
            }
        }
    }

    // MARK: Footer

    private func drawFooter() {
        let line: String
        switch booking.ending {
        case .lock: line = "Nothing was posted. Click anywhere to lock this Mac."
        case .close: line = "Nothing was posted. Click anywhere to close."
        case .preview: line = "This is a preview. Click anywhere to close."
        }
        let font = NSFont.systemFont(ofSize: max(20, bounds.height * 0.022), weight: .semibold)
        let text = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: Booth.ink])
        let size = text.size()
        let origin = NSPoint(x: bounds.width * 0.93 - size.width, y: bounds.height * 0.92 - size.height)
        // A strip of wall behind the line, so the height chart doesn't run through the text.
        Booth.wall.setFill()
        NSRect(origin: origin, size: size).insetBy(dx: -14, dy: -8).fill()
        text.draw(at: origin)
    }

    // MARK: Helpers

    private func drawCentered(_ string: String, font: NSFont, color: NSColor, in rect: NSRect) {
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: font.pointSize * 0.08])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + font.pointSize * 0.06))
    }

    private func rotated(_ ctx: CGContext, around point: NSPoint, degrees: CGFloat, _ draw: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.rotate(by: degrees * .pi / 180)
        ctx.translateBy(x: -point.x, y: -point.y)
        draw()
        ctx.restoreGState()
    }
}

extension NSShadow {
    static func with(blur: CGFloat, offset: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: -offset)
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
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
    private var booking: Booking?
    private var shownAt = Date.distantPast

    var isShowing: Bool { !windows.isEmpty }

    /// Stays up until a click or key press, then locks or just closes, as the booking says.
    func show(_ booking: Booking, takePhoto: Bool) {
        close()
        self.booking = booking
        shownAt = Date()
        let mugshotScreen = NSScreen.underMouse
        var mugshot: MugshotView?
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.onDismiss = { [weak self] in self?.userDismissed() }
            if screen == mugshotScreen {
                let view = MugshotView(booking: booking)
                mugshot = view
                window.contentView = view
            } else {
                window.contentView = WallView()
            }
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)

        if takePhoto {
            let camera = MugshotCamera()
            self.camera = camera
            camera.snap { [weak mugshot] image in mugshot?.show(photo: image) }
        } else {
            mugshot?.show(photo: nil)
        }
    }

    private func userDismissed() {
        // Ignore the click or key that was already on its way when the overlay appeared.
        guard Date().timeIntervalSince(shownAt) > 1 else { return }
        let ending = booking?.ending
        close()
        if ending == .lock { Responder.lockScreen() }
    }

    private func close() {
        camera?.stop()
        camera = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}
