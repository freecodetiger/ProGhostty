import Foundation
import ProGhosttyCore

let response = PGCommandMapper.response(
  arguments: Array(CommandLine.arguments.dropFirst()),
  environment: ProcessInfo.processInfo.environment
)

switch response {
case .osc(let sequence):
  FileHandle.standardOutput.write(Data(sequence.utf8))
case .notification(let plan):
  do {
    try writeNotificationSequence(plan.sequence, to: plan.targetPath)
  } catch {
    FileHandle.standardError.write(
      Data("pg notify could not write to \(plan.targetPath): \(error.localizedDescription)\n".utf8)
    )
    exit(3)
  }
case .message(let text):
  FileHandle.standardOutput.write(Data((text + "\n").utf8))
case .error(let text):
  FileHandle.standardError.write(Data((text + "\n").utf8))
  exit(2)
}

/// Resolve a writable TTY and write OSC bytes. Hook processes often cannot open
/// `/dev/tty` (ENXIO); prefer concrete slave paths from env / stdio.
private func writeNotificationSequence(_ sequence: String, to preferredPath: String) throws {
  let candidates = ttyCandidates(preferred: preferredPath)
  var lastError: Error = CocoaError(.fileWriteUnknown)
  for path in candidates {
    do {
      try writePOSIX(sequence, toPath: path)
      return
    } catch {
      lastError = error
    }
  }
  throw lastError
}

private func ttyCandidates(preferred: String) -> [String] {
  var paths: [String] = []
  func append(_ path: String?) {
    guard let path, !path.isEmpty, !paths.contains(path) else { return }
    paths.append(path)
  }
  if preferred != "/dev/tty" {
    append(preferred)
  }
  if let env = ProcessInfo.processInfo.environment["PROGHOSTTY_NOTIFY_TTY"], env != "/dev/tty" {
    append(env)
  }
  for fd: Int32 in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
    if let cstr = ttyname(fd) {
      append(String(cString: cstr))
    }
  }
  append("/dev/tty")
  return paths
}

private func writePOSIX(_ sequence: String, toPath path: String) throws {
  let fd = open(path, O_WRONLY | O_NOCTTY)
  guard fd >= 0 else {
    throw NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(errno),
      userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
    )
  }
  defer { close(fd) }
  let data = Data(sequence.utf8)
  try data.withUnsafeBytes { raw in
    guard let base = raw.baseAddress else { return }
    var written = 0
    let total = raw.count
    while written < total {
      let n = write(fd, base.advanced(by: written), total - written)
      if n < 0 {
        throw NSError(
          domain: NSPOSIXErrorDomain,
          code: Int(errno),
          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
        )
      }
      written += n
    }
  }
}
