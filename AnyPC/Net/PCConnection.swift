import CryptoKit
import Foundation
import Network
import UIKit

struct Monitor: Identifiable, Equatable {
    let id: Int
    let name: String
    let width: Int
    let height: Int
    let primary: Bool
}

struct FsEntry: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDir: Bool
    let size: Int64
    let modified: Date?
}

struct FsListing {
    let path: String
    let parent: String
    let entries: [FsEntry]
}

enum ConnectionState: Equatable {
    case idle
    case connecting
    case needPair
    case pairing
    case connected
    case failed(String)
}

/// Everything needed to reach a PC: from a saved PC, a Bonjour result, a QR code or a typed IP.
struct ConnectTarget: Identifiable {
    let id = UUID()
    var name: String
    var hosts: [String]
    var port: Int = Wire.defaultPort
    var fingerprint: String?
    var serverId: String?
    var token: String?
    var pin: String?
    var endpoint: NWEndpoint?

    init(name: String, hosts: [String], port: Int = Wire.defaultPort, fingerprint: String? = nil,
         serverId: String? = nil, token: String? = nil, pin: String? = nil, endpoint: NWEndpoint? = nil) {
        self.name = name
        self.hosts = hosts
        self.port = port
        self.fingerprint = fingerprint
        self.serverId = serverId
        self.token = token
        self.pin = pin
        self.endpoint = endpoint
    }

    init(saved pc: SavedPC, endpoint: NWEndpoint?) {
        self.init(name: pc.name, hosts: [pc.host], port: pc.port, fingerprint: pc.fingerprint,
                  serverId: pc.id, token: pc.token, endpoint: endpoint)
    }

    /// Parses `anypc://pair?h=ip1,ip2&p=47800&fp=…&id=…&pin=123456&n=NAME`.
    init?(qr: String) {
        guard let c = URLComponents(string: qr), c.scheme == "anypc", c.host == "pair" else { return nil }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name] = item.value }
        let hosts = (q["h"] ?? "").split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
        guard !hosts.isEmpty, let fp = q["fp"], fp.count == 64 else { return nil }
        self.init(name: q["n"] ?? "PC", hosts: hosts, port: Int(q["p"] ?? "") ?? Wire.defaultPort,
                  fingerprint: fp.lowercased(), serverId: q["id"], pin: q["pin"])
    }
}

/// One connection to a PC: TLS WebSocket with certificate pinning, pairing, screen frames,
/// input and file transfer. Published state is only mutated on the main thread.
final class PCConnection: NSObject, ObservableObject {
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var serverName: String
    @Published private(set) var monitors: [Monitor] = []
    @Published private(set) var currentMonitor = 0
    @Published private(set) var seenFingerprint: String?
    @Published var pairMessage: String?
    @Published var toast: String?

    /// Called on the main thread for each decoded frame.
    var onFrame: ((UIImage, CGPoint?) -> Void)?
    private(set) var lastFrame: UIImage?
    private(set) var lastCursor: CGPoint?

    private(set) var target: ConnectTarget
    private var hostIndex = 0
    private var resolvedEndpoint = false
    private var gotMessage = false
    private var fingerprintMismatch = false
    private var userClosed = false
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var pingTimer: Timer?
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private let lock = NSLock()
    private var expectedFingerprint: String?

    // File transfers (main thread only)
    private var nextId: UInt32 = 1
    private var listHandlers: [UInt32: (Result<FsListing, Error>) -> Void] = [:]
    private var downloads: [UInt32: Download] = [:]
    private var uploads: [UInt32: Upload] = [:]

    private final class Download {
        let progress: (Double) -> Void
        let done: (Result<URL, Error>) -> Void
        var url: URL?
        var handle: FileHandle?
        var size: Int64 = 0
        var received: Int64 = 0
        init(progress: @escaping (Double) -> Void, done: @escaping (Result<URL, Error>) -> Void) {
            self.progress = progress
            self.done = done
        }
    }

