import SwiftUI

/// Pro-camera style strip: mode selector + value chips (S, ISO, EV, WB, AF).
/// Tapping a chip opens a slider for that value above the strip.
struct CameraStripView: View {
    @ObservedObject var camera: CameraController
    var compact = false
    @State private var selected: Control?

    enum Control { case shutter, iso, ev, wb, tint }

    var body: some View {
        VStack(spacing: 8) {
            if let selected, camera.isAvailable {
                slider(for: selected)
                    .frame(width: compact ? 340 : 420)
                    .hudPanel()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: compact ? 3 : 6) {
                ForEach(CameraController.Mode.allCases) { mode in
                    Button(mode.rawValue.uppercased()) {
                        camera.setMode(mode)
                        if mode != .manual, selected != .ev { selected = nil }
                    }
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(camera.mode == mode ? Color.yellow : Color.white.opacity(0.1), in: Capsule())
                    .foregroundStyle(camera.mode == mode ? .black : .white)
                }
                Divider().frame(height: 24).overlay(.white.opacity(0.3))
                chip("S", shutterText, .shutter, enabled: camera.mode == .manual)
                chip("ISO", isoText, .iso, enabled: camera.mode == .manual)
                chip("EV", String(format: "%+.1f", camera.evBias), .ev, enabled: camera.mode == .auto)
                chip("WB", wbText, .wb, enabled: camera.mode == .manual)
                chip("TINT", String(format: "%+.0f", camera.tint), .tint, enabled: camera.mode == .manual)
                Button {
                    camera.setFocusLocked(!camera.focusLocked)
                } label: {
                    Text(camera.focusLocked ? "AF-L" : "AF")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(camera.focusLocked ? Color.yellow : Color.white.opacity(0.1), in: Capsule())
                        .foregroundStyle(camera.focusLocked ? .black : .white)
                }
            }
            }
            .fixedSize(horizontal: !compact, vertical: true)
            .hudPanel(cornerRadius: 22)
            if !camera.isAvailable {
                Text("Camera controls not available on this device").font(.caption).foregroundStyle(.orange)
            }
        }
        .animation(.easeOut(duration: 0.15), value: selected)
        .onAppear { camera.refresh() }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in camera.readCurrent() }
    }

    // MARK: Chips

    private var shutterText: String {
        let s = camera.mode == .manual ? camera.shutterSeconds : camera.currentShutter
        return s > 0 ? "1/\(Int((1 / s).rounded()))" : "–"
    }
    private var isoText: String {
        String(format: "%.0f", camera.mode == .manual ? camera.iso : camera.currentISO)
    }
    private var wbText: String {
        String(format: "%.0fK", camera.mode == .manual ? camera.kelvin : camera.currentKelvin)
    }

    private func chip(_ title: String, _ value: String, _ control: Control, enabled: Bool) -> some View {
        Button {
            guard enabled else { return }
            selected = (selected == control) ? nil : control
        } label: {
            VStack(spacing: 0) {
                Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Text(value).font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(selected == control ? .yellow : (enabled ? .white : .white.opacity(0.55)))
            }
            .frame(minWidth: compact ? 46 : 56)
            .padding(.vertical, 2)
        }
    }

    // MARK: Sliders

    @ViewBuilder
    private func slider(for control: Control) -> some View {
        switch control {
        case .shutter:
            let range = log2(camera.shutterRange.lowerBound)...log2(camera.shutterRange.upperBound)
            labeledSlider("Shutter \(shutterText) s",
                          value: Binding(get: { log2(camera.shutterSeconds) },
                                         set: { camera.shutterSeconds = pow(2, $0); camera.applyManual() }),
                          range: range)
        case .iso:
            labeledSlider("ISO \(isoText)",
                          value: Binding(get: { Double(camera.iso) },
                                         set: { camera.iso = Float($0); camera.applyManual() }),
                          range: Double(camera.isoRange.lowerBound)...Double(camera.isoRange.upperBound))
        case .ev:
            labeledSlider(String(format: "Exposure compensation %+.1f EV", camera.evBias),
                          value: Binding(get: { Double(camera.evBias) },
                                         set: { camera.evBias = Float(($0 * 10).rounded() / 10); camera.applyEV() }),
                          range: Double(camera.evRange.lowerBound)...Double(camera.evRange.upperBound))
        case .wb:
            labeledSlider("White balance \(wbText)",
                          value: Binding(get: { Double(camera.kelvin) },
                                         set: { camera.kelvin = Float(($0 / 50).rounded() * 50); camera.applyManual() }),
                          range: 2500...9000)
        case .tint:
            labeledSlider(String(format: "Tint %+.0f", camera.tint),
                          value: Binding(get: { Double(camera.tint) },
                                         set: { camera.tint = Float($0.rounded()); camera.applyManual() }),
                          range: -100...100)
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
            Slider(value: value, in: range).tint(.yellow)
        }
    }
}
