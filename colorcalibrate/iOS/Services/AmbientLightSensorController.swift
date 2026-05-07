
//
//  AmbientLightSensorController.swift
//  colorcalibrate
//
//  Uses the ambient light sensor's chromaticity (CIE xy) + lux to produce
//  real color readings instead of grayscale-only values.
//

import Foundation
import Observation
#if canImport(SensorKit)
import SensorKit
#endif

@Observable
final class AmbientLightSensorController: NSObject {
    private(set) var latestLux: Double = 0.0
    private(set) var latestColor = RGBColor.neutralGray
    private(set) var latestXY: Chromaticity?
    private(set) var sensorAuthorized = true
    private(set) var isReceivingData = false

    /// Rolling buffer for stability verification (last N measurements).
    @ObservationIgnored
    private var recentColors: [RGBColor] = []
    @ObservationIgnored
    private let stabilityWindowSize = 6

    @ObservationIgnored
    private var reader: SRSensorReader?

    @ObservationIgnored
    private var timer: DispatchSourceTimer?

    @ObservationIgnored
    private var lastRequestTime: SRAbsoluteTime?

    // MARK: - Temperature monitoring
    #if canImport(UIKit)
    private var thermalState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }
    var isThermallyThrottled: Bool {
        thermalState == .serious || thermalState == .critical
    }
    #else
    var isThermallyThrottled: Bool { false }
    #endif

    var colorStability: Double {
        guard recentColors.count >= 3 else { return 0 }
        let lastN = recentColors.suffix(3)
        let avgR = lastN.map(\.red).reduce(0,+) / Double(lastN.count)
        let avgG = lastN.map(\.green).reduce(0,+) / Double(lastN.count)
        let avgB = lastN.map(\.blue).reduce(0,+) / Double(lastN.count)
        let variance = lastN.map { c in
            let dr = c.red - avgR
            let dg = c.green - avgG
            let db = c.blue - avgB
            return dr*dr + dg*dg + db*db
        }.reduce(0,+) / Double(lastN.count)
        return max(0, 1.0 - variance * 100)
    }

    func start() {
        guard #available(iOS 14.0, *) else {
            sensorAuthorized = false
            return
        }

        SRSensorReader.requestAuthorization(sensors: [.ambientLightSensor]) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.sensorAuthorized = false
                    self.isReceivingData = false
                    print("Ambient light sensor authorization error: \(error)")
                    return
                }

                self.sensorAuthorized = true
                self.configureReaderAndStartUpdates()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastRequestTime = nil
        recentColors.removeAll()

        guard #available(iOS 14.0, *), let reader = reader else { return }
        reader.stopRecording()
        self.reader = nil

        Task { @MainActor in
            self.isReceivingData = false
        }
    }

    private func configureReaderAndStartUpdates() {
        guard #available(iOS 14.0, *) else { return }

        let reader = SRSensorReader(sensor: .ambientLightSensor)
        reader.delegate = self
        self.reader = reader

        reader.startRecording()
        schedulePollingTimer()
    }

    private func schedulePollingTimer() {
        timer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.25, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.pollLatestSamples()
        }

        self.timer = timer
        timer.resume()
    }

    private func pollLatestSamples() {
        guard #available(iOS 14.0, *), let reader = reader else { return }

        let nowAbsolute = CFAbsoluteTime(Date().timeIntervalSinceReferenceDate)
        let now = SRAbsoluteTime.fromCFAbsoluteTime(_cf: nowAbsolute)
        let request = SRFetchRequest()

        if let last = lastRequestTime {
            request.from = last
        } else {
            let oneSecondAgo = SRAbsoluteTime.fromCFAbsoluteTime(_cf: nowAbsolute - 1.0)
            request.from = oneSecondAgo
        }

        request.to = now

        lastRequestTime = now

        reader.fetch(request)
    }

    private func update(with sample: SRAmbientLightSample) {
        let luxValue = sample.lux.value
        let chromaticity = sample.chromaticity

        // Use CIE xy chromaticity + lux to derive real sRGB color.
        // Scale Y from lux: typical display white at 8-12 cm yields ~200-800 lux.
        // Map to a reasonable luminance range for sRGB conversion.
        let Y = min(max(luxValue / 500.0, 0.0), 1.5)
        let x = Double(chromaticity.x)
        let y = Double(chromaticity.y)
        let color = ColorScience.xyYToSRGB(x: x, y: y, Y: Y)

        // Store raw chromaticity for device-independent comparisons.
        self.latestXY = Chromaticity(x: x, y: y, Y: Y)

        Task { @MainActor in
            self.latestLux = luxValue
            self.latestColor = color
            // latestXY already assigned above
            self.isReceivingData = true

            // Maintain rolling buffer for stability tracking.
            self.recentColors.append(color)
            if self.recentColors.count > self.stabilityWindowSize {
                self.recentColors.removeFirst(self.recentColors.count - self.stabilityWindowSize)
            }
        }
    }
}

@available(iOS 14.0, *)
extension AmbientLightSensorController: SRSensorReaderDelegate {
    func sensorReader(_ reader: SRSensorReader, didChange authorizationStatus: SRAuthorizationStatus) {
        Task { @MainActor in
            self.sensorAuthorized = (authorizationStatus == .authorized)
            if !self.sensorAuthorized {
                self.isReceivingData = false
            }
        }
    }

    func sensorReaderWillStartRecording(_ reader: SRSensorReader) {
        Task { @MainActor in
            self.isReceivingData = true
        }
    }

    func sensorReaderDidStopRecording(_ reader: SRSensorReader) {
        Task { @MainActor in
            self.isReceivingData = false
        }
    }

    func sensorReader(_ reader: SRSensorReader, startRecordingFailedWithError error: Error) {
        Task { @MainActor in
            self.sensorAuthorized = false
            self.isReceivingData = false
            print("Ambient light sensor start recording failed: \(error)")
        }
    }

    func sensorReader(_ reader: SRSensorReader, fetching fetchRequest: SRFetchRequest, didFetchResult result: SRFetchResult<AnyObject>) -> Bool {
        if let sample = result.sample as? SRAmbientLightSample {
            update(with: sample)
        }
        return true
    }

    func sensorReader(_ reader: SRSensorReader, fetching fetchRequest: SRFetchRequest, failedWithError error: Error) {
        print("Ambient light sensor fetch failed: \(error)")
    }
}
