import Foundation
import MultipeerConnectivity
import Observation

#if os(iOS)
    import UIKit
#endif

enum PeerRole {
    case macHost
    case phoneSensor
}

enum PeerMessage: Codable {
    case calibrate(targetIndex: Int, target: CalibrationTarget)
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
    var onCalibrationStep: ((Int, CalibrationTarget) -> Void)?
    @ObservationIgnored
    var onCalibrationFinished: ((CalibrationProfile) -> Void)?

    private let serviceType = "clrclb"
    private let role: PeerRole
    private let peerID: MCPeerID
    @ObservationIgnored nonisolated(unsafe) private let session: MCSession
    @ObservationIgnored
    private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored
    private var browser: MCNearbyServiceBrowser?

    init(role: PeerRole) {
        self.role = role
        let deviceName: String
        #if os(macOS)
            deviceName = Host.current().localizedName ?? "Mac"
        #else
            deviceName = UIDevice.current.name
        #endif
        self.peerID = MCPeerID(displayName: deviceName)
        self.session = MCSession(
            peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
        start()
    }

    var isConnected: Bool {
        !session.connectedPeers.isEmpty
    }

    func sendCalibrationStep(index: Int, target: CalibrationTarget) {
        send(.calibrate(targetIndex: index, target: target))
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
            case .calibrate(let index, let target):
                self.onCalibrationStep?(index, target)
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
        invitationHandler(true, session)
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
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 12)
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
