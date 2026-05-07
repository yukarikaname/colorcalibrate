//
//  MacCalibrationViewModel.swift
//  colorcalibrate
//
//  Created by Yukari Kaname on 3/22/26.
//

import AppKit
import Foundation
import Observation

// MARK: - Calibration Mode

enum CalibrationMode {
    case calibration
    case measurement

    var title: String {
        switch self {
        case .calibration: return "Calibration"
        case .measurement: return "Measurement"
        }
    }
}

// MARK: - Precision Report

struct PrecisionReport: Equatable {
    let preCalibrationDeltaE: Double  // ΔE before calibration (vs neutral white)
    let postCalibrationDeltaE: Double // ΔE after calibration
    let improvementPercent: Double    // (pre - post) / pre * 100
    let sensorAccuracyPercent: Double // Conservative estimate for iPhone sensor accuracy
    let sensorNoiseLevel: Double      // Conservative chromaticity uncertainty
    
    var improvementSummary: String {
        "ΔE \(String(format: "%.2f", preCalibrationDeltaE)) → \(String(format: "%.2f", postCalibrationDeltaE)) (\(String(format: "+%.1f", improvementPercent))%)"
    }
    
    var sensorAccuracySummary: String {
        "Lux error ±\(String(format: "%.1f", SensorConservativeEstimate.luxErrorPercent))% · Chromaticity ±\(String(format: "%.3f", sensorNoiseLevel))"
    }
}

// MARK: - Display Environment

struct DisplayEnvironmentSummary {
    var displayID: CGDirectDisplayID
    var screenName: String
    var colorSpaceName: String
    var currentEDRHeadroom: Double
    var potentialEDRHeadroom: Double

    var hdrCapable: Bool { potentialEDRHeadroom > 1.05 }
    var hdrLikelyEnabled: Bool { currentEDRHeadroom > 1.05 }
    var dynamicRangeMode: DisplayDynamicRangeMode { hdrLikelyEnabled ? .hdr : .sdr }

    static func current(screen: NSScreen? = nil) -> DisplayEnvironmentSummary {
        let resolvedScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        return DisplayEnvironmentSummary(
            displayID: resolvedScreen?.displayID ?? CGMainDisplayID(),
            screenName: resolvedScreen?.localizedName ?? "Current Display",
            colorSpaceName: resolvedScreen?.colorSpace?.localizedName ?? "Unknown Color Space",
            currentEDRHeadroom: Double(resolvedScreen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0),
            potentialEDRHeadroom: Double(resolvedScreen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0)
        )
    }
}

// MARK: - Quality Report

struct CalibrationQualityReport {
    let averageDeltaE: Double
    let whitePointCCT: Double?
    let grayDeltaE: Double?
    let gainRange: (min: Double, max: Double)
    let offsetRange: (min: Double, max: Double)

    var qualityRating: String {
        if averageDeltaE < 1.0 { return "Excellent" }
        if averageDeltaE < 3.0 { return "Good" }
        if averageDeltaE < 6.0 { return "Acceptable" }
        return "Poor"
    }

    var summary: String {
        var parts: [String] = ["ΔE₀₀ avg: \(String(format: "%.2f", averageDeltaE))"]
        if let cct = whitePointCCT {
            parts.append("White CCT: \(String(format: "%.0f", cct)) K")
        }
        if let grayDE = grayDeltaE {
            parts.append("Gray ΔE: \(String(format: "%.2f", grayDE))")
        }
        parts.append("Gains: \(String(format: "%.2f–%.2f", gainRange.min, gainRange.max))")
        parts.append("Offsets: \(String(format: "%.3f–%.3f", offsetRange.min, offsetRange.max))")
        parts.append("→ \(qualityRating)")
        return parts.joined(separator: " · ")
    }

