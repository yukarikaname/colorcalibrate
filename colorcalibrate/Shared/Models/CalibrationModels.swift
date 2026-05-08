//
//  CalibrationModels.swift
//  colorcalibrate
//
//  Created by Yukari Kaname on 3/22/26.
//

import Foundation
import SwiftUI

enum DisplayDynamicRangeMode: String, Codable, Hashable, Sendable, CaseIterable {
    case sdr
    case edr
    case hdr

    var suffix: String {
        rawValue.uppercased()
    }

    var title: String {
        switch self {
        case .sdr: return "SDR"
        case .edr: return "EDR"
        case .hdr: return "HDR"
        }
    }

    /// Whether this mode uses extended range (values can exceed 1.0).
    var isExtendedRange: Bool {
        switch self {
        case .sdr: return false
        case .edr, .hdr: return true
        }
    }
}

enum SensorConservativeEstimate {
    static let luxErrorPercent: Double = 5.0
    static let chromaticityError: Double = 0.002
    static let estimatedAccuracyPercent: Double = 95.0
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
        return profile.previewCorrectedColor(self)
    }

    func clamped() -> RGBColor {
        RGBColor(red: clamped(red), green: clamped(green), blue: clamped(blue))
    }

    func linearComponents(
        colorSpace: DisplayColorSpace,
        dynamicRangeMode: DisplayDynamicRangeMode = .sdr
    ) -> (r: Double, g: Double, b: Double) {
        (
            ColorScience.decode(red, colorSpace: colorSpace, dynamicRangeMode: dynamicRangeMode),
            ColorScience.decode(green, colorSpace: colorSpace, dynamicRangeMode: dynamicRangeMode),
            ColorScience.decode(blue, colorSpace: colorSpace, dynamicRangeMode: dynamicRangeMode)
        )
    }

    static func fromLinear(
        _ linear: (r: Double, g: Double, b: Double),
        colorSpace: DisplayColorSpace,
        dynamicRangeMode: DisplayDynamicRangeMode = .sdr
    ) -> RGBColor {
        RGBColor(
            red: clamped(ColorScience.encode(linear.r, colorSpace: colorSpace, dynamicRangeMode: dynamicRangeMode)),
            green: clamped(ColorScience.encode(linear.g, colorSpace: colorSpace, dynamicRangeMode: dynamicRangeMode)),
            blue: clamped(ColorScience.encode(linear.b, colorSpace: colorSpace, dynamicRangeMode: dynamicRangeMode))
        )
    }

    var description: String {
        "R \(Int(red * 255))  G \(Int(green * 255))  B \(Int(blue * 255))"
    }

    /// Clamps a component value to the valid encoded RGB range [0, 1].
    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }

    private func clamped(_ value: Double) -> Double {
        Self.clamp(value)
    }

    private static func clamped(_ value: Double) -> Double {
        Self.clamp(value)
    }
}

struct Chromaticity: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let Y: Double
}

