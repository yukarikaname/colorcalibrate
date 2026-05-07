//
//  PhoneCalibrationViewModel.swift
//  colorcalibrate
//
//  Created by Yukari Kaname on 3/22/26.
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class PhoneCalibrationViewModel {
    var peerSession = PeerCalibrationSession(role: .phoneSensor)
    var ambientSensor = AmbientLightSensorController()
    var localNetwork = LocalNetworkPermissionController()
    var currentTarget: CalibrationTarget?
    var statusLine = "Open the Mac app and position the iPhone toward the screen."
    var receivedProfile: CalibrationProfile?

    @ObservationIgnored
    private var measurementTask: Task<Void, Never>?
    @ObservationIgnored
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        ambientSensor.start()
        localNetwork.requestAccess()
        peerSession.restartDiscovery()

        peerSession.onCalibrationStep = { [weak self] _, target, colorSpace in
            self?.handleCalibrationStep(target, colorSpace: colorSpace)
        }

        peerSession.onCalibrationFinished = { [weak self] profile in
            self?.measurementTask?.cancel()
            self?.receivedProfile = profile
            self?.statusLine =
                "Calibration finished on the Mac. You can compare the saved display calibration there."
        }

        peerSession.onDisconnect = { [weak self] in
            self?.measurementTask?.cancel()
            self?.currentTarget = nil
            self?.statusLine = "Connection lost. Retry discovery when the Mac is nearby."
        }
    }

    func stop() {
        measurementTask?.cancel()
        ambientSensor.stop()
        localNetwork.stop()
    }

    func retryDiscovery() {
        localNetwork.requestAccess()
        peerSession.restartDiscovery()
        statusLine = "Retrying local network discovery..."
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    var bonjourStatusText: String {
        if localNetwork.discoveredServices.isEmpty {
            return "No Mac Bonjour host visible yet"
        }
        return localNetwork.discoveredServices.joined(separator: ", ")
    }

    private func handleCalibrationStep(_ target: CalibrationTarget, colorSpace: DisplayColorSpace) {
        measurementTask?.cancel()
        currentTarget = target
        statusLine = target.instruction
        ambientSensor.activeColorSpace = colorSpace

        measurementTask = Task { [weak self] in
            guard let self else { return }

            // Wait for sensor data to stabilize before sampling.
            // Collect multiple samples to measure sensor noise.
            let deadline = Date().addingTimeInterval(5)
            while !Task.isCancelled {
                let stable = self.ambientSensor.colorStability > 0.95
                let cool = !self.ambientSensor.isThermallyThrottled

                if stable && cool { break }
                if Date() > deadline { break }

                self.statusLine = "\(target.instruction) (stabilizing: \(Int(self.ambientSensor.colorStability * 100))%)"
                try? await Task.sleep(for: .milliseconds(250))
            }

            guard !Task.isCancelled else { return }

            let measurement = CalibrationMeasurement(
                targetID: target.id,
                measuredXY: self.ambientSensor.averagedXY(),
                measuredColor: self.ambientSensor.latestColor,
                capturedAt: .now,
                colorStability: self.ambientSensor.colorStability
            )

            peerSession.sendMeasurement(measurement)
            statusLine = "Measured \(target.title). Waiting for the next patch..."
        }
    }
}
