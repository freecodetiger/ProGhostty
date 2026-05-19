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

public struct DashScopeASRConfiguration: Equatable, Sendable {
  public var endpoint: URL
  public var model: String
  public var sampleRate: Int
  public var format: String
  public var semanticPunctuationEnabled: Bool
  public var maxSentenceSilence: Int
  public var heartbeat: Bool
  public var languageHints: [String]

  public init(
    endpoint: URL = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference/")!,
    model: String = "fun-asr-realtime",
    sampleRate: Int = 16_000,
    format: String = "pcm",
    semanticPunctuationEnabled: Bool = false,
    maxSentenceSilence: Int = 800,
    heartbeat: Bool = true,
    languageHints: [String] = []
  ) {
    self.endpoint = endpoint
    self.model = model
    self.sampleRate = sampleRate
    self.format = format
    self.semanticPunctuationEnabled = semanticPunctuationEnabled
    self.maxSentenceSilence = maxSentenceSilence
    self.heartbeat = heartbeat
    self.languageHints = languageHints
  }

  public static let defaultRealtime = DashScopeASRConfiguration()
}

public enum DashScopeASRProtocolEvent: Equatable, Sendable {
  case taskStarted
  case taskFinished
  case transcript(ASRTranscriptEvent)
  case taskFailed(String)
}

public enum DashScopeASRProtocol {
  public static func makeRunTaskRequest(
    taskID: String,
    configuration: DashScopeASRConfiguration
  ) -> [String: Any] {
    var parameters: [String: Any] = [
      "sample_rate": configuration.sampleRate,
      "format": configuration.format,
      "semantic_punctuation_enabled": configuration.semanticPunctuationEnabled,
      "max_sentence_silence": configuration.maxSentenceSilence,
      "heartbeat": configuration.heartbeat,
    ]
    if !configuration.languageHints.isEmpty {
      parameters["language_hints"] = configuration.languageHints
    }

    return [
      "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
      "payload": [
        "task_group": "audio",
        "task": "asr",
        "function": "recognition",
        "model": configuration.model,
        "parameters": parameters,
        "input": [:],
      ],
    ]
  }

  public static func makeFinishTaskRequest(taskID: String) -> [String: Any] {
    ["header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"], "payload": ["input": [:]]]
  }

  public static func parse(_ text: String) -> DashScopeASRProtocolEvent? {
    guard
      let data = text.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    let header = json["header"] as? [String: Any]
    let event = header?["event"] as? String
    switch event {
    case "task-started":
      return .taskStarted
    case "task-finished":
      return .taskFinished
    case "task-failed":
      let message = header?["error_message"] as? String ?? "network or recognition error"
      return .taskFailed(message)
    default:
      break
    }

    let payload = json["payload"] as? [String: Any]
    guard let output = (payload?["output"] as? [String: Any]) ?? (json["output"] as? [String: Any]) else {
      return nil
    }
    let sentence = output["sentence"] as? [String: Any]
    let text = (sentence?["text"] as? String) ?? (output["text"] as? String) ?? ""
    guard !text.isEmpty else { return nil }
    let isFinal = (sentence?["sentence_end"] as? Bool) ?? (output["is_final"] as? Bool) ?? false
    return .transcript(isFinal ? .final(text) : .partial(text))
  }
}

public final class AliyunASRService: NSObject, Sendable {
  public let configuration: DashScopeASRConfiguration
  private let apiKeyProvider: AliyunAPIKeyProvider

