import AppKit
import Testing

@testable import ProGhosttyApp

@MainActor
private final class FakeWindowDelegate: NSObject, NSWindowDelegate {
  var shouldCloseAnswer = true
  var shouldCloseAsked = false
  var didResizeCalled = false

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    shouldCloseAsked = true
    return shouldCloseAnswer
  }

  func windowDidResize(_ notification: Notification) {
    didResizeCalled = true
  }
}

@MainActor
@Suite("Window delegate proxy")
struct WindowDelegateProxyTests {
  @Test func guardDenialBlocksCloseWithoutAskingBase() {
    let base = FakeWindowDelegate()
    let proxy = WindowDelegateProxy(base: base, shouldClose: { _ in false })
    let window = NSWindow()
    #expect(proxy.windowShouldClose(window) == false)
    #expect(!base.shouldCloseAsked)
  }

  @Test func guardApprovalConsultsBase() {
    let base = FakeWindowDelegate()
    base.shouldCloseAnswer = false
    let proxy = WindowDelegateProxy(base: base, shouldClose: { _ in true })
    let window = NSWindow()
    #expect(proxy.windowShouldClose(window) == false)
    #expect(base.shouldCloseAsked)

    base.shouldCloseAnswer = true
    base.shouldCloseAsked = false
    #expect(proxy.windowShouldClose(window) == true)
    #expect(base.shouldCloseAsked)
  }

  @Test func guardApprovalWithoutBaseAllowsClose() {
    let proxy = WindowDelegateProxy(base: nil, shouldClose: { _ in true })
    #expect(proxy.windowShouldClose(NSWindow()) == true)
  }

  @Test func unrelatedDelegateMethodsForwardToBase() {
    let base = FakeWindowDelegate()
    let proxy = WindowDelegateProxy(base: base, shouldClose: { _ in true })
    #expect(proxy.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
    (proxy as NSWindowDelegate).windowDidResize?(
      Notification(name: NSWindow.didResizeNotification, object: NSWindow())
    )
    #expect(base.didResizeCalled)
  }

  @Test func proxyDoesNotClaimSelectorsNobodyImplements() {
    let proxy = WindowDelegateProxy(base: nil, shouldClose: { _ in true })
    #expect(!proxy.responds(to: #selector(NSWindowDelegate.windowDidMiniaturize(_:))))
  }
}
