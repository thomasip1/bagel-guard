// Jev (TypeSafe's System One model) as a second opinion on the message box: it sees the box as
// rendered, so a bagel emoji uploaded under another name still looks like a bagel, and it reads the
// text for anything a software engineer wouldn't send themselves.

import Cocoa
import ScreenCaptureKit

/// What Slack's message box holds right now.
struct MessageSnapshot {
    let text: String
    /// Labels of the emoji images in the box, e.g. "party-parrot emoji".
    let emojiLabels: [String]
    /// Where each emoji image is on screen, for cropping it out of the box capture.
    var emojiFrames: [CGRect] = []
    /// The box's label, e.g. "Message to office-london".
    let field: String
    /// The box on screen, in global top-left-origin points.
    let frame: CGRect?

    /// Identifies the content, so a verdict is reused until the message changes.
    var key: String { ([text] + emojiLabels).joined(separator: "\u{1}") }

    var isEmpty: Bool {
        emojiLabels.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{FFFC}"])).isEmpty
    }
}

struct JevVerdict {
    /// Probability that the message holds a bagel in any form.
    let bagel: Double
    /// Probability that someone else is posting from the unlocked laptop.
    let impostor: Double

    /// Lower for bagels: anything that might be one is worth stopping, and in testing a crude
    /// drawn bagel emoji scored about 0.4 while a doughnut and a rocket stayed under 0.2.
    static let bagelThreshold = 0.3
    static let impostorThreshold = 0.5

    var intercepts: Bool { bagel >= Self.bagelThreshold || impostor >= Self.impostorThreshold }

    /// How the overlay names it.
    var reason: String {
        bagel / Self.bagelThreshold >= impostor / Self.impostorThreshold
            ? "looks like a bagel (Jev \(Int((bagel * 100).rounded()))%)"
            : "not something you'd send (Jev \(Int((impostor * 100).rounded()))%)"
    }
}

