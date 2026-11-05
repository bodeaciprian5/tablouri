import ARKit
import AVFoundation
import Combine

/// Manual camera control for the camera ARKit is using:
/// Auto, Lock (freeze current auto values) or Manual (shutter, ISO, white balance in Kelvin + tint),
/// exposure compensation (EV) and focus lock.
final class CameraController: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case auto = "Auto", locked = "Lock", manual = "Manual"
        var id: String { rawValue }
    }

    @Published private(set) var mode: Mode = .auto
    @Published private(set) var isAvailable = false
    @Published private(set) var focusLocked = false
    @Published var lastError: String?

    // Manual values
    @Published var shutterSeconds: Double = 1.0 / 120
    @Published var iso: Float = 100
    @Published var kelvin: Float = 5000
    @Published var tint: Float = 0
    @Published var evBias: Float = 0

    // Device ranges
    @Published private(set) var shutterRange: ClosedRange<Double> = (1.0 / 8000)...(1.0 / 60)
    @Published private(set) var isoRange: ClosedRange<Float> = 25...2000
    @Published private(set) var evRange: ClosedRange<Float> = -3...3

    // Live read-out
    @Published private(set) var currentShutter: Double = 0
    @Published private(set) var currentISO: Float = 0
    @Published private(set) var currentKelvin: Float = 0

    private var device: AVCaptureDevice? {
        ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
    }

    /// Read ranges and current values (call after the AR session is running).
    func refresh() {
        guard let d = device else { isAvailable = false; return }
        isAvailable = true
        let format = d.activeFormat
        let minS = CMTimeGetSeconds(format.minExposureDuration)
        let maxS = CMTimeGetSeconds(format.maxExposureDuration)
        if minS > 0, maxS > minS { shutterRange = minS...maxS }
        if format.maxISO > format.minISO { isoRange = format.minISO...format.maxISO }
        if d.maxExposureTargetBias > d.minExposureTargetBias { evRange = d.minExposureTargetBias...d.maxExposureTargetBias }
        readCurrent()
    }

    func readCurrent() {
        guard let d = device else { return }
        currentShutter = CMTimeGetSeconds(d.exposureDuration)
        currentISO = d.iso
        currentKelvin = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains).temperature
    }

    func setMode(_ newMode: Mode) {
        if newMode == .manual, mode != .manual, let d = device {
            // Start manual mode from what auto exposure chose, so the image doesn't jump.
            readCurrent()
            shutterSeconds = min(max(currentShutter, shutterRange.lowerBound), shutterRange.upperBound)
            iso = min(max(currentISO, isoRange.lowerBound), isoRange.upperBound)
            let wb = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
            kelvin = wb.temperature
            tint = wb.tint
        }
        mode = newMode
        reapply()
    }

    func setFocusLocked(_ locked: Bool) {
        focusLocked = locked
        guard let d = device else { return }
        configure(d) { self.applyFocus($0) }
    }

    /// Re-applies the current mode (also needed after the AR session restarts).
    func reapply() {
        guard let d = device else { return }
        configure(d) { d in
            switch self.mode {
            case .auto:
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
                d.setExposureTargetBias(self.clampedEV(d), completionHandler: nil)
            case .locked:
                d.setExposureTargetBias(self.clampedEV(d), completionHandler: nil)
                if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
                if d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }
            case .manual:
                self.applyExposure(d)
                self.applyWhiteBalance(d)
            }
            self.applyFocus(d)
        }
    }

    /// Call when a manual slider changes.
    func applyManual() {
        guard mode == .manual, let d = device else { return }
        configure(d) { d in
            self.applyExposure(d)
            self.applyWhiteBalance(d)
        }
    }

    /// Call when the EV slider changes (works in Auto mode).
    func applyEV() {
        guard mode == .auto, let d = device else { return }
        configure(d) { d in d.setExposureTargetBias(self.clampedEV(d), completionHandler: nil) }
    }

    // MARK: Private

    private func clampedEV(_ d: AVCaptureDevice) -> Float {
        min(max(evBias, d.minExposureTargetBias), d.maxExposureTargetBias)
    }

    private func applyExposure(_ d: AVCaptureDevice) {
        guard d.isExposureModeSupported(.custom) else { return }
        let format = d.activeFormat
        let seconds = min(max(shutterSeconds, CMTimeGetSeconds(format.minExposureDuration)),
                          CMTimeGetSeconds(format.maxExposureDuration))
        let clampedISO = min(max(iso, format.minISO), format.maxISO)
        d.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000),
                                iso: clampedISO, completionHandler: nil)
    }

    private func applyWhiteBalance(_ d: AVCaptureDevice) {
        guard d.isWhiteBalanceModeSupported(.locked) else { return }
        let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: tint)
        var gains = d.deviceWhiteBalanceGains(for: values)
        let maxGain = d.maxWhiteBalanceGain
        gains.redGain = min(max(gains.redGain, 1), maxGain)
        gains.greenGain = min(max(gains.greenGain, 1), maxGain)
        gains.blueGain = min(max(gains.blueGain, 1), maxGain)
        d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
    }

    private func applyFocus(_ d: AVCaptureDevice) {
        if focusLocked {
            if d.isFocusModeSupported(.locked) {
                d.setFocusModeLocked(lensPosition: d.lensPosition, completionHandler: nil)
            }
        } else if d.isFocusModeSupported(.continuousAutoFocus) {
            d.focusMode = .continuousAutoFocus
        }
    }

    private func configure(_ d: AVCaptureDevice, _ body: (AVCaptureDevice) -> Void) {
        do {
            try d.lockForConfiguration()
            body(d)
            d.unlockForConfiguration()
        } catch {
            lastError = "Camera settings could not be changed: \(error.localizedDescription)"
        }
    }
}
