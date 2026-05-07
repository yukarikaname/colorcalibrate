//
//  ColorScience.swift
//  colorcalibrate
//
//  Color science utilities for CIE xyY/XYZ, common display RGB spaces,
//  color temperature estimation, and ΔE computation.
//

import Foundation

enum DisplayColorSpace: String, Codable, Hashable, Sendable, CaseIterable {
    case sRGB
    case displayP3
    case adobeRGB1998
    case unknownSRGBFallback

    var title: String {
        switch self {
        case .sRGB:
            return "sRGB"
        case .displayP3:
            return "Display P3"
        case .adobeRGB1998:
            return "Adobe RGB (1998)"
        case .unknownSRGBFallback:
            return "Unknown (sRGB fallback)"
        }
    }

    var usesSRGBTransferFunction: Bool {
        switch self {
        case .sRGB, .displayP3, .unknownSRGBFallback:
            return true
        case .adobeRGB1998:
            return false
        }
    }

    static func from(localizedName: String?) -> DisplayColorSpace {
        let name = (localizedName ?? "").lowercased()
        if name.contains("adobe") && name.contains("rgb") {
            return .adobeRGB1998
        }
        if name.contains("display p3") || name.contains("p3") {
            return .displayP3
        }
        if name.contains("srgb") || name.contains("s rgb") {
            return .sRGB
        }
        return .unknownSRGBFallback
    }
}

/// Color science helper functions.
enum ColorScience {

    // MARK: - CIE 1931 xyY / XYZ

    /// Converts xyY to CIE XYZ.
    static func xyYToXYZ(x: Double, y: Double, Y: Double) -> (X: Double, Y: Double, Z: Double) {
        guard y > 0 else { return (0, 0, 0) }
        let X = (x * Y) / y
        let Z = ((1 - x - y) * Y) / y
        return (X, Y, Z)
    }

    /// Converts CIE XYZ to linear RGB in the requested display color space.
    static func xyzToLinearRGB(
        _ X: Double,
        _ Y: Double,
        _ Z: Double,
        colorSpace: DisplayColorSpace = .sRGB
    ) -> (r: Double, g: Double, b: Double) {
        let m = xyzToRGBMatrix(for: colorSpace)
        return (
            m[0] * X + m[1] * Y + m[2] * Z,
            m[3] * X + m[4] * Y + m[5] * Z,
            m[6] * X + m[7] * Y + m[8] * Z
        )
    }

    /// Converts linear RGB in the requested display color space to CIE XYZ.
    static func linearRGBToXYZ(
        r: Double,
        g: Double,
        b: Double,
        colorSpace: DisplayColorSpace = .sRGB
    ) -> (X: Double, Y: Double, Z: Double) {
        let m = rgbToXYZMatrix(for: colorSpace)
        return (
            m[0] * r + m[1] * g + m[2] * b,
            m[3] * r + m[4] * g + m[5] * b,
            m[6] * r + m[7] * g + m[8] * b
        )
    }

    /// Backward-compatible sRGB conversion used by the iPhone sensor preview.
    static func xyYToLinearSRGB(x: Double, y: Double, Y: Double) -> (r: Double, g: Double, b: Double) {
        let xyz = xyYToXYZ(x: x, y: y, Y: Y)
        return xyzToLinearRGB(xyz.X, xyz.Y, xyz.Z, colorSpace: .sRGB)
    }

    /// Full pipeline: xyY -> clamped encoded RGB for the requested display color space.
    static func xyYToRGBColor(
        x: Double,
        y: Double,
        Y: Double,
        colorSpace: DisplayColorSpace = .sRGB
    ) -> RGBColor {
        let xyz = xyYToXYZ(x: x, y: y, Y: Y)
        let linear = xyzToLinearRGB(xyz.X, xyz.Y, xyz.Z, colorSpace: colorSpace)
        return RGBColor(
            red: clamped(encode(linear.r, colorSpace: colorSpace)),
            green: clamped(encode(linear.g, colorSpace: colorSpace)),
            blue: clamped(encode(linear.b, colorSpace: colorSpace))
        )
    }