struct CalibrationTarget: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let instruction: String
    let color: RGBColor
    /// Device-independent target chromaticity (CIE 1931 xyY). If present, used as the
    /// authoritative target color for device-independent calibration. `Y` is relative
    /// luminance (unitless; typical white target use 1.0).
    let xyY: Chromaticity?

    // MARK: - Target Sequences

    /// SDR calibration targets — D65 white plus RGB primaries and 50% gray.
    private static let sdrSequence: [CalibrationTarget] = [
        CalibrationTarget(
            id: "white",
            title: "White Patch",
            subtitle: "Measure the screen's white point",
            instruction:
                "Point the iPhone front camera straight at the bright square and hold it about 8 to 12 cm from the screen.",
            color: .white,
            xyY: Chromaticity(x: 0.3127, y: 0.3290, Y: 1.0)
        ),
        CalibrationTarget(
            id: "red",
            title: "Red Patch",
            subtitle: "Measure red channel strength",
            instruction:
                "Keep the front camera centered on the red square and hold the same distance and angle.",
            color: RGBColor(red: 1.0, green: 0.12, blue: 0.12),
            xyY: Chromaticity(x: 0.680, y: 0.320, Y: 0.5)
        ),
        CalibrationTarget(
            id: "green",
            title: "Green Patch",
            subtitle: "Measure green channel strength",
            instruction:
                "Keep the notch or Dynamic Island side facing the screen and centered on the patch.",
            color: RGBColor(red: 0.12, green: 1.0, blue: 0.18),
            xyY: Chromaticity(x: 0.265, y: 0.690, Y: 0.5)
        ),
        CalibrationTarget(
            id: "blue",
            title: "Blue Patch",
            subtitle: "Measure blue channel strength",
            instruction:
                "Stay steady and keep reflections off the front camera while the blue patch is sampled.",
            color: RGBColor(red: 0.12, green: 0.22, blue: 1.0),
            xyY: Chromaticity(x: 0.150, y: 0.060, Y: 0.5)
        ),
        CalibrationTarget(
            id: "gray",
            title: "Neutral Gray Patch",
            subtitle: "Measure neutral balance",
            instruction:
                "Keep the iPhone aligned with the screen for one last neutral-balance reading.",
            color: .neutralGray,
            xyY: Chromaticity(x: 0.3127, y: 0.3290, Y: 0.5)
        ),
    ]

    /// HDR calibration targets — extends SDR with a highlight patch to sample EDR headroom.
    private static let hdrSequence: [CalibrationTarget] = sdrSequence + [
        CalibrationTarget(
            id: "hdr-highlight",
            title: "HDR Highlight",
            subtitle: "Measure EDR headroom response",
            instruction:
                "Point the iPhone at the bright highlight patch. This samples the display's extended dynamic range.",
            color: RGBColor(red: 2.0, green: 2.0, blue: 2.0),
            xyY: Chromaticity(x: 0.3127, y: 0.3290, Y: 2.0)
        ),
    ]

    /// Returns the appropriate calibration target sequence for the given dynamic range mode.
    static func sequence(for dynamicRangeMode: DisplayDynamicRangeMode) -> [CalibrationTarget] {
        dynamicRangeMode == .hdr ? hdrSequence : sdrSequence
    }

    /// Legacy SDR target sequence. Prefer `sequence(for:)` when the dynamic range mode is known.
    @available(*, deprecated, message: "Use sequence(for:) instead")
    static let sequence: [CalibrationTarget] = sdrSequence

    func renderedRGBColor(colorSpace: DisplayColorSpace, dynamicRangeMode: DisplayDynamicRangeMode = .sdr) -> RGBColor {
        guard let xyY else { return color.clamped() }
        return ColorScience.xyYToRGBColor(x: xyY.x, y: xyY.y, Y: xyY.Y, colorSpace: colorSpace, dynamicRangeMode: dynamicRangeMode)
    }
}

struct CalibrationMeasurement: Codable, Hashable, Sendable {
    let targetID: String
    let measuredColor: RGBColor
    /// Measured chromaticity returned by the sensor (if available).
    let measuredXY: Chromaticity?
    let capturedAt: Date
    let colorStability: Double?      // 0-1, stability at measurement time
    
    init(
        targetID: String,
        measuredColor: RGBColor,
        measuredXY: Chromaticity? = nil,
        capturedAt: Date,
        colorStability: Double? = nil
    ) {
        self.targetID = targetID
        self.measuredColor = measuredColor
        self.measuredXY = measuredXY
        self.capturedAt = capturedAt
        self.colorStability = colorStability
    }
}

struct CalibrationProfile: Codable, Hashable, Sendable {
    let name: String
    let createdAt: Date
    let displayID: UInt32
    let displayName: String
    let colorSpace: DisplayColorSpace
    let dynamicRangeMode: DisplayDynamicRangeMode
    /// 3x3 correction matrix in row-major order. Used for app preview/reporting.
    let matrix: [Double]
    /// Per-channel 1D fallback for CoreGraphics gamma table application.
    let fallbackRedGain: Double
    let fallbackGreenGain: Double
    let fallbackBlueGain: Double
    let fallbackRedOffset: Double
    let fallbackGreenOffset: Double
    let fallbackBlueOffset: Double

    var redGain: Double { fallbackRedGain }
    var greenGain: Double { fallbackGreenGain }
    var blueGain: Double { fallbackBlueGain }
    var redOffset: Double { fallbackRedOffset }
    var greenOffset: Double { fallbackGreenOffset }
    var blueOffset: Double { fallbackBlueOffset }

