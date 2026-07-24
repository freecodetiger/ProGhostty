import Foundation

public enum SplitAxis: String, Codable, Equatable, Sendable {
  /// Left/right panes.
  case horizontal
  /// Top/bottom panes.
  case vertical
}

public typealias TerminalSplitAxis = SplitAxis

public struct TerminalPane: Identifiable, Codable, Equatable, Sendable {
  public var paneId: UUID
  public var sessionId: TerminalSessionID
  public var title: String
  public var cwd: String?
  /// User-assigned display label; nil = not set (label hidden).
  public var label: String?

  public var id: UUID { paneId }
  public var sessionID: TerminalSessionID { sessionId }

  public init(
    paneId: UUID = UUID(),
    sessionId: TerminalSessionID,
    title: String = "zsh",
    cwd: String? = nil,
    label: String? = nil
  ) {
    self.paneId = paneId
    self.sessionId = sessionId
    self.title = title
    self.cwd = cwd
    self.label = label
  }

  public init(id: UUID = UUID(), sessionID: TerminalSessionID) {
    self.init(paneId: id, sessionId: sessionID)
  }
}

public struct SplitPane: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var axis: SplitAxis
  public var ratio: Double
  public var first: PaneNode
  public var second: PaneNode

  public init(
    id: UUID = UUID(),
    axis: SplitAxis,
    ratio: Double = 0.5,
    first: PaneNode,
    second: PaneNode
  ) {
    self.id = id
    self.axis = axis
    self.ratio = Self.clampedRatio(ratio)
    self.first = first
    self.second = second
  }

  static func clampedRatio(_ ratio: Double) -> Double {
    min(0.9, max(0.1, ratio))
  }
}

public indirect enum PaneNode: Codable, Equatable, Sendable {
  case leaf(TerminalPane)
  case split(SplitPane)
}

public struct WorkspaceLayout: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var root: PaneNode
  public var workspaceId: UUID?

  public init(
    id: UUID = UUID(),
    title: String,
    root: PaneNode,
    workspaceId: UUID? = nil
  ) {
    self.id = id
    self.title = title
    self.root = root
    self.workspaceId = workspaceId
  }
}

@MainActor
public final class TerminalFocusStore {
  private var focusedPaneByWorkspaceId: [UUID: UUID] = [:]

  public init(focusedPaneByWorkspaceId: [UUID: UUID] = [:]) {
    self.focusedPaneByWorkspaceId = focusedPaneByWorkspaceId
  }

  public func focusPane(_ paneId: UUID?, in workspaceId: UUID) {
    if let paneId {
      focusedPaneByWorkspaceId[workspaceId] = paneId
    } else {
      focusedPaneByWorkspaceId[workspaceId] = nil
    }
  }

  public func focusedPaneId(in workspaceId: UUID) -> UUID? {
    focusedPaneByWorkspaceId[workspaceId]
  }

  public func removeFocus(for workspaceId: UUID) {
    focusedPaneByWorkspaceId[workspaceId] = nil
  }

  public func focusedSessionId(in workspace: WorkspaceLayout) -> TerminalSessionID? {
    guard let focusedPaneId = focusedPaneId(in: workspace.id) else { return nil }
    return PaneTreeReducer.findPane(in: workspace.root, paneId: focusedPaneId)?.sessionId
  }
}

public enum PaneTreeReducer {
  @discardableResult
  public static func splitPane(
    in root: inout PaneNode,
    targetPaneId: UUID,
    axis: SplitAxis,
    newPane: TerminalPane,
    ratio: Double = 0.5
  ) -> Bool {
    switch root {
    case .leaf(let pane) where pane.paneId == targetPaneId:
      root = .split(SplitPane(
        axis: axis,
        ratio: ratio,
        first: .leaf(pane),
        second: .leaf(newPane)
      ))
      return true
    case .leaf:
      return false
    case .split(var split):
      if splitPane(in: &split.first, targetPaneId: targetPaneId, axis: axis, newPane: newPane, ratio: ratio) {
        root = .split(split)
        return true
      }
      if splitPane(in: &split.second, targetPaneId: targetPaneId, axis: axis, newPane: newPane, ratio: ratio) {
        root = .split(split)
        return true
      }
      return false
    }
  }

