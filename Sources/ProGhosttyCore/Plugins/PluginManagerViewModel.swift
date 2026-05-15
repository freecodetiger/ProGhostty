import Combine
import Foundation

public final class PluginManagerViewModel: ObservableObject {
  @Published public private(set) var report: ShellEnvironmentReport
  private let scanner: ShellEnvironmentScanner

  public init(scanner: ShellEnvironmentScanner = ShellEnvironmentScanner()) {
    self.scanner = scanner
    self.report = scanner.scan()
  }

  public func refresh() {
    report = scanner.scan()
  }
}
