import Foundation
import simd

/// Tracks camera speed and detects tracking jumps, so frames are only captured
/// while the device moves smoothly (prevents motion blur and pose drift).
struct MotionGate {
    private(set) var linearSpeed: Float = 0     // m/s (smoothed)
    private(set) var angularSpeed: Float = 0    // degrees/s (smoothed)
    private(set) var jumpDetected = false

    private var previousTransform: simd_float4x4?
    private var previousTime: TimeInterval = 0

    mutating func update(transform: simd_float4x4, time: TimeInterval, trackingNormal: Bool) {
        jumpDetected = false
        let prior = previousTransform
        let priorTime = previousTime
        previousTransform = transform
        previousTime = time

        guard trackingNormal, let prior = prior, time > priorTime, time - priorTime < 0.5 else {
            linearSpeed = 0
            angularSpeed = 0
            return
        }

        let dt = Float(time - priorTime)
        let distance = simd_distance(Self.position(of: prior), Self.position(of: transform))
        let angle = Self.angleDegrees(from: prior, to: transform)

        // More than 8 cm between two consecutive frames (~5 m/s) is not real motion:
        // ARKit corrected its pose (drift correction / relocalization).
        if distance > 0.08 && dt < 0.05 {
            jumpDetected = true
            return
        }

        let alpha: Float = 0.25
        linearSpeed += alpha * (distance / dt - linearSpeed)
        angularSpeed += alpha * (angle / dt - angularSpeed)
    }

    static func position(of m: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    static func angleDegrees(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let relative = simd_quatf(b) * simd_quatf(a).inverse
        var degrees = relative.angle * 180 / .pi
        if degrees > 180 { degrees = 360 - degrees }
        return degrees
    }

    static func movedEnough(from a: simd_float4x4, to b: simd_float4x4,
                            minTranslation: Float, minRotationDegrees: Float) -> Bool {
        if simd_distance(position(of: a), position(of: b)) >= minTranslation { return true }
        return angleDegrees(from: a, to: b) >= minRotationDegrees
    }
}
