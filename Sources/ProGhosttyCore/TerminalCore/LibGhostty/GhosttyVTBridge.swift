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

public enum TerminalCellWidth: UInt8, Sendable {
  case narrow = 0
  case wide = 1
  case spacerTail = 2
  case spacerHead = 3

  init(ghosttyRawValue: UInt8) {
    self = TerminalCellWidth(rawValue: ghosttyRawValue) ?? .narrow
  }
}

public enum CellSemanticContent: UInt8, Sendable {
  case output = 0
  case input = 1
  case prompt = 2

  init(ghosttyRawValue: UInt8) {
    self = CellSemanticContent(rawValue: ghosttyRawValue) ?? .output
  }
}

public struct GhosttyTerminalFrame: Sendable, Equatable {
  public struct Cell: Sendable, Equatable {
    public var scalar: UnicodeScalar
    public var width: TerminalCellWidth
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
    public var semanticContent: CellSemanticContent

    public init(
      scalar: UnicodeScalar,
      width: TerminalCellWidth = .narrow,
      foreground: RGB,
      background: RGB,
      bold: Bool,
      italic: Bool,
      faint: Bool,
      underline: Bool,
      inverse: Bool,
      usesDefaultForeground: Bool = false,
      usesDefaultBackground: Bool = false,
      hyperlink: String? = nil,
      semanticContent: CellSemanticContent = .output
    ) {
      self.scalar = scalar
      self.width = width
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
      self.semanticContent = semanticContent
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
  /// Semantic content of the active screen's cursor. After OSC 133;C the cursor
  /// flips to .output even though written input cells stay .input — this is what
  /// distinguishes a live prompt from a stale/running command line (Ghostty's
  /// prompt-click movement keys off this same state).
  public var cursorSemanticContent: CellSemanticContent = .output
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

/// A bare window of rows fetched directly by absolute scrollback row number.
/// This is the pattern-2 primitive: the renderer asks for exactly the rows it
/// needs to draw at a scroll position `(topAbsoluteRow, P)`, with no
/// viewport/overscan geometry. The returned `rows` may be fewer than requested
/// when the window runs past the end of scrollback (clamped to `[startRow, total)`).
public struct GhosttyTerminalRowWindow: Sendable, Equatable {
  /// Absolute scrollback row number of `rows[0]` (clamped into `[0, total]`).
  public var startRow: UInt64
  /// Total rows currently in scrollback (history + screen).
  public var total: UInt64
  /// Column count these rows were fetched at.
  public var cols: Int
  public var rows: [GhosttyTerminalCellRow]

  public init(startRow: UInt64, total: UInt64, cols: Int, rows: [GhosttyTerminalCellRow]) {
    self.startRow = startRow
    self.total = total
    self.cols = cols
    self.rows = rows
  }
}

public struct GhosttyTerminalScrollFrame: Sendable, Equatable {
  /// Overscan rows requested above/below the viewport for pixel-smooth
  /// scrolling. The display link translates the visible band within this
  /// buffer without a synchronous VT row commit per row crossed, so this must
  /// be deep enough to absorb a fast fling's per-frame travel. Bounded by the
  /// C shim cap (PROGHOSTTY_VT_MAX_OVERSCAN_ROWS); keep the two in sync.
  public static let pixelScrollOverscanRows = 24

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

public enum TerminalScrollOwnership: Sendable, Equatable {
  case localScrollback
  case mouseReporting
  case alternateCursorKeys(applicationMode: Bool)
  case consumed
}

public enum TerminalMouseAction: Sendable, Equatable {
  case press
  case release
  case motion
}

public enum TerminalMouseButton: Sendable, Hashable {
  case left
  case right
  case middle
  case wheelUp
  case wheelDown
  case wheelLeft
  case wheelRight
}

public struct TerminalMouseInputEvent: Sendable, Equatable {
  public var action: TerminalMouseAction
  public var button: TerminalMouseButton?
  public var shift: Bool
  public var control: Bool
  public var alt: Bool
  public var anyButtonPressed: Bool
  public var x: Float
  public var y: Float

  public init(
    action: TerminalMouseAction,
    button: TerminalMouseButton? = nil,
    shift: Bool = false,
    control: Bool = false,
    alt: Bool = false,
    anyButtonPressed: Bool = false,
    x: Float,
    y: Float
  ) {
    self.action = action
    self.button = button
    self.shift = shift
    self.control = control
    self.alt = alt
    self.anyButtonPressed = anyButtonPressed
    self.x = x
    self.y = y
  }
}

public struct TerminalMouseGeometry: Sendable, Equatable {
  public var screenWidth: UInt32
  public var screenHeight: UInt32
  public var cellWidth: UInt32
  public var cellHeight: UInt32
  public var paddingTop: UInt32
  public var paddingBottom: UInt32
  public var paddingRight: UInt32
  public var paddingLeft: UInt32

  public init(
    screenWidth: UInt32,
    screenHeight: UInt32,
    cellWidth: UInt32,
    cellHeight: UInt32,
    paddingTop: UInt32,
    paddingBottom: UInt32,
    paddingRight: UInt32,
    paddingLeft: UInt32
  ) {
    self.screenWidth = screenWidth
    self.screenHeight = screenHeight
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.paddingTop = paddingTop
    self.paddingBottom = paddingBottom
    self.paddingRight = paddingRight
    self.paddingLeft = paddingLeft
  }
}

public final class GhosttyVTBridge {
  public enum BridgeError: Error, CustomStringConvertible {
    case createFailed(Int32)
    case formatFailed(Int32)
    case pasteEncodeFailed(Int32)
    case inputEncodeFailed(Int32)

    public var description: String {
      switch self {
      case .createFailed(let code):
        return "libghostty-vt create failed with code \(code)"
      case .formatFailed(let code):
        return "libghostty-vt format failed with code \(code)"
      case .pasteEncodeFailed(let code):
        return "libghostty-vt paste encode failed with code \(code)"
      case .inputEncodeFailed(let code):
        return "libghostty-vt input encode failed with code \(code)"
      }
    }
  }

  private var handle: OpaquePointer?
  private let lock = NSLock()

  public init(cols: Int = 80, rows: Int = 24, maxScrollback: Int = 10_000) throws {
    var handle: OpaquePointer?
    let result = proghostty_vt_new(UInt16(cols), UInt16(rows), maxScrollback, &handle)
    guard result == 0, let handle else {
      throw BridgeError.createFailed(result)
    }
    self.handle = handle
  }

  deinit {
    lock.lock()
    if let handle {
      self.handle = nil
      proghostty_vt_free(handle)
    }
    lock.unlock()
  }

  public func write(_ data: Data) {
    locked {
      guard let handle else { return }
      data.withUnsafeBytes { bytes in
        guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
        proghostty_vt_write(handle, base, data.count)
      }
    }
  }

  public func resize(cols: Int, rows: Int) {
    locked {
      guard let handle else { return }
      _ = proghostty_vt_resize(handle, UInt16(cols), UInt16(rows))
    }
  }

  public func scrollViewport(deltaRows: Int) {
    locked {
      guard let handle else { return }
      proghostty_vt_scroll_viewport(handle, deltaRows)
    }
  }

  public func encodedPaste(_ text: String) throws -> Data {
    try locked {
      guard let handle else { return Data() }
      let input = Data(text.utf8)
      var pointer: UnsafeMutablePointer<UInt8>?
      var length = 0
      let result = input.withUnsafeBytes { bytes in
        proghostty_vt_encode_paste(
          handle,
          bytes.bindMemory(to: UInt8.self).baseAddress,
          input.count,
          &pointer,
          &length
        )
      }
      guard result == 0 else {
        throw BridgeError.pasteEncodeFailed(result)
      }
      guard let pointer else { return Data() }
      defer { proghostty_vt_free_bytes(pointer, length) }
      return Data(bytes: pointer, count: length)
    }
  }

  public func isMouseReportingActive() -> Bool {
    locked {
      guard let handle else { return false }
      return proghostty_vt_mouse_reporting_active(handle)
    }
  }

  public func scrollOwnership() throws -> TerminalScrollOwnership {
    try locked {
      guard let handle else { return .localScrollback }
      var ownership = ProGhosttyVTScrollOwnership()
      let result = proghostty_vt_scroll_ownership(handle, &ownership)
      guard result == 0 else {
        throw BridgeError.inputEncodeFailed(result)
      }
      switch ownership.kind {
      case PROGHOSTTY_VT_SCROLL_MOUSE_REPORTING:
        return .mouseReporting
      case PROGHOSTTY_VT_SCROLL_ALTERNATE_CURSOR_KEYS:
        return .alternateCursorKeys(applicationMode: ownership.application_cursor_keys)
      case PROGHOSTTY_VT_SCROLL_CONSUMED:
        return .consumed
      default:
        return .localScrollback
      }
    }
  }

  public func encodedMouseInput(
    _ event: TerminalMouseInputEvent,
    geometry: TerminalMouseGeometry
  ) throws -> Data {
    try locked {
      guard let handle else { return Data() }
      var rawEvent = ProGhosttyVTMouseEvent(
        action: rawMouseAction(event.action),
        button: rawMouseButton(event.button),
        shift: event.shift,
        control: event.control,
        alt: event.alt,
        any_button_pressed: event.anyButtonPressed,
        x: event.x,
        y: event.y
      )
      var rawGeometry = ProGhosttyVTMouseGeometry(
        screen_width: geometry.screenWidth,
        screen_height: geometry.screenHeight,
        cell_width: geometry.cellWidth,
        cell_height: geometry.cellHeight,
        padding_top: geometry.paddingTop,
        padding_bottom: geometry.paddingBottom,
        padding_right: geometry.paddingRight,
        padding_left: geometry.paddingLeft
      )
      var pointer: UnsafeMutablePointer<UInt8>?
      var length = 0
      let result = proghostty_vt_encode_mouse_input(
        handle,
        &rawEvent,
        &rawGeometry,
        &pointer,
        &length
      )
      guard result == 0 else {
        throw BridgeError.inputEncodeFailed(result)
      }
      guard let pointer else { return Data() }
      defer { proghostty_vt_free_bytes(pointer, length) }
      return Data(bytes: pointer, count: length)
    }
  }

  private func rawMouseAction(_ action: TerminalMouseAction) -> ProGhosttyVTMouseAction {
    switch action {
    case .press:
      return PROGHOSTTY_VT_MOUSE_ACTION_PRESS
    case .release:
      return PROGHOSTTY_VT_MOUSE_ACTION_RELEASE
    case .motion:
      return PROGHOSTTY_VT_MOUSE_ACTION_MOTION
    }
  }

  private func rawMouseButton(_ button: TerminalMouseButton?) -> ProGhosttyVTMouseButton {
    switch button {
    case .left:
      return PROGHOSTTY_VT_MOUSE_BUTTON_LEFT
    case .right:
      return PROGHOSTTY_VT_MOUSE_BUTTON_RIGHT
    case .middle:
      return PROGHOSTTY_VT_MOUSE_BUTTON_MIDDLE
    case .wheelUp:
      return PROGHOSTTY_VT_MOUSE_BUTTON_FOUR
    case .wheelDown:
      return PROGHOSTTY_VT_MOUSE_BUTTON_FIVE
    case .wheelLeft:
      return PROGHOSTTY_VT_MOUSE_BUTTON_SEVEN
    case .wheelRight:
      return PROGHOSTTY_VT_MOUSE_BUTTON_SIX
    case nil:
      return PROGHOSTTY_VT_MOUSE_BUTTON_NONE
    }
  }

  public func encodedAlternateScroll(wheelUp: Bool, count: Int) throws -> Data {
    try locked {
      guard let handle, count > 0 else { return Data() }
      var pointer: UnsafeMutablePointer<UInt8>?
      var length = 0
      let result = proghostty_vt_encode_alternate_scroll(
        handle,
        wheelUp,
        count,
        &pointer,
        &length
      )
      guard result == 0 else {
        throw BridgeError.inputEncodeFailed(result)
      }
      guard let pointer else { return Data() }
      defer { proghostty_vt_free_bytes(pointer, length) }
      return Data(bytes: pointer, count: length)
    }
  }

  public func scrollbar() throws -> GhosttyTerminalScrollbar {
    try locked {
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
  }

  public func scrollFrame(overscanTop: Int, overscanBottom: Int) throws -> GhosttyTerminalScrollFrame {
    try locked {
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
  }

  /// Fetch a window of `count` rows starting at absolute scrollback row
  /// `startRow`. The pattern-2 rendering primitive: browsing never moves the VT
  /// viewport, so this reads arbitrary rows directly. The result is clamped to
  /// `[startRow, total)` and may contain fewer rows than requested near the end.
  public func rows(at startRow: UInt64, count: Int) throws -> GhosttyTerminalRowWindow {
    try locked {
      guard let handle, count > 0 else {
        return GhosttyTerminalRowWindow(startRow: startRow, total: 0, cols: 0, rows: [])
      }

      var window = ProGhosttyVTRows()
      let result = proghostty_vt_rows_at(handle, startRow, count, &window)
      guard result == 0 else {
        throw BridgeError.formatFailed(result)
      }
      defer { proghostty_vt_rows_free(&window) }

      let cols = Int(window.cols)
      return GhosttyTerminalRowWindow(
        startRow: window.start_row,
        total: window.total,
        cols: cols,
        rows: Self.rows(
          from: window.cells,
          rowCount: Int(window.rows),
          cols: cols
        )
      )
    }
  }

  public func frame() throws -> GhosttyTerminalFrame {
    try locked {
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
      cursorSemanticContent: CellSemanticContent(ghosttyRawValue: snapshot.cursor_semantic_content),
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
      width: TerminalCellWidth(ghosttyRawValue: rawCell.wide),
      foreground: GhosttyTerminalFrame.RGB(r: rawCell.fg_r, g: rawCell.fg_g, b: rawCell.fg_b),
      background: GhosttyTerminalFrame.RGB(r: rawCell.bg_r, g: rawCell.bg_g, b: rawCell.bg_b),
      bold: rawCell.bold,
      italic: rawCell.italic,
      faint: rawCell.faint,
      underline: rawCell.underline,
      inverse: rawCell.inverse,
      usesDefaultForeground: rawCell.fg_default,
      usesDefaultBackground: rawCell.bg_default,
      hyperlink: hyperlink,
      semanticContent: CellSemanticContent(ghosttyRawValue: rawCell.semantic_content)
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
    return HTMLPaletteNormalizer.normalized(html)
  }

  private func formattedString(
    _ format: (OpaquePointer, inout UnsafeMutablePointer<UInt8>?, inout Int) -> Int32
  ) throws -> String {
    try locked {
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

  private func locked<T>(_ work: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try work()
  }
}

extension GhosttyVTBridge: @unchecked Sendable {}
