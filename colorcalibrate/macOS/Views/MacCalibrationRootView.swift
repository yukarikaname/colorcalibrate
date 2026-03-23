//
//  MacCalibrationRootView.swift
//  colorcalibrate
//
//  Created by Yukari Kaname on 3/22/26.
//

import SwiftUI

struct MacCalibrationRootView: View {
    @State private var model = MacCalibrationViewModel()
    @State private var reminderDaysText = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Color Calibrate")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(
                    "Use the iPhone front camera as the sensor while the Mac displays calibration patches."
                )
                .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    StatusPill(
                        label: "Connection", value: model.peerSession.connectionDescription)
                    StatusPill(label: "Progress", value: model.progressText)
                    StatusPill(label: "Mode", value: model.currentModeTitle)
                }

                if let target = model.activeTarget {
                    CalibrationHeroCard(
                        title: target.title,
                        subtitle: target.subtitle,
                        color: target.color,
                        profile: nil
                    )
                } else {
                    CalibrationHeroCard(
                        title: "Ready to Calibrate",
                        subtitle:
                            "Start a pass when the iPhone is connected and pointed at the display.",
                        color: RGBColor(red: 0.92, green: 0.94, blue: 1.0),
                        profile: nil
                    )
                }

                HStack(spacing: 12) {
                    Button("Start Calibration") {
                        model.startCalibrationButtonTapped()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.peerSession.isConnected)

                    Button("Apply \(model.currentModeTitle) Profile") {
                        model.applyCalibrationToDisplay()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.currentProfile == nil)

                    Button("Restore Current Display") {
                        model.restoreCurrentDisplayState()
                    }
                    .buttonStyle(.bordered)
                }

                Text(model.statusLine)
                    .font(.headline)

                if let error = model.displayApplier.lastErrorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }

                if model.pendingApplyConfirmation {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Keep Applied Calibration?")
                            .font(.title3.bold())
                        Text(
                            "The display will restore automatically in \(model.pendingRestoreSeconds) seconds unless you confirm that you want to keep the applied calibration active."
                        )
                        .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button("Keep Applied") {
                                model.confirmAppliedCalibration()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Restore Now") {
                                model.restoreCurrentDisplayState()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Use The Result On The Real Display")
                        .font(.title3.bold())
                    Text(
                        "The calibrated comparison now applies to the screen itself instead of a preview inside this app. Use the mode-specific apply button to see the adjusted output, then use Restore Current Display to return to the active macOS color state."
                    )
                    .foregroundStyle(.secondary)
                    Text(
                        "macOS does not provide a supported public API for this app to directly switch the selected profile in Displays settings. Use Open Display Settings to review the current display color setup after calibration."
                    )
                    .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        StatusPill(
                            label: "Display Apply",
                            value: model.displayApplier.isCalibrationApplied
                                ? "Calibrated output active"
                                : "Current macOS color state active")
                        StatusPill(label: "Saved Profile", value: model.currentProfileName)

                        Button("Open Display Settings") {
                            model.openDisplaySettings()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recalibration Reminder")
                        .font(.title3.bold())
                    HStack(alignment: .center, spacing: 12) {
                        Text("Remind again after")
                        TextField("180", text: $reminderDaysText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onSubmit {
                                applyReminderDays()
                            }
                        Text("days")
                    }

                    Text("Type a value from 7 to 730 days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let nextReminderDate = model.store.nextReminderDate {
                        Text(
                            "Next reminder: \(nextReminderDate.formatted(date: .abbreviated, time: .omitted))"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
            }
            .padding(28)
        }
        .frame(minWidth: 920, minHeight: 760)
        .background(
            LinearGradient(
                colors: colorScheme == .dark
                    ? [
                        Color(red: 0.09, green: 0.11, blue: 0.14),
                        Color(red: 0.14, green: 0.18, blue: 0.24),
                    ]
                    : [
                        Color(red: 0.95, green: 0.97, blue: 1.0),
                        Color(red: 0.89, green: 0.93, blue: 0.98),
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .sheet(isPresented: $model.showDisplayPreparation) {
            DisplayPreparationSheet(model: model)
        }
        .background {
            ScreenTrackingView { screen in
                model.updateTrackedScreen(screen)
            }
        }
        .onAppear {
            reminderDaysText = String(model.store.settings.intervalDays)
        }
        .onChange(of: model.store.settings.intervalDays) { _, newValue in
            reminderDaysText = String(newValue)
        }
    }

    private func applyReminderDays() {
        let digits = reminderDaysText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedDays = Int(digits) ?? model.store.settings.intervalDays
        let clampedDays = min(max(parsedDays, 7), 730)
        model.updateReminder(days: clampedDays)
        reminderDaysText = String(clampedDays)
    }
}

private struct ScreenTrackingView: NSViewRepresentable {
    let onScreenChange: (NSScreen?) -> Void

    func makeNSView(context: Context) -> ScreenObserverView {
        let view = ScreenObserverView()
        view.onScreenChange = onScreenChange
        return view
    }

    func updateNSView(_ nsView: ScreenObserverView, context: Context) {
        nsView.onScreenChange = onScreenChange
        nsView.reportCurrentScreenIfPossible()
    }
}

private final class ScreenObserverView: NSView {
    var onScreenChange: ((NSScreen?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportCurrentScreenIfPossible()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportCurrentScreenIfPossible()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reportCurrentScreenIfPossible()
    }

    func reportCurrentScreenIfPossible() {
        DispatchQueue.main.async { [weak self] in
            self?.onScreenChange?(self?.window?.screen)
        }
    }
}

private struct DisplayPreparationSheet: View {
    @Bindable var model: MacCalibrationViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Prepare The Display")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text(
                "This app calibrates in the display mode macOS is currently using, so an HDR screen state produces an HDR profile and an SDR screen state produces an SDR profile."
            )
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text("Auto-Detected Environment")
                    .font(.headline)
                StatusPill(label: "Display", value: model.displayEnvironment.screenName)
                StatusPill(label: "Color Space", value: model.displayEnvironment.colorSpaceName)
                StatusPill(label: "Calibration Mode", value: model.currentModeTitle)
                StatusPill(
                    label: "EDR Headroom",
                    value: String(
                        format: "%.2f current / %.2f potential",
                        model.displayEnvironment.currentEDRHeadroom,
                        model.displayEnvironment.potentialEDRHeadroom))

                if model.displayEnvironment.hdrLikelyEnabled {
                    Text(
                        "HDR or EDR output looks active, so this pass will be saved as an HDR calibration."
                    )
                    .foregroundStyle(.secondary)
                } else if model.displayEnvironment.hdrCapable {
                    Text(
                        "HDR is not active right now, so this pass will be saved as an SDR calibration."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))

            VStack(alignment: .leading, spacing: 12) {
                Text("Automatic Checks")
                    .font(.headline)
                StatusPill(
                    label: "Night Shift",
                    value: model.displayConditions.snapshot.nightShift.description)
                StatusPill(
                    label: "True Tone",
                    value: model.displayConditions.snapshot.trueTone.description)
                StatusPill(
                    label: "Signal",
                    value: model.displayConditions.snapshot.signal.signalDescription)
                StatusPill(
                    label: "Pixel Encoding",
                    value: model.displayConditions.snapshot.signal.pixelEncoding)
                StatusPill(
                    label: "Brightness",
                    value: model.displayConditions.snapshot.brightnessDescription)
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))

            if model.displayConditions.snapshot.signal.ycbcrLikely
                || model.displayConditions.snapshot.signal.limitedRangeLikely
                || model.displayConditions.snapshot.nightShift == .enabled
                || model.displayConditions.snapshot.trueTone == .enabled
            {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Result Risk")
                        .font(.headline)

                    if model.displayConditions.snapshot.nightShift == .enabled {
                        Text("Night Shift is on, so the measured white balance will be skewed warmer.")
                            .foregroundStyle(.secondary)
                    }

                    if model.displayConditions.snapshot.trueTone == .enabled {
                        Text("True Tone is on, so the display can keep adapting while you measure.")
                            .foregroundStyle(.secondary)
                    }

                    if model.displayConditions.snapshot.signal.ycbcrLikely {
                        Text("The display signal looks like YCbCr instead of RGB, which can distort patch accuracy.")
                            .foregroundStyle(.secondary)
                    }

                    if model.displayConditions.snapshot.signal.limitedRangeLikely {
                        Text("The signal also looks limited-range, so dark and bright samples can clip differently.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            }

            Text(model.unsupportedSettingDetectionNote)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Open Display Settings") {
                    model.openDisplaySettings()
                }

                Spacer()

                Button("Cancel") {
                    model.showDisplayPreparation = false
                }

                Button("Begin \(model.currentModeTitle) Calibration") {
                    model.beginCalibrationAfterReview()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 680)
        .background(
            LinearGradient(
                colors: colorScheme == .dark
                    ? [
                        Color(red: 0.1, green: 0.11, blue: 0.14),
                        Color(red: 0.15, green: 0.17, blue: 0.22),
                    ]
                    : [
                        Color(red: 0.98, green: 0.99, blue: 1.0),
                        Color(red: 0.94, green: 0.96, blue: 0.99),
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}
