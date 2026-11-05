import ARKit
import SceneKit
import SwiftUI

/// Camera preview with the point cloud / coverage overlay.
struct ARViewContainer: UIViewRepresentable {
    @EnvironmentObject var capture: CaptureManager

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = capture.session
        view.automaticallyUpdatesLighting = false
        view.scene.rootNode.addChildNode(capture.renderer.root)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
