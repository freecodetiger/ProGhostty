import Foundation
import ProGhosttyGhosttyVT

public struct GhosttyTerminalFrame: Sendable {
  public struct Cell: Sendable {
    public var scalar: UnicodeScalar
    public var foreground: RGB
    public var background: RGB
    public var bold: Bool
    public var italic: Bool
    public var faint: Bool
    public var underline: Bool
    public var inverse: Bool
    public var usesDefaultForeground: Bool
    public var usesDefaultBackground: Bool

    public init(
      scalar: UnicodeScalar,
      foreground: RGB,
      background: RGB,
      bold: Bool,
      italic: Bool,
      faint: Bool,
      underline: Bool,
      inverse: Bool,
      usesDefaultForeground: Bool = false,
      usesDefaultBackground: Bool = false
    ) {
      self.scalar = scalar
      self.foreground = foreground
      self.background = background
      self.bold = bold
      self.italic = italic
      self.faint = faint
      self.underline = underline
      self.inverse = inverse
      self.usesDefaultForeground = usesDefaultForeground
      self.usesDefaultBackground = usesDefaultBackground
    }
  }

  public struct RGB: Sendable, Equatable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
  }

  public var cols: Int
  public var rows: Int
  public var cursorVisible: Bool
  public var cursorX: Int
  public var cursorY: Int
  public var cells: [Cell]
}

public final class GhosttyVTBridge {
  public enum BridgeError: Error, CustomStringConvertible {
    case createFailed(Int32)
    case formatFailed(Int32)

    public var description: String {
      switch self {
      case .createFailed(let code):
        return "libghostty-vt create failed with code \(code)"
      case .formatFailed(let code):
        return "libghostty-vt format failed with code \(code)"
      }
    }
  }

  private var handle: OpaquePointer?

  public init(cols: Int = 80, rows: Int = 24, maxScrollback: Int = 10_000) throws {
    var handle: OpaquePointer?
    let result = proghostty_vt_new(UInt16(cols), UInt16(rows), maxScrollback, &handle)
    guard result == 0, let handle else {
      throw BridgeError.createFailed(result)
    }
    self.handle = handle
  }

  deinit {
    if let handle {
      proghostty_vt_free(handle)
    }
  }

  public func write(_ data: Data) {
    guard let handle else { return }
    data.withUnsafeBytes { bytes in
      guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
      proghostty_vt_write(handle, base, data.count)
    }
  }

  public func resize(cols: Int, rows: Int) {
    guard let handle else { return }
    _ = proghostty_vt_resize(handle, UInt16(cols), UInt16(rows))
  }

  public func frame() throws -> GhosttyTerminalFrame {
    guard let handle else {
      return GhosttyTerminalFrame(
        cols: 0, rows: 0, cursorVisible: false, cursorX: 0, cursorY: 0, cells: [])
    }

    var snapshot = ProGhosttyVTSnapshot()
    let result = proghostty_vt_snapshot(handle, &snapshot)
    guard result == 0, let rawCells = snapshot.cells else {
      throw BridgeError.formatFailed(result)
    }
    defer { proghostty_vt_snapshot_free(&snapshot) }

    let count = Int(snapshot.cell_count)
    let buffer = UnsafeBufferPointer(start: rawCells, count: count)
    let cells = buffer.map { rawCell in
      let scalar = UnicodeScalar(rawCell.codepoint) ?? " "
      return GhosttyTerminalFrame.Cell(
        scalar: scalar,
        foreground: GhosttyTerminalFrame.RGB(r: rawCell.fg_r, g: rawCell.fg_g, b: rawCell.fg_b),
        background: GhosttyTerminalFrame.RGB(r: rawCell.bg_r, g: rawCell.bg_g, b: rawCell.bg_b),
        bold: rawCell.bold,
        italic: rawCell.italic,
        faint: rawCell.faint,
        underline: rawCell.underline,
        inverse: rawCell.inverse,
        usesDefaultForeground: rawCell.fg_default,
        usesDefaultBackground: rawCell.bg_default
      )
    }

    return GhosttyTerminalFrame(
      cols: Int(snapshot.cols),
      rows: Int(snapshot.rows),
      cursorVisible: snapshot.cursor_visible,
      cursorX: Int(snapshot.cursor_x),
      cursorY: Int(snapshot.cursor_y),
      cells: cells
    )
  }

  public func plainText() throws -> String {
    try formattedString { handle, pointer, length in
      proghostty_vt_format_plain(handle, &pointer, &length)
    }
  }

  public func htmlText() throws -> String {
    try formattedString { handle, pointer, length in
      proghostty_vt_format_html(handle, &pointer, &length)
    }
  }

  private func formattedString(
    _ format: (OpaquePointer, inout UnsafeMutablePointer<UInt8>?, inout Int) -> Int32
  ) throws -> String {
    guard let handle else { return "" }
    var pointer: UnsafeMutablePointer<UInt8>?
    var length = 0
    let result = format(handle, &pointer, &length)
    guard result == 0, let pointer else {
      throw BridgeError.formatFailed(result)
    }
    defer { proghostty_vt_free_bytes(pointer, length) }
    return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
  }
}