    static let identity = CalibrationProfile(
        name: "Identity SDR",
        createdAt: .now,
        displayID: 0,
        displayName: "Current Display",
        colorSpace: .unknownSRGBFallback,
        dynamicRangeMode: .sdr,
        matrix: [1,0,0, 0,1,0, 0,0,1],
        fallbackRedGain: 1.0,
        fallbackGreenGain: 1.0,
        fallbackBlueGain: 1.0,
        fallbackRedOffset: 0.0,
        fallbackGreenOffset: 0.0,
        fallbackBlueOffset: 0.0
    )

    static func from(
        measurements: [CalibrationMeasurement],
        dynamicRangeMode: DisplayDynamicRangeMode,
        displayID: UInt32,
        displayName: String,
        colorSpace: DisplayColorSpace
    ) -> CalibrationProfile? {
        let measurementByID = Dictionary(uniqueKeysWithValues: measurements.map { ($0.targetID, $0) })
        let requiredIDs = ["white", "red", "green", "blue"]
        guard requiredIDs.allSatisfy({ measurementByID[$0] != nil }) else {
            return nil
        }

        var rows: [[Double]] = []
        var cols: [Double] = []

        for target in CalibrationTarget.sequence(for: dynamicRangeMode) {
            guard let measurement = measurementByID[target.id] else { continue }

            let measuredLinear: (r: Double, g: Double, b: Double)
            if let mxy = measurement.measuredXY {
                let xyz = ColorScience.xyYToXYZ(x: mxy.x, y: mxy.y, Y: mxy.Y)
                measuredLinear = ColorScience.xyzToLinearRGB(
                    xyz.X,
                    xyz.Y,
                    xyz.Z,
                    colorSpace: colorSpace
                )
            } else {
                measuredLinear = measurement.measuredColor.linearComponents(colorSpace: colorSpace, dynamicRangeMode: dynamicRangeMode)
            }

            let targetLinear = target.renderedRGBColor(colorSpace: colorSpace)
                .linearComponents(colorSpace: colorSpace, dynamicRangeMode: dynamicRangeMode)

            rows.append([measuredLinear.r, measuredLinear.g, measuredLinear.b, 0,0,0, 0,0,0])
            cols.append(targetLinear.r)
            rows.append([0,0,0, measuredLinear.r, measuredLinear.g, measuredLinear.b, 0,0,0])
            cols.append(targetLinear.g)
            rows.append([0,0,0, 0,0,0, measuredLinear.r, measuredLinear.g, measuredLinear.b])
            cols.append(targetLinear.b)
        }

        guard !rows.isEmpty else { return nil }

        let A = rows
        let At = transpose(A)
        let solution = solveLinear(matMul(At, A), matVecMul(At, cols))
            ?? [1,0,0, 0,1,0, 0,0,1]

        let gR = clampGain(solution[0])
        let gG = clampGain(solution[4])
        let gB = clampGain(solution[8])

        return CalibrationProfile(
            name: "\(displayName) \(colorSpace.title) \(dynamicRangeMode.suffix)",
            createdAt: .now,
            displayID: displayID,
            displayName: displayName,
            colorSpace: colorSpace,
            dynamicRangeMode: dynamicRangeMode,
            matrix: solution,
            fallbackRedGain: gR,
            fallbackGreenGain: gG,
            fallbackBlueGain: gB,
            fallbackRedOffset: 0.0,
            fallbackGreenOffset: 0.0,
            fallbackBlueOffset: 0.0
        )
    }

    func previewCorrectedColor(_ color: RGBColor) -> RGBColor {
        let linear = color.linearComponents(colorSpace: colorSpace, dynamicRangeMode: dynamicRangeMode)
        let corrected = Self.multiply(matrix: normalizedMatrix, vector: linear)
        return RGBColor.fromLinear(corrected, colorSpace: colorSpace, dynamicRangeMode: dynamicRangeMode)
    }

    func matches(displayID: UInt32, colorSpace: DisplayColorSpace, dynamicRangeMode: DisplayDynamicRangeMode) -> Bool {
        self.displayID == displayID
            && self.colorSpace == colorSpace
            && self.dynamicRangeMode == dynamicRangeMode
    }

