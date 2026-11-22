#if canImport(Darwin)
    import DualControlCore
    import Foundation

    /// The owner's settings in UserDefaults: the approval timeout, the project rules, the serial device rules and
    /// the network hosts allowed always. Nothing secret.
    ///
    /// Unreadable values fall back to the defaults (600 s, no rules, no extra hosts), which never allow more than
    /// before.
    public struct SettingsStore {
        static let timeoutKey = "approvalTimeoutSeconds"
        static let rulesKey = "projectRules"
        static let deviceRulesKey = "deviceRules"
        static let allowedHostsKey = "allowedHosts"
        static let repositoryPoliciesKey = "repositoryPolicies"
        static let relayBudgetKey = "modelRelayBudget"
        static let lastSessionFolderKey = "lastSessionFolder"

        private let defaults: UserDefaults

        /// A store backed by `defaults`.
        public init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        /// Seconds an ask waits before it is denied.
        public var approvalTimeout: TimeInterval {
            get { (defaults.object(forKey: Self.timeoutKey) as? NSNumber)?.doubleValue ?? 600 }
            set { defaults.set(newValue, forKey: Self.timeoutKey) }
        }

        /// The session folder last chosen (D13b), offered again at launch after its checks run again; only an
        /// absolute path. The approval mode is never saved.
        public var lastSessionFolder: String? {
            get { defaults.string(forKey: Self.lastSessionFolderKey).flatMap { $0.hasPrefix("/") ? $0 : nil } }
            set { defaults.set(newValue, forKey: Self.lastSessionFolderKey) }
        }

        /// Per repository: auto-push of agent branches and the cap on open ones (D12b).
        public var repositoryPolicies: [String: RepositoryPolicy] {
            get {
                guard let data = defaults.data(forKey: Self.repositoryPoliciesKey) else { return [:] }
                return (try? JSONDecoder().decode([String: RepositoryPolicy].self, from: data)) ?? [:]
            }
            set {
                guard let data = try? JSONEncoder().encode(newValue) else { return }
                defaults.set(data, forKey: Self.repositoryPoliciesKey)
            }
        }

        /// The model relay's monthly budget and this month's spend (D12e).
        public var relayBudget: RelayBudget? {
            get {
                guard let data = defaults.data(forKey: Self.relayBudgetKey) else { return nil }
                return try? JSONDecoder().decode(RelayBudget.self, from: data)
            }
            set {
                guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                    defaults.removeObject(forKey: Self.relayBudgetKey)
                    return
                }
                defaults.set(data, forKey: Self.relayBudgetKey)
            }
        }

        /// Project allow rules.
        public var rules: [AllowRule] {
            get {
                guard let data = defaults.data(forKey: Self.rulesKey) else { return [] }
                return (try? JSONDecoder().decode([AllowRule].self, from: data)) ?? []
            }
            set {
                guard let data = try? JSONEncoder().encode(newValue) else { return }
                defaults.set(data, forKey: Self.rulesKey)
            }
        }

        /// Serial device rules.
        public var deviceRules: [DeviceRule] {
            get {
                guard let data = defaults.data(forKey: Self.deviceRulesKey) else { return [] }
                return (try? JSONDecoder().decode([DeviceRule].self, from: data)) ?? []
            }
            set {
                guard let data = try? JSONEncoder().encode(newValue) else { return }
                defaults.set(data, forKey: Self.deviceRulesKey)
            }
        }

        /// Network hosts the owner allowed always. Only valid host names are kept (`NetworkHost.normalized`).
        public var allowedHosts: [String] {
            get { (defaults.stringArray(forKey: Self.allowedHostsKey) ?? []).compactMap(NetworkHost.normalized) }
            set { defaults.set(newValue.compactMap(NetworkHost.normalized), forKey: Self.allowedHostsKey) }
        }
    }
#endif
