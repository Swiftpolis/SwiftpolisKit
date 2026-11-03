import Foundation
import Security
import SwiftpolisDomain
import SwiftpolisEngines

/// Where each Download's passwords and browser cookies live, away from the library.
public protocol SecretStore: Sendable {
    func load(for gid: GID) -> DownloadSecrets
    func save(_ secrets: DownloadSecrets, for gid: GID)
    func remove(for gid: GID)
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [GID: DownloadSecrets] = [:]

    public init() {}

    public func load(for gid: GID) -> DownloadSecrets {
        lock.withLock { secrets[gid] ?? DownloadSecrets() }
    }

    public func save(_ newSecrets: DownloadSecrets, for gid: GID) {
        lock.withLock { secrets[gid] = newSecrets }
    }

    public func remove(for gid: GID) {
        lock.withLock { secrets[gid] = nil }
    }
}

/// Stores secrets as generic passwords in the user's login Keychain.
public struct KeychainSecretStore: SecretStore {
    private enum Slot: String, CaseIterable {
        case proxy
        case http
        case cookie
    }

    private let service: String

    public init(service: String = "com.amirabravesh.Swiftpolis.download") {
        self.service = service
    }

    public func load(for gid: GID) -> DownloadSecrets {
        DownloadSecrets(
            proxyPassword: read(.proxy, gid),
            httpPassword: read(.http, gid),
            cookieHeader: read(.cookie, gid)
        )
    }

    public func save(_ secrets: DownloadSecrets, for gid: GID) {
        write(secrets.proxyPassword, slot: .proxy, gid)
        write(secrets.httpPassword, slot: .http, gid)
        write(secrets.cookieHeader, slot: .cookie, gid)
    }

    public func remove(for gid: GID) {
        for slot in Slot.allCases { write(nil, slot: slot, gid) }
    }

    private func query(_ slot: Slot, _ gid: GID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(gid.rawValue).\(slot.rawValue)",
        ]
    }

    private func read(_ slot: Slot, _ gid: GID) -> String? {
        var request = query(slot, gid)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ value: String?, slot: Slot, _ gid: GID) {
        let match = query(slot, gid)
        SecItemDelete(match as CFDictionary)
        guard let value else { return }
        var item = match
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