    enum CodingKeys: String, CodingKey {
        case name
        case createdAt
        case displayID
        case displayName
        case colorSpace
        case dynamicRangeMode
        case matrix
        case fallbackRedGain
        case fallbackGreenGain
        case fallbackBlueGain
        case fallbackRedOffset
        case fallbackGreenOffset
        case fallbackBlueOffset
        case legacyRedGain = "redGain"
        case legacyGreenGain = "greenGain"
        case legacyBlueGain = "blueGain"
        case legacyRedOffset = "redOffset"
        case legacyGreenOffset = "greenOffset"
        case legacyBlueOffset = "blueOffset"
    }

    init(
        name: String,
        createdAt: Date,
        displayID: UInt32,
        displayName: String,
        colorSpace: DisplayColorSpace,
        dynamicRangeMode: DisplayDynamicRangeMode,
        matrix: [Double],
        fallbackRedGain: Double,
        fallbackGreenGain: Double,
        fallbackBlueGain: Double,
        fallbackRedOffset: Double,
        fallbackGreenOffset: Double,
        fallbackBlueOffset: Double
    ) {
        self.name = name
        self.createdAt = createdAt
        self.displayID = displayID
        self.displayName = displayName
        self.colorSpace = colorSpace
        self.dynamicRangeMode = dynamicRangeMode
        self.matrix = matrix.count == 9 ? matrix : [1,0,0, 0,1,0, 0,0,1]
        self.fallbackRedGain = fallbackRedGain
        self.fallbackGreenGain = fallbackGreenGain
        self.fallbackBlueGain = fallbackBlueGain
        self.fallbackRedOffset = fallbackRedOffset
        self.fallbackGreenOffset = fallbackGreenOffset
        self.fallbackBlueOffset = fallbackBlueOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let dynamicRangeMode = try container.decode(DisplayDynamicRangeMode.self, forKey: .dynamicRangeMode)
        let matrix = try container.decodeIfPresent([Double].self, forKey: .matrix)
            ?? [1,0,0, 0,1,0, 0,0,1]

        self.init(
            name: name,
            createdAt: createdAt,
            displayID: try container.decodeIfPresent(UInt32.self, forKey: .displayID) ?? 0,
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName) ?? name,
            colorSpace: try container.decodeIfPresent(DisplayColorSpace.self, forKey: .colorSpace)
                ?? .unknownSRGBFallback,
            dynamicRangeMode: dynamicRangeMode,
            matrix: matrix,
            fallbackRedGain: try Self.decodeDouble(
                from: container,
                primary: .fallbackRedGain,
                legacy: .legacyRedGain,
                defaultValue: 1.0
            ),
            fallbackGreenGain: try Self.decodeDouble(
                from: container,
                primary: .fallbackGreenGain,
                legacy: .legacyGreenGain,
                defaultValue: 1.0
            ),
            fallbackBlueGain: try Self.decodeDouble(
                from: container,
                primary: .fallbackBlueGain,
                legacy: .legacyBlueGain,
                defaultValue: 1.0
            ),
            fallbackRedOffset: try Self.decodeDouble(
                from: container,
                primary: .fallbackRedOffset,
                legacy: .legacyRedOffset,
                defaultValue: 0.0
            ),
            fallbackGreenOffset: try Self.decodeDouble(
                from: container,
                primary: .fallbackGreenOffset,
                legacy: .legacyGreenOffset,
                defaultValue: 0.0
            ),
            fallbackBlueOffset: try Self.decodeDouble(
                from: container,
                primary: .fallbackBlueOffset,
                legacy: .legacyBlueOffset,
                defaultValue: 0.0
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(displayID, forKey: .displayID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(colorSpace, forKey: .colorSpace)
        try container.encode(dynamicRangeMode, forKey: .dynamicRangeMode)
        try container.encode(normalizedMatrix, forKey: .matrix)
        try container.encode(fallbackRedGain, forKey: .fallbackRedGain)
        try container.encode(fallbackGreenGain, forKey: .fallbackGreenGain)
        try container.encode(fallbackBlueGain, forKey: .fallbackBlueGain)
        try container.encode(fallbackRedOffset, forKey: .fallbackRedOffset)
        try container.encode(fallbackGreenOffset, forKey: .fallbackGreenOffset)
        try container.encode(fallbackBlueOffset, forKey: .fallbackBlueOffset)
    }

    private var normalizedMatrix: [Double] {
        matrix.count == 9 ? matrix : [1,0,0, 0,1,0, 0,0,1]
    }

    private static func decodeDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        primary: CodingKeys,
        legacy: CodingKeys,
        defaultValue: Double
    ) throws -> Double {
        if let value = try container.decodeIfPresent(Double.self, forKey: primary) {
            return value
        }
        return try container.decodeIfPresent(Double.self, forKey: legacy) ?? defaultValue
    }

    private static func transpose(_ m: [[Double]]) -> [[Double]] {
        guard let c = m.first?.count else { return [] }
        var t = Array(repeating: Array(repeating: 0.0, count: m.count), count: c)
        for i in 0..<m.count {
            for j in 0..<c { t[j][i] = m[i][j] }
        }
        return t
    }

    private static func matMul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        guard let aCols = a.first?.count, aCols == b.count, let bCols = b.first?.count else {
            return []
        }
        var out = Array(repeating: Array(repeating: 0.0, count: bCols), count: a.count)
        for i in 0..<a.count {
            for j in 0..<bCols {
                var sum = 0.0
                for k in 0..<aCols {
                    sum += a[i][k] * b[k][j]
                }
                out[i][j] = sum
            }
        }
        return out
    }