    private final class Upload {
        let handle: FileHandle
        let size: Int64
        var sent: Int64 = 0
        let progress: (Double) -> Void
        let done: (Result<String, Error>) -> Void
        init(handle: FileHandle, size: Int64, progress: @escaping (Double) -> Void, done: @escaping (Result<String, Error>) -> Void) {
            self.handle = handle
            self.size = size
            self.progress = progress
            self.done = done
        }
    }

    init(target: ConnectTarget) {
        self.target = target
        self.serverName = target.name
        super.init()
    }

    deinit {
        pingTimer?.invalidate()
        session?.invalidateAndCancel()
    }

    // MARK: - Connection lifecycle

    func connect() {
        userClosed = false
        fingerprintMismatch = false
        pairMessage = nil
        state = .connecting
        if let endpoint = target.endpoint, !resolvedEndpoint {
            Discovery.resolve(endpoint) { [weak self] host in
                guard let self = self, !self.userClosed else { return }
                self.resolvedEndpoint = true
                if let host = host {
                    self.target.hosts.removeAll { $0 == host }
                    self.target.hosts.insert(host, at: 0)
                }
                self.open(hostAt: 0)
            }
            return
        }
        open(hostAt: 0)
    }

    private func open(hostAt index: Int) {
        guard index < target.hosts.count else {
            state = .failed("Could not find the PC on the network. Make sure AnyPC is running on the PC and both devices are on the same Wi-Fi.")
            return
        }
        closeSocket()
        generation += 1
        let gen = generation
        hostIndex = index
        gotMessage = false

        let host = target.hosts[index]
        let hostPart = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "wss://\(hostPart):\(target.port)\(Wire.path)") else {
            state = .failed("Invalid address: \(host)")
            return
        }

