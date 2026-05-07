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
    
    var improvementSummary: String {
        "ΔE \(String(format: "%.2f", preCalibrationDeltaE)) → \(String(format: "%.2f", postCalibrationDeltaE)) (\(String(format: "+%.1f", improvementPercent))%)"
    }
    
    var sensorAccuracySummary: String {
        "Lux error ±\(String(format: "%.1f", SensorConservativeEstimate.luxErrorPercent))% · Chromaticity ±\(String(format: "%.3f", SensorConservativeEstimate.chromaticityError))"
    }
}

// MARK: - Display Environment

struct DisplayEnvironmentSummary {
    var displayID: CGDirectDisplayID
    var screenName: String
    var colorSpaceName: String
    var colorSpace: DisplayColorSpace
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
            colorSpace: DisplayColorSpace.from(localizedName: resolvedScreen?.colorSpace?.localizedName),
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
        let measurementByID = Dictionary(uniqueKeysWithValues: measurements.map { ($0.targetID, $0) })
        var deltas: [Double] = []

        for target in CalibrationTarget.sequence(for: displayEnvironment.dynamicRangeMode) {
            guard let measurement = measurementByID[target.id] else { continue }
            let targetColor = target.renderedRGBColor(colorSpace: profile.colorSpace)
            let labTarget = ColorScience.rgbToLab(targetColor, colorSpace: profile.colorSpace)
            let de: Double
            if let measuredXY = measurement.measuredXY {
                let labMeasured = ColorScience.xyYToLab(x: measuredXY.x, y: measuredXY.y, Y: measuredXY.Y)
                de = ColorScience.deltaE2000(lab1: labTarget, lab2: labMeasured)
            } else {
                de = ColorScience.deltaE2000(
                    color1: targetColor,
                    color2: measurement.measuredColor,
                    colorSpace: profile.colorSpace
                )
            }
            deltas.append(de)
        }

        guard !deltas.isEmpty else { return nil }
        let avgDeltaE = deltas.reduce(0, +) / Double(deltas.count)

        // Estimate white point CCT from the white measurement
        var whiteCCT: Double? = nil
        if let whiteMeasured = measurements.first(where: { $0.targetID == "white" }) {
            if let measuredXY = whiteMeasured.measuredXY {
                whiteCCT = ColorScience.correlatedColorTemperature(x: measuredXY.x, y: measuredXY.y)
            } else {
                let linear = whiteMeasured.measuredColor.linearComponents(colorSpace: profile.colorSpace, dynamicRangeMode: profile.dynamicRangeMode)
                let xyz = ColorScience.linearRGBToXYZ(
                    r: linear.r,
                    g: linear.g,
                    b: linear.b,
                    colorSpace: profile.colorSpace
                )
                let X = xyz.X
                let Y = xyz.Y
                let Z = xyz.Z
                let sum = X+Y+Z
                if sum > 0 {
                    let x = X / sum, y = Y / sum
                    whiteCCT = ColorScience.correlatedColorTemperature(x: x, y: y)
                }
            }
        }

