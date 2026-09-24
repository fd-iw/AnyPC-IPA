import Foundation
import Network

/// Finds PCs running AnyPC on the local network via Bonjour.
final class Discovery: ObservableObject {
    struct Found: Identifiable, Equatable {
        let id: String
        let name: String
        let serverId: String?
        let fingerprint: String?
        let endpoint: NWEndpoint
    }

    @Published private(set) var found: [Found] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Wire.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let items: [Found] = results.compactMap { r in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var sid: String?
                var fp: String?
                if case let .bonjour(txt) = r.metadata {
                    sid = txt["id"]
                    fp = txt["fp"]
                }
                return Found(id: sid ?? name, name: name, serverId: sid, fingerprint: fp, endpoint: r.endpoint)
            }
            DispatchQueue.main.async {
                self?.found = items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self?.browser?.cancel()
                    self?.browser = nil
                    self?.start()
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    func endpoint(for serverId: String) -> NWEndpoint? {
        found.first { $0.serverId == serverId }?.endpoint
    }

    /// Resolves a Bonjour service to an IPv4 address by briefly opening a TCP connection.
    static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 4, completion: @escaping (String?) -> Void) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: endpoint, using: params)
        var finished = false
        let finish: (String?) -> Void = { host in
            if finished { return }
            finished = true
            conn.cancel()
            completion(host)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case let .hostPort(host, _)? = conn.currentPath?.remoteEndpoint {
                    finish(hostString(host))
                } else {
                    finish(nil)
                }
            case .failed, .cancelled, .waiting:
                finish(nil)
            default:
                break
            }
        }
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }

    static func hostString(_ host: NWEndpoint.Host) -> String {
        let raw: String
        switch host {
        case .ipv4(let a): raw = "\(a)"
        case .ipv6(let a): raw = "\(a)"
        case .name(let n, _): raw = n
        @unknown default: raw = "\(host)"
        }
        // Drop any interface scope suffix such as "%en0".
        if let i = raw.firstIndex(of: "%") { return String(raw[..<i]) }
        return raw
    }
}
