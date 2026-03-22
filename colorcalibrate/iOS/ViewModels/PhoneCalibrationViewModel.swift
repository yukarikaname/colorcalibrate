#if os(iOS)
    import Foundation
    import Observation
    import UIKit

    @MainActor
    @Observable
    final class PhoneCalibrationViewModel {
        var peerSession = PeerCalibrationSession(role: .phoneSensor)
        var camera = CameraMeasurementController()
        var localNetwork = LocalNetworkPermissionController()
        var currentTarget: CalibrationTarget?
        var statusLine = "Open the Mac app and point the iPhone front camera at the screen."
        var receivedProfile: CalibrationProfile?

        @ObservationIgnored
        private var measurementTask: Task<Void, Never>?
        @ObservationIgnored
        private var started = false

        func start() {
            guard !started else { return }
            started = true

            camera.start()
            localNetwork.requestAccess()
            peerSession.restartDiscovery()

            peerSession.onCalibrationStep = { [weak self] _, target in
                self?.handleCalibrationStep(target)
            }

            peerSession.onCalibrationFinished = { [weak self] profile in
                self?.measurementTask?.cancel()
                self?.receivedProfile = profile
                self?.statusLine =
                    "Calibration finished on the Mac. You can compare the saved display calibration there."
            }
        }

        func stop() {
            measurementTask?.cancel()
            camera.stop()
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

        private func handleCalibrationStep(_ target: CalibrationTarget) {
            measurementTask?.cancel()
            currentTarget = target
            statusLine = target.instruction

            measurementTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, !Task.isCancelled else { return }

                let measurement = CalibrationMeasurement(
                    targetID: target.id,
                    measuredColor: camera.latestColor,
                    capturedAt: .now
                )

                peerSession.sendMeasurement(measurement)
                statusLine = "Measured \(target.title). Waiting for the next patch..."
            }
        }
    }
#endif
