//
//  PeerCalibrationSession.swift
//  colorcalibrate
//
//  Multipeer connectivity with disconnect callback and thread safety.
//

import Foundation
@preconcurrency import MultipeerConnectivity
import Observation

#if os(iOS)
import UIKit
#endif

// MARK: - Helpers

/// A simple mutex wrapper to protect shared mutable state from data races.
final class Synchronized<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { self._value = value }
    var value: T { lock.withLock { _value } }
    func update(_ transform: (inout T) -> Void) { lock.withLock { transform(&_value) } }
}

/// A sendable box for the session so we can store it safely on nonisolated paths.
final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Types

enum PeerRole {
    case macHost
    case phoneSensor
}

enum PeerMessage: Codable {
    case calibrate(targetIndex: Int, target: CalibrationTarget, colorSpace: DisplayColorSpace)
    case measurement(CalibrationMeasurement)
    case calibrationFinished(CalibrationProfile)
}

@MainActor
@Observable
final class PeerCalibrationSession: NSObject {
    var connectedPeerName: String?
    var connectionDescription = "Searching for partner device..."

    @ObservationIgnored
    var onMeasurement: ((CalibrationMeasurement) -> Void)?
    @ObservationIgnored
    var onCalibrationStep: ((Int, CalibrationTarget, DisplayColorSpace) -> Void)?
    @ObservationIgnored
    var onCalibrationFinished: ((CalibrationProfile) -> Void)?
    @ObservationIgnored
    var onDisconnect: (() -> Void)?

    private let serviceType = "clrclb"
    private let role: PeerRole
    private let peerID: MCPeerID

    /// Thread-safe box so we can access the session from delegate callbacks.
    @ObservationIgnored
    private let sessionBox: SendableBox<MCSession>

    private var session: MCSession { sessionBox.value }

    @ObservationIgnored
    private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored
    private var browser: MCNearbyServiceBrowser?

    /// Track previous connection state to detect disconnects.
    @ObservationIgnored
    private let wasConnected = Synchronized(false)

    init(role: PeerRole) {
        self.role = role
        let deviceName: String
        #if os(macOS)
            deviceName = Host.current().localizedName ?? "Mac"
        #else
            deviceName = UIDevice.current.name
        #endif
        self.peerID = MCPeerID(displayName: deviceName)
        let session = MCSession(
            peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        self.sessionBox = SendableBox(session)
        super.init()
        session.delegate = self
        start()
    }

    var isConnected: Bool {
        !session.connectedPeers.isEmpty
    }

    func sendCalibrationStep(index: Int, target: CalibrationTarget, colorSpace: DisplayColorSpace) {
        send(.calibrate(targetIndex: index, target: target, colorSpace: colorSpace))
    }

    func sendMeasurement(_ measurement: CalibrationMeasurement) {
        send(.measurement(measurement))
    }

    func sendFinishedProfile(_ profile: CalibrationProfile) {
        send(.calibrationFinished(profile))
    }

    func restartDiscovery() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        start()
    }

    private func start() {
        switch role {
        case .macHost:
            let advertiser = MCNearbyServiceAdvertiser(
                peer: peerID, discoveryInfo: ["role": "mac"], serviceType: serviceType)
            advertiser.delegate = self
            advertiser.startAdvertisingPeer()
            self.advertiser = advertiser
            connectionDescription = "Waiting for iPhone to connect..."
        case .phoneSensor:
            let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
            browser.delegate = self
            browser.startBrowsingForPeers()
            self.browser = browser
            connectionDescription = "Looking for the Mac calibration host..."
        }
    }

    private func send(_ message: PeerMessage) {
        guard !session.connectedPeers.isEmpty,
            let data = try? JSONEncoder().encode(message)
        else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func applyConnectedPeers() {
        connectedPeerName = session.connectedPeers.first?.displayName
        if let name = connectedPeerName {
            connectionDescription = "Connected to \(name)"
        } else {
            connectionDescription =
                role == .macHost
                ? "Waiting for iPhone to connect..." : "Looking for the Mac calibration host..."
        }
    }
}

extension PeerCalibrationSession: MCSessionDelegate {
    nonisolated func session(
        _ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState
    ) {
        Task { @MainActor in
            self.applyConnectedPeers()
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID)
    {
        Task { @MainActor in
            guard let message = try? JSONDecoder().decode(PeerMessage.self, from: data) else {
                return
            }
            switch message {
            case .measurement(let measurement):
                self.onMeasurement?(measurement)
            case .calibrate(let index, let target, let colorSpace):
                self.onCalibrationStep?(index, target, colorSpace)
            case .calibrationFinished(let profile):
                self.onCalibrationFinished?(profile)
            }
        }
    }

    nonisolated func session(
        _ session: MCSession, didReceive stream: InputStream, withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}
    nonisolated func session(
        _ session: MCSession, didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID, with progress: Progress
    ) {}
    nonisolated func session(
        _ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?
    ) {}
    nonisolated func session(
        _ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID,
        certificateHandler: @escaping (Bool) -> Void
    ) {
        certificateHandler(true)
    }
}

extension PeerCalibrationSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor in
            invitationHandler(true, self.sessionBox.value)
        }
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error
    ) {
        Task { @MainActor in
            self.connectionDescription = "Mac advertising failed: \(error.localizedDescription)"
        }
    }
}

extension PeerCalibrationSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        guard info?["role"] == "mac" else { return }
        Task { @MainActor in
            browser.invitePeer(peerID, to: self.sessionBox.value, withContext: nil, timeout: 12)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.applyConnectedPeers()
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error
    ) {
        Task { @MainActor in
            self.connectionDescription = "Discovery failed: \(error.localizedDescription)"
        }
    }
}
