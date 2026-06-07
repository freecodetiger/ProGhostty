import Foundation

public enum BoundedDebugLogWriter {
  public static func write(_ message: String, to url: URL, maxBytes: Int) {
    guard maxBytes > 0 else { return }
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    writeData(data, to: url, maxBytes: maxBytes)
  }

  public static func writeData(_ data: Data, to url: URL, maxBytes: Int) {
    guard maxBytes > 0 else { return }
    var data = data
    if data.count > maxBytes {
      data = Data(data.suffix(maxBytes))
    }

    let fileManager = FileManager.default
    try? fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if currentSize(of: url, fileManager: fileManager) + data.count > maxBytes {
      rotate(url, maxBytes: maxBytes, fileManager: fileManager)
    }

    if fileManager.fileExists(atPath: url.path),
      let handle = try? FileHandle(forWritingTo: url)
    {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url)
    }
  }

  private static func rotate(_ url: URL, maxBytes: Int, fileManager: FileManager) {
    let rotatedURL = url.appendingPathExtension("1")
    try? fileManager.removeItem(at: rotatedURL)
    let size = currentSize(of: url, fileManager: fileManager)
    guard size > 0 else { return }
    if size <= maxBytes {
      try? fileManager.moveItem(at: url, to: rotatedURL)
    } else {
      try? fileManager.removeItem(at: url)
    }
  }

  private static func currentSize(of url: URL, fileManager: FileManager) -> Int {
    guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
      return 0
    }
    return size.intValue
  }
}

public final class BoundedDebugLogSink: @unchecked Sendable {
  private let url: URL
  private let maxBytes: Int
  private let batchSize: Int
  private let flushDelay: TimeInterval
  private let queue: DispatchQueue
  private var buffer = Data()
  private var bufferedLineCount = 0
  private var flushScheduled = false

  public init(
    url: URL,
    maxBytes: Int,
    batchSize: Int = 32,
    flushDelay: TimeInterval = 0.05
  ) {
    self.url = url
    self.maxBytes = maxBytes
    self.batchSize = max(1, batchSize)
    self.flushDelay = max(0, flushDelay)
    queue = DispatchQueue(label: "dev.proghostty.debug-log.\(UUID().uuidString)")
  }

  public func write(_ message: String) {
    guard maxBytes > 0 else { return }
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    queue.async { [self] in
      buffer.append(data)
      bufferedLineCount += 1
      if bufferedLineCount >= batchSize {
        flushOnQueue()
      } else {
        scheduleFlushOnQueue()
      }
    }
  }

  public func flushSynchronously() {
    queue.sync {
      flushOnQueue()
    }
  }

  private func scheduleFlushOnQueue() {
    guard !flushScheduled else { return }
    flushScheduled = true
    queue.asyncAfter(deadline: .now() + flushDelay) { [self] in
      flushOnQueue()
    }
  }

  private func flushOnQueue() {
    flushScheduled = false
    guard !buffer.isEmpty else { return }
    let data = buffer
    buffer.removeAll(keepingCapacity: true)
    bufferedLineCount = 0
    BoundedDebugLogWriter.writeData(data, to: url, maxBytes: maxBytes)
  }
}
