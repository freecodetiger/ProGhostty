import Carbon
import Foundation

public enum TerminalInputMethodState {
  public static func isCurrentInputSourceCompositionMethod() -> Bool {
    guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
      return false
    }

    return isCompositionInputSource(inputSource)
  }

  static func isCompositionInputSource(_ inputSource: TISInputSource) -> Bool {
    propertyString(inputSource, key: kTISPropertyInputSourceType) == (kTISTypeKeyboardInputMode as String)
  }

  private static func propertyString(_ inputSource: TISInputSource, key: CFString) -> String? {
    guard let pointer = TISGetInputSourceProperty(inputSource, key) else {
      return nil
    }

    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
  }
}
