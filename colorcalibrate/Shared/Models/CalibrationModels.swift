import Foundation
import SwiftUI

enum DisplayDynamicRangeMode: String, Codable, Hashable, Sendable, CaseIterable {
    case sdr
    case hdr

    var suffix: String {
        rawValue.uppercased()
    }

    var title: String {
        self == .hdr ? "HDR" : "SDR"
    }
}

struct RGBColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = RGBColor(red: 0.02, green: 0.02, blue: 0.02)
    static let white = RGBColor(red: 1.0, green: 1.0, blue: 1.0)
    static let neutralGray = RGBColor(red: 0.5, green: 0.5, blue: 0.5)

    var swiftUIColor: Color {
        Color(red: clamped(red), green: clamped(green), blue: clamped(blue))
    }

    func applying(profile: CalibrationProfile?) -> RGBColor {
        guard let profile else { return clamped() }
        return RGBColor(
            red: clamped(red * profile.redGain + profile.redOffset),
            green: clamped(green * profile.greenGain + profile.greenOffset),
            blue: clamped(blue * profile.blueGain + profile.blueOffset)
        )
    }

    func clamped() -> RGBColor {
        RGBColor(red: clamped(red), green: clamped(green), blue: clamped(blue))
    }

    var description: String {
        "R \(Int(red * 255))  G \(Int(green * 255))  B \(Int(blue * 255))"
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }
}

struct CalibrationTarget: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let instruction: String
    let color: RGBColor

    static let sequence: [CalibrationTarget] = [
        CalibrationTarget(
            id: "white",
            title: "White Patch",
            subtitle: "Measure the screen's white point",
            instruction:
                "Point the iPhone front camera straight at the bright square and hold it about 8 to 12 cm from the screen.",
            color: .white
        ),
        CalibrationTarget(
            id: "red",
            title: "Red Patch",
            subtitle: "Measure red channel strength",
            instruction:
                "Keep the front camera centered on the red square and hold the same distance and angle.",
            color: RGBColor(red: 1.0, green: 0.12, blue: 0.12)
        ),
        CalibrationTarget(
            id: "green",
            title: "Green Patch",
            subtitle: "Measure green channel strength",
            instruction:
                "Keep the notch or Dynamic Island side facing the screen and centered on the patch.",
            color: RGBColor(red: 0.12, green: 1.0, blue: 0.18)
        ),
        CalibrationTarget(
            id: "blue",
            title: "Blue Patch",
            subtitle: "Measure blue channel strength",
            instruction:
                "Stay steady and keep reflections off the front camera while the blue patch is sampled.",
            color: RGBColor(red: 0.12, green: 0.22, blue: 1.0)
        ),
        CalibrationTarget(
            id: "gray",
            title: "Neutral Gray Patch",
            subtitle: "Measure neutral balance",
            instruction:
                "Keep the iPhone aligned with the screen for one last neutral-balance reading.",
            color: .neutralGray
        ),
    ]
}

struct CalibrationMeasurement: Codable, Hashable, Sendable {
    let targetID: String
    let measuredColor: RGBColor
    let capturedAt: Date
}

struct CalibrationProfile: Codable, Hashable, Sendable {
    let name: String
    let createdAt: Date
    let dynamicRangeMode: DisplayDynamicRangeMode
    let redGain: Double
    let greenGain: Double
    let blueGain: Double
    let redOffset: Double
    let greenOffset: Double
    let blueOffset: Double

    static let identity = CalibrationProfile(
        name: "Identity SDR",
        createdAt: .now,
        dynamicRangeMode: .sdr,
        redGain: 1.0,
        greenGain: 1.0,
        blueGain: 1.0,
        redOffset: 0.0,
        greenOffset: 0.0,
        blueOffset: 0.0
    )

    static func from(
        measurements: [CalibrationMeasurement],
        dynamicRangeMode: DisplayDynamicRangeMode,
        displayName: String
    ) -> CalibrationProfile? {
        let map = Dictionary(
            uniqueKeysWithValues: measurements.map { ($0.targetID, $0.measuredColor) })
        guard
            let white = map["white"],
            let red = map["red"],
            let green = map["green"],
            let blue = map["blue"]
        else {
            return nil
        }

        let whiteGainR = 1.0 / max(white.red, 0.05)
        let whiteGainG = 1.0 / max(white.green, 0.05)
        let whiteGainB = 1.0 / max(white.blue, 0.05)

        let redGain = ((1.0 / max(red.red, 0.05)) * 0.55) + (whiteGainR * 0.45)
        let greenGain = ((1.0 / max(green.green, 0.05)) * 0.55) + (whiteGainG * 0.45)
        let blueGain = ((1.0 / max(blue.blue, 0.05)) * 0.55) + (whiteGainB * 0.45)

        let redOffset = ((white.green + white.blue) * 0.5 - white.red) * 0.08
        let greenOffset = ((white.red + white.blue) * 0.5 - white.green) * 0.08
        let blueOffset = ((white.red + white.green) * 0.5 - white.blue) * 0.08

        return CalibrationProfile(
            name: "\(displayName) \(dynamicRangeMode.suffix)",
            createdAt: .now,
            dynamicRangeMode: dynamicRangeMode,
            redGain: clampGain(redGain),
            greenGain: clampGain(greenGain),
            blueGain: clampGain(blueGain),
            redOffset: clampOffset(redOffset),
            greenOffset: clampOffset(greenOffset),
            blueOffset: clampOffset(blueOffset)
        )
    }

    private static func clampGain(_ value: Double) -> Double {
        min(max(value, 0.55), 1.75)
    }

    private static func clampOffset(_ value: Double) -> Double {
        min(max(value, -0.12), 0.12)
    }
}

enum PreviewMode: String, Codable {
    case original
    case calibrated
}

struct RecalibrationSettings: Codable {
    var intervalDays: Int

    static let `default` = RecalibrationSettings(intervalDays: 180)
}

struct SwatchExample: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let color: RGBColor

    static let examples: [SwatchExample] = [
        SwatchExample(title: "Paper White", detail: "UI backgrounds", color: .white),
        SwatchExample(title: "Neutral Gray", detail: "Typography balance", color: .neutralGray),
        SwatchExample(
            title: "Accent Red", detail: "Warm tones",
            color: RGBColor(red: 0.92, green: 0.22, blue: 0.25)),
        SwatchExample(
            title: "Accent Green", detail: "Mid-spectrum",
            color: RGBColor(red: 0.18, green: 0.82, blue: 0.35)),
        SwatchExample(
            title: "Accent Blue", detail: "Cool tones",
            color: RGBColor(red: 0.16, green: 0.46, blue: 0.95)),
        SwatchExample(title: "Deep Black", detail: "Contrast floor", color: .black),
    ]
}
