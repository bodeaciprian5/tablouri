import Foundation

/// User-adjustable capture parameters.
struct CaptureSettings: Equatable {
    // LiDAR
    /// Ignore LiDAR points closer than this (metres). Lowest useful value is 0.05 m.
    var minDepth: Float = 0.15
    /// Ignore LiDAR points farther than this (metres) – keeps the room out of the painting scan.
    var maxDepth: Float = 2.0
    /// Sample every Nth LiDAR pixel when building the point cloud.
    var pointStride: Int = 4
    /// Hard cap on stored points per scan.
    var maxPointsPerScan: Int = 1_000_000

    // Scan & Go
    /// Capture a new frame after moving at least this far (metres)...
    var minTranslation: Float = 0.04
    /// ...or after rotating at least this much (degrees).
    var minRotationDegrees: Float = 4
    /// Frames whose sharpness score is below this are rejected as blurry.
    var sharpnessThreshold: Double = 12

    // Motion gate
    var motionGateEnabled = true
    /// Maximum camera speed while capturing (m/s).
    var maxLinearSpeed: Float = 0.30
    /// Maximum rotation speed while capturing (degrees/s).
    var maxAngularSpeed: Float = 30

    // Camera
    /// Use the 4K camera format when the device supports it.
    var use4K = true

    // Display
    var showLivePoints = true
    var showHistoryPoints = true
    var showCameraMarkers = true
    var showPreviewWindow = true
    /// How many of each frame's points are drawn on screen (all are saved).
    var displayPointsPerFrame = 800
}
