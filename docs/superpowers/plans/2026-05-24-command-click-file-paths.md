# Command Click File Paths Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Cmd+click reveal local terminal file paths in Finder while preserving existing Cmd+click web URL behavior.

**Architecture:** Add a link target model in `ProGhosttyCore` that distinguishes web URL targets from local path targets. Keep hit testing in the terminal rendering layer, but route clicked targets with the clicked session ID back to `AppModel` for cwd resolution and Finder reveal. Keep local path resolution testable as pure Core logic; keep `NSWorkspace` side effects isolated in the app layer.

**Tech Stack:** Swift 6.1, AppKit `NSWorkspace`, existing `PTYGridView` hit testing, Swift Testing.

---

## File Structure

- Create `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalLinkDetector.swift`
  - Defines `TerminalLinkTarget`, `TerminalFilePathTarget`, `TerminalLinkHit`, and detector logic for URLs plus local paths.
- Create `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalFilePathResolver.swift`
  - Resolves path targets against home directory and optional pane cwd, checks existence, and returns a file URL or typed error.
- Modify `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalURLDetector.swift`
  - Keep existing URL detector API for compatibility, or make its internal helpers usable by the new link detector without changing behavior.
- Modify `Sources/ProGhosttyCore/TerminalCore/TerminalModels.swift`
  - Add `setLinkTargetHandler` to `TerminalSurfaceRegistry`.
- Modify `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
  - Route Cmd+click through `TerminalLinkDetector`.
  - Preserve `openURLHandler` fallback for URL tests.
  - Add registry-level link target callback carrying `TerminalSessionID`.
- Modify `Sources/ProGhosttyCore/TerminalCore/LibGhostty/LibGhosttyTerminalEngine.swift`
  - Add no-op `setLinkTargetHandler`.
- Modify `Sources/ProGhosttyCore/TerminalCore/Mock/MockTerminalEngine.swift`
  - Add no-op or stored `setLinkTargetHandler`.
- Modify `Sources/ProGhosttyApp/UI/AppModel.swift`
  - Register link target handler.
  - Resolve local paths with session cwd.
  - Open URLs normally and reveal local paths in Finder.
  - Show short titlebar hints for missing/unresolvable paths.
- Modify `Sources/ProGhosttyApp/UI/AppText.swift`
  - Add localized short hint strings.
- Modify `Tests/ProGhosttyCoreTests/TerminalURLDetectorTests.swift`
  - Keep URL regression tests.
- Create `Tests/ProGhosttyCoreTests/TerminalLinkDetectorTests.swift`
  - Unit tests for URL/path hit detection.
- Create `Tests/ProGhosttyCoreTests/TerminalFilePathResolverTests.swift`
  - Unit tests for path resolution and existence checks.
- Modify `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`
  - Add grid Cmd+click path target behavior tests and keep URL behavior tests passing.

---

### Task 1: Add Link Target Detection

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalLinkDetector.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalLinkDetectorTests.swift`

- [ ] **Step 1: Write failing detector tests**

Create `Tests/ProGhosttyCoreTests/TerminalLinkDetectorTests.swift`:

