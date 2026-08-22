import Foundation

/// Pure layout math for the markdown preview float (spec:
/// 2026-08-18-markdown-preview-float.md). All frames are in the container's
/// coordinate space, y-up (AppKit convention). Testable without UI.
public enum MarkdownPreviewLayout {
  public static let minimumSize = CGSize(width: 280, height: 180)
  public static let defaultWidth: CGFloat = 560
  public static let defaultHeightRatio: CGFloat = 0.6
  public static let edgeInset: CGFloat = 12

  /// Initial frame: top-right of the container (or of the anchor pane), sized
  /// to the reading measure, clamped inside the container. Top placement keeps
  /// it clear of the bottom input region of any pane.
  public static func initialFrame(in container: CGSize, anchoredTo pane: CGRect? = nil) -> CGRect {
    let width = min(defaultWidth, max(minimumSize.width, container.width - edgeInset * 2))
    let height = min(max(minimumSize.height, container.height * defaultHeightRatio), container.height - edgeInset * 2)
    guard width > 0, height > 0 else {
      return CGRect(origin: .zero, size: CGSize(width: max(0, width), height: max(0, height)))
    }
    var frame = CGRect(
      x: container.width - width - edgeInset,
      y: container.height - height - edgeInset,
      width: width,
      height: height
    )
    if let pane {
      frame.origin.x = pane.maxX - width
      frame.origin.y = pane.maxY - height
    }
    return clamped(frame, in: container)
  }

  /// Clamp a frame fully inside the container: size is capped to the container
  /// and the origin is pushed back so nothing overflows.
  public static func clamped(_ frame: CGRect, in container: CGSize) -> CGRect {
    let width = min(frame.width, container.width)
    let height = min(frame.height, container.height)
    let maxX = max(0, container.width - width)
    let maxY = max(0, container.height - height)
    return CGRect(
      x: min(max(0, frame.minX), maxX),
      y: min(max(0, frame.minY), maxY),
      width: max(0, width),
      height: max(0, height)
    )
  }

  /// Move by a drag delta, clamped to the container.
  public static func moved(_ frame: CGRect, by delta: CGSize, in container: CGSize) -> CGRect {
    clamped(
      CGRect(x: frame.minX + delta.width, y: frame.minY + delta.height, width: frame.width, height: frame.height),
      in: container
    )
  }

  /// How a mini card is anchored to the grab point. `.top` keeps the card's grab
  /// handle (the three dots, ~`handleGrabOffset` below the top edge) under the
  /// cursor — used for the handle grab, so the mouse stays on the dots like
  /// dragging a window by its title bar. `.center` keeps the card centered on
  /// the cursor — used for an ⌥-drag anywhere on the float, so the card stays
  /// under your finger. Centering is the natural default; a top-grab centered
  /// on a cursor near the container's top would be clamped down, leaving the
  /// cursor outside the card.
  public enum MiniCardAnchor {
    case top
    case center
  }

  /// Distance from the mini card's top edge down to its grab handle (a 60×16
  /// strip at top+2). `.top` anchors so this handle — and the three dots — stays
  /// under the cursor while dragging; anchoring the top EDGE there would leave
  /// the cursor on the top edge, which is a resize zone (resize cursor, and the
  /// mouse misses the dots).
  public static let handleGrabOffset: CGFloat = 10

  /// Frame of the mini "carry" card shown while a dock-directed drag lifts a
  /// pane-filling float (or ⌥-drags one): a small thumbnail anchored on the
  /// grab point so the preview is maneuverable and can be dropped onto any
  /// pane. A pane-sized float physically can't be dropped onto a small pane
  /// (`moved` clamps it inside the container, so a full-height float never moves
  /// down and a wide float's center can't reach a narrow pane), so a
  /// dock-directed grab tears the float off at this size.
  public static func miniCardFrame(
    grabbedAt point: CGPoint,
    container: CGSize,
    anchor: MiniCardAnchor = .center
  ) -> CGRect {
    let width = min(320, max(200, container.width - edgeInset * 2))
    let height = min(250, max(150, container.height - edgeInset * 2))
    let y: CGFloat
    switch anchor {
    case .top: y = point.y - height + handleGrabOffset // top edge above the cursor; the handle sits on it
    case .center: y = point.y - height / 2
    }
    return clamped(
      CGRect(x: point.x - width / 2, y: y, width: width, height: height),
      in: container
    )
  }

  /// Which edge/corner of the float the user is resizing from. The opposite
  /// edge(s) stay anchored.
  public enum ResizeZone: Sendable, CaseIterable, Equatable {
    case top, bottom, left, right
    case topLeft, topRight, bottomLeft, bottomRight
  }

  /// Resize from any edge or corner (macOS-window style): the edges opposite
  /// the zone stay fixed and the dragged edge follows the mouse. Clamped to the
  /// container and to the minimum size. In y-up coords "top"/"right" move
  /// maxY/maxX; "bottom"/"left" move minY/minX.
  public static func resized(
    _ frame: CGRect,
    by delta: CGSize,
    from zone: ResizeZone,
    minimumSize: CGSize = minimumSize,
    in container: CGSize
  ) -> CGRect {
    var minX = frame.minX, maxX = frame.maxX
    var minY = frame.minY, maxY = frame.maxY
    switch zone {
    case .left, .topLeft, .bottomLeft: minX += delta.width
    case .right, .topRight, .bottomRight: maxX += delta.width
    default: break
    }
    switch zone {
    case .bottom, .bottomLeft, .bottomRight: minY += delta.height
    case .top, .topLeft, .topRight: maxY += delta.height
    default: break
    }
    if maxX - minX < minimumSize.width {
      switch zone {
      case .left, .topLeft, .bottomLeft: minX = maxX - minimumSize.width
      default: maxX = minX + minimumSize.width
      }
    }
    if maxY - minY < minimumSize.height {
      switch zone {
      case .bottom, .bottomLeft, .bottomRight: minY = maxY - minimumSize.height
      default: maxY = minY + minimumSize.height
      }
    }
    return clamped(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), in: container)
  }

  /// Snap threshold: how close the float's center must get to a panel's (dilated)
  /// bounds for the panel to become a drop target.
  public static let snapThreshold: CGFloat = 12

  /// Returns the index of the panel to dock into when the float is dropped here,
  /// or nil if the float isn't over any panel. Rule: the float's center inside a
  /// panel's bounds (dilated by the snap threshold) → that panel is the target.
  /// Requires at least 2 panels: with a single panel, docking would cover the
  /// whole terminal, which is never a useful dock.
  public static func snapTarget(for frame: CGRect, panels: [CGRect], threshold: CGFloat = snapThreshold) -> Int? {
    snapTarget(at: CGPoint(x: frame.midX, y: frame.midY), panels: panels, threshold: threshold)
  }

  /// The panel containing `point` (dilated by the snap threshold), or nil. The
  /// dock-directed drag uses the carry card's center (and thus the cursor) as
  /// the point, so the target is the pane the card is actually over — aiming is
  /// done with the card, not a pixel-perfect edge.
  public static func snapTarget(at point: CGPoint, panels: [CGRect], threshold: CGFloat = snapThreshold) -> Int? {
    guard panels.count >= 2 else { return nil }
    return panels.firstIndex { $0.insetBy(dx: -threshold, dy: -threshold).contains(point) }
  }

  /// Frame when docked into a panel: exactly the panel's bounds (a 1pt inset
  /// keeps the float's rounded border from hiding the panel edge entirely).
  public static func dockedFrame(for panel: CGRect) -> CGRect {
    panel.insetBy(dx: 1, dy: 1)
  }
}
