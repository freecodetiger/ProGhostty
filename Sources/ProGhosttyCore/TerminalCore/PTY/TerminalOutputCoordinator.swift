import Foundation

@MainActor
public final class TerminalOutputCoordinator {
  public enum Delivery: Sendable {
    case coalesced
    case immediate
  }

  public typealias RenderOutputHandler = @MainActor (
    ResizeRenderSnapshot,
    GhosttyVTBridge,
    TerminalSessionID,
    Bool
  ) -> Void

  private struct PendingOutputRender {
    var snapshot: ResizeRenderSnapshot
    var bridge: GhosttyVTBridge
    var wasPinnedToBottom: Bool
  }

  private let coalescingDelayNanoseconds: UInt64
  private let renderOutputHandler: RenderOutputHandler
  private var pendingOutputRenders: [TerminalSessionID: PendingOutputRender] = [:]
  private var outputRenderTasks: [TerminalSessionID: Task<Void, Never>] = [:]

  public init(
    coalescingDelayNanoseconds: UInt64 = 8_000_000,
    renderOutputHandler: @escaping RenderOutputHandler
  ) {
    self.coalescingDelayNanoseconds = coalescingDelayNanoseconds
    self.renderOutputHandler = renderOutputHandler
  }

  public func scheduleRender(
    snapshot: ResizeRenderSnapshot,
    bridge: GhosttyVTBridge,
    session id: TerminalSessionID,
    wasPinnedToBottom: Bool,
    delivery: Delivery = .coalesced
  ) {
    if delivery == .immediate {
      outputRenderTasks[id]?.cancel()
      outputRenderTasks[id] = nil
      pendingOutputRenders[id] = nil
      renderOutputHandler(snapshot, bridge, id, wasPinnedToBottom)
      return
    }

    pendingOutputRenders[id] = PendingOutputRender(
      snapshot: snapshot,
      bridge: bridge,
      wasPinnedToBottom: wasPinnedToBottom
    )
    scheduleFlush(session: id)
  }

  public func flush(session id: TerminalSessionID) {
    outputRenderTasks[id]?.cancel()
    outputRenderTasks[id] = nil
    guard let pending = pendingOutputRenders.removeValue(forKey: id) else { return }
    renderOutputHandler(
      pending.snapshot,
      pending.bridge,
      id,
      pending.wasPinnedToBottom
    )
  }

  public func flushAll() {
    for sessionID in Array(pendingOutputRenders.keys) {
      flush(session: sessionID)
    }
  }

  public func cancel(session id: TerminalSessionID) {
    outputRenderTasks[id]?.cancel()
    outputRenderTasks[id] = nil
    pendingOutputRenders[id] = nil
  }

  private func scheduleFlush(session id: TerminalSessionID) {
    outputRenderTasks[id]?.cancel()
    outputRenderTasks[id] = Task { [weak self] in
      try? await Task.sleep(nanoseconds: self?.coalescingDelayNanoseconds ?? 0)
      guard !Task.isCancelled else { return }
      self?.flush(session: id)
    }
  }
}
