import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers
import simd

/// Writes one scan inside a project:
///
///   Scan_001/
///     images/frame_00000.jpg        RGB photo (sensor orientation)
///     depth/frame_00000.png         16-bit LiDAR depth in millimetres
///     confidence/frame_00000.png    8-bit LiDAR confidence (0 low, 127 medium, 254 high)
///     points.ply                    coloured high-confidence LiDAR points (max 1M)
///     frames.json                   per-frame intrinsics + camera-to-world pose
///
/// Poses are in the project's shared AR world coordinates (ARKit / OpenGL camera convention).
final class ScanWriter {

    struct FrameResult {
        var totalPoints = 0
        var limitReached = false
        var displayPoints: [ColoredPoint] = []
        var preview: UIImage?
        var depthPreview: UIImage?
    }

    static let pointsFileName = "points.ply"
    static let framesFileName = "frames.json"

    let directory: URL
    let saveQueue = DispatchQueue(label: "scan.save", qos: .userInitiated)

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var frames: [[String: Any]] = []
    private var points: [ColoredPoint] = []

    init(directory: URL) throws {
        self.directory = directory
        for sub in ["images", "depth", "confidence"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(sub, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
    }

    static func loadFrames(in directory: URL) -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(framesFileName)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["frames"] as? [[String: Any]]
    }

    // MARK: Per frame (saveQueue)

    func write(_ capture: FrameCapture, settings: CaptureSettings) -> FrameResult {
        var result = FrameResult()
        let name = String(format: "frame_%05d", capture.index)
        let imagePath = "images/\(name).jpg"

        // 1. Photo
        let ciImage = CIImage(cvPixelBuffer: capture.image)
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [quality: 0.92]),
              (try? jpeg.write(to: directory.appendingPathComponent(imagePath))) != nil else {
            result.totalPoints = points.count
            return result
        }

        if settings.showPreviewWindow {
            let scale = 360 / ciImage.extent.width
            let small = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cg = ciContext.createCGImage(small, from: small.extent) {
                result.preview = UIImage(cgImage: cg)
            }
        }

        // 2. Camera (per-frame intrinsics: autofocus changes focal length slightly)
        let K = capture.intrinsics
        var frame: [String: Any] = [
            "file_path": imagePath,
            "fl_x": Double(K.columns.0.x),
            "fl_y": Double(K.columns.1.y),
            "cx": Double(K.columns.2.x),
            "cy": Double(K.columns.2.y),
            "w": Int(capture.imageResolution.width),
            "h": Int(capture.imageResolution.height),
            "transform_matrix": Self.rows(of: capture.transform),
            "timestamp": capture.timestamp,
            "sharpness": capture.sharpness
        ]

        // 3. LiDAR
        if let depth = capture.depth {
            let depthPath = "depth/\(name).png"
            if writeDepthPNG(depth, to: directory.appendingPathComponent(depthPath)) {
                frame["depth_file_path"] = depthPath
            }
            if let confidence = capture.confidence {
                let confPath = "confidence/\(name).png"
                if writeConfidencePNG(confidence, to: directory.appendingPathComponent(confPath)) {
                    frame["confidence_file_path"] = confPath
                }
            }
            let newPoints = accumulatePoints(capture, depth: depth, settings: settings)
            let step = max(1, newPoints.count / max(1, settings.displayPointsPerFrame))
            result.displayPoints = stride(from: 0, to: newPoints.count, by: step).map { newPoints[$0] }
            if settings.showPreviewWindow {
                result.depthPreview = depthPreview(depth, minDepth: settings.minDepth, maxDepth: settings.maxDepth)
            }
        }

        frames.append(frame)
        if frames.count % 25 == 0 { try? writeFramesFile() }   // crash safety

        result.totalPoints = points.count
        result.limitReached = points.count >= settings.maxPointsPerScan
        return result
    }

    // MARK: Finish (saveQueue)