    static func from(profile: CalibrationProfile, measurements: [CalibrationMeasurement]) -> CalibrationQualityReport? {
        let map = Dictionary(uniqueKeysWithValues: measurements.map { ($0.targetID, $0.measuredColor) })
        var deltas: [Double] = []

        for target in CalibrationTarget.sequence {
            guard let measured = map[target.id] else { continue }
            let corrected = target.color.applying(profile: profile)
            let de = ColorScience.deltaE2000(color1: target.color, color2: corrected)
            deltas.append(de)
        }

        guard !deltas.isEmpty else { return nil }
        let avgDeltaE = deltas.reduce(0, +) / Double(deltas.count)

        // Estimate white point CCT from the white measurement
        var whiteCCT: Double? = nil
        if let whiteMeasured = map["white"] {
            // Convert RGB to xy approximately via linear sRGB -> XYZ -> xy
            let sRGB = whiteMeasured
            let rLin = ColorScience.gammaExpand(sRGB.red)
            let gLin = ColorScience.gammaExpand(sRGB.green)
            let bLin = ColorScience.gammaExpand(sRGB.blue)
            let X = 0.4124564*rLin + 0.3575761*gLin + 0.1804375*bLin
            let Y = 0.2126729*rLin + 0.7151522*gLin + 0.0721750*bLin
            let Z = 0.0193339*rLin + 0.1191920*gLin + 0.9503041*bLin
            let sum = X+Y+Z
            if sum > 0 {
                let x = X / sum, y = Y / sum
                whiteCCT = ColorScience.correlatedColorTemperature(x: x, y: y)
            }
        }

        let grayDeltaE = map["gray"].map { ColorScience.deltaE2000(color1: RGBColor.neutralGray, color2: $0) }

        let gains = [profile.redGain, profile.greenGain, profile.blueGain]
        let offsets = [profile.redOffset, profile.greenOffset, profile.blueOffset]

        return CalibrationQualityReport(
            averageDeltaE: avgDeltaE,
            whitePointCCT: whiteCCT,
            grayDeltaE: grayDeltaE,
            gainRange: (gains.min() ?? 1, gains.max() ?? 1),
            offsetRange: (offsets.min() ?? 0, offsets.max() ?? 0)
        )
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class MacCalibrationViewModel {
    var store = CalibrationStore()
    var peerSession = PeerCalibrationSession(role: .macHost)
    var displayApplier = DisplayCalibrationApplier()
    var displayConditions = DisplayConditionController()
    var currentTargetIndex: Int?
    var activeTarget: CalibrationTarget?
    var measurements: [CalibrationMeasurement] = []
    var statusLine = "Connect an iPhone, point its front camera at the screen, and start calibration."
    var showDisplayPreparation = false
    var showFullScreenCalibration = false
    var displayEnvironment = DisplayEnvironmentSummary.current()
    var pendingApplyConfirmation = false
    var pendingRestoreSeconds = 0
    var latestQualityReport: CalibrationQualityReport?
    var latestPrecisionReport: PrecisionReport?
    var confirmationCountdownSeconds: Int = 10 {
        didSet { UserDefaults.standard.set(confirmationCountdownSeconds, forKey: "confirmationCountdownSeconds") }
    }
    
    // Calibration vs Measurement modes
    var currentMode: CalibrationMode = .calibration
    var isMeasuring = false
    var currentMeasurementColor: RGBColor?
    var measurementHistory: [RGBColor] = []
    
    // Pre-calibration reference
    @ObservationIgnored private var preCalibrationWhiteColor: RGBColor? = RGBColor(red: 1.0, green: 1.0, blue: 1.0)
    @ObservationIgnored private var preCalibrationDeltaE: Double = 0

    @ObservationIgnored private var applyConfirmationTask: Task<Void, Never>?
    @ObservationIgnored private var boostedBrightnessDisplayID: CGDirectDisplayID?
    @ObservationIgnored private var measurementTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private let measurementTimeoutSeconds: TimeInterval = 30

    init() {
        peerSession.onMeasurement = { [weak self] measurement in self?.handleMeasurement(measurement) }
        peerSession.onDisconnect = { [weak self] in self?.handleDisconnect() }
        RecalibrationScheduler.requestAuthorization()
        refreshDisplayEnvironment()
        confirmationCountdownSeconds = UserDefaults.standard.integer(forKey: "confirmationCountdownSeconds")
        if confirmationCountdownSeconds < 5 { confirmationCountdownSeconds = 10 }
    }

    // MARK: - Computed

    var progressText: String {
        if let idx = currentTargetIndex {
            return "Sample \(idx + 1) of \(CalibrationTarget.sequence.count)"
        }
        return "Ready"
    }

    var currentModeTitle: String { displayEnvironment.dynamicRangeMode.title }
    var currentProfile: CalibrationProfile? { store.profile(for: displayEnvironment.dynamicRangeMode) }
    var currentProfileName: String { currentProfile?.name ?? "No \(currentModeTitle) calibration saved yet" }

    var unsupportedSettingDetectionNote: String {
        "These checks use a mix of public display APIs and private macOS frameworks. They are intended for internal use and may be unavailable on some Mac or display combinations."
    }

    // MARK: - Actions

    func startCalibrationButtonTapped() {
        guard peerSession.isConnected else { return }
        refreshDisplayEnvironment()
        showDisplayPreparation = true
    }
    
    func switchMode(to mode: CalibrationMode) {
        currentMode = mode
        isMeasuring = false
        currentMeasurementColor = nil
        measurementHistory = []
    }
    
    func startMeasurementMode() {
        guard peerSession.isConnected, currentMode == .measurement else { return }
        isMeasuring = true
        measurementHistory = []
        currentMeasurementColor = nil
        statusLine = "Measuring current display color with iPhone sensor..."
        
        // Request a single measurement from the white point target
        if let whiteTarget = CalibrationTarget.sequence.first(where: { $0.id == "white" }) {
            peerSession.sendCalibrationStep(index: 0, target: whiteTarget)
            startMeasurementTimeout()
        }
    }
    
    func stopMeasurementMode() {
        isMeasuring = false
        cancelMeasurementTimeout()
        statusLine = "Measurement stopped."
    }

    func beginCalibrationAfterReview() {
        showDisplayPreparation = false
        refreshDisplayEnvironment()
        maximizeMeasurementBrightnessIfAvailable()
        showFullScreenCalibration = true
        startCalibration()
    }

    func openDisplaySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Displays-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.displays"
        ]
        for rawValue in urls {
            if let url = URL(string: rawValue), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
                                            configuration: .init(), completionHandler: nil)
    }

