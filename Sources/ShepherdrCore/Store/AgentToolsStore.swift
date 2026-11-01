import Foundation
import Observation

/// Where the agent tools stand on each machine, and your choices about them: which machines not to
/// ask about, which to trust, which keep the machine list to themselves, and what this Mac is
/// called in the lists. Statuses live in memory and are learned again each launch.
@MainActor @Observable
public final class AgentToolsStore {
    public enum Status: Equatable, Sendable {
        /// Not checked yet this launch.
        case unknown
        case checking
        case missing
        /// Installed, but older than the tools this Shepherdr carries.
        case outdated(Int)
        case current
        /// Installed by a newer Shepherdr: left alone.
        case newer(Int)
        case installing
        case removing
        case failed(String)

        public var isInstalled: Bool {
            switch self {
            case .outdated, .current, .newer: true
            default: false
            }
        }
    }

    public struct MachineTools: Equatable, Sendable {
        public var status: Status = .unknown
        /// What the last check found.
        public var check: AgentTools.Check?
        public var lastCheck: Date?
    }

    public enum UpdatePolicy: String, CaseIterable, Sendable {
        case ask, always, never
    }

    public private(set) var machines: [String: MachineTools] = [:]
    /// Machines whose offer to install was put off until the next launch.
    public private(set) var postponed = Set<String>()
    public var updatePolicy: UpdatePolicy { didSet { defaults.set(updatePolicy.rawValue, forKey: Keys.policy) } }
    /// Machines never to offer the tools to.
    public private(set) var declined: Set<String>
    /// Machines whose handoffs, session requests and pages go through without asking.
    public private(set) var trusted: Set<String>
    /// Machines that only learn their own name, not the others'.
    public private(set) var unshared: Set<String>
    /// What this Mac is called in the machine lists; its computer name until you choose one.
    public private(set) var macName: String
    /// This Shepherdr among others that may keep the same machines: its machine list on each is
    /// named after it. Made once, at random.
    public let instanceID: String
    @ObservationIgnored private let defaults: UserDefaults

    enum Keys {
        static let policy = "agentTools.updatePolicy"
        static let declined = "agentTools.declined"
        static let trusted = "agentTools.trusted"
        static let unshared = "agentTools.unshared"
        static let macName = "agentTools.macName"
        static let instance = "agentTools.instance"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        updatePolicy = defaults.string(forKey: Keys.policy).flatMap(UpdatePolicy.init) ?? .ask
        declined = Set(defaults.stringArray(forKey: Keys.declined) ?? [])
        trusted = Set(defaults.stringArray(forKey: Keys.trusted) ?? [])
        unshared = Set(defaults.stringArray(forKey: Keys.unshared) ?? [])
        macName = defaults.string(forKey: Keys.macName).map(MachineList.clean) ?? MachineList.defaultMacName
        if let saved = defaults.string(forKey: Keys.instance), AgentTools.isInstance(saved) {
            instanceID = saved
        } else {
            instanceID = (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            defaults.set(instanceID, forKey: Keys.instance)
        }
    }

    public func tools(on machineID: String) -> MachineTools { machines[machineID] ?? MachineTools() }

    public func status(on machineID: String) -> Status { tools(on: machineID).status }

    public func set(_ status: Status, on machineID: String) {
        machines[machineID, default: MachineTools()].status = status
    }

    /// Records a check and the status it implies against the tools this Shepherdr carries.
    public func record(_ check: AgentTools.Check, on machineID: String, bundled: Int, at date: Date = Date()) {
        var tools = machines[machineID] ?? MachineTools()
        tools.check = check
        tools.lastCheck = date
        if let version = check.version {
            tools.status = version < bundled ? .outdated(version) : version > bundled ? .newer(version) : .current
        } else {
            tools.status = .missing
        }
        machines[machineID] = tools
    }

    /// A check that didn't get an answer: tried again later.
    public func recordFailedCheck(_ message: String, on machineID: String, at date: Date = Date()) {
        machines[machineID, default: MachineTools()].status = .failed(message)
        machines[machineID, default: MachineTools()].lastCheck = date
    }

    /// The machine list's revision there changed, such as after writing it.
    public func recordList(_ revision: String?, on machineID: String) {
        machines[machineID, default: MachineTools()].check?.listRevision = revision
    }

    public func forget(_ machineID: String) {
        machines[machineID] = nil
    }

    // MARK: Choices

    public func postpone(_ machineID: String) { postponed.insert(machineID) }

    /// Names this Mac in the lists; blank goes back to its computer name.
    public func setMacName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        macName = trimmed.isEmpty ? MachineList.defaultMacName : MachineList.clean(trimmed)
        if trimmed.isEmpty { defaults.removeObject(forKey: Keys.macName) } else { defaults.set(macName, forKey: Keys.macName) }
    }

    public func setDeclined(_ machineID: String, _ value: Bool) {
        update(&declined, machineID, value, key: Keys.declined)
    }

    public func setTrusted(_ machineID: String, _ value: Bool) {
        update(&trusted, machineID, value, key: Keys.trusted)
    }

    public func setShares(_ machineID: String, _ value: Bool) {
        update(&unshared, machineID, !value, key: Keys.unshared)
    }

    public func shares(_ machineID: String) -> Bool { !unshared.contains(machineID) }

    private func update(_ set: inout Set<String>, _ machineID: String, _ value: Bool, key: String) {
        guard set.contains(machineID) != value else { return }
        if value { set.insert(machineID) } else { set.remove(machineID) }
        defaults.set(set.sorted(), forKey: key)
    }
}