    /// Full pipeline: xyY -> clamped encoded sRGB.
    static func xyYToSRGB(x: Double, y: Double, Y: Double) -> RGBColor {
        xyYToRGBColor(x: x, y: y, Y: Y, colorSpace: .sRGB)
    }

    // MARK: - Transfer Functions

    /// Expands an encoded component to linear light for the selected RGB space and dynamic range.
    /// For HDR, uses the PQ (ST.2084) inverse EOTF to recover display linear values above 1.0.
    static func decode(
        _ value: Double,
        colorSpace: DisplayColorSpace = .sRGB,
        dynamicRangeMode: DisplayDynamicRangeMode = .sdr
    ) -> Double {
        if dynamicRangeMode == .hdr {
            return pqToLinear(value)
        }
        switch colorSpace {
        case .sRGB, .displayP3, .unknownSRGBFallback:
            return gammaExpand(value)
        case .adobeRGB1998:
            return pow(max(value, 0), 2.2)
        }
    }

    /// Encodes a linear-light component for the selected RGB space and dynamic range.
    /// For HDR, uses the PQ (ST.2084) EOTF to map linear light (potentially > 1.0) to [0,1].
    static func encode(
        _ linear: Double,
        colorSpace: DisplayColorSpace = .sRGB,
        dynamicRangeMode: DisplayDynamicRangeMode = .sdr
    ) -> Double {
        if dynamicRangeMode == .hdr {
            return linearToPQ(linear)
        }
        switch colorSpace {
        case .sRGB, .displayP3, .unknownSRGBFallback:
            return linearToSRGBComponent(linear)
        case .adobeRGB1998:
            return linear <= 0 ? 0 : pow(linear, 1.0 / 2.2)
        }
    }

    // MARK: - PQ (ST.2084) Transfer Functions

    /// Converts a PQ-encoded value (0...1) to linear display light.
    /// Uses the standard ST.2084 inverse EOTF with 10,000 cd/m² peak reference.
    static func pqToLinear(_ pq: Double) -> Double {
        // ST.2084 constants
        let m1 = 0.1593017578125  // 2610/16384
        let m2 = 2523.0 / 4096.0 * 128.0   // 78.84375
        let c1 = 3424.0 / 4096.0           // 0.8359375
        let c2 = 2413.0 / 4096.0 * 32.0    // 18.8515625
        let c3 = 2392.0 / 4096.0 * 32.0    // 18.6875

        let v = max(pq, 0.0)
        let vPow = pow(v, 1.0 / m2)
        let numerator = max(vPow - c1, 0)
        let denominator = max(c2 - c3 * vPow, 1e-10)
        return pow(numerator / denominator, 1.0 / m1)
    }

    /// Converts linear display light (0...~100 for 10,000 cd/m² reference) to PQ-encoded [0,1].
    static func linearToPQ(_ linear: Double) -> Double {
        let m1 = 0.1593017578125
        let m2 = 78.84375
        let c1 = 0.8359375
        let c2 = 18.8515625
        let c3 = 18.6875

        let l = max(linear, 0.0)
        let lPow = pow(l, m1)
        let numerator = c1 + c2 * lPow
        let denominator = 1.0 + c3 * lPow
        return pow(numerator / denominator, m2)
    }

