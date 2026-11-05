import SwiftUI

/// Full-screen capture HUD:
///  top     – project, tracking / warning pills, format, LiDAR badge
///  left    – tool rail (live points, history points, camera markers, preview, depth range, settings)
///  right   – stats, point budget, speed gauge, record button
///  bottom  – pro camera strip (mode, S, ISO, EV, WB, tint, AF)
///  overlay – preview window (last saved frame + depth), relocalization hint, status toast
struct ContentView: View {
    @EnvironmentObject var capture: CaptureManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showSettings = false
    @State private var showProjects = false
    @State private var showDepthPanel = false

    /// iPhone in landscape: short screen, so every panel is smaller.
    private var compact: Bool { verticalSizeClass == .compact }
    private var previewWidth: CGFloat { compact ? 130 : 220 }

    var body: some View {
        ZStack {
            ARViewContainer().ignoresSafeArea()

            if capture.isRecording {
                RoundedRectangle(cornerRadius: 0).stroke(.red.opacity(0.8), lineWidth: 4).ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            VStack(spacing: compact ? 6 : 10) {
                topBar
                HStack(alignment: .top, spacing: compact ? 6 : 10) {
                    leftRail
                    if showDepthPanel { DepthRangePanel(settings: $capture.settings) }
                    Spacer()
                    if capture.settings.showPreviewWindow { previewWindow }
                    rightColumn
                }
                Spacer()
                if let message = capture.statusMessage {
                    Text(message)
                        .font(.callout).foregroundStyle(.white)
                        .hudPanel()
                        .onTapGesture { capture.statusMessage = nil }
                }
                CameraStripView(camera: capture.camera, compact: compact)
            }
            .padding(compact ? 6 : 16)

            if capture.isRelocalizing { relocalizeHint }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear {
            if capture.project == nil { capture.openDefaultProject() }
            // Small screen: start with the preview window hidden (toggle it from the left rail).
            if compact { capture.settings.showPreviewWindow = false }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background { capture.pauseSession() }
            if newPhase == .active && oldPhase == .background { capture.restartSession() }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(capture) }
        .sheet(isPresented: $showProjects) { ProjectsView().environmentObject(capture) }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { showProjects = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill")
                    Text(capture.project?.name ?? "No project").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.black.opacity(0.5), in: Capsule())
            }
            .disabled(capture.isRecording || capture.isBusy)

            Pill(text: capture.trackingMessage, color: capture.trackingIsNormal ? .green : .yellow)

            if let warning = capture.warning, capture.trackingIsNormal {
                Pill(text: warning, color: .red)
            }
            if capture.isRecording {
                Pill(text: "REC", color: .red)
            }
            Spacer()
            if capture.isBusy { ProgressView().tint(.white) }
            if !compact {
                Text(capture.videoFormatDescription)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            }
            Pill(text: capture.hasLiDAR ? "LiDAR" : "No LiDAR", color: capture.hasLiDAR ? .cyan : .orange)
        }
    }

    // MARK: Left tool rail

    private var leftRail: some View {
        VStack(spacing: compact ? 5 : 10) {
            RailButton(systemImage: "circle.grid.3x3.fill", isOn: capture.settings.showLivePoints, size: compact ? 34 : 44) {
                capture.settings.showLivePoints.toggle()
            }
            RailButton(systemImage: "clock.arrow.circlepath", isOn: capture.settings.showHistoryPoints, size: compact ? 34 : 44) {
                capture.settings.showHistoryPoints.toggle()
            }
            RailButton(systemImage: "camera.viewfinder", isOn: capture.settings.showCameraMarkers, size: compact ? 34 : 44) {
                capture.settings.showCameraMarkers.toggle()
            }
            RailButton(systemImage: "pip", isOn: capture.settings.showPreviewWindow, size: compact ? 34 : 44) {
                capture.settings.showPreviewWindow.toggle()
            }
            RailButton(systemImage: "ruler", isOn: showDepthPanel, size: compact ? 34 : 44) {
                showDepthPanel.toggle()
            }
            RailButton(systemImage: "gearshape.fill", size: compact ? 34 : 44) { showSettings = true }
                .disabled(capture.isRecording)
        }
        .hudPanel(cornerRadius: 30)
    }

    // MARK: Right column

