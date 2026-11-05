import ARKit
import Combine
import UIKit
import simd

/// Runs the AR session, owns the current project, decides when to grab frames
/// (Scan & Go + motion gate + blur check) and hands them to the ScanWriter.
final class CaptureManager: NSObject, ObservableObject, ARSessionDelegate {

    // MARK: Published UI state (main thread)
    @Published private(set) var project: Project?
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var isRelocalizing = false
    @Published private(set) var frameCount = 0
    @Published private(set) var scanCount = 0
    @Published private(set) var pointCount = 0
    @Published private(set) var pointLimitReached = false
    @Published private(set) var trackingMessage = "Starting camera…"
    @Published private(set) var trackingIsNormal = false
    @Published private(set) var warning: String?
    @Published private(set) var linearSpeed: Float = 0
    @Published private(set) var angularSpeed: Float = 0
    @Published private(set) var lastSharpness: Double = 0
    @Published private(set) var blurRejections = 0
    @Published private(set) var motionRejections = 0
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var previewDepth: UIImage?
    @Published private(set) var videoFormatDescription = ""
    @Published var statusMessage: String?
    @Published var settings = CaptureSettings() {
        didSet {
            let s = settings
            captureQueue.async { self.workerSettings = s }
            renderer.apply(s)
        }
    }

    let camera = CameraController()
    let renderer = PointCloudRenderer()
    let session = ARSession()
    let hasLiDAR = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

    // MARK: Worker state (captureQueue only)
    private let captureQueue = DispatchQueue(label: "capture.queue", qos: .userInteractive)
    private var workerSettings = CaptureSettings()
    private var writer: ScanWriter?
    private var lastCapturedTransform: simd_float4x4?
    private var capturedCount = 0
    private var pendingSaves = 0
    private var motion = MotionGate()
    private var blockedUntil: TimeInterval = 0
    private var wasNormal = false
    private var lastUIUpdate: TimeInterval = 0
    private var lastJumpTime: TimeInterval = -100