    func refreshDisplayEnvironment() {
        displayEnvironment = .current()
        displayConditions.refresh(displayID: displayEnvironment.displayID)
    }

    func updateTrackedScreen(_ screen: NSScreen?) {
        displayEnvironment = .current(screen: screen)
        displayConditions.refresh(displayID: displayEnvironment.displayID)
    }

    func applyCalibrationToDisplay() {
        refreshDisplayEnvironment()
        guard let profile = currentProfile else {
            statusLine = "No \(currentModeTitle) calibration is saved for the current display mode yet."
            return
        }

        displayApplier.apply(profile, to: displayEnvironment.displayID)
        if let error = displayApplier.lastErrorMessage {
            statusLine = error
        } else {
            startApplyConfirmationCountdown()
            statusLine = "Applied \(profile.name). Confirm within \(confirmationCountdownSeconds) seconds or it will restore."
        }
    }

    func restoreCurrentDisplayState() {
        cancelApplyConfirmation()
        displayApplier.restoreCurrentSystemDisplayState()
        restoreMeasurementBrightnessIfNeeded()
        statusLine = "Restored the current macOS display color state."
    }

    func confirmAppliedCalibration() {
        guard displayApplier.isCalibrationApplied else { return }
        cancelApplyConfirmation()
        statusLine = "Kept \(currentProfileName) active on the display until you restore it."
    }

    func updateReminder(days: Int) {
        store.updateReminderInterval(days: days)
        if store.latestProfile != nil {
            Task { await RecalibrationScheduler.scheduleReminder(afterDays: store.settings.intervalDays) }
        }
    }

