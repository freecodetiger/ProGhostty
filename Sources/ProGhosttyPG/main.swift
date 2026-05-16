import Foundation
import ProGhosttyCore

let response = PGCommandMapper.response(
  arguments: Array(CommandLine.arguments.dropFirst()),
  environment: ProcessInfo.processInfo.environment
)

switch response {
case .osc(let sequence):
  FileHandle.standardOutput.write(Data(sequence.utf8))
case .message(let text):
  FileHandle.standardOutput.write(Data((text + "\n").utf8))
case .error(let text):
  FileHandle.standardError.write(Data((text + "\n").utf8))
  exit(2)
}
