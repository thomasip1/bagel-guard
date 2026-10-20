// Development aid: measures how the webcam's brightness settles after the camera starts, and how
// much darker the face gets once the overlay covers the screen.

import AVFoundation
import Cocoa
import CoreImage

final class CameraProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "probe")
    private let context = CIContext()
    private var device: AVCaptureDevice?
    private var start = Date()
    private var frames = 0

    /// Takes one photo exactly as a detection would, and logs how long it took and how bright it is.
    static func snapTest() {
        _ = NSApplication.shared
        let start = Date()
        var done = false
        let camera = MugshotCamera()
        camera.snap { mugshot in
            defer { done = true }
            guard let mugshot, let cg = mugshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return Log.write("snap-test: no photo")
            }
            let image = CIImage(cgImage: cg)
            var pixel = [UInt8](repeating: 0, count: 4)
            let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
            CIContext().render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            let luma = 0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])
            Log.write(String(format: "snap-test: photo after %.2f s, luma=%.0f, face=%@", Date().timeIntervalSince(start), luma,
                             mugshot.face.map { "\(Int($0.width))px" } ?? "none"))
        }
        while !done && Date().timeIntervalSince(start) < 6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    static func run() {
        let probe = CameraProbe()
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else {
            return Log.write("probe: no camera")
        }
        Log.write("probe: camera \(device.localizedName), authorized \(MugshotCamera.isAuthorized)")
        probe.device = device
        probe.session.sessionPreset = .high
        probe.session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(probe, queue: probe.queue)
        probe.session.addOutput(output)
        probe.start = Date()
        probe.session.startRunning()

        _ = NSApplication.shared
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        // Cover the screen like the overlay does.
        let window = NSWindow(contentRect: NSScreen.main!.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1)
        window.orderFrontRegardless()
        Log.write("probe: screen covered at \(String(format: "%.2f", Date().timeIntervalSince(probe.start))) s")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        window.orderOut(nil)
        probe.session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
        guard frames % 3 == 1, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        var pixel = [UInt8](repeating: 0, count: 4)
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let luma = 0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])
        Log.write(String(format: "probe: t=%.2f frame=%d luma=%.0f adjusting=%@", Date().timeIntervalSince(start), frames, luma,
                         device?.isAdjustingExposure == true ? "yes" : "no"))
    }
}