```swift
import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Terminal link detector")
struct TerminalLinkDetectorTests {
  @Test func detectsHTTPURLAsURLTarget() throws {
    let frame = frame(rows: ["open https://example.com/docs now"], cols: 40)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 8, in: frame))

    #expect(hit.target == .url(URL(string: "https://example.com/docs")!))
    #expect(hit.text == "https://example.com/docs")
  }

  @Test func detectsAbsolutePathAsFilePathTarget() throws {
    let frame = frame(rows: ["cat /Users/me/project/README.md"], cols: 40)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 8, in: frame))

    #expect(hit.target == .filePath(TerminalFilePathTarget(rawPath: "/Users/me/project/README.md", line: nil, column: nil)))
  }

  @Test func detectsHomeRelativePathAsFilePathTarget() throws {
    let frame = frame(rows: ["open ~/notes/today.md"], cols: 32)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 8, in: frame))

    #expect(hit.target == .filePath(TerminalFilePathTarget(rawPath: "~/notes/today.md", line: nil, column: nil)))
  }

  @Test func detectsDotRelativePathAsFilePathTarget() throws {
    let frame = frame(rows: ["vim ./Sources/App.swift"], cols: 36)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 8, in: frame))

    #expect(hit.target == .filePath(TerminalFilePathTarget(rawPath: "./Sources/App.swift", line: nil, column: nil)))
  }

  @Test func detectsParentRelativePathAsFilePathTarget() throws {
    let frame = frame(rows: ["cat ../README.md"], cols: 28)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 6, in: frame))

    #expect(hit.target == .filePath(TerminalFilePathTarget(rawPath: "../README.md", line: nil, column: nil)))
  }

  @Test func detectsCwdRelativeFileLookingPathAsFilePathTarget() throws {
    let frame = frame(rows: ["error Sources/App.swift:42:3"], cols: 40)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 10, in: frame))

    #expect(hit.target == .filePath(TerminalFilePathTarget(rawPath: "Sources/App.swift", line: 42, column: 3)))
    #expect(hit.text == "Sources/App.swift:42:3")
  }

  @Test func stripsTrailingSentencePunctuationFromPath() throws {
    let frame = frame(rows: ["see docs/readme.md."], cols: 28)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 6, in: frame))

    #expect(hit.target == .filePath(TerminalFilePathTarget(rawPath: "docs/readme.md", line: nil, column: nil)))
    #expect(hit.text == "docs/readme.md")
  }

  @Test func prefersOSC8HyperlinkOverVisiblePath() throws {
    var frame = frame(rows: ["docs/readme.md"], cols: 24)
    for col in 0..<14 {
      frame.cells[col].hyperlink = "https://docs.example/readme"
    }

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 4, in: frame))

    #expect(hit.target == .url(URL(string: "https://docs.example/readme")!))
  }

  @Test func doesNotTreatPlainWordsAsPaths() {
    let frame = frame(rows: ["plain words only"], cols: 24)

    #expect(TerminalLinkDetector.hitTest(row: 0, col: 2, in: frame) == nil)
  }

  private func frame(rows: [String], cols: Int) -> GhosttyTerminalFrame {
    let cells = rows.flatMap { row in
      let padded = row.padding(toLength: cols, withPad: " ", startingAt: 0)
      return padded.unicodeScalars.prefix(cols).map {
        GhosttyTerminalFrame.Cell(
          scalar: $0,
          foreground: GhosttyTerminalFrame.RGB(r: 255, g: 255, b: 255),
          background: GhosttyTerminalFrame.RGB(r: 0, g: 0, b: 0),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false,
          usesDefaultForeground: true,
          usesDefaultBackground: true
        )
      }
    }
    return GhosttyTerminalFrame(
      cols: cols,
      rows: rows.count,
      cursorVisible: true,
      cursorX: 0,
      cursorY: 0,
      cursorShape: .bar,
      cursorBlinking: false,
      isAlternateScreen: false,
      cells: cells
    )
  }
}
```

- [ ] **Step 2: Run detector tests and verify they fail**

Run:

```bash
swift test --filter TerminalLinkDetectorTests
```

Expected: FAIL because `TerminalLinkDetector`, `TerminalLinkTarget`, `TerminalFilePathTarget`, and `TerminalLinkHit` are not defined.

- [ ] **Step 3: Add the link target detector**

Create `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalLinkDetector.swift`:

