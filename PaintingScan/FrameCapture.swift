import ARKit
import simd

/// Everything we need from one ARFrame, detached from the frame itself
/// (so ARKit can recycle frames while we save in the background).
struct FrameCapture {
    let index: Int
    let image: CVPixelBuffer            // YCbCr 4:2:0 full range, sensor (landscape) orientation
    let depth: CVPixelBuffer?           // Float32 metres (LiDAR)
    let confidence: CVPixelBuffer?      // UInt8 0 = low, 1 = medium, 2 = high
    let intrinsics: simd_float3x3       // for `imageResolution`
    let transform: simd_float4x4        // camera-to-world, ARKit / OpenGL convention
    let imageResolution: CGSize
    let timestamp: TimeInterval
    let sharpness: Double
}
