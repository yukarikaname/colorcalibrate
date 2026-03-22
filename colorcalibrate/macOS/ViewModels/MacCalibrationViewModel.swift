//
//  MacCalibrationViewModel.swift
//  colorcalibrate-macOS
//
//  Created by Yukari Kaname on 3/22/26.
//

import AppKit
import Foundation
import Observation

struct DisplayEnvironmentSummary {
    var screenName: String
    var colorSpaceName: String
    var currentEDRHeadroom: Double
    var potentialEDRHeadroom: Double

    var hdrCapable: Bool {
        potentialEDRHeadroom > 1.05
    }

    // Inference from NSScreen EDR headroom: values above 1 usually mean HDR/EDR output is active.
    var hdrLikelyEnabled: Bool {
        currentEDRHeadroom > 1.05
    }

    var dynamicRangeMode: DisplayDynamicRangeMode {
        hdrLikelyEnabled ? .hdr : .sdr
    }

    static func current() -> DisplayEnvironmentSummary {
        let screen = NSScreen.main ?? NSScreen.screens.first
        return DisplayEnvironmentSummary(
            screenName: screen?.localizedName ?? "Current Display",
            colorSpaceName: screen?.colorSpace?.localizedName ?? "Unknown Color Space",
            currentEDRHeadroom: Double(
                screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0),
            potentialEDRHeadroom: Double(
                screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0)
        )
    }
}

@MainActor
@Observable
final class MacCalibrationViewModel {
    var store = CalibrationStore()
    var peerSession = PeerCalibrationSession(role: .macHost)
    var displayApplier = DisplayCalibrationApplier()
    var currentTargetIndex: Int?
    var activeTarget: CalibrationTarget?
    var measurements: [CalibrationMeasurement] = []
    var statusLine =
        "Connect an iPhone, point its front camera at the screen, and start calibration."
    var showDisplayPreparation = false
    var displayEnvironment = DisplayEnvironmentSummary.current()
    var pendingApplyConfirmation = false
    var pendingRestoreSeconds = 0

    @ObservationIgnored
    private var applyConfirmationTask: Task<Void, Never>?

    init() {
        peerSession.onMeasurement = { [weak self] measurement in
            self?.handleMeasurement(measurement)
        }
        RecalibrationScheduler.requestAuthorization()
        refreshDisplayEnvironment()
    }

    var progressText: String {
        guard let currentTargetIndex else { return "Ready" }
        return "Sample \(currentTargetIndex + 1) of \(CalibrationTarget.sequence.count)"
    }

    func startCalibrationButtonTapped() {
        guard peerSession.isConnected else { return }
        refreshDisplayEnvironment()
        showDisplayPreparation = true
    }

    func beginCalibrationAfterReview() {
        showDisplayPreparation = false
        startCalibration()
    }

    func openDisplaySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Displays-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.displays",
        ]

        for rawValue in urls {
            if let url = URL(string: rawValue), NSWorkspace.shared.open(url) {
                return
            }
        }

        let appURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.openApplication(
            at: appURL, configuration: .init(), completionHandler: nil)
    }

    func refreshDisplayEnvironment() {
        displayEnvironment = .current()
    }

    var currentModeTitle: String {
        displayEnvironment.dynamicRangeMode.title
    }

    var currentProfile: CalibrationProfile? {
        store.profile(for: displayEnvironment.dynamicRangeMode)
    }

    var currentProfileName: String {
        currentProfile?.name ?? "No \(currentModeTitle) calibration saved yet"
    }

    var unsupportedSettingDetectionNote: String {
        "Night Shift, True Tone, and YCbCr or limited-range output are not exposed through supported public macOS APIs, so the app cannot auto-detect them reliably."
    }

    private func startCalibration() {
        measurements = []
        statusLine = "Running \(currentModeTitle) calibration..."
        requestTarget(at: 0)
    }

    func applyCalibrationToDisplay() {
        refreshDisplayEnvironment()
        guard let profile = currentProfile else {
            statusLine =
                "No \(currentModeTitle) calibration is saved for the current display mode yet."
            return
        }

        displayApplier.apply(profile)
        if let lastErrorMessage = displayApplier.lastErrorMessage {
            statusLine = lastErrorMessage
        } else {
            startApplyConfirmationCountdown()
            statusLine =
                "Applied \(profile.name) to the display. Confirm within 10 seconds or it will restore automatically."
        }
    }

    func restoreCurrentDisplayState() {
        cancelApplyConfirmation()
        displayApplier.restoreCurrentSystemDisplayState()
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
            Task {
                await RecalibrationScheduler.scheduleReminder(
                    afterDays: store.settings.intervalDays)
            }
        }
    }

    private func requestTarget(at index: Int) {
        guard CalibrationTarget.sequence.indices.contains(index) else { return }
        currentTargetIndex = index
        activeTarget = CalibrationTarget.sequence[index]
        if let target = activeTarget {
            statusLine = target.instruction
            peerSession.sendCalibrationStep(index: index, target: target)
        }
    }

    private func handleMeasurement(_ measurement: CalibrationMeasurement) {
        measurements.removeAll { $0.targetID == measurement.targetID }
        measurements.append(measurement)

        guard let currentTargetIndex else { return }
        let nextIndex = currentTargetIndex + 1

        if CalibrationTarget.sequence.indices.contains(nextIndex) {
            requestTarget(at: nextIndex)
            return
        }

        finishCalibration()
    }

    private func finishCalibration() {
        currentTargetIndex = nil
        activeTarget = nil

        guard
            let profile = CalibrationProfile.from(
                measurements: measurements,
                dynamicRangeMode: displayEnvironment.dynamicRangeMode,
                displayName: displayEnvironment.screenName
            )
        else {
            statusLine = "Calibration data was incomplete. Try another pass."
            return
        }

        store.save(profile: profile)
        statusLine =
            "Saved \(profile.name). Apply it to the display to compare it against the current macOS color state."
        peerSession.sendFinishedProfile(profile)

        Task {
            await RecalibrationScheduler.scheduleReminder(
                afterDays: store.settings.intervalDays)
        }
    }

    private func startApplyConfirmationCountdown() {
        cancelApplyConfirmation()
        pendingApplyConfirmation = true
        pendingRestoreSeconds = 10

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
            statusLine =
                "Restored the current macOS display color state because the applied calibration was not confirmed."
        }
    }

    private func cancelApplyConfirmation() {
        applyConfirmationTask?.cancel()
        applyConfirmationTask = nil
        pendingApplyConfirmation = false
        pendingRestoreSeconds = 0
    }
}
