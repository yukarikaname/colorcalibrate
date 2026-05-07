import XCTest
@testable import colorcalibrate

final class CalibrationProfileTests: XCTestCase {
    func testProfileGenerationRequiresPrimarySamples() {
        let incomplete = [
            CalibrationMeasurement(
                targetID: "white",
                measuredColor: .white,
                measuredXY: Chromaticity(x: 0.3127, y: 0.3290, Y: 1.0),
                capturedAt: Date()
            )
        ]

        XCTAssertNil(
            CalibrationProfile.from(
                measurements: incomplete,
                dynamicRangeMode: .sdr,
                displayID: 1,
                displayName: "Built-in",
                colorSpace: .displayP3
            )
        )
    }

    func testProfileGenerationStoresIdentityAndFallback() throws {
        let measurements = CalibrationTarget.sequence.map { target in
            CalibrationMeasurement(
                targetID: target.id,
                measuredColor: target.renderedRGBColor(colorSpace: .displayP3),
                measuredXY: target.xyY,
                capturedAt: Date()
            )
        }

        let profile = try XCTUnwrap(
            CalibrationProfile.from(
                measurements: measurements,
                dynamicRangeMode: .hdr,
                displayID: 42,
                displayName: "Reference Display",
                colorSpace: .displayP3
            )
        )

        XCTAssertEqual(profile.displayID, 42)
        XCTAssertEqual(profile.displayName, "Reference Display")
        XCTAssertEqual(profile.colorSpace, .displayP3)
        XCTAssertEqual(profile.dynamicRangeMode, .hdr)
        XCTAssertEqual(profile.matrix.count, 9)
        XCTAssertGreaterThanOrEqual(profile.fallbackRedGain, 0.55)
        XCTAssertLessThanOrEqual(profile.fallbackRedGain, 1.75)
        XCTAssertTrue(profile.matches(displayID: 42, colorSpace: .displayP3, dynamicRangeMode: .hdr))
        XCTAssertFalse(profile.matches(displayID: 43, colorSpace: .displayP3, dynamicRangeMode: .hdr))
    }

    func testLegacyProfileDecodingFallsBackToUnknownSRGBIdentity() throws {
        let json = """
        {
          "name": "Legacy SDR",
          "createdAt": 0,
          "dynamicRangeMode": "sdr",
          "redGain": 1.1,
          "greenGain": 0.9,
          "blueGain": 1.0,
          "redOffset": 0.01,
          "greenOffset": -0.01,
          "blueOffset": 0.0
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let profile = try decoder.decode(CalibrationProfile.self, from: json)

        XCTAssertEqual(profile.displayID, 0)
        XCTAssertEqual(profile.colorSpace, .unknownSRGBFallback)
        XCTAssertEqual(profile.fallbackRedGain, 1.1)
        XCTAssertEqual(profile.fallbackGreenOffset, -0.01)
        XCTAssertEqual(profile.matrix, [1,0,0, 0,1,0, 0,0,1])
    }

    func testPreviewCorrectionUsesMatrixNotFallbackOnly() {
        let profile = CalibrationProfile(
            name: "Matrix",
            createdAt: Date(),
            displayID: 1,
            displayName: "Display",
            colorSpace: .sRGB,
            dynamicRangeMode: .sdr,
            matrix: [0,1,0, 1,0,0, 0,0,1],
            fallbackRedGain: 1,
            fallbackGreenGain: 1,
            fallbackBlueGain: 1,
            fallbackRedOffset: 0,
            fallbackGreenOffset: 0,
            fallbackBlueOffset: 0
        )

        let corrected = RGBColor(red: 0.2, green: 0.8, blue: 0.4).applying(profile: profile)
        XCTAssertEqual(corrected.red, 0.8, accuracy: 0.001)
        XCTAssertEqual(corrected.green, 0.2, accuracy: 0.001)
        XCTAssertEqual(corrected.blue, 0.4, accuracy: 0.001)
    }
}
