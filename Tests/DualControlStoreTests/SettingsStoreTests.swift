#if canImport(Darwin)
    import DualControlCore
    import Foundation
    import Testing

    @testable import DualControlStore

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "dualcontrol.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func defaultsWhenNothingIsSaved() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            #expect(store.approvalTimeout == 600)
            #expect(store.rules == [])
            #expect(store.deviceRules == [])
        }
    }

    @Test func settingsRoundTrip() throws {
        try withDefaults { defaults in
            let rules = [
                AllowRule(id: "a", projectID: "/w", folder: "/w", argv: ["make", "a b"]),
                AllowRule(id: "b", projectID: "/x", folder: "/x", argv: ["ls"]),
            ]
            let deviceRules = [
                DeviceRule(
                    id: "d",
                    folder: "/w",
                    device: SerialDevice(vendorID: 0x10C4, productID: 0xEA60, serialNumber: "1")
                )
            ]
            var store = SettingsStore(defaults: defaults)
            store.approvalTimeout = 120
            store.rules = rules
            store.deviceRules = deviceRules
            let reloaded = SettingsStore(defaults: defaults)
            #expect(reloaded.approvalTimeout == 120)
            #expect(reloaded.rules == rules)
            #expect(reloaded.deviceRules == deviceRules)
        }
    }

    @Test func theLastSessionFolderIsKeptButNeverTheMode() throws {
        try withDefaults { defaults in
            #expect(SettingsStore(defaults: defaults).lastSessionFolder == nil)
            var store = SettingsStore(defaults: defaults)
            store.lastSessionFolder = "/Users/o/Developer/p"
            store.repositoryPolicies = ["/Users/o/Developer/p": RepositoryPolicy(autoPush: true, maxOpenBranches: 3)]
            let reloaded = SettingsStore(defaults: defaults)
            #expect(reloaded.lastSessionFolder == "/Users/o/Developer/p")
            #expect(
                reloaded.repositoryPolicies["/Users/o/Developer/p"]
                    == RepositoryPolicy(autoPush: true, maxOpenBranches: 3)
            )
            // Nothing about the approval mode is saved: every launch starts in ask-each.
            // Keys of an untouched suite are the global ones; everything else was written by the store.
            let empty = try #require(UserDefaults(suiteName: "dualcontrol.tests.untouched"))
            let baseline = Set(empty.dictionaryRepresentation().keys)
            let written = Set(defaults.dictionaryRepresentation().keys).subtracting(baseline)
            #expect(written == [SettingsStore.lastSessionFolderKey, SettingsStore.repositoryPoliciesKey])
            store.lastSessionFolder = nil
            #expect(SettingsStore(defaults: defaults).lastSessionFolder == nil)
            // Only an absolute path is taken back.
            defaults.set("relative/p", forKey: SettingsStore.lastSessionFolderKey)
            #expect(SettingsStore(defaults: defaults).lastSessionFolder == nil)
            defaults.set(42, forKey: SettingsStore.lastSessionFolderKey)
            #expect(SettingsStore(defaults: defaults).lastSessionFolder == nil)
        }
    }

    @Test func corruptRulesLoadAsNone() throws {
        try withDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: SettingsStore.rulesKey)
            defaults.set(Data("not json".utf8), forKey: SettingsStore.deviceRulesKey)
            defaults.set("soon", forKey: SettingsStore.timeoutKey)
            let store = SettingsStore(defaults: defaults)
            #expect(store.rules == [])
            #expect(store.deviceRules == [])
            #expect(store.approvalTimeout == 600)
        }
    }

    @Test func allowedHostsKeepOnlyHostNames() throws {
        try withDefaults { defaults in
            #expect(SettingsStore(defaults: defaults).allowedHosts == [])
            var store = SettingsStore(defaults: defaults)
            store.allowedHosts = ["mirror.example.org", "Example.COM."]
            #expect(SettingsStore(defaults: defaults).allowedHosts == ["mirror.example.org", "example.com"])
            // Something edited into the defaults by hand is filtered on the way in, too.
            defaults.set(["10.0.0.1", "localhost", "ok.example"], forKey: SettingsStore.allowedHostsKey)
            #expect(SettingsStore(defaults: defaults).allowedHosts == ["ok.example"])
            defaults.set("not a list", forKey: SettingsStore.allowedHostsKey)
            #expect(SettingsStore(defaults: defaults).allowedHosts == [])
        }
    }
#endif
