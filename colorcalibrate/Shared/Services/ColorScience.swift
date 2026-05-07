//
//  ColorScience.swift
//  colorcalibrate
//
//  Color science utilities for xyY ↔ linear sRGB conversion,
//  color temperature estimation, and ΔE computation.
//

import Foundation

/// Color science helper functions.
enum ColorScience {

    // MARK: - CIE 1931 xyY → linear sRGB

    /// Converts CIE 1931 xyY values to a linear sRGB color.
    /// - Parameters:
    ///   - x: CIE 1931 x chromaticity coordinate.
    ///   - y: CIE 1931 y chromaticity coordinate.
    ///   - Y: Absolute luminance (cd/m² or lux-proportional).
    /// - Returns: Linear sRGB components (R, G, B) unclamped.
    static func xyYToLinearSRGB(x: Double, y: Double, Y: Double) -> (r: Double, g: Double, b: Double) {
        guard y > 0 else { return (0, 0, 0) }

        // xyY to CIE XYZ
        let X = (x * Y) / y
        let Z = ((1 - x - y) * Y) / y

        // XYZ to linear sRGB using D65 white point and sRGB primaries.
        // Matrix from IEC 61966-2-1:1999.
        let r =  3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z
        let g = -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z
        let b =  0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z

        return (r, g, b)
    }

    // MARK: - Linear sRGB → sRGB (gamma-corrected)

    /// Inverse of linearToSRGBComponent — expands a gamma-compressed sRGB value to linear.
    static func gammaExpand(_ value: Double) -> Double {
        if value <= 0.04045 {
            return value / 12.92
        } else {
            return pow((value + 0.055) / 1.055, 2.4)
        }
    }

    /// Applies the sRGB transfer function (gamma correction) to a linear component.
    static func linearToSRGBComponent(_ linear: Double) -> Double {
        if linear <= 0.0031308 {
            return 12.92 * linear
        } else {
            return 1.055 * pow(linear, 1.0 / 2.4) - 0.055
        }
    }

    /// Converts a linear sRGB color to gamma-corrected sRGB (0…1).
    static func linearSRGBToSRGB(r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        return (
            linearToSRGBComponent(r),
            linearToSRGBComponent(g),
            linearToSRGBComponent(b)
        )
    }

    /// Full pipeline: xyY → clamped sRGB.
    static func xyYToSRGB(x: Double, y: Double, Y: Double) -> RGBColor {
        let linear = xyYToLinearSRGB(x: x, y: y, Y: Y)
        let srgb = linearSRGBToSRGB(r: linear.r, g: linear.g, b: linear.b)
        return RGBColor(
            red: max(0, min(1, srgb.r)),
            green: max(0, min(1, srgb.g)),
            blue: max(0, min(1, srgb.b))
        )
    }

    // MARK: - Color temperature estimation

    /// Estimates correlated color temperature (CCT) from CIE 1931 xy coordinates.
    /// Uses McCamy's cubic approximation (valid for 2856 K … 6500 K).
    static func correlatedColorTemperature(x: Double, y: Double) -> Double? {
        guard y > 0 else { return nil }
        let n = (x - 0.3320) / (0.1858 - y)
        let cct = 449.0 * pow(n, 3) + 3525.0 * pow(n, 2) + 6823.3 * n + 5520.33
        // Clamp to physically meaningful range.
        return max(1000, min(20000, cct))
    }

    // MARK: - CIE XYZ → CIELAB

    /// D65 white point (CIE 1931 2°).
    static let d65WhitePoint: (x: Double, y: Double) = (0.3127, 0.3290)

    /// Converts XYZ to CIE Lab under D65 illuminant.
    static func xyzToLab(X: Double, Y: Double, Z: Double) -> (L: Double, a: Double, b: Double) {
        // Reference white for D65: Yn = 100 typically, but we'll use normalized values.
        // Here we assume XYZ are already normalized with Yn = 1.0 for the perfect white.
        // The white point for D65 in XYZ: Xn = 0.95047, Yn = 1.0, Zn = 1.08883.
        let Xn: Double = 0.95047
        let Yn: Double = 1.0
        let Zn: Double = 1.08883

        func f(_ t: Double) -> Double {
            if t > 0.008856 {
                return pow(t, 1.0 / 3.0)
            } else {
                return 7.787037 * t + 16.0 / 116.0
            }
        }

        let L = 116.0 * f(Y / Yn) - 16.0
        let a = 500.0 * (f(X / Xn) - f(Y / Yn))
        let b = 200.0 * (f(Y / Yn) - f(Z / Zn))
        return (L, a, b)
    }

    /// Converts an sRGB color to CIE Lab.
    static func srgbToLab(_ color: RGBColor) -> (L: Double, a: Double, b: Double) {
        // sRGB → linear sRGB → XYZ.
        func linearize(_ c: Double) -> Double {
            if c <= 0.04045 {
                return c / 12.92
            } else {
                return pow((c + 0.055) / 1.055, 2.4)
            }
        }
        let rLin = linearize(color.red)
        let gLin = linearize(color.green)
        let bLin = linearize(color.blue)

        // linear sRGB to XYZ (D65)
        let X = 0.4124564 * rLin + 0.3575761 * gLin + 0.1804375 * bLin
        let Y = 0.2126729 * rLin + 0.7151522 * gLin + 0.0721750 * bLin
        let Z = 0.0193339 * rLin + 0.1191920 * gLin + 0.9503041 * bLin

        return xyzToLab(X: X, Y: Y, Z: Z)
    }

    // MARK: - ΔE 2000

    /// Computes ΔE₀₀ (CIE 2000) between two colors in Lab space.
    static func deltaE2000(lab1: (L: Double, a: Double, b: Double),
                           lab2: (L: Double, a: Double, b: Double)) -> Double {

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

        let h1Prime = atan2(b1, a1Prime) >= 0 ? atan2(b1, a1Prime) : atan2(b1, a1Prime) + 2 * .pi
        let h2Prime = atan2(b2, a2Prime) >= 0 ? atan2(b2, a2Prime) : atan2(b2, a2Prime) + 2 * .pi

        let HBarPrime = if abs(h1Prime - h2Prime) > .pi {
            (h1Prime + h2Prime + 2 * .pi) / 2
        } else {
            (h1Prime + h2Prime) / 2
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

        let deltaTheta = (30 * .pi / 180) * exp(-pow((HBarPrime - 275 * .pi / 180) / (25 * .pi / 180), 2))
        let RC = 2 * sqrt(pow(CBarPrime, 7) / (pow(CBarPrime, 7) + pow(25, 7)))
        let RT = -sin(2 * deltaTheta) * RC

        let part1 = deltaLPrime / (1 * SL)
        let part2 = deltaCPrime / (1 * SC)
        let part3 = deltaHPrimeFinal / (1 * SH)
        let part4 = RT * (deltaCPrime / (1 * SC)) * (deltaHPrimeFinal / (1 * SH))

        return sqrt(part1 * part1 + part2 * part2 + part3 * part3 + part4)
    }

    /// Computes ΔE₀₀ between two RGBColor values.
    static func deltaE2000(color1: RGBColor, color2: RGBColor) -> Double {
        let lab1 = srgbToLab(color1)
        let lab2 = srgbToLab(color2)
        return deltaE2000(lab1: lab1, lab2: lab2)
    }
}