    private let haptics = UINotificationFeedbackGenerator()

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = captureQueue
        renderer.apply(settings)
    }

    // MARK: Projects

    func openDefaultProject() {
        if let p = ProjectStore.openOrCreateDefault() { openProject(p) }
    }

    func openProject(_ p: Project) {
        if isRecording { stopRecording() }
        project = p
        ProjectStore.lastOpenedName = p.name
        frameCount = 0
        pointCount = 0
        previewImage = nil
        previewDepth = nil
        renderer.clearAll()
        restartSession()
        reloadHistory()
    }

    func reloadHistory() {
        guard let p = project else { return }
        scanCount = p.scans().count
        DispatchQueue.global(qos: .userInitiated).async {
            let points = p.loadHistoryPoints(maxPoints: 300_000)
            DispatchQueue.main.async {
                if self.project == p { self.renderer.setHistory(points) }
            }
        }
    }

    // MARK: Session

    /// (Re)starts tracking. If the project has a saved AR map, the session relocalizes into it,
    /// so new scans share the coordinate system of the earlier ones.
    func restartSession() {
        let map = project?.loadWorldMap()
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)   // raw per-frame depth, aligned with each photo
        }
        if settings.use4K, let format = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
            config.videoFormat = format
        } else if let best = ARWorldTrackingConfiguration.supportedVideoFormats.max(by: {
            $0.imageResolution.width * $0.imageResolution.height < $1.imageResolution.width * $1.imageResolution.height
        }) {
            config.videoFormat = best
        }
        config.isAutoFocusEnabled = true
        config.initialWorldMap = map

        let res = config.videoFormat.imageResolution
        videoFormatDescription = "\(Int(res.width))×\(Int(res.height)) · \(config.videoFormat.framesPerSecond) fps"

        isRelocalizing = map != nil
        renderer.setAligned(map == nil)
        captureQueue.async {
            self.motion = MotionGate()
            self.wasNormal = false
        }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.camera.refresh()
            self.camera.reapply()
        }
    }

    func pauseSession() {
        if isRecording { stopRecording() }
        session.pause()
    }

    // MARK: Recording

    func startRecording() {
        guard let project else { statusMessage = "Open a project first."; return }
        guard !isRelocalizing else {
            statusMessage = "Point at the painting until the earlier scans line up (blue points)."
            return
        }
        do {
            let w = try ScanWriter(directory: try project.newScanDirectory())
            let s = settings
            renderer.promoteCurrentToHistory()
            renderer.clearMarkers()
            captureQueue.async {
                self.workerSettings = s
                self.writer = w
                self.lastCapturedTransform = nil
                self.capturedCount = 0
            }
            frameCount = 0
            pointCount = 0
            blurRejections = 0
            motionRejections = 0
            pointLimitReached = false
            statusMessage = nil
            isRecording = true
            haptics.prepare()
        } catch {
            statusMessage = "Could not create scan folder: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isBusy = true
        captureQueue.async {
            guard let writer = self.writer else {
                DispatchQueue.main.async { self.isBusy = false }
                return
            }
            self.writer = nil
            // The save queue is serial, so finish() runs after every pending frame is written.
            writer.saveQueue.async {
                let result = Result { try writer.finish() }
                DispatchQueue.main.async { self.scanFinished(result) }
            }
        }
    }

    private func scanFinished(_ result: Result<Int, Error>) {
        switch result {
        case .success(let frames) where frames > 0:
            statusMessage = "Saved scan with \(frames) frames. Saving AR map…"
            scanCount = project?.scans().count ?? 0
            saveWorldMap()
        case .success:
            statusMessage = "No frames captured – scan discarded."
            isBusy = false
        case .failure(let error):
            statusMessage = "Save failed: \(error.localizedDescription)"
            isBusy = false
        }
    }

    private func saveWorldMap() {
        guard let project else { isBusy = false; return }
        session.getCurrentWorldMap { map, error in
            DispatchQueue.main.async {
                defer { self.isBusy = false }
                guard let map else {
                    self.statusMessage = "Scan saved, but the AR map could not be stored (\(error?.localizedDescription ?? "unknown error")). Later scans may not line up."
                    return
                }
                do {
                    try project.saveWorldMap(map)
                    self.statusMessage = "Scan saved. Record again to add another scan to \(project.name)."
                } catch {
                    self.statusMessage = "Scan saved, but the AR map could not be written: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: ARSessionDelegate (captureQueue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        let transform = frame.camera.transform
        let state = frame.camera.trackingState
        let isNormal: Bool
        if case .normal = state { isNormal = true } else { isNormal = false }

        motion.update(transform: transform, time: now, trackingNormal: isNormal)
        if motion.jumpDetected {
            lastJumpTime = now
            blockedUntil = max(blockedUntil, now + 1.0)
        }
        handleTrackingTransition(isNormal: isNormal, now: now)
        publishUIIfNeeded(state: state, now: now)

        guard let writer else { return }
        let s = workerSettings
        guard isNormal, now >= blockedUntil, pendingSaves < 2 else { return }

        // Scan & Go: only when moved / rotated enough since the last frame.
        if let last = lastCapturedTransform,
           !MotionGate.movedEnough(from: last, to: transform,
                                   minTranslation: s.minTranslation, minRotationDegrees: s.minRotationDegrees) {
            return
        }

        // Motion gate: too fast → blur and drift.
        if s.motionGateEnabled && (motion.linearSpeed > s.maxLinearSpeed || motion.angularSpeed > s.maxAngularSpeed) {
            DispatchQueue.main.async { self.motionRejections += 1 }
            return
        }

        let sharpness = Sharpness.score(frame.capturedImage)
        guard sharpness >= s.sharpnessThreshold else {
            DispatchQueue.main.async {
                self.lastSharpness = sharpness
                self.blurRejections += 1
            }
            return
        }

        lastCapturedTransform = transform
        let index = capturedCount
        capturedCount += 1

        let capture = FrameCapture(
            index: index,
            image: frame.capturedImage,
            depth: frame.sceneDepth?.depthMap,
            confidence: frame.sceneDepth?.confidenceMap,
            intrinsics: frame.camera.intrinsics,
            transform: transform,
            imageResolution: frame.camera.imageResolution,
            timestamp: now,
            sharpness: sharpness
        )

        pendingSaves += 1
        writer.saveQueue.async {
            let result = writer.write(capture, settings: s)
            self.captureQueue.async { self.pendingSaves -= 1 }
            DispatchQueue.main.async {
                guard self.isRecording else { return }
                self.frameCount = index + 1
                self.pointCount = result.totalPoints
                self.pointLimitReached = result.limitReached
                self.lastSharpness = sharpness
                if let p = result.preview { self.previewImage = p }
                if let d = result.depthPreview { self.previewDepth = d }
                self.renderer.addCurrent(result.displayPoints)
                self.renderer.addMarker(at: transform)
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            if self.isRecording { self.stopRecording() }
            self.statusMessage = "AR session failed: \(error.localizedDescription). Try turning off 4K in Settings."
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async {
            if self.isRecording {
                self.stopRecording()
                self.statusMessage = "Session interrupted – recording stopped and saved."
            }
        }
    }

    // MARK: Helpers (captureQueue)

    private func handleTrackingTransition(isNormal: Bool, now: TimeInterval) {
        if isNormal && !wasNormal {
            blockedUntil = max(blockedUntil, now + 0.7)   // let the pose settle after recovery
            DispatchQueue.main.async {
                if self.isRelocalizing {
                    self.isRelocalizing = false
                    self.renderer.setAligned(true)
                    self.statusMessage = "Relocalized – new scans line up with the earlier ones."
                }
            }
        }
        if !isNormal && wasNormal && writer != nil {
            DispatchQueue.main.async { self.haptics.notificationOccurred(.warning) }
        }
        wasNormal = isNormal
    }

    private func publishUIIfNeeded(state: ARCamera.TrackingState, now: TimeInterval) {
        guard now - lastUIUpdate > 0.1 else { return }
        lastUIUpdate = now

        let (message, normal) = Self.describe(state)
        let s = workerSettings
        let lin = motion.linearSpeed, ang = motion.angularSpeed
        var warning: String?
        if !normal {
            warning = message
        } else if now - lastJumpTime < 1.5 {
            warning = "Tracking jump – hold steady"
        } else if lin > s.maxLinearSpeed {
            warning = "Too fast – slow down"
        } else if ang > s.maxAngularSpeed {
            warning = "Turning too fast"
        }

        DispatchQueue.main.async {
            self.trackingMessage = message
            self.trackingIsNormal = normal
            self.linearSpeed = lin
            self.angularSpeed = ang
            self.warning = warning
        }
    }

    private static func describe(_ state: ARCamera.TrackingState) -> (String, Bool) {
        switch state {
        case .normal:
            return ("Tracking", true)
        case .notAvailable:
            return ("Tracking lost", false)
        case .limited(let reason):
            switch reason {
            case .initializing: return ("Initializing – move slowly", false)
            case .excessiveMotion: return ("Too much motion", false)
            case .insufficientFeatures: return ("Low detail – include frame & wall", false)
            case .relocalizing: return ("Relocalizing – aim at earlier scan area", false)
            @unknown default: return ("Tracking limited", false)
            }
        }
    }
}
