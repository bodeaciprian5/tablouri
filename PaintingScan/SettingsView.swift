import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var capture: CaptureManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Scan & Go") {
                    sliderRow("Capture every", value: Binding(
                        get: { capture.settings.minTranslation * 100 },
                        set: { capture.settings.minTranslation = $0 / 100 }),
                              range: 1...15, format: "%.0f cm")
                    sliderRow("or every", value: $capture.settings.minRotationDegrees, range: 1...15, format: "%.0f° rotation")
                    VStack(alignment: .leading) {
                        Text(String(format: "Reject blurry frames below sharpness %.0f", capture.settings.sharpnessThreshold))
                        Slider(value: $capture.settings.sharpnessThreshold, in: 0...100)
                        Text("The preview window shows the sharpness of each saved frame – use it to calibrate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Motion gate") {
                    Toggle("Skip frames when moving too fast", isOn: $capture.settings.motionGateEnabled)
                    sliderRow("Max speed", value: Binding(
                        get: { capture.settings.maxLinearSpeed * 100 },
                        set: { capture.settings.maxLinearSpeed = $0 / 100 }),
                              range: 5...80, format: "%.0f cm/s")
                    sliderRow("Max rotation", value: $capture.settings.maxAngularSpeed, range: 5...90, format: "%.0f°/s")
                }
                Section("LiDAR") {
                    sliderRow("Nearest", value: $capture.settings.minDepth, range: 0.05...2.0, format: "%.2f m")
                    sliderRow("Farthest", value: $capture.settings.maxDepth, range: 0.2...10.0, format: "%.2f m")
                    Stepper("Point density: every \(capture.settings.pointStride) px",
                            value: $capture.settings.pointStride, in: 1...8)
                    Text("Up to \(capture.settings.maxPointsPerScan.formatted()) points are stored per scan.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Display") {
                    Toggle("Live points", isOn: $capture.settings.showLivePoints)
                    Toggle("History points (earlier scans)", isOn: $capture.settings.showHistoryPoints)
                    Toggle("Camera position markers", isOn: $capture.settings.showCameraMarkers)
                    Toggle("Preview window", isOn: $capture.settings.showPreviewWindow)
                }
                Section("Camera") {
                    Toggle("Use 4K video format (if supported)", isOn: $capture.settings.use4K)
                        .onChange(of: capture.settings.use4K) { _, _ in capture.restartSession() }
                    Text("Changing this restarts tracking. Turn it off if the session fails to start.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Tips for paintings") {
                    Text("• Soft, even light; avoid reflections on varnish.\n• Choose MANUAL or LOCK in the camera strip before recording.\n• Sweep slowly in arcs: left–right, then top–bottom, 40–80 cm away.\n• Add close passes and oblique angles for brush-stroke relief.\n• Keep the frame and some wall in view.")
                        .font(.callout)
                }
            }
            .navigationTitle("Capture settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, format: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(String(format: format, value.wrappedValue))")
            Slider(value: value, in: range)
        }
    }
}