```swift
import Foundation

public enum TerminalLinkTarget: Equatable, Sendable {
  case url(URL)
  case filePath(TerminalFilePathTarget)
}

public struct TerminalFilePathTarget: Equatable, Sendable {
  public var rawPath: String
  public var line: Int?
  public var column: Int?

  public init(rawPath: String, line: Int? = nil, column: Int? = nil) {
    self.rawPath = rawPath
    self.line = line
    self.column = column
  }

  public var requiresWorkingDirectory: Bool {
    !(rawPath.hasPrefix("/") || rawPath.hasPrefix("~/"))
  }
}

public struct TerminalLinkHit: Equatable, Sendable {
  public var target: TerminalLinkTarget
  public var row: Int
  public var range: Range<Int>
  public var text: String

  public init(target: TerminalLinkTarget, row: Int, range: Range<Int>, text: String) {
    self.target = target
    self.row = row
    self.range = range
    self.text = text
  }

  public func contains(row: Int, col: Int) -> Bool {
    self.row == row && range.contains(col)
  }
}

public enum TerminalLinkDetector {
  private static let pathPattern =
    #"(?<![A-Za-z0-9_])((?:~|/|\.{1,2})/[^\s<>"']+|(?:[A-Za-z0-9._@%+=~-]+/)+[A-Za-z0-9._@%+=~-]+\.[A-Za-z0-9._@%+=~-]+(?::\d+){0,2})"#
  private static let trailingCharacters = CharacterSet(charactersIn: ".,;!?)]}")

  public static func hitTest(row: Int, col: Int, in frame: GhosttyTerminalFrame) -> TerminalLinkHit? {
    hits(inRow: row, frame: frame).first { $0.contains(row: row, col: col) }
  }

  public static func hits(inRow row: Int, frame: GhosttyTerminalFrame) -> [TerminalLinkHit] {
    guard row >= 0, row < frame.rows, frame.cols > 0 else { return [] }
    let urlHits = TerminalURLDetector.hits(inRow: row, frame: frame).map {
      TerminalLinkHit(target: .url($0.url), row: $0.row, range: $0.range, text: $0.text)
    }
    let pathHits = visiblePathHits(inRow: row, frame: frame).filter { pathHit in
      !urlHits.contains { rangesOverlap($0.range, pathHit.range) }
    }
    return urlHits + pathHits
  }

  private static func visiblePathHits(inRow row: Int, frame: GhosttyTerminalFrame) -> [TerminalLinkHit] {
    let rowStart = row * frame.cols
    let rowEnd = min(rowStart + frame.cols, frame.cells.count)
    guard rowStart < rowEnd else { return [] }
    let line = frame.cells[rowStart..<rowEnd].map { String($0.scalar) }.joined()
    let nsLine = line as NSString
    let fullRange = NSRange(location: 0, length: nsLine.length)
    guard let regex = try? NSRegularExpression(pattern: pathPattern) else { return [] }
    return regex.matches(in: line, options: [], range: fullRange).compactMap { match in
      pathHit(from: nsLine.substring(with: match.range(at: 1)), range: match.range(at: 1), row: row)
    }
  }

  private static func pathHit(from rawText: String, range rawRange: NSRange, row: Int) -> TerminalLinkHit? {
    let trimmed = rawText.trimmingCharacters(in: trailingCharacters)
    guard !trimmed.isEmpty else { return nil }
    let parsed = stripLineAndColumn(from: trimmed)
    let removedCharacterCount = rawText.count - parsed.visibleText.count
    let range = rawRange.location..<(rawRange.location + max(0, rawRange.length - removedCharacterCount))
    return TerminalLinkHit(
      target: .filePath(TerminalFilePathTarget(rawPath: parsed.path, line: parsed.line, column: parsed.column)),
      row: row,
      range: range,
      text: parsed.visibleText
    )
  }

  private static func stripLineAndColumn(from text: String) -> (path: String, line: Int?, column: Int?, visibleText: String) {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 2, let lineText = parts.dropLast().last, let line = Int(lineText) else {
      return (text, nil, nil, text)
    }
    if parts.count >= 3, let columnText = parts.last, let column = Int(columnText) {
      let path = parts.dropLast(2).joined(separator: ":")
      guard !path.isEmpty else { return (text, nil, nil, text) }
      return (path, line, column, text)
    }
    let path = parts.dropLast().joined(separator: ":")
    guard !path.isEmpty else { return (text, nil, nil, text) }
    return (path, line, nil, text)
  }

  private static func rangesOverlap(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
    lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
  }
}
```

- [ ] **Step 4: Run detector tests and verify they pass**

Run:

```bash
swift test --filter TerminalLinkDetectorTests
```

Expected: PASS.

- [ ] **Step 5: Commit detector work**

Run:

```bash
git add Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalLinkDetector.swift Tests/ProGhosttyCoreTests/TerminalLinkDetectorTests.swift
git commit -m "Add terminal link target detector"
```

---

### Task 2: Add File Path Resolution

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalFilePathResolver.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalFilePathResolverTests.swift`

- [ ] **Step 1: Write failing resolver tests**

Create `Tests/ProGhosttyCoreTests/TerminalFilePathResolverTests.swift`:

```swift
import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Terminal file path resolver")
struct TerminalFilePathResolverTests {
  @Test func resolvesExistingAbsolutePathWithoutCwd() throws {
    let file = try makeTempFile(name: "absolute.md")

    let resolved = try TerminalFilePathResolver.resolve(
      TerminalFilePathTarget(rawPath: file.path),
      cwd: nil,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
    )

    #expect(resolved == file)
  }

  @Test func resolvesHomeRelativePath() throws {
    let home = try makeTempDirectory()
    let file = home.appendingPathComponent("notes/today.md")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "note".write(to: file, atomically: true, encoding: .utf8)

    let resolved = try TerminalFilePathResolver.resolve(
      TerminalFilePathTarget(rawPath: "~/notes/today.md"),
      cwd: nil,
      homeDirectory: home.path
    )

    #expect(resolved == file)
  }

  @Test func resolvesRelativePathAgainstCwd() throws {
    let cwd = try makeTempDirectory()
    let file = cwd.appendingPathComponent("Sources/App.swift")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "print(1)".write(to: file, atomically: true, encoding: .utf8)

    let resolved = try TerminalFilePathResolver.resolve(
      TerminalFilePathTarget(rawPath: "Sources/App.swift"),
      cwd: cwd.path,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
    )

    #expect(resolved == file)
  }

  @Test func rejectsRelativePathWithoutCwd() {
    #expect(throws: TerminalFilePathResolver.Error.missingWorkingDirectory) {
      try TerminalFilePathResolver.resolve(
        TerminalFilePathTarget(rawPath: "Sources/App.swift"),
        cwd: nil,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
      )
    }
  }

  @Test func rejectsMissingPathInsteadOfOpeningParent() throws {
    let cwd = try makeTempDirectory()

    #expect(throws: TerminalFilePathResolver.Error.pathNotFound) {
      try TerminalFilePathResolver.resolve(
        TerminalFilePathTarget(rawPath: "missing/file.md"),
        cwd: cwd.path,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
      )
    }
  }

  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeTempFile(name: String) throws -> URL {
    let directory = try makeTempDirectory()
    let file = directory.appendingPathComponent(name)
    try "content".write(to: file, atomically: true, encoding: .utf8)
    return file
  }
}
```

- [ ] **Step 2: Run resolver tests and verify they fail**

Run:

```bash
swift test --filter TerminalFilePathResolverTests
```

Expected: FAIL because `TerminalFilePathResolver` is not defined.

- [ ] **Step 3: Add resolver implementation**

Create `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalFilePathResolver.swift`:

```swift
import Foundation

public enum TerminalFilePathResolver {
  public enum Error: Swift.Error, Equatable {
    case missingWorkingDirectory
    case pathNotFound
  }

  public static func resolve(
    _ target: TerminalFilePathTarget,
    cwd: String?,
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
    fileManager: FileManager = .default
  ) throws -> URL {
    let expandedPath: String
    if target.rawPath.hasPrefix("/") {
      expandedPath = target.rawPath
    } else if target.rawPath == "~" {
      expandedPath = homeDirectory
    } else if target.rawPath.hasPrefix("~/") {
      expandedPath = homeDirectory + String(target.rawPath.dropFirst())
    } else {
      guard let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw Error.missingWorkingDirectory
      }
      expandedPath = URL(fileURLWithPath: cwd).appendingPathComponent(target.rawPath).standardizedFileURL.path
    }