    private static func matVecMul(_ a: [[Double]], _ v: [Double]) -> [Double] {
        a.map { row in row.enumerated().reduce(0.0) { $0 + $1.element * v[$1.offset] } }
    }

    private static func solveLinear(_ matrix: [[Double]], _ values: [Double]) -> [Double]? {
        var a = matrix
        var b = values
        let n = a.count
        guard n == b.count, a.allSatisfy({ $0.count == n }) else { return nil }

        for i in 0..<n {
            var maxRow = i
            var maxValue = abs(a[i][i])
            for row in (i + 1)..<n where abs(a[row][i]) > maxValue {
                maxValue = abs(a[row][i])
                maxRow = row
            }
            if maxValue < 1e-12 { return nil }
            if maxRow != i {
                a.swapAt(i, maxRow)
                b.swapAt(i, maxRow)
            }

            let pivot = a[i][i]
            for column in i..<n {
                a[i][column] /= pivot
            }
            b[i] /= pivot

            for row in 0..<n where row != i {
                let factor = a[row][i]
                if factor == 0 { continue }
                for column in i..<n {
                    a[row][column] -= factor * a[i][column]
                }
                b[row] -= factor * b[i]
            }
        }

        return b
    }

    private static func multiply(
        matrix: [Double],
        vector: (r: Double, g: Double, b: Double)
    ) -> (r: Double, g: Double, b: Double) {
        guard matrix.count == 9 else { return vector }
        return (
            matrix[0] * vector.r + matrix[1] * vector.g + matrix[2] * vector.b,
            matrix[3] * vector.r + matrix[4] * vector.g + matrix[5] * vector.b,
            matrix[6] * vector.r + matrix[7] * vector.g + matrix[8] * vector.b
        )
    }

    private static func clampGain(_ value: Double) -> Double {
        min(max(value, 0.55), 1.75)
    }
}

enum PreviewMode: String, Codable {
    case original
    case calibrated
}

struct RecalibrationSettings: Codable {
    var intervalDays: Int
    var recalibrateAlertEnabled: Bool

    static let `default` = RecalibrationSettings(intervalDays: 180, recalibrateAlertEnabled: false)

    // Codable conformance for backward compatibility
    enum CodingKeys: String, CodingKey {
        case intervalDays
        case recalibrateAlertEnabled
    }

    init(intervalDays: Int, recalibrateAlertEnabled: Bool = false) {
        self.intervalDays = intervalDays
        self.recalibrateAlertEnabled = recalibrateAlertEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intervalDays = try container.decode(Int.self, forKey: .intervalDays)
        recalibrateAlertEnabled = try container.decodeIfPresent(Bool.self, forKey: .recalibrateAlertEnabled) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(intervalDays, forKey: .intervalDays)
        try container.encode(recalibrateAlertEnabled, forKey: .recalibrateAlertEnabled)
    }
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
