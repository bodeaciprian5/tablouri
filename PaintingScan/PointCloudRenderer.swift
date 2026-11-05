import SceneKit
import UIKit
import simd

/// Draws LiDAR points on top of the camera view:
/// - live points of the scan being recorded (real colours)
/// - history points of earlier scans in this project (tinted blue)
/// - small green pyramids where frames were captured
/// All methods must be called on the main thread.
final class PointCloudRenderer {
    let root = SCNNode()
    private let historyNode = SCNNode()
    private let currentNode = SCNNode()
    private let markersNode = SCNNode()
    private var currentPoints: [ColoredPoint] = []
    private var aligned = true
    private var settings = CaptureSettings()
    private static let historyTint = SIMD3<Float>(0.25, 0.55, 1.0)

    private lazy var markerGeometry: SCNGeometry = {
        let g = SCNPyramid(width: 0.02, height: 0.03, length: 0.02)
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.8)
        m.lightingModel = .constant
        g.materials = [m]
        return g
    }()

    init() {
        root.addChildNode(historyNode)
        root.addChildNode(currentNode)
        root.addChildNode(markersNode)
    }

    func apply(_ settings: CaptureSettings) {
        self.settings = settings
        updateVisibility()
    }

    /// History is hidden until the session has relocalized into the project's coordinate system.
    func setAligned(_ isAligned: Bool) {
        aligned = isAligned
        updateVisibility()
    }

    func setHistory(_ points: [ColoredPoint]) {
        historyNode.childNodes.forEach { $0.removeFromParentNode() }
        if let g = Self.geometry(points, tint: Self.historyTint) {
            historyNode.addChildNode(SCNNode(geometry: g))
        }
    }

    func addCurrent(_ points: [ColoredPoint]) {
        guard let g = Self.geometry(points, tint: nil) else { return }
        currentPoints.append(contentsOf: points)
        currentNode.addChildNode(SCNNode(geometry: g))
    }

    /// When a new scan starts, the previous scan's live points become history points.
    func promoteCurrentToHistory() {
        if let g = Self.geometry(currentPoints, tint: Self.historyTint) {
            historyNode.addChildNode(SCNNode(geometry: g))
        }
        currentPoints = []
        currentNode.childNodes.forEach { $0.removeFromParentNode() }
    }

    func addMarker(at transform: simd_float4x4) {
        let node = SCNNode(geometry: markerGeometry)
        node.simdTransform = transform
        // Point the pyramid tip along the camera's viewing direction (-z).
        node.simdOrientation = node.simdOrientation * simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        markersNode.addChildNode(node)
    }

    func clearMarkers() {
        markersNode.childNodes.forEach { $0.removeFromParentNode() }
    }

    func clearAll() {
        historyNode.childNodes.forEach { $0.removeFromParentNode() }
        currentNode.childNodes.forEach { $0.removeFromParentNode() }
        currentPoints = []
        clearMarkers()
    }

    private func updateVisibility() {
        historyNode.isHidden = !(settings.showHistoryPoints && aligned)
        currentNode.isHidden = !settings.showLivePoints
        markersNode.isHidden = !settings.showCameraMarkers
    }

    private static func geometry(_ points: [ColoredPoint], tint: SIMD3<Float>?) -> SCNGeometry? {
        guard !points.isEmpty else { return nil }
        var positions: [Float] = []
        var colors: [Float] = []
        positions.reserveCapacity(points.count * 3)
        colors.reserveCapacity(points.count * 3)
        for p in points {
            positions.append(p.x); positions.append(p.y); positions.append(p.z)
            var c = SIMD3<Float>(Float(p.r), Float(p.g), Float(p.b)) / 255
            if let t = tint { c = c * 0.4 + t * 0.6 }
            colors.append(c.x); colors.append(c.y); colors.append(c.z)
        }
        let positionData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }

        let vertexSource = SCNGeometrySource(data: positionData, semantic: .vertex, vectorCount: points.count,
                                             usesFloatComponents: true, componentsPerVector: 3,
                                             bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: points.count,
                                            usesFloatComponents: true, componentsPerVector: 3,
                                            bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let indices = Array(0..<UInt32(points.count))
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = 3
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 4

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        geometry.materials = [material]
        return geometry
    }
}