    let url = URL(fileURLWithPath: expandedPath).standardizedFileURL
    guard fileManager.fileExists(atPath: url.path) else {
      throw Error.pathNotFound
    }
    return url
  }
}
```

- [ ] **Step 4: Run resolver tests and verify they pass**

Run:

```bash
swift test --filter TerminalFilePathResolverTests
```

Expected: PASS.

- [ ] **Step 5: Commit resolver work**

Run:

```bash
git add Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalFilePathResolver.swift Tests/ProGhosttyCoreTests/TerminalFilePathResolverTests.swift
git commit -m "Resolve terminal file path targets"
```

---

### Task 3: Route Cmd-Click Link Targets From Grid Views

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/TerminalModels.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/LibGhostty/LibGhosttyTerminalEngine.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Mock/MockTerminalEngine.swift`
- Modify: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

- [ ] **Step 1: Write failing grid behavior tests**

In `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`, add these tests near existing Cmd+click URL tests:

```swift
  @MainActor @Test func ptyGridCommandClickOpensFilePathTarget() throws {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["edit Sources/App.swift"], cols: 32, cursorX: 0, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)
    var openedTarget: TerminalLinkTarget?
    gridView.openLinkTargetHandler = { openedTarget = $0 }
    let rect = PTYGridView.textGlyphRect(row: 0, col: 8, cellSize: cellSize, inset: inset)
    let event = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: NSPoint(x: rect.midX, y: rect.midY),
      modifierFlags: [.command],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))

    gridView.mouseDown(with: event)

    #expect(openedTarget == .filePath(TerminalFilePathTarget(rawPath: "Sources/App.swift")))
  }

  @MainActor @Test func ptyGridPlainClickOnFilePathDoesNotOpenTarget() throws {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["edit Sources/App.swift"], cols: 32, cursorX: 0, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)
    var openedTarget: TerminalLinkTarget?
    gridView.openLinkTargetHandler = { openedTarget = $0 }
    let rect = PTYGridView.textGlyphRect(row: 0, col: 8, cellSize: cellSize, inset: inset)
    let event = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: NSPoint(x: rect.midX, y: rect.midY),
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))

    gridView.mouseDown(with: event)

    #expect(openedTarget == nil)
  }
```

- [ ] **Step 2: Run grid tests and verify they fail**

Run:

```bash
swift test --filter "ptyGridCommandClickOpensFilePathTarget|ptyGridPlainClickOnFilePathDoesNotOpenTarget"
```

Expected: FAIL because `PTYGridView.openLinkTargetHandler` is not defined.

- [ ] **Step 3: Add registry protocol method**

In `Sources/ProGhosttyCore/TerminalCore/TerminalModels.swift`, add this method to `TerminalSurfaceRegistry` after `setLinkHoverHandler`:

```swift
  func setLinkTargetHandler(_ handler: (@MainActor (TerminalSessionID, TerminalLinkTarget) -> Void)?)
```

- [ ] **Step 4: Add no-op implementations**

In `Sources/ProGhosttyCore/TerminalCore/LibGhostty/LibGhosttyTerminalEngine.swift`, add:

```swift
  public func setLinkTargetHandler(_ handler: (@MainActor (TerminalSessionID, TerminalLinkTarget) -> Void)?) {}
```

In `Sources/ProGhosttyCore/TerminalCore/Mock/MockTerminalEngine.swift`, add:

```swift
  public func setLinkTargetHandler(_ handler: (@MainActor (TerminalSessionID, TerminalLinkTarget) -> Void)?) {}
```

- [ ] **Step 5: Wire link target handler in PTY registry**

In `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`, add a stored property near `linkHoverHandler`:

```swift
  private var linkTargetHandler: (@MainActor (TerminalSessionID, TerminalLinkTarget) -> Void)?
```

In `createSurface(session:)`, after setting `gridView.linkHoverHandler`, add:

```swift
    gridView.openLinkTargetHandler = { [weak self] target in
      self?.linkTargetHandler?(id, target)
    }
```

Add this public method near `setLinkHoverHandler`:

```swift
  public func setLinkTargetHandler(_ handler: (@MainActor (TerminalSessionID, TerminalLinkTarget) -> Void)?) {
    linkTargetHandler = handler
    for (id, surface) in surfaces {
      surface.gridView.openLinkTargetHandler = { [weak self] target in
        self?.linkTargetHandler?(id, target)
      }
    }
  }
```

