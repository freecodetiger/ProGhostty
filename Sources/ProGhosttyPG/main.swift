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
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: plan.targetPath))
    defer { try? handle.close() }
    handle.write(Data(plan.sequence.utf8))
  } catch {
    FileHandle.standardError.write(Data("pg notify could not write to \(plan.targetPath): \(error.localizedDescription)\n".utf8))
    exit(3)
  }
case .message(let text):
  FileHandle.standardOutput.write(Data((text + "\n").utf8))
case .error(let text):
  FileHandle.standardError.write(Data((text + "\n").utf8))
  exit(2)
}
