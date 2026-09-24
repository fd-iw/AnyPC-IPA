import Foundation
import Security
import UIKit

/// A PC this phone has paired with.
struct SavedPC: Codable, Identifiable, Equatable {
    var id: String          // server id
    var name: String
    var host: String
    var port: Int
    var fingerprint: String // pinned TLS certificate SHA-256
    var token: String
    var lastConnected: Date?
}

/// Minimal Keychain wrapper for small secrets.
enum Keychain {
    private static let service = "com.anypc.remote"

    static func get(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func set(_ key: String, _ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Paired PCs, persisted in the Keychain (they contain access tokens).
final class PCStore: ObservableObject {
    static let shared = PCStore()
    private static let key = "saved-pcs"

    @Published private(set) var pcs: [SavedPC] = []

    private init() {
        if let data = Keychain.get(Self.key),
           let list = try? JSONDecoder().decode([SavedPC].self, from: data) {
            pcs = list
        }
    }

    func find(_ id: String?) -> SavedPC? {
        guard let id = id else { return nil }
        return pcs.first { $0.id == id }
    }

    func upsert(_ pc: SavedPC) {
        if let i = pcs.firstIndex(where: { $0.id == pc.id }) {
            pcs[i] = pc
        } else {
            pcs.append(pc)
        }
        save()
    }

    func remove(_ id: String) {
        pcs.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        pcs.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pcs) {
            Keychain.set(Self.key, data)
        }
    }

    /// Stable identifier for this phone, sent to the PC when pairing.
    static let deviceId: String = {
        if let data = Keychain.get("device-id"), let id = String(data: data, encoding: .utf8), !id.isEmpty {
            return id
        }
        let id = UUID().uuidString
        Keychain.set("device-id", Data(id.utf8))
        return id
    }()

    static var deviceName: String { UIDevice.current.name }
}

/// User preferences (also bound with @AppStorage in SettingsView).
enum Prefs {
    static let qualityKey = "quality"
    static let fpsKey = "fps"
    static let maxWidthKey = "maxWidth"
    static let sensitivityKey = "sensitivity"
    static let modeKey = "mode"

    static func register() {
        UserDefaults.standard.register(defaults: [
            qualityKey: 60.0,
            fpsKey: 20.0,
            maxWidthKey: 1136,
            sensitivityKey: 1.3,
            modeKey: "trackpad",
        ])
    }

    static var quality: Int { Int(UserDefaults.standard.double(forKey: qualityKey)) }
    static var fps: Int { Int(UserDefaults.standard.double(forKey: fpsKey)) }
    static var maxWidth: Int { UserDefaults.standard.integer(forKey: maxWidthKey) }
    static var sensitivity: Double { UserDefaults.standard.double(forKey: sensitivityKey) }
}
