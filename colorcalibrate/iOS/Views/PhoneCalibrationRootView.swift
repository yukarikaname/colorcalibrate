//
//  PhoneCalibrationRootView.swift
//  colorcalibrate
//
//  Created by Yukari Kaname on 3/22/26.
//

import SwiftUI

struct PhoneCalibrationRootView: View {
    @State private var model = PhoneCalibrationViewModel()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [
                        Color(red: 0.08, green: 0.1, blue: 0.13),
                        Color(red: 0.15, green: 0.18, blue: 0.23),
                    ]
                    : [
                        Color(red: 0.93, green: 0.96, blue: 1.0),
                        Color(red: 0.84, green: 0.9, blue: 0.98),
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        Text("Screen Sensor")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(colorScheme == .dark ? .white : .black)
                        Text(
                            "Hold the iPhone front camera toward the Mac display so the center guide sits over the calibration patch."
                        )
                        .multilineTextAlignment(.center)
                        .foregroundStyle(
                            colorScheme == .dark ? .white.opacity(0.76) : .black.opacity(0.72))
                    }

                    if model.camera.cameraAuthorized {
                        CameraPreviewView(session: model.camera.session)
                            .frame(height: 330)
                            .clipShape(RoundedRectangle(cornerRadius: 32))
                            .overlay {
                                RoundedRectangle(cornerRadius: 32)
                                    .stroke(
                                        (colorScheme == .dark ? Color.white : Color.black)
                                            .opacity(0.14), lineWidth: 1)
                            }
                            .overlay {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(
                                            style: StrokeStyle(lineWidth: 2, dash: [10, 8])
                                        )
                                        .foregroundStyle(
                                            (colorScheme == .dark ? Color.white : Color.black)
                                                .opacity(0.55)
                                        )
                                        .padding(46)

                                    VStack {
                                        HStack {
                                            Spacer()
                                            LiveBadge(
                                                text: model.camera.isReceivingFrames
                                                    ? "LIVE" : "WAITING",
                                                tint: model.camera.isReceivingFrames
                                                    ? .green : .orange
                                            )
                                        }
                                        Spacer()
                                    }
                                    .padding(18)
                                }
                            }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 42))
                            Text(
                                "Camera access is required on iPhone to read the screen patch."
                            )
                            .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(colorScheme == .dark ? .white : .black)
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
                    }

                    VStack(spacing: 14) {
                        HStack(alignment: .center, spacing: 14) {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(model.camera.latestColor.swiftUIColor)
                                .frame(width: 72, height: 72)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.currentTarget?.title ?? "Waiting For Patch")
                                    .font(.headline)
                                Text(model.camera.latestColor.description)
                                    .font(.title3.monospacedDigit().weight(.semibold))
                                Text(
                                    model.camera.isReceivingFrames
                                        ? "Live reading from the front camera center area."
                                        : "Waiting for camera frames..."
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }

                        if let target = model.currentTarget {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(target.instruction)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 10) {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(target.color.swiftUIColor)
                                        .frame(width: 28, height: 28)
                                    Text("Target patch: \(target.subtitle)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("How To Hold iPhone")
                            .font(.title3.bold())
                        GuideStepRow(
                            number: "1",
                            text:
                                "Use the front camera side of the iPhone and aim it straight at the center of the patch."
                        )
                        GuideStepRow(
                            number: "2",
                            text:
                                "Keep the front camera facing the screen and place it directly against the display so the patch fills most of the dashed frame."
                        )
                        GuideStepRow(
                            number: "3",
                            text:
                                "Stay steady and turn off nearby ambient lights while sampling."
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connection")
                            .font(.title3.bold())
                        StatusPill(
                            label: "Network", value: model.localNetwork.state.description)
                        StatusPill(
                            label: "Connection", value: model.peerSession.connectionDescription)
                        StatusPill(label: "Bonjour", value: model.bonjourStatusText)

                        if model.localNetwork.state != .granted {
                            HStack(spacing: 12) {
                                Button("Retry Network Search") {
                                    model.retryDiscovery()
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Open Settings") {
                                    model.openSettings()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))

                    Text(model.statusLine)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(colorScheme == .dark ? .white : .black)
                        .padding(.horizontal, 8)
                }
                .padding(22)
            }
        }
        .task {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }
}

private struct LiveBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(tint.opacity(0.2), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct GuideStepRow: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.headline.monospacedDigit())
                .frame(width: 28, height: 28)
                .background(.thinMaterial, in: Circle())
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
