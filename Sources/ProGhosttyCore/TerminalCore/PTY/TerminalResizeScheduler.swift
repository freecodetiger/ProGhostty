import Foundation

@MainActor
public final class TerminalResizeScheduler<Request> {
  public typealias ResizeHandler = @MainActor (TerminalSessionID, Request) -> Void

  private struct PendingResize {
    var request: Request
  }

  private let coalescingDelayNanoseconds: UInt64
  private let resizeHandler: ResizeHandler
  private var pendingResizes: [TerminalSessionID: PendingResize] = [:]
  private var resizeTasks: [TerminalSessionID: Task<Void, Never>] = [:]

  public init(
    coalescingDelayNanoseconds: UInt64 = 8_000_000,
    resizeHandler: @escaping ResizeHandler
  ) {
    self.coalescingDelayNanoseconds = coalescingDelayNanoseconds
    self.resizeHandler = resizeHandler
  }

  public func schedule(
    request: Request,
    session id: TerminalSessionID
  ) {
    pendingResizes[id] = PendingResize(request: request)
    scheduleFlush(session: id)
  }

  public func flush(session id: TerminalSessionID) {
    resizeTasks[id]?.cancel()
    resizeTasks[id] = nil
    guard let pending = pendingResizes.removeValue(forKey: id) else { return }
    resizeHandler(id, pending.request)
  }

  public func flushAll() {
    for sessionID in Array(pendingResizes.keys) {
      flush(session: sessionID)
    }
  }

  public func cancel(session id: TerminalSessionID) {
    resizeTasks[id]?.cancel()
    resizeTasks[id] = nil
    pendingResizes[id] = nil
  }

  private func scheduleFlush(session id: TerminalSessionID) {
    resizeTasks[id]?.cancel()
    resizeTasks[id] = Task { [weak self] in
      try? await Task.sleep(nanoseconds: self?.coalescingDelayNanoseconds ?? 0)
      guard !Task.isCancelled else { return }
      self?.flush(session: id)
    }
  }
}
