
//
//  AmbientLightSensorController.swift
//  colorcalibrate
//
//  Created by GitHub Copilot on 3/23/26.
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
    private(set) var sensorAuthorized = true
    private(set) var isReceivingData = false

    @ObservationIgnored
    private var reader: SRSensorReader?

    @ObservationIgnored
    private var timer: DispatchSourceTimer?

    @ObservationIgnored
    private var lastRequestTime: SRAbsoluteTime?

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
        let normalized = min(max(luxValue / 5000.0, 0.0), 1.0)
        let color = RGBColor(red: normalized, green: normalized, blue: normalized)

        Task { @MainActor in
            self.latestLux = luxValue
            self.latestColor = color
            self.isReceivingData = true
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
        // Keep fetching until all results processed.
        return true
    }

    func sensorReader(_ reader: SRSensorReader, fetching fetchRequest: SRFetchRequest, failedWithError error: Error) {
        print("Ambient light sensor fetch failed: \(error)")
    }
}
