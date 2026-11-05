import SwiftUI

/// Quick depth-range control (0.05 m – 10 m) shown from the left tool rail.
struct DepthRangePanel: View {
    @Binding var settings: CaptureSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DEPTH RANGE").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7))
            row("Near", value: $settings.minDepth, range: 0.05...2.0)
            row("Far", value: $settings.maxDepth, range: 0.2...10.0)
            Text("Only LiDAR points inside this range are kept.\nFor a painting: near 0.05–0.2 m, far just behind the wall.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(width: 280)
        .hudPanel()
        .onChange(of: settings.minDepth) { _, newValue in
            if settings.maxDepth < newValue + 0.1 { settings.maxDepth = newValue + 0.1 }
        }
    }

    private func row(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(String(format: "%.2f m", value.wrappedValue))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
            Slider(value: value, in: range).tint(.yellow)
        }
    }
}