  public init(
    configuration: DashScopeASRConfiguration = .defaultRealtime,
    apiKeyProvider: AliyunAPIKeyProvider
  ) {
    self.configuration = configuration
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

    let client = ASRWebSocketClient(apiKey: apiKey, configuration: configuration)
    do {
      try await client.connect(continuation: continuation)
      try await streamAudio(to: client)
      if Task.isCancelled {
        Task.detached {
          try? await client.finish()
        }
        return
      }
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
      let maximumBufferedChunks = 24

      func push(_ data: Data) {
        lock.lock()
        if buffers.count >= maximumBufferedChunks {
          buffers.removeFirst(buffers.count - maximumBufferedChunks + 1)
        }
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
  private let apiKey: String
  private let configuration: DashScopeASRConfiguration
  private var webSocket: URLSessionWebSocketTask?
  private let lifecycle = ASRTaskLifecycle()
  private let taskID = UUID().uuidString

  init(apiKey: String, configuration: DashScopeASRConfiguration) {
    self.apiKey = apiKey
    self.configuration = configuration
  }

  func connect(continuation: AsyncStream<ASRTranscriptEvent>.Continuation) async throws {
    var request = URLRequest(url: configuration.endpoint)
    request.setValue("bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let task = URLSession.shared.webSocketTask(with: request)
    webSocket = task
    task.resume()
    Task { await receiveLoop(continuation: continuation) }
    try await sendJSON(DashScopeASRProtocol.makeRunTaskRequest(taskID: taskID, configuration: configuration))
    try await lifecycle.waitForStart()
  }

  func sendAudio(_ data: Data) async throws {
    try await webSocket?.send(.data(data))
  }

  func finish() async throws {
    try await sendJSON(DashScopeASRProtocol.makeFinishTaskRequest(taskID: taskID))
    try await lifecycle.waitForFinish()
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
      let message = AliyunASRError.connectionFailed(error.localizedDescription).localizedDescription
      lifecycle.fail(message)
      continuation.yield(.error(message))
    }
  }

  private func handle(_ text: String, continuation: AsyncStream<ASRTranscriptEvent>.Continuation) {
    guard let event = DashScopeASRProtocol.parse(text) else { return }
    switch event {
    case .taskStarted:
      lifecycle.markStarted()
    case .taskFinished:
      lifecycle.markFinished()
    case .transcript(let event):
      continuation.yield(event)
    case .taskFailed(let message):
      let localized = AliyunASRError.connectionFailed(message).localizedDescription
      lifecycle.fail(localized)
      continuation.yield(.error(localized))
    }
  }
}

private final class ASRTaskLifecycle: @unchecked Sendable {
  private enum State {
    case pending
    case completed
    case failed(String)
  }

  private let lock = NSLock()
  private var startState: State = .pending
  private var finishState: State = .pending
  private var startContinuations: [CheckedContinuation<Void, Error>] = []
  private var finishContinuations: [CheckedContinuation<Void, Error>] = []

  func waitForStart() async throws {
    try await wait(state: \.startState, continuations: \.startContinuations)
  }

  func waitForFinish() async throws {
    try await wait(state: \.finishState, continuations: \.finishContinuations)
  }

  func markStarted() {
    complete(state: \.startState, continuations: \.startContinuations)
  }

  func markFinished() {
    complete(state: \.finishState, continuations: \.finishContinuations)
  }

  func fail(_ message: String) {
    fail(state: \.startState, continuations: \.startContinuations, message: message)
    fail(state: \.finishState, continuations: \.finishContinuations, message: message)
  }

  private func wait(
    state: ReferenceWritableKeyPath<ASRTaskLifecycle, State>,
    continuations: ReferenceWritableKeyPath<ASRTaskLifecycle, [CheckedContinuation<Void, Error>]>
  ) async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      switch self[keyPath: state] {
      case .pending:
        self[keyPath: continuations].append(continuation)
        lock.unlock()
      case .completed:
        lock.unlock()
        continuation.resume()
      case .failed(let message):
        lock.unlock()
        continuation.resume(throwing: AliyunASRError.connectionFailed(message))
      }
    }
  }

  private func complete(
    state: ReferenceWritableKeyPath<ASRTaskLifecycle, State>,
    continuations: ReferenceWritableKeyPath<ASRTaskLifecycle, [CheckedContinuation<Void, Error>]>
  ) {
    lock.lock()
    guard case .pending = self[keyPath: state] else {
      lock.unlock()
      return
    }
    self[keyPath: state] = .completed
    let waiting = self[keyPath: continuations]
    self[keyPath: continuations] = []
    lock.unlock()
    for continuation in waiting {
      continuation.resume()
    }
  }

  private func fail(
    state: ReferenceWritableKeyPath<ASRTaskLifecycle, State>,
    continuations: ReferenceWritableKeyPath<ASRTaskLifecycle, [CheckedContinuation<Void, Error>]>,
    message: String
  ) {
    lock.lock()
    guard case .pending = self[keyPath: state] else {
      lock.unlock()
      return
    }
    self[keyPath: state] = .failed(message)
    let waiting = self[keyPath: continuations]
    self[keyPath: continuations] = []
    lock.unlock()
    for continuation in waiting {
      continuation.resume(throwing: AliyunASRError.connectionFailed(message))
    }
  }
}