    /// Writes frames.json and points.ply. Returns the number of frames (0 = scan discarded).
    func finish() throws -> Int {
        guard !frames.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            return 0
        }
        try writeFramesFile()
        if !points.isEmpty {
            try PointCloudIO.writePLY(points, to: directory.appendingPathComponent(Self.pointsFileName))
        }
        return frames.count
    }

    private func writeFramesFile() throws {
        let json: [String: Any] = ["frames": frames, "capture_app": "PaintingScan 0.2"]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent(Self.framesFileName), options: .atomic)
    }

    // MARK: Point cloud

    private func accumulatePoints(_ capture: FrameCapture, depth: CVPixelBuffer, settings: CaptureSettings) -> [ColoredPoint] {
        guard points.count < settings.maxPointsPerScan else { return [] }

        let image = capture.image
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        if let c = capture.confidence { CVPixelBufferLockBaseAddress(c, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            if let c = capture.confidence { CVPixelBufferUnlockBaseAddress(c, .readOnly) }
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depth),
              CVPixelBufferGetPlaneCount(image) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return [] }

        let dw = CVPixelBufferGetWidth(depth)
        let dh = CVPixelBufferGetHeight(depth)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depth)

        var confBase: UnsafeMutableRawPointer?
        var confRowBytes = 0
        if let c = capture.confidence {
            confBase = CVPixelBufferGetBaseAddress(c)
            confRowBytes = CVPixelBufferGetBytesPerRow(c)
        }

        let yPlane = yBase.assumingMemoryBound(to: UInt8.self)
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let cbcr = cbcrBase.assumingMemoryBound(to: UInt8.self)
        let cbcrRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let imgW = CVPixelBufferGetWidthOfPlane(image, 0)
        let imgH = CVPixelBufferGetHeightOfPlane(image, 0)

        let K = capture.intrinsics
        let fx = K.columns.0.x, fy = K.columns.1.y, cx = K.columns.2.x, cy = K.columns.2.y
        let scaleX = Float(capture.imageResolution.width) / Float(dw)
        let scaleY = Float(capture.imageResolution.height) / Float(dh)
        let T = capture.transform
        let step = max(1, settings.pointStride)
        let room = settings.maxPointsPerScan - points.count

        var newPoints: [ColoredPoint] = []
        var v = 0
        rows: while v < dh {
            let depthRow = (depthBase + v * depthRowBytes).assumingMemoryBound(to: Float32.self)
            let confRow = confBase.map { ($0 + v * confRowBytes).assumingMemoryBound(to: UInt8.self) }
            var u = 0
            while u < dw {
                defer { u += step }
                if let confRow = confRow, confRow[u] < 2 { continue }   // high confidence only
                let d = depthRow[u]
                guard d.isFinite, d >= settings.minDepth, d <= settings.maxDepth else { continue }

                // Pixel centre in full-resolution image coordinates.
                let xi = (Float(u) + 0.5) * scaleX
                let yi = (Float(v) + 0.5) * scaleY

                // Back-project (image y points down; ARKit camera y up, looks down -z).
                let xc = (xi - cx) / fx * d
                let yc = (yi - cy) / fy * d
                let world = T * SIMD4<Float>(xc, -yc, -d, 1)

                // Colour from the YCbCr image (BT.601 full range).
                let px = min(imgW - 1, Int(xi)), py = min(imgH - 1, Int(yi))
                let Y = Float(yPlane[py * yRowBytes + px])
                let cIndex = (py / 2) * cbcrRowBytes + (px / 2) * 2
                let Cb = Float(cbcr[cIndex]) - 128
                let Cr = Float(cbcr[cIndex + 1]) - 128

                newPoints.append(ColoredPoint(x: world.x, y: world.y, z: world.z,
                                              r: Self.clampByte(Y + 1.402 * Cr),
                                              g: Self.clampByte(Y - 0.344136 * Cb - 0.714136 * Cr),
                                              b: Self.clampByte(Y + 1.772 * Cb)))
                if newPoints.count >= room { break rows }
            }
            v += step
        }
        points.append(contentsOf: newPoints)
        return newPoints
    }

    // MARK: Depth / confidence images

    private func writeDepthPNG(_ buffer: CVPixelBuffer, to url: URL) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        var millimetres = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<w {
                let d = row[x]
                millimetres[y * w + x] = (d.isFinite && d > 0) ? UInt16(min(d * 1000, 65535)) : 0
            }
        }
        let data = millimetres.withUnsafeBufferPointer { Data(buffer: $0) }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).union(.byteOrder16Little)
        guard let image = Self.makeImage(data: data, width: w, height: h, bitsPerComponent: 16, components: 1, bitmapInfo: info) else { return false }
        return Self.writePNG(image, to: url)
    }

    private func writeConfidencePNG(_ buffer: CVPixelBuffer, to url: URL) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        var values = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { values[y * w + x] = min(row[x], 2) * 127 }
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let image = Self.makeImage(data: Data(values), width: w, height: h, bitsPerComponent: 8, components: 1, bitmapInfo: info) else { return false }
        return Self.writePNG(image, to: url)
    }

    /// Colour-coded depth for the preview window: red = near, blue = far, black = outside the depth range.
    private func depthPreview(_ buffer: CVPixelBuffer, minDepth: Float, maxDepth: Float) -> UIImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer), maxDepth > minDepth else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<w {
                let i = (y * w + x) * 4
                rgba[i + 3] = 255
                let d = row[x]
                guard d.isFinite, d >= minDepth, d <= maxDepth else { continue }
                let t = (d - minDepth) / (maxDepth - minDepth)
                rgba[i] = UInt8(255 * (1 - t))
                rgba[i + 1] = UInt8(255 * (1 - abs(2 * t - 1)))
                rgba[i + 2] = UInt8(255 * t)
            }
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let image = Self.makeImage(data: Data(rgba), width: w, height: h, bitsPerComponent: 8, components: 4, bitmapInfo: info) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func makeImage(data: Data, width: Int, height: Int, bitsPerComponent: Int,
                                  components: Int, bitmapInfo: CGBitmapInfo) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let space = components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        return CGImage(width: width, height: height,
                       bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerComponent * components,
                       bytesPerRow: width * bitsPerComponent * components / 8,
                       space: space, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: Utilities

    /// simd matrices are column-major; JSON stores a list of rows.
    static func rows(of m: simd_float4x4) -> [[Double]] {
        (0..<4).map { r in (0..<4).map { c in Double(m[c][r]) } }
    }

    private static func clampByte(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, v.rounded())))
    }
}