enum Jev {
    static let model = "jev-1.14.0"
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    /// `JEV_API_KEY` from the fish config, since apps opened from Finder don't inherit the shell's
    /// environment. Read once; takes a moment, so call it off the main thread.
    static func loadAPIKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["JEV_API_KEY"], !key.isEmpty { return key }
        for fish in ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"] where FileManager.default.isExecutableFile(atPath: fish) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: fish)
            process.arguments = ["-c", "printf %s \"$JEV_API_KEY\""]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return key
            }
        }
        return nil
    }

    /// Asks both questions in one request. `boxImage` is the box as rendered and `emojiImages` each
    /// emoji cut out of it, enlarged: a custom emoji is too small in the whole box to judge well.
    /// Without them (no Screen Recording permission) Jev judges the text and emoji names alone.
    static func judge(_ snapshot: MessageSnapshot, boxImage: CGImage?, emojiImages: [CGImage] = [], apiKey: String) async throws -> JevVerdict {
        var state: [String: Any] = [
            "message_text": snapshot.text,
            "emoji_in_message": snapshot.emojiLabels,
            "destination": snapshot.field,
        ]
        var assets: [String: Any] = [:]
        var bagelRef: String?
        var bagelTrue: Any = "A bagel picture or emoji (even one whose name says something else), the word bagel, or talk of bagels."
        if let boxImage, let boxPNG = png(fitted(boxImage)), let bagelPNG = referenceBagel {
            let boxRef = "box-\(UUID().uuidString)"
            let ref = "bagel-\(UUID().uuidString)"
            bagelRef = ref
            state["message_box"] = boxRef
            assets[boxRef] = ["type": "image", "format": "png", "data_base64": boxPNG.base64EncodedString()]
            assets[ref] = ["type": "image", "format": "png", "data_base64": bagelPNG.base64EncodedString()]
            bagelTrue = ["description": bagelTrue, "looks_like": ref]
            var emojiRefs: [String] = []
            for emoji in emojiImages.prefix(8) {
                guard let data = png(fitted(enlarged(emoji))) else { continue }
                let ref = "emoji-\(UUID().uuidString)"
                emojiRefs.append(ref)
                assets[ref] = ["type": "image", "format": "png", "data_base64": data.base64EncodedString()]
            }
            if !emojiRefs.isEmpty { state["emoji_pictures"] = emojiRefs }
        }

        var questions: [String: Any] = [
            "bagel": [
                "type": "noul",
                "instructions": "Does the Slack message being written contain a bagel in any form? Check the rendered `message_box`, each emoji in `emoji_pictures`, `message_text` and `emoji_in_message`: a custom emoji can look like a bagel while its name says something else.",
                "criteria": ["true": bagelTrue, "false": "No bagel anywhere in the message."],
            ],
            "impostor": [
                "type": "noul",
                "instructions": "Does this Slack message look like a prank typed by someone else on a software engineer's unlocked laptop, rather than something the engineer would send at work themselves?",
                "criteria": [
                    "true": "A prank or out-of-character message: offering to buy food or treats for everyone, embarrassing confessions or declarations, joke announcements made in the owner's name, keyboard mashing or gibberish, or anything a colleague would type to tease the owner.",
                    "false": "Ordinary work chat a software engineer would send: code, reviews, deploys, incidents, meetings, questions, status updates, links, and casual friendly replies or jokes they would plausibly make themselves.",
                ],
            ],
        ]
        // A closer look at the emoji alone: a renamed bagel emoji is easy to miss in the whole box.
        if state["emoji_pictures"] != nil, let bagelRef {
            questions["bagel_emoji"] = [
                "type": "noul",
                "instructions": "Is any picture in `emoji_pictures` a bagel, whatever the emoji is called?",
                "criteria": [
                    "true": ["description": "At least one picture shows a bagel: a round bread roll with a hole in the middle, plain or topped with seeds.", "looks_like": bagelRef],
                    "false": "None of the pictures is a bagel.",
                ],
            ]
        }
        var body: [String: Any] = ["model": model, "state": state, "questions": questions]
        if !assets.isEmpty { body["assets"] = assets }

        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !assets.isEmpty { request.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let answers = json["answers"] as? [String: [String: Any]],
            let bagel = (answers["bagel"]?["noul"] as? NSNumber)?.doubleValue,
            let impostor = (answers["impostor"]?["noul"] as? NSNumber)?.doubleValue
        else {
            throw NSError(domain: "Jev", code: status, userInfo: [NSLocalizedDescriptionKey: String(decoding: data.prefix(300), as: UTF8.self)])
        }
        let bagelEmoji = (answers["bagel_emoji"]?["noul"] as? NSNumber)?.doubleValue ?? 0
        return JevVerdict(bagel: max(bagel, bagelEmoji), impostor: impostor)
    }

    // MARK: Images

    /// A rendered 🥯, for Jev to compare emoji in the box against.
    static let referenceBagel: Data? = {
        let side = 320
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        let glyph = NSAttributedString(string: "\u{1F96F}", attributes: [.font: NSFont.systemFont(ofSize: 220)])
        let size = glyph.size()
        glyph.draw(at: NSPoint(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }()

    /// The message box is a wide, short strip; Jev takes 280 to 1568 pixels a side, so shrink it to
    /// fit and pad it out on a white canvas.
    static func fitted(_ image: CGImage) -> CGImage {
        let minSide = 280, maxSide = 1568
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = Int(Double(image.width) * scale), height = Int(Double(image.height) * scale)
        let canvasWidth = max(width, minSide), canvasHeight = max(height, minSide)
        guard let context = CGContext(
            data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: (canvasHeight - height) / 2, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Scales a small emoji crop up so it fills most of Jev's 280-pixel minimum.
    static func enlarged(_ image: CGImage) -> CGImage {
        let target = 240.0
        let scale = target / Double(max(image.width, image.height, 1))
        guard scale > 1 else { return image }
        let width = Int(Double(image.width) * scale), height = Int(Double(image.height) * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Cuts each emoji out of the box capture. `captured` is the screen rect the capture covers.
    static func crops(of frames: [CGRect], from image: CGImage, captured: CGRect) -> [CGImage] {
        let scale = CGFloat(image.width) / captured.width
        return frames.compactMap { frame in
            let local = frame.intersection(captured).offsetBy(dx: -captured.minX, dy: -captured.minY)
            guard !local.isEmpty else { return nil }
            let pixels = CGRect(x: local.minX * scale, y: local.minY * scale, width: local.width * scale, height: local.height * scale)
            return image.cropping(to: pixels.integral)
        }
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// The screen inside `rect` (global top-left-origin points). Needs Screen Recording.
    static func capture(_ rect: CGRect) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else { return nil }
            let local = rect.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.sourceRect = local
            config.width = Int(local.width * scale)
            config.height = Int(local.height * scale)
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            Log.write("message box capture failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Screens message box contents with Jev, caching one verdict per content so the send check can
/// usually answer straight away from the check made while typing.
final class JevGuard {
    private var apiKey: String?
    private var cache: [String: JevVerdict] = [:]
    private var cacheOrder: [String] = []
    private var waiters: [String: [(JevVerdict?) -> Void]] = [:]

    var isAvailable: Bool { apiKey != nil }

    func start() {
        DispatchQueue.global(qos: .utility).async {
            let key = Jev.loadAPIKey()
            DispatchQueue.main.async {
                self.apiKey = key
                Log.write(key == nil ? "jev: no JEV_API_KEY found; Jev checks off" : "jev: ready (\(Jev.model))")
            }
        }
        if !CGPreflightScreenCaptureAccess() {
            Log.write("jev: no Screen Recording permission; judging text only")
            CGRequestScreenCaptureAccess()
        }
    }

    func cached(_ key: String) -> JevVerdict? { cache[key] }

    /// Calls back on the main thread with the verdict, or nil if Jev couldn't be reached.
    func screen(_ snapshot: MessageSnapshot, completion: @escaping (JevVerdict?) -> Void) {
        guard let apiKey, !snapshot.isEmpty else { return completion(nil) }
        let key = snapshot.key
        if let verdict = cache[key] { return completion(verdict) }
        if waiters[key] != nil {
            waiters[key]?.append(completion)
            return
        }
        waiters[key] = [completion]
        Task {
            let started = Date()
            var verdict: JevVerdict?
            let captured = snapshot.frame?.insetBy(dx: -6, dy: -6)
            let image = if let captured { await Jev.capture(captured) } else { CGImage?.none }
            let emoji = if let image, let captured { Jev.crops(of: snapshot.emojiFrames, from: image, captured: captured) } else { [CGImage]() }
            do {
                verdict = try await Jev.judge(snapshot, boxImage: image, emojiImages: emoji, apiKey: apiKey)
            } catch {
                Log.write("jev: request failed: \(error.localizedDescription)")
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async {
                if let verdict {
                    Log.write(String(format: "jev: bagel=%.2f impostor=%.2f image=%@ emoji=%d %dms", verdict.bagel, verdict.impostor, image == nil ? "no" : "yes", emoji.count, ms))
                    self.remember(key, verdict)
                }
                for waiter in self.waiters.removeValue(forKey: key) ?? [] { waiter(verdict) }
            }
        }
    }

    private func remember(_ key: String, _ verdict: JevVerdict) {
        cache[key] = verdict
        cacheOrder.append(key)
        if cacheOrder.count > 64 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }
}
