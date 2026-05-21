import Foundation
import ProGhosttyGhosttyVT

public enum TerminalCursorShape: UInt8, Sendable {
  case bar = 0
  case block = 1
  case underline = 2
  case hollowBlock = 3

  init(ghosttyRawValue: UInt8) {
    self = TerminalCursorShape(rawValue: ghosttyRawValue) ?? .block
  }
}

public struct GhosttyTerminalFrame: Sendable, Equatable {
  public struct Cell: Sendable, Equatable {
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
    public var hyperlink: String?

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
      usesDefaultBackground: Bool = false,
      hyperlink: String? = nil
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
      self.hyperlink = hyperlink
    }
  }

  public struct RGB: Sendable, Equatable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
  }

  public var cols: Int
  public var rows: Int
  public var cursorVisible: Bool
  public var cursorX: Int
  public var cursorY: Int
  public var cursorShape: TerminalCursorShape = .block
  public var cursorBlinking: Bool = false
  public var isAlternateScreen: Bool = false
  public var cells: [Cell]
}

public struct GhosttyTerminalScrollbar: Equatable, Sendable {
  public var total: UInt64
  public var offset: UInt64
  public var length: UInt64
}

public struct GhosttyTerminalCellRow: Sendable, Equatable {
  public var cells: [GhosttyTerminalFrame.Cell]

  public init(cells: [GhosttyTerminalFrame.Cell]) {
    self.cells = cells
  }
}

public struct GhosttyTerminalScrollFrame: Sendable, Equatable {
  public var viewport: GhosttyTerminalFrame
  public var overscanTop: [GhosttyTerminalCellRow]
  public var overscanBottom: [GhosttyTerminalCellRow]
  public var requestedOverscanTop: Int
  public var requestedOverscanBottom: Int
  public var viewportStartRow: UInt64?

  public init(
    viewport: GhosttyTerminalFrame,
    overscanTop: [GhosttyTerminalCellRow],
    overscanBottom: [GhosttyTerminalCellRow],
    requestedOverscanTop: Int,
    requestedOverscanBottom: Int,
    viewportStartRow: UInt64?
  ) {
    self.viewport = viewport
    self.overscanTop = overscanTop
    self.overscanBottom = overscanBottom
    self.requestedOverscanTop = requestedOverscanTop
    self.requestedOverscanBottom = requestedOverscanBottom
    self.viewportStartRow = viewportStartRow
  }

  public var overscanAvailable: Bool {
    !overscanTop.isEmpty || !overscanBottom.isEmpty
  }
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

  public func scrollViewport(deltaRows: Int) {
    guard let handle else { return }
    proghostty_vt_scroll_viewport(handle, deltaRows)
  }

  public func scrollbar() throws -> GhosttyTerminalScrollbar {
    guard let handle else {
      return GhosttyTerminalScrollbar(total: 0, offset: 0, length: 0)
    }
    var scrollbar = ProGhosttyVTScrollbar()
    let result = proghostty_vt_scrollbar(handle, &scrollbar)
    guard result == 0 else {
      throw BridgeError.formatFailed(result)
    }
    return GhosttyTerminalScrollbar(
      total: scrollbar.total,
      offset: scrollbar.offset,
      length: scrollbar.length
    )
  }

  public func scrollFrame(overscanTop: Int, overscanBottom: Int) throws -> GhosttyTerminalScrollFrame {
    guard let handle else {
      return GhosttyTerminalScrollFrame(
        viewport: GhosttyTerminalFrame(
          cols: 0, rows: 0, cursorVisible: false, cursorX: 0, cursorY: 0, cells: []),
        overscanTop: [],
        overscanBottom: [],
        requestedOverscanTop: max(0, overscanTop),
        requestedOverscanBottom: max(0, overscanBottom),
        viewportStartRow: nil
      )
    }

    var snapshot = ProGhosttyVTScrollSnapshot()
    let result = proghostty_vt_scroll_snapshot(
      handle,
      UInt16(max(0, min(overscanTop, Int(UInt16.max)))),
      UInt16(max(0, min(overscanBottom, Int(UInt16.max)))),
      &snapshot
    )
    guard result == 0 else {
      throw BridgeError.formatFailed(result)
    }
    defer { proghostty_vt_scroll_snapshot_free(&snapshot) }

    let viewport = Self.frame(from: snapshot.viewport)
    return GhosttyTerminalScrollFrame(
      viewport: viewport,
      overscanTop: Self.rows(
        from: snapshot.overscan_top_cells,
        rowCount: Int(snapshot.overscan_top_rows),
        cols: viewport.cols
      ),
      overscanBottom: Self.rows(
        from: snapshot.overscan_bottom_cells,
        rowCount: Int(snapshot.overscan_bottom_rows),
        cols: viewport.cols
      ),
      requestedOverscanTop: Int(snapshot.requested_overscan_top),
      requestedOverscanBottom: Int(snapshot.requested_overscan_bottom),
      viewportStartRow: snapshot.viewport_start_row
    )
  }

