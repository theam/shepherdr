import Foundation

/// Where a split puts its new pane: beside the pane it splits, or under it.
public enum SplitDirection: String, Sendable {
    case right, down
}

/// How Herdr lays out the panes of one tab.
public struct TabLayout: Equatable, Sendable {
    public struct Pane: Equatable, Sendable {
        public let paneID: String
        /// Its place in the tab, as parts of the tab's width and height, from 0 to 1.
        public let frame: CGRect

        public init(paneID: String, frame: CGRect) {
            self.paneID = paneID
            self.frame = frame
        }
    }

    public let tabID: String
    /// In Herdr's order, from the top left.
    public let panes: [Pane]

    public init(tabID: String, panes: [Pane]) {
        self.tabID = tabID
        self.panes = panes
    }
}

/// One of the panes a session shows side by side or stacked, because they share its Herdr tab.
public struct SplitPane: Identifiable, Equatable, Sendable {
    public let terminalID: String
    public let paneID: String
    /// Its place in the session's terminal area, as parts of its width and height.
    public let frame: CGRect

    public var id: String { terminalID }
}

extension MachineSnapshot {
    /// The panes of a terminal's tab, as Herdr lays them out, when the tab has more than one.
    public func split(of terminalID: String) -> [SplitPane]? {
        guard let pane = panes.first(where: { $0.terminalID == terminalID }),
              let layout = layouts[pane.tabID], layout.panes.count > 1 else { return nil }
        let terminals = Dictionary(panes.map { ($0.paneID, $0.terminalID) }, uniquingKeysWith: { first, _ in first })
        let split = layout.panes.compactMap { item in
            terminals[item.paneID].map { SplitPane(terminalID: $0, paneID: item.paneID, frame: item.frame) }
        }
        return split.count > 1 && split.contains { $0.terminalID == terminalID } ? split : nil
    }

    /// Whether a shell shows inside another pane's session rather than on its own: it shares its
    /// tab with an agent, or with a shell before it in the tab's layout.
    public func showsInside(shell terminalID: String) -> Bool {
        guard let split = split(of: terminalID) else { return false }
        let agentTerminals = Set(agents.map(\.id.terminalID))
        return split.contains { agentTerminals.contains($0.terminalID) } || split.first?.terminalID != terminalID
    }
}