        lock.lock()
        expectedFingerprint = target.fingerprint
        lock.unlock()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.session = session
        self.task = task
        task.resume()
        receive(task, gen: gen)
    }

    private func closeSocket() {
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }

    /// Closes the connection; the view is going away.
    func disconnect() {
        userClosed = true
        generation += 1
        closeSocket()
        failTransfers("Disconnected")
        state = .idle
    }

    /// Called when the app goes to the background; `connect()` resumes.
    func suspend() {
        guard state == .connected || state == .connecting else { return }
        generation += 1
        closeSocket()
        failTransfers("Connection interrupted")
        state = .idle
    }

    private func socketFailed(_ error: Error?, gen: Int) {
        guard gen == generation, !userClosed else { return }
        closeSocket()
        failTransfers("Connection lost")
        if fingerprintMismatch {
            state = .failed("Security check failed: this PC's security code doesn't match the one saved when you paired. If you reinstalled AnyPC on the PC, remove it from the list and pair again.")
            return
        }
        if !gotMessage && hostIndex + 1 < target.hosts.count {
            open(hostAt: hostIndex + 1)
            return
        }
        if state == .connected {
            state = .failed("Connection to \(serverName) was lost.")
        } else {
            let detail = (error as NSError?)?.localizedDescription ?? "Unknown error"
            state = .failed("Could not connect to \(serverName) (\(target.hosts[min(hostIndex, target.hosts.count - 1)])).\n\n\(detail)\n\nCheck that AnyPC is running on the PC, both devices are on the same Wi-Fi, and Local Network access is allowed in Settings › AnyPC.")
        }
    }

    // MARK: - Sending

    func send(_ obj: [String: Any]) {
        guard let task = task,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func sendHello() {
        var hello: [String: Any] = [
            "t": "hello", "v": Wire.version,
            "deviceId": PCStore.deviceId, "deviceName": PCStore.deviceName,
        ]
        if let token = target.token { hello["token"] = token }
        send(hello)
    }

    func pair(pin: String) {
        pairMessage = nil
        state = .pairing
        send(["t": "pair", "deviceId": PCStore.deviceId, "deviceName": PCStore.deviceName, "pin": pin])
    }

    func startStream(monitor: Int? = nil) {
        if let m = monitor { currentMonitor = m }
        send([
            "t": "stream", "on": true, "monitor": currentMonitor,
            "maxWidth": Prefs.maxWidth, "quality": Prefs.quality, "fps": Prefs.fps,
        ])
    }

    func stopStream() { send(["t": "stream", "on": false]) }

    // Input
    func move(_ p: CGPoint) { send(["t": "move", "x": Double(p.x), "y": Double(p.y)]) }
    func moveRelative(dx: Int, dy: Int) { send(["t": "moverel", "dx": dx, "dy": dy]) }
    func button(_ b: String = "left", _ a: String = "click") { send(["t": "button", "b": b, "a": a]) }
    func wheel(dx: Int, dy: Int) { send(["t": "wheel", "dx": dx, "dy": dy]) }
    func key(_ vk: UInt16, action: String = "press", mods: [String] = []) {
        send(["t": "key", "vk": Int(vk), "a": action, "mods": mods])
    }
    func text(_ s: String) { send(["t": "text", "s": s]) }
    func system(_ action: String) { send(["t": "sys", "a": action]) }

    // MARK: - Receiving

    private func receive(_ task: URLSessionWebSocketTask, gen: Int) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { self.socketFailed(error, gen: gen) }
            case .success(let message):
                switch message {
                case .string(let s):
                    DispatchQueue.main.async {
                        guard gen == self.generation else { return }
                        self.handleText(s)
                    }
                case .data(let d):
                    self.handleBinary(d, gen: gen)
                @unknown default:
                    break
                }
                self.receive(task, gen: gen)
            }
        }
    }

    /// Runs on the delegate queue so JPEG decoding stays off the main thread.
    private func handleBinary(_ data: Data, gen: Int) {
        guard let type = data.first else { return }
        if type == Wire.frameType, data.count > Wire.frameHeaderSize {
            let header = [UInt8](data.prefix(Wire.frameHeaderSize))
            let seq = Wire.readU32(header, 1)
            let cx = Wire.readU16(header, 9)
            let cy = Wire.readU16(header, 11)
            let jpeg = data.subdata(in: (data.startIndex + Wire.frameHeaderSize)..<data.endIndex)
            let image = UIImage(data: jpeg)
            let decoded = image?.preparingForDisplay() ?? image
            let cursor: CGPoint? = (cx == 0xFFFF || cy == 0xFFFF) ? nil : CGPoint(x: cx, y: cy)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                if let img = decoded {
                    self.lastFrame = img
                    self.lastCursor = cursor
                    self.onFrame?(img, cursor)
                }
                self.send(["t": "ack", "seq": Int(seq)])
            }
        } else if type == Wire.downloadChunkType, data.count >= Wire.chunkHeaderSize {
            let header = [UInt8](data.prefix(Wire.chunkHeaderSize))
            let id = Wire.readU32(header, 1)
            let payload = data.subdata(in: (data.startIndex + Wire.chunkHeaderSize)..<data.endIndex)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.handleDownloadChunk(id, payload)
            }
        }
    }

    private static func num(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
    private static func id(_ obj: [String: Any]) -> UInt32 { UInt32(truncatingIfNeeded: num(obj["id"])) }

    private func handleText(_ s: String) {
        guard let data = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = obj["t"] as? String else { return }
        gotMessage = true

        switch t {
        case "need_pair":
            if let name = obj["serverName"] as? String { serverName = name }
            if let sid = obj["serverId"] as? String { target.serverId = sid }
            if target.token != nil {
                // The PC no longer knows this phone (it was removed there).
                target.token = nil
                if let sid = target.serverId { PCStore.shared.remove(sid) }
                pairMessage = "This PC no longer recognizes your iPhone. Enter the PIN shown on the PC to pair again."
            }
            if let pin = target.pin {
                target.pin = nil
                pair(pin: pin)
            } else {
                state = .needPair
            }

        case "pair_fail":
            target.pin = nil
            let reason = obj["reason"] as? String ?? ""
            let retry = Self.num(obj["retryAfter"])
            pairMessage = reason == "locked"
                ? "Too many wrong PINs. Try again in \(retry) seconds."
                : "That PIN isn't right. Check the PIN shown in the AnyPC window on the PC."
            state = .needPair

        case "paired":
            if let token = obj["token"] as? String { target.token = token }

        case "welcome":
            if let name = obj["serverName"] as? String { serverName = name }
            if let sid = obj["serverId"] as? String { target.serverId = sid }
            let list = obj["monitors"] as? [[String: Any]] ?? []
            monitors = list.map {
                Monitor(id: Self.num($0["i"]), name: $0["name"] as? String ?? "Display",
                        width: Self.num($0["w"]), height: Self.num($0["h"]), primary: ($0["primary"] as? Bool) ?? false)
            }
            if !monitors.indices.contains(currentMonitor) {
                currentMonitor = monitors.firstIndex { $0.primary } ?? 0
            }
            saveToStore()
            state = .connected
            startStream()
            startPing()

        case "pong":
            break

        case "sys_ok":
            showToast("Done")

        case "error":
            showToast(obj["msg"] as? String ?? "Error")

        case "fs_list":
            let id = Self.id(obj)
            let entries = (obj["entries"] as? [[String: Any]] ?? []).map { e -> FsEntry in
                let m = Self.num(e["m"])
                let name = e["n"] as? String ?? "?"
                return FsEntry(name: name, path: e["p"] as? String ?? name, isDir: (e["d"] as? Bool) ?? false,
                               size: Int64(Self.num(e["s"])), modified: m > 0 ? Date(timeIntervalSince1970: TimeInterval(m)) : nil)
            }
            listHandlers.removeValue(forKey: id)?(.success(FsListing(path: obj["path"] as? String ?? "", parent: obj["parent"] as? String ?? "", entries: entries)))

        case "fs_meta":
            handleDownloadMeta(Self.id(obj), name: obj["name"] as? String ?? "download", size: Int64(Self.num(obj["size"])))

        case "fs_ready":
            pumpUpload(Self.id(obj))

        case "fs_done":
            let id = Self.id(obj)
            if let d = downloads.removeValue(forKey: id) {
                try? d.handle?.close()
                if let url = d.url { d.done(.success(url)) } else { d.done(.failure(AnyPCError("Download failed"))) }
            } else if let u = uploads.removeValue(forKey: id) {
                try? u.handle.close()
                u.done(.success(obj["name"] as? String ?? ""))
            }

        case "fs_err":
            let id = Self.id(obj)
            let err = AnyPCError(obj["msg"] as? String ?? "File error")
            listHandlers.removeValue(forKey: id)?(.failure(err))
            if let d = downloads.removeValue(forKey: id) {
                try? d.handle?.close()
                if let url = d.url { try? FileManager.default.removeItem(at: url) }
                d.done(.failure(err))
            }
            if let u = uploads.removeValue(forKey: id) {
                try? u.handle.close()
                u.done(.failure(err))
            }

        default:
            break
        }
    }

    private func saveToStore() {
        guard let sid = target.serverId, let token = target.token else { return }
        let fp = seenFingerprint ?? target.fingerprint ?? ""
        target.fingerprint = fp
        let host = target.hosts[min(hostIndex, target.hosts.count - 1)]
        PCStore.shared.upsert(SavedPC(id: sid, name: serverName, host: host, port: target.port,
                                      fingerprint: fp, token: token, lastConnected: Date()))
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.send(["t": "ping", "ts": Date().timeIntervalSince1970])
        }
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    // MARK: - Files

    private func newId() -> UInt32 {
        defer { nextId &+= 1 }
        return nextId
    }

    func list(_ path: String, completion: @escaping (Result<FsListing, Error>) -> Void) {
        let id = newId()
        listHandlers[id] = completion
        send(["t": "fs_list", "id": Int(id), "path": path])
    }

    static var downloadsFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("From PC", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func download(_ path: String, progress: @escaping (Double) -> Void, done: @escaping (Result<URL, Error>) -> Void) -> UInt32 {
        let id = newId()
        downloads[id] = Download(progress: progress, done: done)
        send(["t": "fs_get", "id": Int(id), "path": path])
        return id
    }

    func cancelTransfer(_ id: UInt32) {
        send(["t": "fs_cancel", "id": Int(id)])
    }

    private func handleDownloadMeta(_ id: UInt32, name: String, size: Int64) {
        guard let d = downloads[id] else { return }
        let safe = name.replacingOccurrences(of: "/", with: "_")
        var url = Self.downloadsFolder.appendingPathComponent(safe)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = Self.downloadsFolder.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            n += 1
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        d.url = url
        d.size = size
        d.handle = try? FileHandle(forWritingTo: url)
        if d.handle == nil {
            downloads.removeValue(forKey: id)
            cancelTransfer(id)
            d.done(.failure(AnyPCError("Could not create \(safe) on the iPhone")))
        }
    }

    private func handleDownloadChunk(_ id: UInt32, _ payload: Data) {
        guard let d = downloads[id], let h = d.handle else { return }
        h.write(payload)
        d.received += Int64(payload.count)
        d.progress(d.size > 0 ? Double(d.received) / Double(d.size) : 1)
    }

    func upload(_ fileURL: URL, toFolder dir: String, progress: @escaping (Double) -> Void, done: @escaping (Result<String, Error>) -> Void) {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            done(.failure(AnyPCError("Could not read \(fileURL.lastPathComponent)")))
            return
        }
        let id = newId()
        uploads[id] = Upload(handle: handle, size: size, progress: progress, done: done)
        send(["t": "fs_put", "id": Int(id), "dir": dir, "name": fileURL.lastPathComponent, "size": size])
    }

    private func pumpUpload(_ id: UInt32) {
        guard let up = uploads[id], let task = task else { return }
        let chunk: Data
        do {
            chunk = try up.handle.read(upToCount: Wire.chunkSize) ?? Data()
        } catch {
            uploads.removeValue(forKey: id)
            cancelTransfer(id)
            up.done(.failure(error))
            return
        }
        if chunk.isEmpty {
            send(["t": "fs_put_end", "id": Int(id)])
            return
        }
        up.sent += Int64(chunk.count)
        up.progress(up.size > 0 ? Double(up.sent) / Double(up.size) : 1)
        task.send(.data(Wire.chunk(type: Wire.uploadChunkType, id: id, payload: chunk))) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    if let u = self.uploads.removeValue(forKey: id) { u.done(.failure(error)) }
                } else {
                    self.pumpUpload(id)
                }
            }
        }
    }

    private func failTransfers(_ reason: String) {
        let err = AnyPCError(reason)
        let lists = listHandlers
        listHandlers.removeAll()
        lists.values.forEach { $0(.failure(err)) }
        let ds = downloads
        downloads.removeAll()
        for d in ds.values {
            try? d.handle?.close()
            if let url = d.url { try? FileManager.default.removeItem(at: url) }
            d.done(.failure(err))
        }
        let us = uploads
        uploads.removeAll()
        for u in us.values {
            try? u.handle.close()
            u.done(.failure(err))
        }
    }
}

// MARK: - URLSession delegate (TLS pinning and socket events)

extension PCConnection: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()

        lock.lock()
        let expected = expectedFingerprint
        lock.unlock()

        // The PC uses a self-signed certificate, so trust comes from pinning:
        // the fingerprint from the QR code / Bonjour / first pairing must match exactly.
        if let expected = expected, !expected.isEmpty, expected != fingerprint {
            DispatchQueue.main.async { self.fingerprintMismatch = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        DispatchQueue.main.async { self.seenFingerprint = fingerprint }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async {
            guard webSocketTask === self.task else { return }
            self.sendHello()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            guard task === self.task else { return }
            self.socketFailed(error, gen: self.generation)
        }
    }
}

extension ConnectionState {
    var isBusy: Bool { self == .connecting || self == .pairing }
}
