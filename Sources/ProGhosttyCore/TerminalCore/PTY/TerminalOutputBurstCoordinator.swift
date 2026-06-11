import Foundation

@MainActor
final class TerminalOutputBurstCoordinator {
  typealias FlushHandler = @MainActor (
    Data,
    TerminalSessionID,
    TerminalOutputCoordinator.Delivery,
    Bool,
    @escaping @MainActor () -> Void
  ) -> Void

  private struct PendingOutput {
    var data: Data
    var offset: Int = 0
    var coalescingTask: Task<Void, Never>?
    var drainTask: Task<Void, Never>?
    var isDraining: Bool = false
    var presentedFrames: Int = 0
  }

  private let flushDelayNanoseconds: UInt64
  private let frameIntervalNanoseconds: UInt64
  private let maxPendingBytes: Int
  private let maxFlushBytes: Int
  private let maxFlushLineFeeds: Int
  private let startupFlushLineFeeds: Int
  private let rampFlushLineFeeds: Int
  private let tailFlushLineFeeds: Int
  private let frameIngestBudgetNanoseconds: UInt64
  private let maxIngestChunksPerFrame: Int
  private let nowNanoseconds: () -> UInt64
  private let flushHandler: FlushHandler
  private var pendingOutputs: [TerminalSessionID: PendingOutput] = [:]
  private let startupFrameCount = 2
  private let rampFrameCount = 5
  private let tailLineFeedThreshold = 96

  init(
    coalescingDelayNanoseconds: UInt64 = 8_000_000,
    frameIntervalNanoseconds: UInt64 = 8_333_333,
    maxPendingBytes: Int = 512 * 1024,
    maxFlushBytes: Int = 16 * 1024,
    maxFlushLineFeeds: Int = 128,
    frameIngestBudgetNanoseconds: UInt64 = 4_000_000,
    maxIngestChunksPerFrame: Int = 64,
    nowNanoseconds: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
    flushHandler: @escaping FlushHandler
  ) {
    self.flushDelayNanoseconds = coalescingDelayNanoseconds
    self.frameIntervalNanoseconds = frameIntervalNanoseconds
    self.maxPendingBytes = maxPendingBytes
    self.maxFlushBytes = max(1, maxFlushBytes)
    self.maxFlushLineFeeds = max(1, maxFlushLineFeeds)
    self.startupFlushLineFeeds = min(16, self.maxFlushLineFeeds)
    self.rampFlushLineFeeds = min(32, self.maxFlushLineFeeds)
    self.tailFlushLineFeeds = min(16, self.maxFlushLineFeeds)
    self.frameIngestBudgetNanoseconds = frameIngestBudgetNanoseconds
    self.maxIngestChunksPerFrame = max(1, maxIngestChunksPerFrame)
    self.nowNanoseconds = nowNanoseconds
    self.flushHandler = flushHandler
  }

  func receive(
    _ data: Data,
    session id: TerminalSessionID,
    delivery: TerminalOutputCoordinator.Delivery
  ) {
    guard !data.isEmpty else { return }
    if delivery == .immediate {
      if var pending = pendingOutputs[id],
        pending.offset < pending.data.count || pending.isDraining
      {
        let remaining = Data(pending.data[pending.offset..<pending.data.count])
        let combined = remaining + data
        if !pending.isDraining
          && chunkEnd(in: combined, from: 0, maxLineFeeds: maxFlushLineFeeds) == combined.count
        {
          flush(session: id)
          flushHandler(data, id, delivery, true) {}
          return
        }
        pending.data.append(data)
        pendingOutputs[id] = pending
        beginDraining(session: id)
        return
      }
      flushHandler(data, id, delivery, true) {}
      return
    }

    var pending = pendingOutputs[id] ?? PendingOutput(data: Data())
    if pending.offset >= pending.data.count {
      pending.data = Data()
      pending.offset = 0
      pending.presentedFrames = 0
    }
    pending.data.append(data)
    pendingOutputs[id] = pending

    if pending.data.count >= maxPendingBytes {
      beginDraining(session: id)
      return
    }

    scheduleFlush(session: id)
  }

  func flush(session id: TerminalSessionID) {
    guard var pending = pendingOutputs.removeValue(forKey: id) else { return }
    pending.coalescingTask?.cancel()
    pending.drainTask?.cancel()
    guard pending.offset < pending.data.count else { return }
    while pending.offset < pending.data.count {
      let end = chunkEnd(in: pending.data, from: pending.offset, maxLineFeeds: maxFlushLineFeeds)
      let shouldRender = end >= pending.data.count
      flushHandler(Data(pending.data[pending.offset..<end]), id, .coalesced, shouldRender) {}
      pending.offset = end
    }
  }

  func cancel(session id: TerminalSessionID) {
    pendingOutputs[id]?.coalescingTask?.cancel()
    pendingOutputs[id]?.drainTask?.cancel()
    pendingOutputs[id] = nil
  }

