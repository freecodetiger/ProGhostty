import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Bounded debug log writer")
struct BoundedDebugLogWriterTests {
  @Test func rotatesLogBeforeItExceedsMaximumByteCount() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("proghostty-log-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("debug.log")
    for index in 0..<20 {
      BoundedDebugLogWriter.write(
        "entry-\(index)-abcdefghijklmnopqrstuvwxyz",
        to: url,
        maxBytes: 160
      )
    }

    let currentSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
    let rotatedSize = try FileManager.default.attributesOfItem(atPath: url.appendingPathExtension("1").path)[.size] as? NSNumber
    let currentText = try String(contentsOf: url, encoding: .utf8)

    #expect((currentSize?.intValue ?? 0) <= 160)
    #expect((rotatedSize?.intValue ?? 0) <= 160)
    #expect(currentText.contains("entry-19"))
  }

  @Test func truncatesSingleLogLineLargerThanMaximumByteCount() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("proghostty-log-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("debug.log")
    BoundedDebugLogWriter.write(String(repeating: "x", count: 512), to: url, maxBytes: 128)

    let currentSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber

    #expect((currentSize?.intValue ?? 0) <= 128)
  }

  @Test func asyncSinkFlushesBatchedWritesWithinMaximumByteCount() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("proghostty-log-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("debug.log")
    let sink = BoundedDebugLogSink(url: url, maxBytes: 256, batchSize: 8)
    for index in 0..<20 {
      sink.write("entry-\(index)-abcdefghijklmnopqrstuvwxyz")
    }
    sink.flushSynchronously()

    let currentSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
    let currentText = try String(contentsOf: url, encoding: .utf8)

    #expect((currentSize?.intValue ?? 0) <= 256)
    #expect(currentText.contains("entry-19"))
  }
}
