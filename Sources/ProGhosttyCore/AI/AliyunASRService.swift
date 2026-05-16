import AVFoundation
import Foundation

public enum ASRTranscriptEvent: Equatable, Sendable {
  case partial(String)
  case final(String)
  case error(String)
  case completed
}

public enum AliyunASRError: Error, LocalizedError, Equatable {
  case missingAPIKey
  case microphoneDenied
  case audioFormatUnavailable
  case connectionFailed(String)

  public var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "Missing DashScope API key. Configure it in Settings or set DASHSCOPE_API_KEY."
    case .microphoneDenied:
      return "Microphone access is not allowed. Enable microphone permission for ProGhostty in System Settings."
    case .audioFormatUnavailable:
      return "Unable to prepare microphone audio for 16 kHz mono PCM streaming."
    case .connectionFailed(let message):
      return "Aliyun speech recognition failed: \(message)"
    }
  }
}

public final class AliyunASRService: NSObject, Sendable {
  public let endpoint: URL
  public let model: String
  private let apiKeyProvider: AliyunAPIKeyProvider

  public init(
    endpoint: URL = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference/")!,
    model: String = "fun-asr-realtime-2026-02-28",
    apiKeyProvider: AliyunAPIKeyProvider
  ) {
    self.endpoint = endpoint
    self.model = model
    self.apiKeyProvider = apiKeyProvider
  }

  public func transcribe() -> AsyncStream<ASRTranscriptEvent> {
    AsyncStream { continuation in
      let task = Task {
        await run(continuation: continuation)
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func run(continuation: AsyncStream<ASRTranscriptEvent>.Continuation) async {
    guard let apiKey = apiKeyProvider.apiKey() else {
      continuation.yield(.error(AliyunASRError.missingAPIKey.localizedDescription))
      continuation.finish()
      return
    }
    guard await requestMicrophoneAccess() else {
      continuation.yield(.error(AliyunASRError.microphoneDenied.localizedDescription))
      continuation.finish()
      return
    }

    let client = ASRWebSocketClient(endpoint: endpoint, apiKey: apiKey, model: model)
    do {
      try await client.connect(continuation: continuation)
      try await streamAudio(to: client)
      try await client.finish()
      continuation.yield(.completed)
    } catch {
      if !Task.isCancelled {
        continuation.yield(.error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
      }
    }
    continuation.finish()
  }

  private func requestMicrophoneAccess() async -> Bool {
    return await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private func streamAudio(to client: ASRWebSocketClient) async throws {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
      let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
    else {
      throw AliyunASRError.audioFormatUnavailable
    }

    final class AudioBufferQueue: @unchecked Sendable {
      var buffers: [Data] = []
      let lock = NSLock()

      func push(_ data: Data) {
        lock.lock()
        buffers.append(data)
        lock.unlock()
      }

      func pop() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return buffers.isEmpty ? nil : buffers.removeFirst()
      }
    }

    let queue = AudioBufferQueue()
    input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
      guard let data = Self.convert(buffer: buffer, converter: converter, targetFormat: targetFormat) else { return }
      queue.push(data)
    }

    engine.prepare()
    try engine.start()
    defer {
      engine.stop()
      input.removeTap(onBus: 0)
    }

    while !Task.isCancelled {
      if let data = queue.pop() {
        try await client.sendAudio(data)
      } else {
        try await Task.sleep(nanoseconds: 20_000_000)
      }
    }
  }

  private static func convert(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) -> Data? {
    let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate) + 1
    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return nil }
    var consumed = false
    let inputBlock: AVAudioConverterInputBlock = { _, status in
      if consumed {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return buffer
    }
    var error: NSError?
    converter.convert(to: output, error: &error, withInputFrom: inputBlock)
    guard error == nil, let channelData = output.int16ChannelData else { return nil }
    return Data(bytes: channelData[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
  }
}

private final class ASRWebSocketClient: @unchecked Sendable {
  private let endpoint: URL
  private let apiKey: String
  private let model: String
  private var webSocket: URLSessionWebSocketTask?
  private let taskID = UUID().uuidString

  init(endpoint: URL, apiKey: String, model: String) {
    self.endpoint = endpoint
    self.apiKey = apiKey
    self.model = model
  }

  func connect(continuation: AsyncStream<ASRTranscriptEvent>.Continuation) async throws {
    var request = URLRequest(url: endpoint)
    request.setValue("bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("enable", forHTTPHeaderField: "X-DashScope-DataInspection")
    let task = URLSession.shared.webSocketTask(with: request)
    webSocket = task
    task.resume()
    try await sendJSON([
      "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
      "payload": [
        "task_group": "audio",
        "task": "asr",
        "function": "recognition",
        "model": model,
        "parameters": ["sample_rate": 16000, "format": "pcm"],
        "input": [:],
      ],
    ])
    Task { await receiveLoop(continuation: continuation) }
  }

  func sendAudio(_ data: Data) async throws {
    try await webSocket?.send(.data(data))
  }

  func finish() async throws {
    try await sendJSON(["header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"], "payload": [:]])
    webSocket?.cancel(with: .normalClosure, reason: nil)
  }

  private func sendJSON(_ value: [String: Any]) async throws {
    let data = try JSONSerialization.data(withJSONObject: value)
    try await webSocket?.send(.string(String(decoding: data, as: UTF8.self)))
  }

  private func receiveLoop(continuation: AsyncStream<ASRTranscriptEvent>.Continuation) async {
    do {
      while let webSocket {
        let message = try await webSocket.receive()
        switch message {
        case .string(let text):
          handle(text, continuation: continuation)
        case .data(let data):
          handle(String(decoding: data, as: UTF8.self), continuation: continuation)
        @unknown default:
          break
        }
      }
    } catch {
      continuation.yield(.error(AliyunASRError.connectionFailed(error.localizedDescription).localizedDescription))
    }
  }

  private func handle(_ text: String, continuation: AsyncStream<ASRTranscriptEvent>.Continuation) {
    guard
      let data = text.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }
    if let output = json["output"] as? [String: Any] {
      let sentence = output["sentence"] as? [String: Any]
      let text = (sentence?["text"] as? String) ?? (output["text"] as? String) ?? ""
      guard !text.isEmpty else { return }
      let isFinal = (sentence?["sentence_end"] as? Bool) ?? (output["is_final"] as? Bool) ?? false
      continuation.yield(isFinal ? .final(text) : .partial(text))
    }
    if let header = json["header"] as? [String: Any],
      let event = header["event"] as? String,
      event == "task-failed"
    {
      let message = header["error_message"] as? String ?? "network or recognition error"
      continuation.yield(.error(AliyunASRError.connectionFailed(message).localizedDescription))
    }
  }
}