    private var rightColumn: some View {
        VStack(spacing: compact ? 6 : 12) {
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                HUDLabel(title: "Frames", value: "\(capture.frameCount)")
                VStack(alignment: .leading, spacing: 3) {
                    HUDLabel(title: "Points", value: compact(capture.pointCount))
                    ProgressView(value: Double(capture.pointCount), total: Double(capture.settings.maxPointsPerScan))
                        .tint(capture.pointLimitReached ? .red : .cyan)
                        .frame(width: 96)
                    if capture.pointLimitReached {
                        Text("1M LIMIT").font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
                    }
                }
                if !compact {
                    HUDLabel(title: "Scans", value: "\(capture.scanCount)")
                    HUDLabel(title: "Skipped", value: "\(capture.blurRejections) blur · \(capture.motionRejections) fast")
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .frame(width: compact ? 100 : 120, alignment: .leading)
            .hudPanel()

            SpeedGauge(linear: capture.linearSpeed, angular: capture.angularSpeed,
                       maxLinear: capture.settings.maxLinearSpeed, maxAngular: capture.settings.maxAngularSpeed,
                       barHeight: compact ? 44 : 90)

            recordButton
        }
    }

    private var recordButton: some View {
        Button {
            capture.isRecording ? capture.stopRecording() : capture.startRecording()
        } label: {
            ZStack {
                let d: CGFloat = compact ? 60 : 78
                Circle().stroke(.white, lineWidth: 4).frame(width: d, height: d)
                if capture.isRecording {
                    RoundedRectangle(cornerRadius: 7).fill(.red).frame(width: d * 0.41, height: d * 0.41)
                } else {
                    Circle().fill(.red).frame(width: d * 0.82, height: d * 0.82)
                }
            }
        }
        .disabled(!capture.isRecording && (!capture.trackingIsNormal || capture.isRelocalizing || capture.isBusy))
        .opacity(!capture.isRecording && (!capture.trackingIsNormal || capture.isBusy) ? 0.5 : 1)
    }

    // MARK: Preview window

    private var previewWindow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(compact ? "LAST FRAME" : "PREVIEW · LAST SAVED FRAME").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7))
            if let image = capture.previewImage {
                Image(uiImage: image).resizable().scaledToFit().frame(width: previewWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)).frame(width: previewWidth, height: previewWidth * 0.75)
                    .overlay(Text("Start recording").font(.caption).foregroundStyle(.white.opacity(0.6)))
            }
            if let depth = capture.previewDepth {
                Image(uiImage: depth).resizable().interpolation(.none).scaledToFit().frame(width: previewWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if !compact {
                Text(String(format: "Depth %.2f–%.2f m · sharpness %.0f",
                            capture.settings.minDepth, capture.settings.maxDepth, capture.lastSharpness))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .hudPanel()
    }

    // MARK: Relocalization hint

    private var relocalizeHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "viewfinder").font(.system(size: 44))
            Text("Relocalizing").font(.headline)
            Text("Aim at the painting from where you scanned before.\nThe earlier scans appear in blue once aligned.")
                .font(.callout).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        .allowsHitTesting(false)
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.2fM", Double(n) / 1_000_000)
            : n >= 1_000 ? String(format: "%.0fk", Double(n) / 1_000) : "\(n)"
    }
}

/// Vertical motion gauge: green = good speed, yellow = near limit, red = over limit (frames are skipped).
struct SpeedGauge: View {
    let linear: Float
    let angular: Float
    let maxLinear: Float
    let maxAngular: Float
    var barHeight: CGFloat = 90

    private var ratio: Double {
        Double(max(linear / max(maxLinear, 0.01), angular / max(maxAngular, 0.01)))
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("SPEED").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7))
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.12)).frame(width: 14, height: barHeight)
                Capsule().fill(color).frame(width: 14, height: barHeight * min(1, ratio / 1.5))
                Rectangle().fill(.white).frame(width: 22, height: 2).offset(y: -barHeight / 1.5)   // limit mark
            }
            .frame(height: barHeight)
            Text(String(format: "%.0f cm/s", linear * 100))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white)
        }
        .hudPanel()
    }

    private var color: Color {
        ratio < 0.7 ? .green : ratio < 1.0 ? .yellow : .red
    }
}
