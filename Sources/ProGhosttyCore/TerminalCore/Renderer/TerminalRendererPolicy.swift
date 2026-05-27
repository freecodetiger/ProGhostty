import Foundation

public enum TerminalRendererPolicy {
  public static func resolve(
    mode: TerminalRendererMode,
    hasFrame: Bool,
    isMetalDirectAvailable: Bool
  ) -> TerminalRendererBackendSelection {
    switch mode {
    case .ghosttyVTTextFallback:
      return TerminalRendererBackendSelection(
        presentation: .textFallback,
        activeBackend: .ghosttyVTTextFallback,
        requestedBackend: nil,
        fallbackReason: nil
      )
    case .metalDirect:
      guard hasFrame else {
        return TerminalRendererBackendSelection(
          presentation: .textFallback,
          activeBackend: .ghosttyVTTextFallback,
          requestedBackend: .metalDirect,
          fallbackReason: nil
        )
      }
      return TerminalRendererBackendSelection(
        presentation: .liveCellGrid,
        activeBackend: isMetalDirectAvailable ? .metalDirect : .ghosttyVTCellGrid,
        requestedBackend: .metalDirect,
        fallbackReason: isMetalDirectAvailable ? nil : TerminalRendererDiagnostics.metalDirectUnavailableFallbackReason
      )
    case .ghosttyVTCellGrid:
      return TerminalRendererBackendSelection(
        presentation: hasFrame ? .liveCellGrid : .textFallback,
        activeBackend: hasFrame ? .ghosttyVTCellGrid : .ghosttyVTTextFallback,
        requestedBackend: nil,
        fallbackReason: nil
      )
    case .auto:
      guard hasFrame else {
        return TerminalRendererBackendSelection(
          presentation: .textFallback,
          activeBackend: .ghosttyVTTextFallback,
          requestedBackend: nil,
          fallbackReason: nil
        )
      }
      return TerminalRendererBackendSelection(
        presentation: .liveCellGrid,
        activeBackend: isMetalDirectAvailable ? .metalDirect : .ghosttyVTCellGrid,
        requestedBackend: nil,
        fallbackReason: nil
      )
    }
  }
}
