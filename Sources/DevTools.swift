// Development aid. `BagelGuard --render out.png [photo.jpg]` draws the overlay off-screen, the same
// way a saved mugshot is drawn, and exits, so the design can be checked without covering the screen.
// Without a photo it uses a synthetic sensor frame with a face box, to check the target lock.

import Cocoa

enum DevTools {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--render"), args.count > flag + 1 else { return }
        let mugshot: Mugshot
        if args.count > flag + 2, let photo = NSImage(contentsOfFile: args[flag + 2]),
            let cgImage = photo.cgImage(forProposedRect: nil, context: nil, hints: nil)
        {
            mugshot = Mugshot(image: NSImage(cgImage: cgImage, size: .zero), face: MugshotCamera.face(in: cgImage))
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
}
