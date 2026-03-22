//
//  DisplayCalibrationApplier.swift
//  colorcalibrate-macOS
//
//  Created by Yukari Kaname on 3/22/26.
//

import AppKit
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class DisplayCalibrationApplier {
    private(set) var isCalibrationApplied = false
    private(set) var lastErrorMessage: String?

    func apply(_ profile: CalibrationProfile) {
        let displayID = CGMainDisplayID()
        let sampleCount: UInt32 = 256
        let values = buildTransferTable(for: profile, sampleCount: Int(sampleCount))

        let result = values.red.withUnsafeBufferPointer { redBuffer in
            values.green.withUnsafeBufferPointer { greenBuffer in
                values.blue.withUnsafeBufferPointer { blueBuffer in
                    CGSetDisplayTransferByTable(
                        displayID,
                        sampleCount,
                        redBuffer.baseAddress,
                        greenBuffer.baseAddress,
                        blueBuffer.baseAddress
                    )
                }
            }
        }

        if result == .success {
            isCalibrationApplied = true
            lastErrorMessage = nil
        } else {
            isCalibrationApplied = false
            lastErrorMessage = "Could not apply the display calibration to the current screen."
        }
    }

    func restoreCurrentSystemDisplayState() {
        CGDisplayRestoreColorSyncSettings()
        isCalibrationApplied = false
        lastErrorMessage = nil
    }

    private func buildTransferTable(for profile: CalibrationProfile, sampleCount: Int) -> (
        red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue]
    ) {
        let denominator = max(sampleCount - 1, 1)

        let red = (0..<sampleCount).map { index in
            transformSample(
                Double(index) / Double(denominator), gain: profile.redGain,
                offset: profile.redOffset)
        }
        let green = (0..<sampleCount).map { index in
            transformSample(
                Double(index) / Double(denominator), gain: profile.greenGain,
                offset: profile.greenOffset)
        }
        let blue = (0..<sampleCount).map { index in
            transformSample(
                Double(index) / Double(denominator), gain: profile.blueGain,
                offset: profile.blueOffset)
        }

        return (red, green, blue)
    }

    private func transformSample(_ value: Double, gain: Double, offset: Double) -> CGGammaValue {
        let corrected = min(max((value * gain) + offset, 0.0), 1.0)
        return CGGammaValue(corrected)
    }
}
