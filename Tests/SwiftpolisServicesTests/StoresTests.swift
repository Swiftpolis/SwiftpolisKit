import Foundation
import Testing
import SwiftpolisDomain
import SwiftpolisEngines
import SwiftpolisServices

@Suite("Preferences")
struct PreferencesTests {
    private func makeStore() throws -> (PreferencesStore, () -> Void) {
        let suite = "SwiftpolisTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (PreferencesStore(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    @Test("defaults match Persepolis's")
    func defaults() throws {
        let (store, cleanUp) = try makeStore()
        defer { cleanUp() }
        let preferences = store.preferences

        #expect(preferences.maxTries == 5)
        #expect(preferences.retryWaitSeconds == 5)
        #expect(preferences.timeoutSeconds == 10)
        #expect(preferences.connections == 64)
        #expect(preferences.chunkSizeKiB == 100)
        #expect(preferences.verifiesCertificates)
        #expect(preferences.usesSubfolders)
        #expect(preferences.showsProgressWindow)
        #expect(preferences.showsAfterDownloadDialog)
        #expect(!preferences.keepsSystemAwake)
        #expect(preferences.downloadFolder.hasSuffix("/Downloads/Swiftpolis"))
    }

    @Test("changes are saved")
    func saves() throws {
        let (store, cleanUp) = try makeStore()
        defer { cleanUp() }
        var preferences = store.preferences
        preferences.connections = 8
        preferences.downloadFolder = "/tmp/x"
        preferences.usesSubfolders = false

        store.preferences = preferences

        #expect(store.preferences == preferences)
    }

    @Test("the engine gets its settings from them")
    func engineSettings() {
        var preferences = Preferences()
        preferences.maxTries = 2
        preferences.retryWaitSeconds = 7
        preferences.timeoutSeconds = 9
        preferences.chunkSizeKiB = 50
        preferences.verifiesCertificates = false
        preferences.downloadFolder = "/d"
        preferences.usesSubfolders = false

        let settings = preferences.engineSettings

        #expect(settings.maxTries == 2)
        #expect(settings.retryWait == 7)
        #expect(settings.timeout == 9)
        #expect(settings.chunkSizeKiB == 50)
        #expect(!settings.verifiesCertificates)
        #expect(settings.defaultFolder == "/d")
        #expect(!settings.usesSubfolders)
    }
}

@Suite("Keychain secrets")
struct KeychainSecretStoreTests {
    @Test("passwords round-trip, and removing leaves nothing behind")
    func roundTrip() throws {
        // A service name of its own, so this never touches real downloads' passwords.
        let store = KeychainSecretStore(service: "com.amirabravesh.Swiftpolis.tests.\(UUID().uuidString)")
        let gid = try #require(GID(rawValue: "1a2b3c4d5e6f7a8b"))
        defer { store.remove(for: gid) }

        store.save(DownloadSecrets(proxyPassword: "proxy", httpPassword: "http"), for: gid)
        #expect(store.load(for: gid).proxyPassword == "proxy")
        #expect(store.load(for: gid).httpPassword == "http")

        store.save(DownloadSecrets(proxyPassword: "new"), for: gid)
        #expect(store.load(for: gid).proxyPassword == "new")
        #expect(store.load(for: gid).httpPassword == nil)

        store.remove(for: gid)
        #expect(store.load(for: gid).proxyPassword == nil)
    }
}
