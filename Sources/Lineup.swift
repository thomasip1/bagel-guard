// Face identification against a small library of known faces. Photos go in
// ~/Pictures/BagelGuard/Lineup/ named "Firstname Lastname.jpg". At launch the lineup is indexed:
// each photo's face is detected, aligned using 5-point landmarks, and embedded with the SFace CoreML
// model. When a mugshot is caught, its face is aligned and embedded the same way, then compared
// against the lineup by cosine similarity.

import CoreML
import Cocoa
import Vision

struct LineupMatch {
    let name: String
    let similarity: Double
}

final class Lineup {
    static let shared = Lineup()
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/BagelGuard/Lineup")
    private static let threshold: Double = 0.363

    private var entries: [(name: String, embedding: [Float])] = []
    private var model: MLModel?
    private let queue = DispatchQueue(label: "com.thomasip.bagelguard.lineup")
    private(set) var isReady = false
    /// The owner's own face, enrolled behind Touch ID and held in the signed store, so swapping the
    /// `Thomas Ip.jpg` file in the (user-writable) lineup folder can't make someone else the owner.
    /// When set it is used for the owner check instead of the file.
    private(set) var ownerEmbedding: [Float]?
    var isOwnerEnrolled: Bool { ownerEmbedding != nil }

    // Standard 5-point reference for 112x112 aligned face (ArcFace/SFace convention).
    private static let refPoints: [(Double, Double)] = [
        (38.2946, 51.6963),  // left eye
        (73.5318, 51.5014),  // right eye
        (56.0252, 71.7366),  // nose tip
        (41.5493, 92.3655),  // left mouth corner
        (70.7299, 92.2041),  // right mouth corner
    ]

    func loadInBackground() {
        queue.async { [self] in
            let modelURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/SFace.mlpackage")
            guard let compiled = try? MLModel.compileModel(at: modelURL),
                  let m = try? MLModel(contentsOf: compiled)
            else {
                Log.write("lineup: failed to load SFace model")
                return
            }
            model = m
            if let stored = SecureStore.dictionary("owner")?["embedding"] as? [Double] {
                ownerEmbedding = stored.map { Float($0) }
                Log.write("lineup: owner face enrolled (\(stored.count)-d)")
            }
            reindex()
        }
    }