        let grayDeltaE = measurements.first(where: { $0.targetID == "gray" }).map { m -> Double in
            let targetColor = CalibrationTarget.sequence(for: displayEnvironment.dynamicRangeMode).first(where: { $0.id == "gray" })?
                .renderedRGBColor(colorSpace: profile.colorSpace) ?? .neutralGray
            let labTarget = ColorScience.rgbToLab(targetColor, colorSpace: profile.colorSpace)
            if let measuredXY = m.measuredXY {
                let labMeasured = ColorScience.xyYToLab(x: measuredXY.x, y: measuredXY.y, Y: measuredXY.Y)
                return ColorScience.deltaE2000(lab1: labTarget, lab2: labMeasured)
            } else {
                return ColorScience.deltaE2000(
                    color1: targetColor,
                    color2: m.measuredColor,
                    colorSpace: profile.colorSpace
                )
            }
        }

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
    @ObservationIgnored private let fullScreenWindow = CalibrationFullScreenWindow()
    @ObservationIgnored private var trackedScreen: NSScreen?

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
            return "Sample \(idx + 1) of \(CalibrationTarget.sequence(for: displayEnvironment.dynamicRangeMode).count)"
        }
        return "Ready"
    }

    var currentModeTitle: String { displayEnvironment.dynamicRangeMode.title }
    var currentProfile: CalibrationProfile? {
        store.profile(
            for: displayEnvironment.dynamicRangeMode,
            displayID: UInt32(displayEnvironment.displayID),
            colorSpace: displayEnvironment.colorSpace
        )
    }
    var currentProfileName: String { currentProfile?.name ?? "No \(currentModeTitle) calibration saved yet" }

    var unsupportedSettingDetectionNote: String {
        "These checks use a mix of public display APIs and private macOS frameworks. They are intended for internal use and may be unavailable on some Mac or display combinations."
    }

    /// True when the display is using YCbCr or limited-range signal, which invalidates calibration.
    var hasProblematicSignalFormat: Bool {
        displayConditions.snapshot.signal.ycbcrLikely || displayConditions.snapshot.signal.limitedRangeLikely
    }

    var signalWarningMessage: String {
        var issues: [String] = []
        if displayConditions.snapshot.signal.ycbcrLikely { issues.append("YCbCr encoding") }
        if displayConditions.snapshot.signal.limitedRangeLikely { issues.append("Limited Range (16-235)") }
        return "Display signal uses \(issues.joined(separator: " + ")), which alters color values before they reach the panel. Calibration results will be inaccurate. Switch to RGB Full Range (0-255) in System Settings → Displays."
    }

    // MARK: - Actions

    func startCalibrationButtonTapped() {
        guard peerSession.isConnected else { return }
        refreshDisplayEnvironment()
        if hasProblematicSignalFormat {
            statusLine = signalWarningMessage
            return
        }
        showDisplayPreparation = true
    }
    
    func switchMode(to mode: CalibrationMode) {
        currentMode = mode
        isMeasuring = false
        currentMeasurementColor = nil
        measurementHistory = []
        closeFullScreenPatch()
    }
    
    func startMeasurementMode() {
        guard peerSession.isConnected, currentMode == .measurement else { return }
        isMeasuring = true
        measurementHistory = []
        currentMeasurementColor = nil
        statusLine = "Measuring current display color with iPhone sensor..."
        
        // Request a single measurement from the white point target
        if let whiteTarget = CalibrationTarget.sequence(for: displayEnvironment.dynamicRangeMode).first(where: { $0.id == "white" }) {
            peerSession.sendCalibrationStep(index: 0, target: whiteTarget, colorSpace: displayEnvironment.colorSpace)
            startMeasurementTimeout()
        }
    }
    
    func stopMeasurementMode() {
        isMeasuring = false
        cancelMeasurementTimeout()
        closeFullScreenPatch()
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

    /// Compute a display-driven RGB patch for the active display color space.
    func displayRGB(for target: CalibrationTarget) -> RGBColor {
        target.renderedRGBColor(colorSpace: displayEnvironment.colorSpace)
    }

    func updateTrackedScreen(_ screen: NSScreen?) {
        trackedScreen = screen
        displayEnvironment = .current(screen: screen)
        displayConditions.refresh(displayID: displayEnvironment.displayID)
        updateFullScreenPatchIfNeeded()
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
            statusLine = "Applied \(profile.name) using the 1D gamma-table fallback. Confirm within \(confirmationCountdownSeconds) seconds or it will restore."
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
        guard CalibrationTarget.sequence(for: displayEnvironment.dynamicRangeMode).indices.contains(index) else { return }
        currentTargetIndex = index
        activeTarget = CalibrationTarget.sequence(for: displayEnvironment.dynamicRangeMode)[index]
        if let target = activeTarget {
            statusLine = target.instruction
            updateFullScreenPatchIfNeeded()
            peerSession.sendCalibrationStep(index: index, target: target, colorSpace: displayEnvironment.colorSpace)
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
            closeFullScreenPatch()
            
            if let profile = currentProfile {
                let targetWhite = CalibrationTarget.sequence(for: displayEnvironment.dynamicRangeMode).first(where: { $0.id == "white" })?
                    .renderedRGBColor(colorSpace: profile.colorSpace) ?? .white
                let corrected = targetWhite.applying(profile: profile)
                let preDE = deltaEFromMeasurement(measurement, targetColor: targetWhite, colorSpace: profile.colorSpace)
                let postDE = ColorScience.deltaE2000(
                    color1: targetWhite,
                    color2: corrected,
                    colorSpace: profile.colorSpace
                )
                statusLine = "Current: \(String(format: "%.2f", preDE)) ΔE (with profile: \(String(format: "%.2f", postDE)) ΔE)"
            } else {
                let targetWhite = CalibrationTarget.sequence(for: displayEnvironment.dynamicRangeMode).first(where: { $0.id == "white" })?
                    .renderedRGBColor(colorSpace: displayEnvironment.colorSpace) ?? .white
                let de = deltaEFromMeasurement(
                    measurement,
                    targetColor: targetWhite,
                    colorSpace: displayEnvironment.colorSpace
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
        if CalibrationTarget.sequence(for: displayEnvironment.dynamicRangeMode).indices.contains(next) {
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
        closeFullScreenPatch()
        restoreMeasurementBrightnessIfNeeded()
        statusLine = "iPhone disconnected. Calibration aborted."
    }

    private func finishCalibration() {
        currentTargetIndex = nil
        activeTarget = nil
        cancelMeasurementTimeout()
        showFullScreenCalibration = false
        closeFullScreenPatch()
        restoreMeasurementBrightnessIfNeeded()

        guard let profile = CalibrationProfile.from(
            measurements: measurements,
            dynamicRangeMode: displayEnvironment.dynamicRangeMode,
            displayID: UInt32(displayEnvironment.displayID),
            displayName: displayEnvironment.screenName,
            colorSpace: displayEnvironment.colorSpace
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
        let targetWhite = CalibrationTarget.sequence(for: displayEnvironment.dynamicRangeMode).first(where: { $0.id == "white" })?
            .renderedRGBColor(colorSpace: profile.colorSpace) ?? .white
        let preCalibDE = deltaEFromMeasurement(
            whiteMeasurement,
            targetColor: targetWhite,
            colorSpace: profile.colorSpace
        )
        let postCalibColor = targetWhite.applying(profile: profile)
        let postCalibDE = ColorScience.deltaE2000(
            color1: targetWhite,
            color2: postCalibColor,
            colorSpace: profile.colorSpace
        )
        
        let improvement = preCalibDE > 0 ? ((preCalibDE - postCalibDE) / preCalibDE) * 100 : 0
        
        return PrecisionReport(
            preCalibrationDeltaE: preCalibDE,
            postCalibrationDeltaE: postCalibDE,
            improvementPercent: improvement
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
            self.closeFullScreenPatch()
            self.restoreMeasurementBrightnessIfNeeded()
            self.statusLine = "Measurement timed out waiting for iPhone response. Check connection."
        }
    }

    private func cancelMeasurementTimeout() {
        measurementTimeoutTask?.cancel()
        measurementTimeoutTask = nil
    }

    // MARK: - Full Screen Patch

    private func updateFullScreenPatchIfNeeded() {
        guard showFullScreenCalibration, let target = activeTarget else {
            closeFullScreenPatch()
            return
        }

        let color = displayRGB(for: target)
        if fullScreenWindow.isVisible {
            fullScreenWindow.update(color: color)
        } else {
            fullScreenWindow.show(color: color, on: trackedScreen)
        }
    }

    private func closeFullScreenPatch() {
        fullScreenWindow.hide()
    }

    private func deltaEFromMeasurement(
        _ measurement: CalibrationMeasurement,
        targetColor: RGBColor,
        colorSpace: DisplayColorSpace
    ) -> Double {
        let labTarget = ColorScience.rgbToLab(targetColor, colorSpace: colorSpace)
        if let measuredXY = measurement.measuredXY {
            let labMeasured = ColorScience.xyYToLab(x: measuredXY.x, y: measuredXY.y, Y: measuredXY.Y)
            return ColorScience.deltaE2000(lab1: labTarget, lab2: labMeasured)
        }
        return ColorScience.deltaE2000(
            color1: targetColor,
            color2: measurement.measuredColor,
            colorSpace: colorSpace
        )
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
