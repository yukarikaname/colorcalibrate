#if os(iOS)
    import Foundation
    import Network
    import Observation
    import dnssd

    enum LocalNetworkAccessState: Equatable {
        case unknown
        case requesting
        case granted
        case denied
        case failed(String)

        var description: String {
            switch self {
            case .unknown:
                return "Not requested"
            case .requesting:
                return "Requesting local network access..."
            case .granted:
                return "Local network access ready"
            case .denied:
                return "Local network access denied"
            case .failed(let message):
                return message
            }
        }
    }

    @MainActor
    @Observable
    final class LocalNetworkPermissionController {
        private static let dnsPolicyDeniedErrors: Set<DNSServiceErrorType> = [
            DNSServiceErrorType(kDNSServiceErr_PolicyDenied),
            DNSServiceErrorType(kDNSServiceErr_NotPermitted),
        ]
        private static let dnsNoRouter = DNSServiceErrorType(kDNSServiceErr_NoRouter)
        private static let dnsServiceNotRunning = DNSServiceErrorType(
            kDNSServiceErr_ServiceNotRunning)

        private(set) var state: LocalNetworkAccessState = .unknown
        private(set) var discoveredServices: [String] = []

        @ObservationIgnored
        private var browser: NWBrowser?
        @ObservationIgnored
        private var listener: NWListener?
        @ObservationIgnored
        private var readinessTask: Task<Void, Never>?

        func requestAccess() {
            stop()
            state = .requesting
            discoveredServices = []

            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true

            do {
                let listener = try NWListener(using: parameters)
                listener.service = NWListener.Service(
                    name: "ColorCalibrateProbe", type: "_clrclb._tcp")
                self.listener = listener

                let browser = NWBrowser(
                    for: .bonjour(type: "_clrclb._tcp", domain: nil), using: parameters)
                self.browser = browser

                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.state = .granted
                        case .failed(let error):
                            self.handleProbeFailure(error)
                            self.stop()
                        default:
                            break
                        }
                    }
                }

                browser.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if case .requesting = self.state {
                                self.state = .granted
                            }
                        case .failed(let error):
                            self.handleProbeFailure(error)
                            self.stop()
                        default:
                            break
                        }
                    }
                }

                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    Task { @MainActor [weak self] in
                        self?.discoveredServices = results.compactMap { result in
                            switch result.endpoint {
                            case .service(let name, _, let domain, _):
                                return domain.isEmpty ? name : "\(name).\(domain)"
                            default:
                                return nil
                            }
                        }.sorted()
                    }
                }

                browser.start(queue: .main)
                listener.start(queue: .main)
                state = .granted

                readinessTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    if self.state == .requesting { self.state = .granted }
                }
            } catch {
                state = .failed("Could not start local network probe.")
            }
        }

        func stop() {
            readinessTask?.cancel()
            readinessTask = nil
            browser?.cancel()
            listener?.cancel()
            browser = nil
            listener = nil
        }

        private func handleProbeFailure(_ error: NWError) {
            if Self.isPermissionDenied(error) {
                state = .denied
                return
            }

            if case .granted = state {
                return
            }

            state = .failed(Self.message(for: error))
        }

        private static func isPermissionDenied(_ error: NWError) -> Bool {
            guard case .dns(let code) = error else { return false }
            return dnsPolicyDeniedErrors.contains(code)
        }

        private static func message(for error: NWError) -> String {
            if case .dns(let code) = error {
                switch code {
                case dnsNoRouter:
                    return "No local network route is available right now."
                case dnsServiceNotRunning:
                    return "Bonjour is not available right now."
                default:
                    break
                }
            }

            return "Local network search failed. You can retry."
        }
    }
#endif
