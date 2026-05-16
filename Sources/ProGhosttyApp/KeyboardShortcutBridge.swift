import ProGhosttyCore
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

extension KeyboardShortcutBinding {
  var swiftUIShortcut: KeyboardShortcut {
    KeyboardShortcut(KeyEquivalent(proGhosttyKey), modifiers: swiftUIModifiers)
  }

  private var proGhosttyKey: Character {
    switch key {
    case "leftArrow":
      return Character(UnicodeScalar(NSLeftArrowFunctionKey)!)
    case "rightArrow":
      return Character(UnicodeScalar(NSRightArrowFunctionKey)!)
    case "upArrow":
      return Character(UnicodeScalar(NSUpArrowFunctionKey)!)
    case "downArrow":
      return Character(UnicodeScalar(NSDownArrowFunctionKey)!)
    case "escape":
      return Character(UnicodeScalar(0x1B)!)
    case "delete":
      return Character(UnicodeScalar(0x7F)!)
    case "return":
      return Character(UnicodeScalar(0x0D)!)
    case "tab":
      return Character(UnicodeScalar(0x09)!)
    case "space":
      return " "
    default:
      return key.first ?? " "
    }
  }

  private var swiftUIModifiers: EventModifiers {
    var result: EventModifiers = []
    if modifiers.contains(.command) {
      result.insert(.command)
    }
    if modifiers.contains(.control) {
      result.insert(.control)
    }
    if modifiers.contains(.option) {
      result.insert(.option)
    }
    if modifiers.contains(.shift) {
      result.insert(.shift)
    }
    return result
  }
}
