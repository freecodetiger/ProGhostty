import Foundation

@MainActor
final class TerminalOutputBatchCoordinator {
  typealias FlushHandler = @MainActor (
    Data,
    TerminalSessionID,
    TerminalOutputCoordinator.Delivery
  ) -> Void

  private struct PendingOutput {
    var data: Data
    var coalescingTask: Task<Void, Never>?
  }

  private let coalescingDelayNanoseconds: UInt64
  private let flushHandler: FlushHandler
  private var pendingOutputs: [TerminalSessionID: PendingOutput] = [:]

  init(
    coalescingDelayNanoseconds: UInt64 = 8_000_000,
    flushHandler: @escaping FlushHandler
  ) {
    self.coalescingDelayNanoseconds = coalescingDelayNanoseconds
    self.flushHandler = flushHandler
  }

  func receive(
    _ data: Data,
    session id: TerminalSessionID,
    delivery: TerminalOutputCoordinator.Delivery
  ) {
    guard !data.isEmpty else { return }
    if delivery == .immediate {
      flush(session: id)
      flushHandler(data, id, delivery)
      return
    }

    var pending = pendingOutputs[id] ?? PendingOutput(data: Data())
    pending.data.append(data)
    pendingOutputs[id] = pending
    scheduleFlush(session: id)
  }

  func flush(session id: TerminalSessionID) {
    guard let pending = pendingOutputs.removeValue(forKey: id) else { return }
    pending.coalescingTask?.cancel()
    guard !pending.data.isEmpty else { return }
    flushHandler(pending.data, id, .coalesced)
  }

  func cancel(session id: TerminalSessionID) {
    pendingOutputs[id]?.coalescingTask?.cancel()
    pendingOutputs[id] = nil
  }

  private func scheduleFlush(session id: TerminalSessionID) {
    var pending = pendingOutputs[id] ?? PendingOutput(data: Data())
    pending.coalescingTask?.cancel()
    pending.coalescingTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: self?.coalescingDelayNanoseconds ?? 0)
      guard !Task.isCancelled else { return }
      self?.flush(session: id)
    }
    pendingOutputs[id] = pending
  }
}