- [ ] **Step 6: Update `PTYGridView` command-click logic**

In `PTYGridView`, add this property next to `openURLHandler`:

```swift
  public var openLinkTargetHandler: ((TerminalLinkTarget) -> Void)?
```

Replace the command-click branch in `mouseDown(with:)` with:

```swift
    if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
      let hit = linkHit(at: convert(event.locationInWindow, from: nil))
    {
      if let openLinkTargetHandler {
        openLinkTargetHandler(hit.target)
      } else if case .url(let url) = hit.target {
        openURLHandler?(url)
      }
      return
    }
```

Rename `urlHit(at:)` to `linkHit(at:)` and use `TerminalLinkDetector`:

```swift
  private func linkHit(at point: NSPoint) -> TerminalLinkHit? {
    guard let geometry = renderedGeometry(),
      let coordinate = geometry.coordinate(at: point)
    else {
      return nil
    }
    return TerminalLinkDetector.hitTest(row: coordinate.row, col: coordinate.col, in: geometry.frame)
  }
```

Update `updateLinkHover(at:)` to use `linkHit(at:)`:

```swift
  private func updateLinkHover(at point: NSPoint) {
    updateLinkHover(isHovering: linkHit(at: point) != nil)
  }
```

- [ ] **Step 7: Update cursor rects to include path targets**

In `PTYGridView.urlHitsByRow(in:)`, replace the body with:

```swift
  private static func urlHitsByRow(in frame: GhosttyTerminalFrame) -> [Int: [TerminalLinkHit]] {
    (0..<frame.rows).reduce(into: [:]) { result, row in
      let hits = TerminalLinkDetector.hits(inRow: row, frame: frame)
      if !hits.isEmpty {
        result[row] = hits
      }
    }
  }
```

Then update helper type signatures in `urlCursorRects` from `[Int: [TerminalURLHit]]` to `[Int: [TerminalLinkHit]]`.

- [ ] **Step 8: Run surface tests and verify they pass**

Run:

```bash
swift test --filter "ptyGridCommandClickOpensFilePathTarget|ptyGridPlainClickOnFilePathDoesNotOpenTarget|ptyGridCommandClickOpensVisibleURL|ptyGridCommandClickOpensOSC8HyperlinkMetadata"
```

Expected: PASS.

- [ ] **Step 9: Commit grid routing work**

Run:

```bash
git add Sources/ProGhosttyCore/TerminalCore/TerminalModels.swift Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift Sources/ProGhosttyCore/TerminalCore/LibGhostty/LibGhosttyTerminalEngine.swift Sources/ProGhosttyCore/TerminalCore/Mock/MockTerminalEngine.swift Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift
git commit -m "Route command-click link targets from grid"
```

---

### Task 4: Reveal File Targets In Finder From AppModel

**Files:**
- Modify: `Sources/ProGhosttyApp/UI/AppModel.swift`
- Modify: `Sources/ProGhosttyApp/UI/AppText.swift`

- [ ] **Step 1: Add app text strings**

In `Sources/ProGhosttyApp/UI/AppText.swift`, add these properties near `openLinkHintToast`:

```swift
  var pathNotFoundToast: String { text("Path not found", "路径不存在") }
  var relativePathMissingCwdToast: String { text("No working directory for relative path", "没有用于解析相对路径的工作目录") }
  var revealPathFailedToast: String { text("Could not reveal path", "无法在访达中定位路径") }
```

- [ ] **Step 2: Register link target handler**

In `Sources/ProGhosttyApp/UI/AppModel.swift`, inside `init()` after `surfaceRegistry.setLinkHoverHandler`, add:

```swift
    surfaceRegistry.setLinkTargetHandler { [weak self] sourceSession, target in
      self?.openTerminalLinkTarget(target, from: sourceSession)
    }
```

- [ ] **Step 3: Add target opening methods**

In `Sources/ProGhosttyApp/UI/AppModel.swift`, add these methods near `routeTerminalPaste`:

```swift
  private func openTerminalLinkTarget(_ target: TerminalLinkTarget, from sourceSession: TerminalSessionID) {
    switch target {
    case .url(let url):
      _ = NSWorkspace.shared.open(url)
    case .filePath(let filePath):
      revealTerminalFilePath(filePath, from: sourceSession)
    }
  }

  private func revealTerminalFilePath(_ target: TerminalFilePathTarget, from sourceSession: TerminalSessionID) {
    let cwd = sessionManager.workingDirectory(for: sourceSession)
      ?? workspaceRuntimes.first { runtime in
        PaneTreeReducer.listLeaves(in: runtime.layout.root).contains { $0.sessionId == sourceSession }
      }?.cwdBySession[sourceSession]

    do {
      let url = try TerminalFilePathResolver.resolve(target, cwd: cwd)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } catch TerminalFilePathResolver.Error.missingWorkingDirectory {
      showTitlebarToast(appText.relativePathMissingCwdToast, style: .info, lifetime: .transient(1.8))
      DebugLog.write("revealTerminalFilePath missing cwd path=\(target.rawPath)")
    } catch TerminalFilePathResolver.Error.pathNotFound {
      showTitlebarToast(appText.pathNotFoundToast, style: .info, lifetime: .transient(1.8))
      DebugLog.write("revealTerminalFilePath not found path=\(target.rawPath) cwd=\(cwd ?? "-")")
    } catch {
      showTitlebarToast(appText.revealPathFailedToast, style: .error, lifetime: .transient(2.2))
      DebugLog.write("revealTerminalFilePath failed path=\(target.rawPath) error=\(error)")
    }
  }
```

- [ ] **Step 4: Build and verify app routing compiles**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 5: Commit app routing work**

Run:

```bash
git add Sources/ProGhosttyApp/UI/AppModel.swift Sources/ProGhosttyApp/UI/AppText.swift
git commit -m "Reveal command-click file paths in Finder"
```

---

### Task 5: Verify End-To-End Behavior

**Files:**
- Verify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalLinkDetector.swift`
- Verify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalFilePathResolver.swift`
- Verify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Verify: `Sources/ProGhosttyApp/UI/AppModel.swift`

- [ ] **Step 1: Run focused detector and resolver tests**

Run:

```bash
swift test --filter "TerminalLinkDetectorTests|TerminalFilePathResolverTests"
```

Expected: PASS.

- [ ] **Step 2: Run focused surface interaction tests**

Run:

```bash
swift test --filter "ptyGridCommandClickOpensFilePathTarget|ptyGridPlainClickOnFilePathDoesNotOpenTarget|ptyGridCommandClickOpensVisibleURL|ptyGridCommandClickOpensOSC8HyperlinkMetadata"
```

Expected: PASS.

- [ ] **Step 3: Run full test suite**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 4: Build app executable**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 5: Manual verification**

Run:

```bash
swift run ProGhostty
```

Manual checks:

- Print a valid absolute file path and Cmd+click it. Finder should select the file.
- Print a valid directory path and Cmd+click it. Finder should select the directory itself.
- Print `~/...` for an existing path and Cmd+click it. Finder should select the expanded target.
- `cd` into a project directory, print `Sources/SomeFile.swift`, and Cmd+click it. Finder should select the cwd-relative target.
- Print `Sources/SomeFile.swift:42:3` and Cmd+click it. Finder should select the file, not treat line/column as part of the path.
- Print a missing path and Cmd+click it. ProGhostty should show a short titlebar hint and not open Finder to a parent directory.
- Cmd+click `https://example.com`. Browser opening should still work.

- [ ] **Step 6: Commit verification fixes if needed**

If verification required small fixes, commit only those files:

```bash
git add Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalLinkDetector.swift Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalFilePathResolver.swift Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift Sources/ProGhosttyApp/UI/AppModel.swift Sources/ProGhosttyApp/UI/AppText.swift Tests/ProGhosttyCoreTests/TerminalLinkDetectorTests.swift Tests/ProGhosttyCoreTests/TerminalFilePathResolverTests.swift Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift
git commit -m "Verify command-click file path reveal"
```