  public func frame() throws -> GhosttyTerminalFrame {
    guard let handle else {
      return GhosttyTerminalFrame(
        cols: 0, rows: 0, cursorVisible: false, cursorX: 0, cursorY: 0, cells: [])
    }

    var snapshot = ProGhosttyVTSnapshot()
    let result = proghostty_vt_snapshot(handle, &snapshot)
    guard result == 0, snapshot.cells != nil else {
      throw BridgeError.formatFailed(result)
    }
    defer { proghostty_vt_snapshot_free(&snapshot) }

    return Self.frame(from: snapshot)
  }

  private static func frame(from snapshot: ProGhosttyVTSnapshot) -> GhosttyTerminalFrame {
    let cells: [GhosttyTerminalFrame.Cell]
    if let rawCells = snapshot.cells {
      cells = UnsafeBufferPointer(start: rawCells, count: Int(snapshot.cell_count)).map(Self.cell(from:))
    } else {
      cells = []
    }

    return GhosttyTerminalFrame(
      cols: Int(snapshot.cols),
      rows: Int(snapshot.rows),
      cursorVisible: snapshot.cursor_visible,
      cursorX: Int(snapshot.cursor_x),
      cursorY: Int(snapshot.cursor_y),
      cursorShape: TerminalCursorShape(ghosttyRawValue: snapshot.cursor_visual_style),
      cursorBlinking: snapshot.cursor_blinking,
      isAlternateScreen: snapshot.alternate_screen,
      cells: cells
    )
  }

  private static func rows(
    from rawCells: UnsafeMutablePointer<ProGhosttyVTCell>?,
    rowCount: Int,
    cols: Int
  ) -> [GhosttyTerminalCellRow] {
    guard let rawCells, rowCount > 0, cols > 0 else {
      return []
    }

    let cells = UnsafeBufferPointer(start: rawCells, count: rowCount * cols).map(Self.cell(from:))
    return (0..<rowCount).map { row in
      let lower = row * cols
      let upper = lower + cols
      return GhosttyTerminalCellRow(cells: Array(cells[lower..<upper]))
    }
  }

  private static func cell(from rawCell: ProGhosttyVTCell) -> GhosttyTerminalFrame.Cell {
    let scalar = UnicodeScalar(rawCell.codepoint) ?? " "
    let hyperlink: String?
    if let pointer = rawCell.hyperlink_uri, rawCell.hyperlink_uri_len > 0 {
      let bytes = UnsafeBufferPointer(start: pointer, count: Int(rawCell.hyperlink_uri_len))
      hyperlink = String(decoding: bytes, as: UTF8.self)
    } else {
      hyperlink = nil
    }
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
      usesDefaultBackground: rawCell.bg_default,
      hyperlink: hyperlink
    )
  }

  public func plainText() throws -> String {
    try formattedString { handle, pointer, length in
      proghostty_vt_format_plain(handle, &pointer, &length)
    }
  }

  public func htmlText() throws -> String {
    let html = try formattedString { handle, pointer, length in
      proghostty_vt_format_html(handle, &pointer, &length)
    }
    return GhosttyHTMLAttributedAdapter.normalizedHTMLPaletteColors(in: html)
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

extension GhosttyVTBridge: @unchecked Sendable {}
