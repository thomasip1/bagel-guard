// Development aid. `BagelGuard --render out.png [photo.jpg]` draws the overlay off-screen, the same
// way a saved mugshot is drawn, and exits, so the design can be checked without covering the screen.
// Without a photo it uses a synthetic sensor frame with a face box, to check the target lock.

import Cocoa
import CoreML

enum DevTools {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--lineup-test"), args.count > idx + 1 {
            lineupTest(photo: args[idx + 1])
        }
        if let idx = args.firstIndex(of: "--jev-test"), args.count > idx + 1 {
            jevTest(text: args[idx + 1], image: args.count > idx + 2 ? args[idx + 2] : nil)
        }
        guard let flag = args.firstIndex(of: "--render"), args.count > flag + 1 else { return }
        let mugshot: Mugshot
        if args.count > flag + 2, let photo = NSImage(contentsOfFile: args[flag + 2]),
            let cgImage = photo.cgImage(forProposedRect: nil, context: nil, hints: nil)
        {
            let lineup = Lineup.shared
            lineup.loadInBackground()
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { while !lineup.isReady { Thread.sleep(forTimeInterval: 0.1) }; sem.signal() }
            sem.wait()
            mugshot = Mugshot(image: NSImage(cgImage: cgImage, size: .zero), face: MugshotCamera.face(in: cgImage), match: lineup.identify(cgImage: cgImage))
        } else {
            let frame = NSImage(size: NSSize(width: 1280, height: 720), flipped: true) { rect in
                NSGradient(starting: NSColor(white: 0.32, alpha: 1), ending: NSColor(white: 0.12, alpha: 1))?.draw(in: rect, angle: 90)
                NSColor(white: 0.45, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: 520, y: 170, width: 240, height: 300)).fill()
                NSBezierPath(roundedRect: NSRect(x: 380, y: 500, width: 520, height: 400), xRadius: 200, yRadius: 200).fill()
                return true
            }
            mugshot = Mugshot(image: frame, face: Face(rect: CGRect(x: 530, y: 200, width: 220, height: 250), confidence: 0.97))
        }
        let png = MugshotArchive.render(mugshot, for: .sample(.lock))?.representation(using: .png, properties: [:])
        do {
            try png?.write(to: URL(fileURLWithPath: args[flag + 1]))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func lineupTest(photo path: String) {
        let lineup = Lineup.shared
        lineup.loadInBackground()
        // Wait for indexing
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while !lineup.isReady { Thread.sleep(forTimeInterval: 0.1) }
            sem.signal()
        }
        sem.wait()

        guard let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { print("could not load \(path)"); exit(1) }

        if let match = lineup.identify(cgImage: cgImage) {
            print("MATCH: \(match.name) (\(String(format: "%.4f", match.similarity)))")
        } else {
            print("NO MATCH (below threshold \(0.363))")
        }
        exit(0)
    }

    /// `--jev-test "message text" [box.png]`: asks Jev about a message, optionally with a picture
    /// standing in for the rendered message box, and prints both probabilities.
    private static func jevTest(text: String, image path: String?) {
        guard let key = Jev.loadAPIKey() else { print("no JEV_API_KEY"); exit(1) }
        let boxImage = path.flatMap { NSImage(contentsOfFile: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        // The test boxes have their emoji at x 200-252 of 1400 (see the box generator).
        let emoji = boxImage.flatMap { $0.cropping(to: CGRect(x: 196, y: 18, width: 60, height: 60)) }
        let snapshot = MessageSnapshot(text: text, emojiLabels: emoji == nil ? [] : ["morning-sun emoji"], field: "Message to eng-team", frame: nil)
        let sem = DispatchSemaphore(value: 0)
        Task {
            let started = Date()
            do {
                let verdict = try await Jev.judge(snapshot, boxImage: boxImage, emojiImages: emoji.map { [$0] } ?? [], apiKey: key)
                print(String(format: "bagel=%.2f impostor=%.2f intercept=%@ %dms", verdict.bagel, verdict.impostor,
                             verdict.intercepts ? "YES" : "no", Int(Date().timeIntervalSince(started) * 1000)))
            } catch {
                print("failed: \(error.localizedDescription)")
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
}
