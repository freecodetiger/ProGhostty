import Foundation

@MainActor
public final class TerminalOutputCoordinator {
  public enum Delivery: Sendable {
    case coalesced
    case immediate
  }

  /// The output pipeline coalesces twice in series: once over raw PTY bytes
  /// (TerminalOutputBatchCoordinator) and once over render snapshots
  /// (TerminalOutputCoordinator). To keep the worst-case byte→pixel latency for
  /// bulk output near a single 8 ms frame instead of ~16 ms, the two stages
  /// split one 8 ms budget rather than each waiting a full 8 ms. Interactive
  /// echo bypasses both stages via `.immediate`, so this only affects bulk
  /// output where coalescing is desired anyway.
  public static let pipelineStageDelayNanoseconds: UInt64 = 4_000_000

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
