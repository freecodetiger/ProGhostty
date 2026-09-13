import AppKit
import Testing
import os
@testable import ProGhosttyCore

@MainActor
struct WindowFocusScrollTests {
  @Test func onlyFocusedPaneWritesProtocolReportsWhenEnabled() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
    let window = NSWindow(contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = root
    let reports = OSAllocatedUnfairLock(initialState: [Data]())
    var userInputCount = 0
    registry.setInputHandler { _, _ in userInputCount += 1 }
    var bridges: [GhosttyVTBridge] = []
    var sessions: [TerminalSessionID] = []
    for index in 0..<2 {
      let id = TerminalSessionID()
      sessions.append(id)
      registry.createSurface(session: id)
      let surface = try #require(registry.viewForSession(id))
      surface.frame = NSRect(x: index * 400, y: 0, width: 400, height: 300)
      root.addSubview(surface)
      let bridge = try GhosttyVTBridge(cols: 40, rows: 10)
      bridge.writePtyHandler = { data in reports.withLock { $0.append(data) } }
      bridge.write(Data("\u{1B}[?1004h".utf8))
      bridges.append(bridge)
      registry.render(bridge, session: id)
    }
    registry.setFocusedSession(sessions[1])
    registry.flushPendingRenderers()
    reports.withLock { $0.removeAll() }
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    #expect(reports.withLock { $0 } == [Data("\u{1B}[O".utf8), Data("\u{1B}[I".utf8)])
    #expect(userInputCount == 0)
    bridges[1].write(Data("\u{1B}[?1004l".utf8))
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    #expect(reports.withLock { $0.count } == 2)
  }

  @Test func windowFocusReportsPreserveHistory() async throws {
    let registry = PTYTerminalSurfaceRegistry()
    let manager = PTYTerminalSessionManager(surfaceRegistry: registry)
    registry.setInputHandler { id, data in manager.writeInput(data, to: id) }
    let session = try manager.createSession(config: TerminalSessionConfig(
      shellPath: "/bin/sh", workingDirectory: "/tmp", environment: ["PS1": ""], rows: 10, cols: 60))
    defer { manager.closeSession(session) }
    let surface = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = surface
    registry.setFocusedSession(session)
    let grid = surface.liveGridView
    manager.writeInput(Data("stty -echo; seq 1 100; printf '\\033[?1004h'\n".utf8), to: session)
    for _ in 0..<150 {
      if grid.focusReportingActiveHandler?() == true,
         (grid.browseScrollMetricsHandler?()?.total ?? 0) >= 100 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(grid.focusReportingActiveHandler?() == true)
    grid.testBeginSmoothScroll(delta: 200, time: 0)
    var time = 0.0
    for _ in 0..<10 {
      time += 1.0 / 120
      grid.testTickSmoothScroll(now: time)
    }
    grid.testEndSmoothScroll(time: time)
    for _ in 0..<3000 {
      guard grid.testIsSmoothScrollBrowsing else { break }
      time += 1.0 / 120
      grid.testTickSmoothScrollWithStop(now: time)
    }
    let top = try #require(grid.browseTopAbsoluteRow)
    let visibleText = grid.renderedText
    for notification in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
      NotificationCenter.default.post(name: notification, object: window)
      #expect(grid.browseTopAbsoluteRow == top)
      try await Task.sleep(for: .milliseconds(50))
      #expect(grid.browseTopAbsoluteRow == top)
      #expect(grid.renderedText == visibleText)
    }
    // Actual typing must still return to the live prompt.
    manager.writeInput(Data("x".utf8), to: session)
    #expect(grid.browseTopAbsoluteRow == nil)
  }
}