  @discardableResult
  public static func closePane(in root: inout PaneNode, paneId: UUID) -> TerminalPane? {
    guard case .split = root else { return nil }
    var closed: TerminalPane?
    if let replacement = closing(root, paneId: paneId, closed: &closed), closed != nil {
      root = replacement
    }
    return closed
  }

  @discardableResult
  public static func updateRatio(in root: inout PaneNode, splitId: UUID, ratio: Double) -> Bool {
    switch root {
    case .leaf:
      return false
    case .split(var split):
      if split.id == splitId {
        split.ratio = SplitPane.clampedRatio(ratio)
        root = .split(split)
        return true
      }
      if updateRatio(in: &split.first, splitId: splitId, ratio: ratio) {
        root = .split(split)
        return true
      }
      if updateRatio(in: &split.second, splitId: splitId, ratio: ratio) {
        root = .split(split)
        return true
      }
      return false
    }
  }

  public static func findPane(in root: PaneNode, paneId: UUID) -> TerminalPane? {
    switch root {
    case .leaf(let pane):
      return pane.paneId == paneId ? pane : nil
    case .split(let split):
      return findPane(in: split.first, paneId: paneId) ?? findPane(in: split.second, paneId: paneId)
    }
  }

  public static func listLeaves(in root: PaneNode) -> [TerminalPane] {
    switch root {
    case .leaf(let pane):
      return [pane]
    case .split(let split):
      return listLeaves(in: split.first) + listLeaves(in: split.second)
    }
  }

  public static func cwd(
    forPane paneId: UUID,
    in root: PaneNode,
    cwdBySession: [TerminalSessionID: String],
    fallback: String?
  ) -> String? {
    guard let pane = findPane(in: root, paneId: paneId) else {
      return nonEmpty(fallback)
    }
    return nonEmpty(cwdBySession[pane.sessionId])
      ?? nonEmpty(pane.cwd)
      ?? nonEmpty(fallback)
  }

  public static func mapLeaves(
    in root: PaneNode,
    transform: (TerminalPane) throws -> TerminalPane
  ) rethrows -> PaneNode {
    switch root {
    case .leaf(let pane):
      return .leaf(try transform(pane))
    case .split(let split):
      return .split(SplitPane(
        id: split.id,
        axis: split.axis,
        ratio: split.ratio,
        first: try mapLeaves(in: split.first, transform: transform),
        second: try mapLeaves(in: split.second, transform: transform)
      ))
    }
  }

  public static func splitIds(in root: PaneNode) -> [UUID] {
    switch root {
    case .leaf:
      return []
    case .split(let split):
      return [split.id] + splitIds(in: split.first) + splitIds(in: split.second)
    }
  }

  public static func neighborPaneId(in root: PaneNode, from paneId: UUID, offset: Int) -> UUID? {
    let leaves = listLeaves(in: root)
    guard let index = leaves.firstIndex(where: { $0.paneId == paneId }), !leaves.isEmpty else {
      return nil
    }
    let next = (index + offset + leaves.count) % leaves.count
    return leaves[next].paneId
  }

  private static func nonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func closing(
    _ node: PaneNode,
    paneId: UUID,
    closed: inout TerminalPane?
  ) -> PaneNode? {
    switch node {
    case .leaf(let pane):
      if pane.paneId == paneId {
        closed = pane
        return nil
      }
      return node
    case .split(let split):
      var firstClosed: TerminalPane?
      let first = closing(split.first, paneId: paneId, closed: &firstClosed)
      if let firstClosed {
        closed = firstClosed
        guard let first else {
          return split.second
        }
        var updated = split
        updated.first = first
        return .split(updated)
      }

      var secondClosed: TerminalPane?
      let second = closing(split.second, paneId: paneId, closed: &secondClosed)
      if let secondClosed {
        closed = secondClosed
        guard let second else {
          return split.first
        }
        var updated = split
        updated.second = second
        return .split(updated)
      }

      return node
    }
  }
}