    func updateRecalibrateAlertEnabled(_ enabled: Bool) {
        store.settings.recalibrateAlertEnabled = enabled
        if let encoded = try? JSONEncoder().encode(store.settings) {
            UserDefaults.standard.set(encoded, forKey: "recalibrationSettings")
        }
        if enabled, store.latestProfile != nil {
            Task { await RecalibrationScheduler.scheduleReminder(afterDays: store.settings.intervalDays) }
        } else {
            Task { await RecalibrationScheduler.cancelReminder() }
        }
    }

    // MARK: - Calibration Flow

    private func startCalibration() {
        measurements = []
        latestQualityReport = nil
        statusLine = brightnessBoostStatusLine(defaultLine: "Running \(currentModeTitle) calibration...")
        requestTarget(at: 0)
    }

    private func requestTarget(at index: Int) {
        guard CalibrationTarget.sequence.indices.contains(index) else { return }
        currentTargetIndex = index
        activeTarget = CalibrationTarget.sequence[index]
        if let target = activeTarget {
            statusLine = target.instruction
            peerSession.sendCalibrationStep(index: index, target: target)
            startMeasurementTimeout()
        }
    }

    private func handleMeasurement(_ measurement: CalibrationMeasurement) {
        cancelMeasurementTimeout()
        
        // In measurement mode, just update the display and stop
        if currentMode == .measurement && isMeasuring {
            currentMeasurementColor = measurement.measuredColor
            measurementHistory.append(measurement.measuredColor)
            isMeasuring = false
            
            if let profile = currentProfile {
                let corrected = RGBColor(red: 1.0, green: 1.0, blue: 1.0).applying(profile: profile)
                let preDE = ColorScience.deltaE2000(
                    color1: RGBColor(red: 1.0, green: 1.0, blue: 1.0),
                    color2: measurement.measuredColor
                )
                let postDE = ColorScience.deltaE2000(
                    color1: RGBColor(red: 1.0, green: 1.0, blue: 1.0),
                    color2: corrected
                )
                statusLine = "Current: \(String(format: "%.2f", preDE)) ΔE (with profile: \(String(format: "%.2f", postDE)) ΔE)"
            } else {
                let de = ColorScience.deltaE2000(
                    color1: RGBColor(red: 1.0, green: 1.0, blue: 1.0),
                    color2: measurement.measuredColor
                )
                statusLine = "Measured white point ΔE: \(String(format: "%.2f", de))"
            }
            return
        }
        
        // Normal calibration mode
        measurements.removeAll { $0.targetID == measurement.targetID }
        measurements.append(measurement)

        guard let idx = currentTargetIndex else { return }
        let next = idx + 1
        if CalibrationTarget.sequence.indices.contains(next) {
            requestTarget(at: next)
        } else {
            finishCalibration()
        }
    }

    private func handleDisconnect() {
        cancelMeasurementTimeout()
        showFullScreenCalibration = false
        currentTargetIndex = nil
        activeTarget = nil
        restoreMeasurementBrightnessIfNeeded()
        statusLine = "iPhone disconnected. Calibration aborted."
    }

    private func finishCalibration() {
        currentTargetIndex = nil
        activeTarget = nil
        cancelMeasurementTimeout()
        showFullScreenCalibration = false
        restoreMeasurementBrightnessIfNeeded()

        guard let profile = CalibrationProfile.from(
            measurements: measurements,
            dynamicRangeMode: displayEnvironment.dynamicRangeMode,
            displayName: displayEnvironment.screenName
        ) else {
            statusLine = "Calibration data was incomplete. Try another pass."
            return
        }

        store.save(profile: profile)
        latestQualityReport = CalibrationQualityReport.from(profile: profile, measurements: measurements)
        
        // Calculate precision report
        latestPrecisionReport = calculatePrecisionReport(profile: profile, measurements: measurements)
        
        statusLine = "Saved \(profile.name). Apply it to the display to compare."
        if let report = latestQualityReport {
            statusLine += " (\(report.qualityRating))"
        }
        if let precisionReport = latestPrecisionReport {
            statusLine += " · \(precisionReport.improvementSummary)"
        }
        peerSession.sendFinishedProfile(profile)
        Task { await RecalibrationScheduler.scheduleReminder(afterDays: store.settings.intervalDays) }
    }
    
