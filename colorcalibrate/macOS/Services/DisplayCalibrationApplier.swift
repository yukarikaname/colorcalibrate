//
//  DisplayCalibrationApplier.swift
//  colorcalibrate
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

    func apply(_ profile: CalibrationProfile, to displayID: CGDirectDisplayID) {
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

        // Extract diagonal elements of the 3x3 matrix as effective per-channel gains.
        // A 1D gamma table cannot represent cross-channel corrections, but using the
        // diagonal ensures the table is at least consistent with the matrix along the
        // neutral axis. The full 3x3 matrix is applied in software preview via
        // `previewCorrectedColor`.
        let matrixGainR = profile.matrix.count == 9 ? profile.matrix[0] : 1.0
        let matrixGainG = profile.matrix.count == 9 ? profile.matrix[4] : 1.0
        let matrixGainB = profile.matrix.count == 9 ? profile.matrix[8] : 1.0

        let effectiveGainR = matrixGainR * profile.fallbackRedGain
        let effectiveGainG = matrixGainG * profile.fallbackGreenGain
        let effectiveGainB = matrixGainB * profile.fallbackBlueGain

        let red = (0..<sampleCount).map { index in
            transformSample(
                Double(index) / Double(denominator), gain: effectiveGainR,
                offset: profile.fallbackRedOffset)
        }
        let green = (0..<sampleCount).map { index in
            transformSample(
                Double(index) / Double(denominator), gain: effectiveGainG,
                offset: profile.fallbackGreenOffset)
        }
        let blue = (0..<sampleCount).map { index in
            transformSample(
                Double(index) / Double(denominator), gain: effectiveGainB,
                offset: profile.fallbackBlueOffset)
        }

        return (red, green, blue)
    }

    private func transformSample(_ value: Double, gain: Double, offset: Double) -> CGGammaValue {
        let corrected = min(max((value * gain) + offset, 0.0), 1.0)
        return CGGammaValue(corrected)
    }
}
