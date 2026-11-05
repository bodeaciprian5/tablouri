import CoreVideo

/// Cheap blur detector: variance of the Laplacian on the luma plane,
/// sampled on a sparse grid in the centre half of the image.
enum Sharpness {
    static func score(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        let step = 4
        var sum = 0.0, sumSq = 0.0, n = 0.0
        var y = height / 4
        while y < 3 * height / 4 {
            var x = width / 4
            while x < 3 * width / 4 {
                let c = Int(luma[y * rowBytes + x])
                let l = Int(luma[y * rowBytes + x - 1])
                let r = Int(luma[y * rowBytes + x + 1])
                let u = Int(luma[(y - 1) * rowBytes + x])
                let d = Int(luma[(y + 1) * rowBytes + x])
                let lap = Double(4 * c - l - r - u - d)
                sum += lap
                sumSq += lap * lap
                n += 1
                x += step
            }
            y += step
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return sumSq / n - mean * mean
    }
}
