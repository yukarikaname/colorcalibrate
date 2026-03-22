#if os(iOS)
    @preconcurrency import AVFoundation
    import Observation
    import QuartzCore

    @Observable
    final class CameraMeasurementController: NSObject {
        private(set) var latestColor = RGBColor.neutralGray
        private(set) var cameraAuthorized = true
        private(set) var isReceivingFrames = false

        @ObservationIgnored
        let session = AVCaptureSession()

        @ObservationIgnored
        private let output = AVCaptureVideoDataOutput()
        @ObservationIgnored
        private let queue = DispatchQueue(label: "camera.measurement.queue")
        private var configured = false
        private var lastPublishedTimestamp: CFTimeInterval = 0

        func start() {
            guard !configured else {
                queue.async { [session] in
                    if !session.isRunning {
                        session.startRunning()
                    }
                }
                return
            }

            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .authorized {
                configureIfNeeded()
                return
            }

            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        self.cameraAuthorized = granted
                        if granted {
                            self.configureIfNeeded()
                        }
                    }
                }
                return
            }

            cameraAuthorized = false
        }

        func stop() {
            queue.async { [session] in
                if session.isRunning {
                    session.stopRunning()
                }
            }
            Task { @MainActor in
                self.isReceivingFrames = false
            }
        }

        private func configureIfNeeded() {
            guard !configured else { return }

            session.beginConfiguration()
            session.sessionPreset = .vga640x480

            guard
                let device = AVCaptureDevice.default(
                    .builtInWideAngleCamera, for: .video, position: .front),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else {
                session.commitConfiguration()
                cameraAuthorized = false
                return
            }

            session.addInput(input)

            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)

            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                cameraAuthorized = false
                return
            }

            session.addOutput(output)
            session.commitConfiguration()
            configured = true

            queue.async { [session] in
                session.startRunning()
            }
        }

        func publish(measured: RGBColor) {
            let current = latestColor
            let delta =
                abs(current.red - measured.red) + abs(current.green - measured.green)
                + abs(current.blue - measured.blue)
            if delta > 0.015 {
                latestColor = measured
            }
        }
    }

    extension CameraMeasurementController: AVCaptureVideoDataOutputSampleBufferDelegate {
        func captureOutput(
            _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            autoreleasepool {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                let measured = averageColor(in: pixelBuffer)

                let now = CACurrentMediaTime()
                guard now - lastPublishedTimestamp >= 0.25 else { return }
                lastPublishedTimestamp = now

                DispatchQueue.main.async {
                    self.isReceivingFrames = true
                    self.publish(measured: measured)
                }
            }
        }

        private func averageColor(in pixelBuffer: CVPixelBuffer) -> RGBColor {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                return latestColor
            }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

            let sampleWidth = max(width / 5, 24)
            let sampleHeight = max(height / 5, 24)
            let startX = max((width - sampleWidth) / 2, 0)
            let startY = max((height - sampleHeight) / 2, 0)

            var redSum = 0.0
            var greenSum = 0.0
            var blueSum = 0.0
            var count = 0.0

            let step = 4
            let endY = min(startY + sampleHeight, height)
            let endX = min(startX + sampleWidth, width)

            var y = startY
            while y < endY {
                let row = bytes + (y * bytesPerRow)
                var x = startX
                while x < endX {
                    let pixel = row + (x * step)
                    blueSum += Double(pixel[0])
                    greenSum += Double(pixel[1])
                    redSum += Double(pixel[2])
                    count += 1
                    x += 4
                }
                y += 4
            }

            guard count > 0 else { return latestColor }

            return RGBColor(
                red: redSum / (count * 255.0),
                green: greenSum / (count * 255.0),
                blue: blueSum / (count * 255.0)
            )
        }
    }
#endif
