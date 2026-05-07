import XCTest
@testable import colorcalibrate

final class ColorScienceTests: XCTestCase {
    func testColorSpaceDetection() {
        XCTAssertEqual(DisplayColorSpace.from(localizedName: "sRGB IEC61966-2.1"), .sRGB)
        XCTAssertEqual(DisplayColorSpace.from(localizedName: "Display P3"), .displayP3)
        XCTAssertEqual(DisplayColorSpace.from(localizedName: "Adobe RGB (1998)"), .adobeRGB1998)
        XCTAssertEqual(DisplayColorSpace.from(localizedName: "Mystery Panel"), .unknownSRGBFallback)
    }

    func testSRGBWhiteRoundTripToXYZ() {
        let linear = RGBColor.white.linearComponents(colorSpace: .sRGB)
        let xyz = ColorScience.linearRGBToXYZ(
            r: linear.r,
            g: linear.g,
            b: linear.b,
            colorSpace: .sRGB
        )

        XCTAssertEqual(xyz.X, 0.95047, accuracy: 0.001)
        XCTAssertEqual(xyz.Y, 1.0, accuracy: 0.001)
        XCTAssertEqual(xyz.Z, 1.08883, accuracy: 0.001)
    }

    func testDisplayP3AndAdobeRGBPrimariesDifferFromSRGB() {
        let p3RedXYZ = ColorScience.linearRGBToXYZ(r: 1, g: 0, b: 0, colorSpace: .displayP3)
        let adobeRedXYZ = ColorScience.linearRGBToXYZ(r: 1, g: 0, b: 0, colorSpace: .adobeRGB1998)
        let srgbRedXYZ = ColorScience.linearRGBToXYZ(r: 1, g: 0, b: 0, colorSpace: .sRGB)

        XCTAssertGreaterThan(p3RedXYZ.X, srgbRedXYZ.X)
        XCTAssertGreaterThan(adobeRedXYZ.X, srgbRedXYZ.X)
        XCTAssertEqual(p3RedXYZ.Y, 0.22897, accuracy: 0.001)
        XCTAssertEqual(adobeRedXYZ.Y, 0.29738, accuracy: 0.001)
    }

    func testTransferFunctions() {
        let linear = ColorScience.gammaExpand(0.5)
        XCTAssertEqual(linear, 0.21404, accuracy: 0.0001)
        XCTAssertEqual(ColorScience.linearToSRGBComponent(linear), 0.5, accuracy: 0.0001)

        let adobeLinear = ColorScience.decode(0.5, colorSpace: .adobeRGB1998)
        XCTAssertEqual(ColorScience.encode(adobeLinear, colorSpace: .adobeRGB1998), 0.5, accuracy: 0.0001)
    }

    func testDeltaEForIdenticalLabIsZero() {
        let lab = ColorScience.xyYToLab(x: 0.3127, y: 0.3290, Y: 1.0)
        XCTAssertEqual(ColorScience.deltaE2000(lab1: lab, lab2: lab), 0, accuracy: 0.0001)
    }
}