    private func calculatePrecisionReport(profile: CalibrationProfile, measurements: [CalibrationMeasurement]) -> PrecisionReport? {
        // Get pre-calibration white measurement (uncalibrated reference)
        guard let whiteMeasurement = measurements.first(where: { $0.targetID == "white" }) else {
            return nil
        }
        
        let preCalibDE = ColorScience.deltaE2000(
            color1: RGBColor(red: 1.0, green: 1.0, blue: 1.0),
            color2: whiteMeasurement.measuredColor
        )
        
        // Get post-calibration white measurement (corrected by profile)
        let postCalibColor = RGBColor(red: 1.0, green: 1.0, blue: 1.0).applying(profile: profile)
        let postCalibDE = ColorScience.deltaE2000(
            color1: RGBColor(red: 1.0, green: 1.0, blue: 1.0),
            color2: postCalibColor
        )
        
        let improvement = preCalibDE > 0 ? ((preCalibDE - postCalibDE) / preCalibDE) * 100 : 0
        
        return PrecisionReport(
            preCalibrationDeltaE: preCalibDE,
            postCalibrationDeltaE: postCalibDE,
            improvementPercent: improvement,
            sensorAccuracyPercent: SensorConservativeEstimate.estimatedAccuracyPercent,
            sensorNoiseLevel: SensorConservativeEstimate.chromaticityError
        )
    }

    // MARK: - Measurement Timeout

    private func startMeasurementTimeout() {
        cancelMeasurementTimeout()
        measurementTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.measurementTimeoutSeconds ?? 30))
            guard let self, !Task.isCancelled else { return }
            self.currentTargetIndex = nil
            self.activeTarget = nil
            self.showFullScreenCalibration = false
            self.restoreMeasurementBrightnessIfNeeded()
            self.statusLine = "Measurement timed out waiting for iPhone response. Check connection."
        }
    }

    private func cancelMeasurementTimeout() {
        measurementTimeoutTask?.cancel()
        measurementTimeoutTask = nil
    }

    // MARK: - Brightness

    private func maximizeMeasurementBrightnessIfAvailable() {
        let id = displayEnvironment.displayID
        displayConditions.maximizeBrightness(for: id)
        boostedBrightnessDisplayID = displayConditions.snapshot.brightness != nil ? id : nil
    }

    private func restoreMeasurementBrightnessIfNeeded() {
        guard let id = boostedBrightnessDisplayID else { return }
        displayConditions.restoreBrightness(for: id)
        boostedBrightnessDisplayID = nil
    }

    private func brightnessBoostStatusLine(defaultLine: String) -> String {
        boostedBrightnessDisplayID == displayEnvironment.displayID && displayConditions.snapshot.brightness != nil
            ? "\(defaultLine) Brightness boosted to 100% for accuracy."
            : defaultLine
    }

    // MARK: - Apply Confirmation Countdown

    private func startApplyConfirmationCountdown() {
        cancelApplyConfirmation()
        pendingApplyConfirmation = true
        pendingRestoreSeconds = confirmationCountdownSeconds
        applyConfirmationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while pendingRestoreSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                pendingRestoreSeconds -= 1
            }
            guard pendingApplyConfirmation else { return }
            displayApplier.restoreCurrentSystemDisplayState()
            pendingApplyConfirmation = false
            statusLine = "Restored because applied calibration was not confirmed."
        }
    }

    private func cancelApplyConfirmation() {
        applyConfirmationTask?.cancel()
        applyConfirmationTask = nil
        pendingApplyConfirmation = false
        pendingRestoreSeconds = 0
    }
}

// MARK: - NSScreen Extension

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