  private func scheduleFlush(session id: TerminalSessionID) {
    var pending = pendingOutputs[id] ?? PendingOutput(data: Data())
    pending.coalescingTask?.cancel()
    pending.coalescingTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: self?.flushDelayNanoseconds ?? 0)
      guard !Task.isCancelled else { return }
      self?.beginDraining(session: id)
    }
    pendingOutputs[id] = pending
  }

  private func beginDraining(session id: TerminalSessionID) {
    guard var pending = pendingOutputs[id], !pending.isDraining else { return }
    pending.coalescingTask?.cancel()
    pending.coalescingTask = nil
    pending.isDraining = true
    pendingOutputs[id] = pending
    drainNext(session: id, frameStartedAt: nowNanoseconds(), chunksInFrame: 0)
  }

  private func drainNext(session id: TerminalSessionID, frameStartedAt: UInt64, chunksInFrame: Int) {
    guard var pending = pendingOutputs[id] else { return }
    pending.drainTask?.cancel()
    pending.drainTask = nil

    guard pending.offset < pending.data.count else {
      pendingOutputs[id] = nil
      return
    }

    if chunksInFrame > 0 && elapsedNanoseconds(since: frameStartedAt) >= frameIngestBudgetNanoseconds {
      presentCurrentFrame(session: id)
      return
    }

    let maxLineFeeds = scheduledLineFeedLimit(for: pending)
    let end = chunkEnd(in: pending.data, from: pending.offset, maxLineFeeds: maxLineFeeds)
    let chunk = Data(pending.data[pending.offset..<end])
    pending.offset = end

    let shouldRender = chunksInFrame + 1 >= maxIngestChunksPerFrame || end >= pending.data.count
    if shouldRender {
      pending.presentedFrames += 1
    }
    pendingOutputs[id] = pending

    flushHandler(chunk, id, .immediate, shouldRender) { [weak self] in
      if shouldRender {
        self?.scheduleDrainFrame(session: id)
      } else {
        self?.drainNext(
          session: id,
          frameStartedAt: frameStartedAt,
          chunksInFrame: chunksInFrame + 1
        )
      }
    }
  }

  private func presentCurrentFrame(session id: TerminalSessionID) {
    guard var pending = pendingOutputs[id] else { return }
    pending.presentedFrames += 1
    pendingOutputs[id] = pending
    flushHandler(Data(), id, .immediate, true) { [weak self] in
      self?.scheduleDrainFrame(session: id)
    }
  }

  private func scheduleDrainFrame(session id: TerminalSessionID) {
    guard var pending = pendingOutputs[id] else { return }
    guard pending.offset < pending.data.count else {
      pendingOutputs[id] = nil
      return
    }
    pending.drainTask?.cancel()
    pending.drainTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: self?.frameIntervalNanoseconds ?? 0)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      self.drainNext(session: id, frameStartedAt: self.nowNanoseconds(), chunksInFrame: 0)
    }
    pendingOutputs[id] = pending
  }

  private func elapsedNanoseconds(since start: UInt64) -> UInt64 {
    let now = nowNanoseconds()
    return now >= start ? now - start : 0
  }

  private func scheduledLineFeedLimit(for pending: PendingOutput) -> Int {
    let remainingLineFeeds = lineFeedCount(
      in: pending.data,
      from: pending.offset,
      upTo: tailLineFeedThreshold + 1
    )
    if remainingLineFeeds > 0 && remainingLineFeeds <= tailLineFeedThreshold {
      return tailFlushLineFeeds
    }
    if pending.presentedFrames < startupFrameCount {
      return startupFlushLineFeeds
    }
    if pending.presentedFrames < rampFrameCount {
      return rampFlushLineFeeds
    }
    return maxFlushLineFeeds
  }

  private func lineFeedCount(in data: Data, from offset: Int, upTo limit: Int) -> Int {
    guard offset < data.count, limit > 0 else { return 0 }
    var lineFeeds = 0

    data.withUnsafeBytes { rawBuffer in
      guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
      var index = offset
      while index < data.count && lineFeeds < limit {
        if bytes[index] == 10 {
          lineFeeds += 1
        }
        index += 1
      }
    }

    return lineFeeds
  }

  private func chunkEnd(in data: Data, from offset: Int, maxLineFeeds: Int) -> Int {
    let count = data.count
    guard offset < count else { return count }
    let byteLimit = min(count, offset + maxFlushBytes)
    var end = byteLimit
    var lineFeeds = 0

    data.withUnsafeBytes { rawBuffer in
      guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
      var index = offset
      while index < byteLimit {
        if bytes[index] == 10 {
          lineFeeds += 1
          if lineFeeds >= maxLineFeeds {
            end = index + 1
            return
          }
        }
        index += 1
      }
    }

    return max(offset + 1, end)
  }
}