    /// Embeds the face in `image` and stores it (signed) as the owner. Returns false if no clear
    /// face is found. Call behind Touch ID.
    func enrollOwner(from image: CGImage, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard model != nil, let aligned = alignFace(in: image), let embedding = embed(aligned) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            ownerEmbedding = embedding
            SecureStore.set("owner", ["embedding": embedding.map { Double($0) }])
            Log.write("lineup: owner face enrolled (\(embedding.count)-d)")
            DispatchQueue.main.async { completion(true) }
        }
    }

    func clearOwnerEnrollment() {
        queue.async { [self] in
            ownerEmbedding = nil
            SecureStore.set("owner", nil)
            Log.write("lineup: owner enrollment cleared")
        }
    }

    private func reindex() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.folder.path) else {
            Log.write("lineup: no Lineup folder at \(Self.folder.path)")
            return
        }
        guard let files = try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil) else { return }
        let images = files.filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }

        // Prefer "-linkedin" variant when present (better quality headshot).
        var bestURL: [String: URL] = [:]
        for url in images {
            let filename = url.deletingPathExtension().lastPathComponent
            let isLinkedIn = filename.hasSuffix("-linkedin")
            let baseName = isLinkedIn ? String(filename.dropLast("-linkedin".count)) : filename
            if isLinkedIn || bestURL[baseName] == nil {
                bestURL[baseName] = url
            }
        }

        var indexed: [(String, [Float])] = []
        for (name, url) in bestURL.sorted(by: { $0.key < $1.key }) {
            guard let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                Log.write("lineup: could not load \(name)")
                continue
            }
            guard let aligned = alignFace(in: cgImage),
                  let embedding = embed(aligned)
            else {
                Log.write("lineup: no face/embed failed in \(name)")
                continue
            }
            indexed.append((name, embedding))
        }
        entries = indexed
        isReady = true
        Log.write("lineup: indexed \(indexed.count)/\(images.count) faces")
    }

    func identify(cgImage: CGImage) -> LineupMatch? {
        guard isReady, !entries.isEmpty else { return nil }
        guard let aligned = alignFace(in: cgImage),
              let query = embed(aligned)
        else { return nil }

        var best: (name: String, sim: Double)?
        for entry in entries {
            let sim = cosine(query, entry.embedding)
            if sim > Self.threshold, sim > (best?.sim ?? -1) {
                best = (entry.name, sim)
            }
        }
        guard let match = best else { return nil }
        Log.write("lineup: matched \(match.name) (similarity \(String(format: "%.3f", match.sim)))")
        return LineupMatch(name: match.name, similarity: match.sim)
    }

    enum Check {
        case noFace
        /// How closely the face matches `owner`'s photo, and the best match above the threshold.
        case face(ownerSimilarity: Double, best: LineupMatch?)
    }

    /// Like `identify`, but scores the face against one person in particular, and doesn't log: it
    /// runs on camera frames several times a second.
    func check(cgImage: CGImage, owner: String) -> Check {
        guard isReady, let aligned = alignFace(in: cgImage), let query = embed(aligned) else { return .noFace }
        // The owner comes from the enrolled embedding when there is one; the file entry is only a
        // fallback for someone who hasn't enrolled.
        var ownerSimilarity = ownerEmbedding.map { cosine(query, $0) } ?? -1.0
        var best: (name: String, sim: Double)?
        for entry in entries {
            let sim = cosine(query, entry.embedding)
            if ownerEmbedding == nil, entry.name == owner { ownerSimilarity = sim }
            if sim > Self.threshold, sim > (best?.sim ?? -1) { best = (entry.name, sim) }
        }
        return .face(ownerSimilarity: ownerSimilarity, best: best.map { LineupMatch(name: $0.name, similarity: $0.sim) })
    }

    static var matchThreshold: Double { threshold }

    // MARK: - Face alignment

    private func alignFace(in image: CGImage) -> CGImage? {
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let landmarks = face.landmarks
        else { return nil }

        let w = CGFloat(image.width), h = CGFloat(image.height)
        let box = face.boundingBox

        func imagePoint(_ normalized: CGPoint) -> (Double, Double) {
            (Double(box.minX * w + normalized.x * box.width * w),
             Double((1 - box.minY) * h - normalized.y * box.height * h))
        }

        func center(_ region: VNFaceLandmarkRegion2D?) -> (Double, Double)? {
            guard let pts = region?.normalizedPoints, !pts.isEmpty else { return nil }
            let sum = pts.reduce((0.0, 0.0)) { (a: (Double, Double), p: CGPoint) in (a.0 + Double(p.x), a.1 + Double(p.y)) }
            return imagePoint(CGPoint(x: sum.0 / Double(pts.count), y: sum.1 / Double(pts.count)))
        }

        guard let leftEye = center(landmarks.leftEye),
              let rightEye = center(landmarks.rightEye),
              let nose = center(landmarks.nose)
        else { return nil }

        let mouth: ((Double, Double), (Double, Double))
        if let outerLips = landmarks.outerLips?.normalizedPoints, outerLips.count >= 6 {
            mouth = (imagePoint(outerLips[0]), imagePoint(outerLips[outerLips.count / 2]))
        } else if let innerLips = landmarks.innerLips?.normalizedPoints, innerLips.count >= 4 {
            mouth = (imagePoint(innerLips[0]), imagePoint(innerLips[innerLips.count / 2]))
        } else {
            let eyeCenter = ((leftEye.0 + rightEye.0) / 2, (leftEye.1 + rightEye.1) / 2)
            let dist = hypot(rightEye.0 - leftEye.0, rightEye.1 - leftEye.1)
            mouth = ((eyeCenter.0 - dist * 0.25, nose.1 + dist * 0.5),
                     (eyeCenter.0 + dist * 0.25, nose.1 + dist * 0.5))
        }

        let src = [leftEye, rightEye, nose, mouth.0, mouth.1]
        let transform = similarityTransform(from: src, to: Self.refPoints)
        return warpAffine(image, transform: transform, size: 112)
    }

    /// Least-squares similarity transform [a, b, tx, ty] mapping src → dst.
    /// x' = a*x - b*y + tx,  y' = b*x + a*y + ty
    private func similarityTransform(from src: [(Double, Double)], to dst: [(Double, Double)]) -> (Double, Double, Double, Double) {
        let n = Double(src.count)
        var sx = 0.0, sy = 0.0, dx = 0.0, dy = 0.0
        for i in 0..<src.count { sx += src[i].0; sy += src[i].1; dx += dst[i].0; dy += dst[i].1 }
        let msx = sx / n, msy = sy / n, mdx = dx / n, mdy = dy / n

        var num_a = 0.0, num_b = 0.0, den = 0.0
        for i in 0..<src.count {
            let cx = src[i].0 - msx, cy = src[i].1 - msy
            let fx = dst[i].0 - mdx, fy = dst[i].1 - mdy
            num_a += cx * fx + cy * fy
            num_b += cx * fy - cy * fx
            den += cx * cx + cy * cy
        }
        let a = num_a / den, b = num_b / den
        let tx = mdx - a * msx + b * msy
        let ty = mdy - b * msx - a * msy
        return (a, b, tx, ty)
    }

    private func warpAffine(_ image: CGImage, transform t: (Double, Double, Double, Double), size: Int) -> CGImage? {
        let (a, b, tx, ty) = t
        let det = a * a + b * b
        let ia = a / det, ib = -b / det
        let itx = -(ia * tx - ib * ty)
        let ity = -(ib * tx + ia * ty)

        let sw = image.width, sh = image.height
        let srcBytesPerRow = sw * 4
        guard let srcCtx = CGContext(
            data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: srcBytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        srcCtx.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let srcData = srcCtx.data else { return nil }
        let src = srcData.assumingMemoryBound(to: UInt8.self)

        let dstBytesPerRow = size * 4
        guard let dstCtx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: dstBytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        guard let dstData = dstCtx.data else { return nil }
        let dst = dstData.assumingMemoryBound(to: UInt8.self)

        for oy in 0..<size {
            for ox in 0..<size {
                let sx = ia * Double(ox) - ib * Double(oy) + itx
                let sy = ib * Double(ox) + ia * Double(oy) + ity
                let isx = Int(sx), isy = Int(sy)
                guard isx >= 0, isx < sw, isy >= 0, isy < sh else { continue }
                let si = isy * srcBytesPerRow + isx * 4
                let di = oy * dstBytesPerRow + ox * 4
                dst[di] = src[si]; dst[di+1] = src[si+1]; dst[di+2] = src[si+2]; dst[di+3] = 255
            }
        }
        return dstCtx.makeImage()
    }

    // MARK: - Embedding

    private func embed(_ face: CGImage) -> [Float]? {
        guard let model, let buffer = pixelBuffer(from: face) else { return nil }
        guard let prediction = try? model.prediction(from: MLDictionaryFeatureProvider(
            dictionary: ["face_image": MLFeatureValue(pixelBuffer: buffer)]
        )) else { return nil }
        guard let multiArray = prediction.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        var embedding = [Float](repeating: 0, count: 128)
        for i in 0..<128 { embedding[i] = multiArray[i].floatValue }
        return l2Normalize(embedding)
    }

    private func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 112, 112, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: 112, height: 112,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 112, height: 112))
        return buffer
    }

    private func l2Normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-10 else { return v }
        return v.map { $0 / norm }
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot: Float = 0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i] }
        return Double(dot)
    }
}