    /// Inverse of linearToSRGBComponent: expands a gamma-compressed sRGB value to linear.
    static func gammaExpand(_ value: Double) -> Double {
        if value <= 0.04045 {
            return value / 12.92
        }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    /// Applies the sRGB transfer function to a linear component.
    static func linearToSRGBComponent(_ linear: Double) -> Double {
        if linear <= 0.0031308 {
            return 12.92 * linear
        }
        return 1.055 * pow(linear, 1.0 / 2.4) - 0.055
    }

    /// Converts a linear sRGB color to gamma-corrected sRGB.
    static func linearSRGBToSRGB(r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        (
            linearToSRGBComponent(r),
            linearToSRGBComponent(g),
            linearToSRGBComponent(b)
        )
    }

    // MARK: - Color Temperature

    /// Estimates correlated color temperature (CCT) from CIE 1931 xy coordinates.
    /// Uses McCamy's cubic approximation.
    static func correlatedColorTemperature(x: Double, y: Double) -> Double? {
        guard y > 0 else { return nil }
        let n = (x - 0.3320) / (0.1858 - y)
        let cct = 449.0 * pow(n, 3) + 3525.0 * pow(n, 2) + 6823.3 * n + 5520.33
        return max(1000, min(20000, cct))
    }

    // MARK: - CIE XYZ / Lab

    /// D65 white point (CIE 1931 2°).
    static let d65WhitePoint: (x: Double, y: Double) = (0.3127, 0.3290)

    /// Converts XYZ to CIE Lab under D65 illuminant.
    static func xyzToLab(X: Double, Y: Double, Z: Double) -> (L: Double, a: Double, b: Double) {
        let Xn: Double = 0.95047
        let Yn: Double = 1.0
        let Zn: Double = 1.08883

        func f(_ t: Double) -> Double {
            if t > 0.008856 {
                return pow(t, 1.0 / 3.0)
            }
            return 7.787037 * t + 16.0 / 116.0
        }

        return (
            116.0 * f(Y / Yn) - 16.0,
            500.0 * (f(X / Xn) - f(Y / Yn)),
            200.0 * (f(Y / Yn) - f(Z / Zn))
        )
    }

    /// Converts CIE xyY directly to Lab.
    static func xyYToLab(x: Double, y: Double, Y: Double) -> (L: Double, a: Double, b: Double) {
        let xyz = xyYToXYZ(x: x, y: y, Y: Y)
        return xyzToLab(X: xyz.X, Y: xyz.Y, Z: xyz.Z)
    }

    /// Converts an encoded RGBColor in the selected display color space to CIE Lab.
    static func rgbToLab(
        _ color: RGBColor,
        colorSpace: DisplayColorSpace = .sRGB
    ) -> (L: Double, a: Double, b: Double) {
        let rLin = decode(color.red, colorSpace: colorSpace)
        let gLin = decode(color.green, colorSpace: colorSpace)
        let bLin = decode(color.blue, colorSpace: colorSpace)
        let xyz = linearRGBToXYZ(r: rLin, g: gLin, b: bLin, colorSpace: colorSpace)
        return xyzToLab(X: xyz.X, Y: xyz.Y, Z: xyz.Z)
    }

    /// Backward-compatible sRGB -> Lab conversion.
    static func srgbToLab(_ color: RGBColor) -> (L: Double, a: Double, b: Double) {
        rgbToLab(color, colorSpace: .sRGB)
    }

    // MARK: - ΔE 2000

    /// Computes ΔE00 between two colors in Lab space.
    static func deltaE2000(
        lab1: (L: Double, a: Double, b: Double),
        lab2: (L: Double, a: Double, b: Double)
    ) -> Double {
        let L1 = lab1.L, a1 = lab1.a, b1 = lab1.b
        let L2 = lab2.L, a2 = lab2.a, b2 = lab2.b

        let C1 = sqrt(a1 * a1 + b1 * b1)
        let C2 = sqrt(a2 * a2 + b2 * b2)
        let CBar = (C1 + C2) / 2

        let G = 0.5 * (1 - sqrt(pow(CBar, 7) / (pow(CBar, 7) + pow(25, 7))))
        let a1Prime = a1 * (1 + G)
        let a2Prime = a2 * (1 + G)

        let C1Prime = sqrt(a1Prime * a1Prime + b1 * b1)
        let C2Prime = sqrt(a2Prime * a2Prime + b2 * b2)
        let CBarPrime = (C1Prime + C2Prime) / 2

        let h1Prime = normalizedHue(b: b1, a: a1Prime)
        let h2Prime = normalizedHue(b: b2, a: a2Prime)

        let HBarPrime: Double
        if abs(h1Prime - h2Prime) > .pi {
            HBarPrime = (h1Prime + h2Prime + 2 * .pi) / 2
        } else {
            HBarPrime = (h1Prime + h2Prime) / 2
        }

        let T = 1
            - 0.17 * cos(HBarPrime - .pi / 6)
            + 0.24 * cos(2 * HBarPrime)
            + 0.32 * cos(3 * HBarPrime + .pi / 30)
            - 0.20 * cos(4 * HBarPrime - 63 * .pi / 180)

        var deltaHPrime = h2Prime - h1Prime
        if abs(deltaHPrime) > .pi {
            if h2Prime <= h1Prime {
                deltaHPrime += 2 * .pi
            } else {
                deltaHPrime -= 2 * .pi
            }
        }
        let deltaHPrimeFinal = 2 * sqrt(C1Prime * C2Prime) * sin(deltaHPrime / 2)

        let deltaLPrime = L2 - L1
        let deltaCPrime = C2Prime - C1Prime
        let LBarPrime = (L1 + L2) / 2

        let SL = 1 + (0.015 * pow(LBarPrime - 50, 2)) / sqrt(20 + pow(LBarPrime - 50, 2))
        let SC = 1 + 0.045 * CBarPrime
        let SH = 1 + 0.015 * CBarPrime * T

        let deltaTheta = (30 * .pi / 180)
            * exp(-pow((HBarPrime - 275 * .pi / 180) / (25 * .pi / 180), 2))
        let RC = 2 * sqrt(pow(CBarPrime, 7) / (pow(CBarPrime, 7) + pow(25, 7)))
        let RT = -sin(2 * deltaTheta) * RC

        let part1 = deltaLPrime / SL
        let part2 = deltaCPrime / SC
        let part3 = deltaHPrimeFinal / SH
        let part4 = RT * (deltaCPrime / SC) * (deltaHPrimeFinal / SH)

        return sqrt(part1 * part1 + part2 * part2 + part3 * part3 + part4)
    }

    /// Computes ΔE00 between two encoded RGBColor values in the selected color space.
    static func deltaE2000(
        color1: RGBColor,
        color2: RGBColor,
        colorSpace: DisplayColorSpace = .sRGB
    ) -> Double {
        let lab1 = rgbToLab(color1, colorSpace: colorSpace)
        let lab2 = rgbToLab(color2, colorSpace: colorSpace)
        return deltaE2000(lab1: lab1, lab2: lab2)
    }

    // MARK: - Matrices

    private static func xyzToRGBMatrix(for colorSpace: DisplayColorSpace) -> [Double] {
        switch colorSpace {
        case .sRGB, .unknownSRGBFallback:
            return [
                3.2404542, -1.5371385, -0.4985314,
                -0.9692660, 1.8760108, 0.0415560,
                0.0556434, -0.2040259, 1.0572252,
            ]
        case .displayP3:
            return [
                2.493496911941425, -0.9313836179191239, -0.40271078445071684,
                -0.8294889695615747, 1.7626640603183463, 0.023624685841943577,
                0.03584583024378447, -0.07617238926804182, 0.9568845240076872,
            ]
        case .adobeRGB1998:
            return [
                2.0413690, -0.5649464, -0.3446944,
                -0.9692660, 1.8760108, 0.0415560,
                0.0134474, -0.1183897, 1.0154096,
            ]
        }
    }

    private static func rgbToXYZMatrix(for colorSpace: DisplayColorSpace) -> [Double] {
        switch colorSpace {
        case .sRGB, .unknownSRGBFallback:
            return [
                0.4124564, 0.3575761, 0.1804375,
                0.2126729, 0.7151522, 0.0721750,
                0.0193339, 0.1191920, 0.9503041,
            ]
        case .displayP3:
            return [
                0.4865709486482162, 0.2656676931690931, 0.1982172852343625,
                0.2289745640697488, 0.6917385218365064, 0.0792869140937450,
                0.0, 0.0451133818589026, 1.043944368900976,
            ]
        case .adobeRGB1998:
            return [
                0.5767309, 0.1855540, 0.1881852,
                0.2973769, 0.6273491, 0.0752741,
                0.0270343, 0.0706872, 0.9911085,
            ]
        }
    }

    private static func normalizedHue(b: Double, a: Double) -> Double {
        let hue = atan2(b, a)
        return hue >= 0 ? hue : hue + 2 * .pi
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }
}
