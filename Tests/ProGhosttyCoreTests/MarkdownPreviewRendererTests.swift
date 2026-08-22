import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Markdown preview renderer (GitHub HTML)")
struct MarkdownPreviewRendererTests {
  private let renderer = MarkdownPreviewRenderer()

  private func bodyHTML(_ markdown: String) -> String {
    renderer.bodyHTML(for: markdown)
  }

  @Test func headingEmitsH1() {
    let out = bodyHTML("# Title\n\nSome **bold** body.")
    #expect(out.contains(#"<h1 id="title">Title</h1>"#))
    #expect(out.contains("Some <strong>bold</strong> body."))
  }

  @Test func tableEmitsHtmlTable() {
    // GFM table → real <table> grid, like GitHub.
    let out = bodyHTML("| Name | Type |\n| --- | --- |\n| rows | int |")
    #expect(out.contains("<table>"))
    #expect(out.contains("<th>"))
    #expect(out.contains("<td>"))
    #expect(out.contains("rows"))
  }

  @Test func linkEmitsAnchorWithHref() {
    let out = bodyHTML("[docs](https://example.com)")
    #expect(out.contains(#"<a href="https://example.com">docs</a>"#))
  }

  @Test func inlineCodeEmitsCodeTag() {
    let out = bodyHTML("Run `swift build` now.")
    #expect(out.contains("<code>swift build</code>"))
  }

  @Test func codeBlockCarriesLanguageClass() {
    // highlight.js keys off `language-*` classes.
    let out = bodyHTML("```swift\nlet x = 1\n```")
    #expect(out.contains(#"<pre><code class="language-swift">"#))
    #expect(out.contains("let x = 1"))
    #expect(out.contains("</code></pre>"))
  }

  @Test func codeBlockEscapesAngleBrackets() {
    // HTMLFormatter emits code raw; < > in code must be escaped or the page breaks.
    let out = bodyHTML("```\nif a < b && b > 0\n```")
    #expect(out.contains("&lt;"))
    #expect(out.contains("&gt;"))
    #expect(out.contains("&amp;&amp;"))
  }

  @Test func headingsGetGithubSlugIDs() {
    // HTMLFormatter emits headings without ids; we inject a GitHub-style slug so
    // `[docs](#build-from-source)` anchor links have something to scroll to.
    let out = bodyHTML("# Build From Source\n\n## Install (quick)\n\nBody.")
    #expect(out.contains(#"<h1 id="build-from-source">Build From Source</h1>"#))
    #expect(out.contains(#"<h2 id="install-quick">Install (quick)</h2>"#))
  }

  @Test func headingSlugMatchesGithubRules() {
    #expect(MarkdownPreviewRenderer.headingSlug("Build From Source") == "build-from-source")
    #expect(MarkdownPreviewRenderer.headingSlug("Hello, World!") == "hello-world")
    #expect(MarkdownPreviewRenderer.headingSlug("Foo (bar)") == "foo-bar")
    #expect(MarkdownPreviewRenderer.headingSlug("Foo(bar)") == "foobar")
    #expect(MarkdownPreviewRenderer.headingSlug("A--B") == "a-b")
    #expect(MarkdownPreviewRenderer.headingSlug("安装") == "安装")
  }

  @Test func emptyMarkdownRendersEmptyBody() {
    #expect(bodyHTML("").isEmpty)
  }

  // MARK: - Local image inlining

  private func withTempImageDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("proghostty-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
  }

  @Test func relativeImageIsInlinedAsDataURL() throws {
    try withTempImageDir { dir in
      let png = try #require(Data(base64Encoded: "iVBORw0KGgo=")) // tiny fake PNG header
      try png.write(to: dir.appendingPathComponent("logo.png"))
      let html = renderer.htmlDocument(
        for: "![logo](logo.png)",
        css: "", highlightCSS: "", highlightJS: "",
        baseDirectory: dir
      )
      let expected = "data:image/png;base64,iVBORw0KGgo="
      #expect(html.contains(#"<img src="\#(expected)""#))
      #expect(!html.contains(#"src="logo.png""#))
    }
  }

  @Test func subdirectoryImageIsResolvedAgainstBaseDirectory() throws {
    try withTempImageDir { dir in
      let sub = dir.appendingPathComponent("img")
      try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
      try Data("svg-data".utf8).write(to: sub.appendingPathComponent("logo.svg"))
      let html = renderer.htmlDocument(
        for: "![logo](img/logo.svg)",
        css: "", highlightCSS: "", highlightJS: "",
        baseDirectory: dir
      )
      #expect(html.contains(#"src="data:image/svg+xml;base64,c3ZnLWRhdGE=""#))
    }
  }

  @Test func remoteUrlIsLeftUntouched() throws {
    try withTempImageDir { dir in
      let html = renderer.htmlDocument(
        for: "![badge](https://img.shields.io/badge/x-y)",
        css: "", highlightCSS: "", highlightJS: "",
        baseDirectory: dir
      )
      #expect(html.contains(#"src="https://img.shields.io/badge/x-y""#))
    }
  }

  @Test func unresolvableRelativeImageKeepsOriginalSrc() throws {
    try withTempImageDir { dir in
      let html = renderer.htmlDocument(
        for: "![missing](nope.png)",
        css: "", highlightCSS: "", highlightJS: "",
        baseDirectory: dir
      )
      #expect(html.contains(#"src="nope.png""#))
      #expect(!html.contains("data:image"))
    }
  }

  @Test func codeBlockSrcTextIsNotInlined() throws {
    // `<img src="…">` as literal text in a code block must stay text.
    try withTempImageDir { dir in
      let html = renderer.htmlDocument(
        for: "```html\n<img src=\"logo.png\">\n```",
        css: "", highlightCSS: "", highlightJS: "",
        baseDirectory: dir
      )
      #expect(html.contains("&lt;img src=\"logo.png\"&gt;"))
      #expect(!html.contains("data:image"))
    }
  }

  @Test func htmlDocumentWrapsWithMarkdownBodyAndInlinedAssets() {
    let html = renderer.htmlDocument(
      for: "# Hi",
      css: "CSS-BODY",
      highlightCSS: "HL-CSS",
      highlightJS: "HL-JS"
    )
    #expect(html.hasPrefix("<!DOCTYPE html>"))
    #expect(html.contains("class=\"markdown-body\""))
    #expect(html.contains("CSS-BODY"))
    #expect(html.contains("HL-JS"))
    #expect(html.contains(#"<h1 id="hi">Hi</h1>"#))
    #expect(html.contains("hljs.highlightAll()"))
  }

  // MARK: - Shell / body split (the app loads the shell once and swaps only body)

  @Test func shellCarriesAssetsButNoBodyOrHighlight() {
    let shell = renderer.shellHTML(css: "CSS-BODY", highlightCSS: "HL-CSS", highlightJS: "HL-JS")
    #expect(shell.contains("CSS-BODY"))
    #expect(shell.contains("HL-CSS"))
    #expect(shell.contains("HL-JS"))
    #expect(shell.contains(#"<div class="markdown-body"></div>"#))
    // Highlighting happens on the injected body, not the shell.
    #expect(!shell.contains("highlightAll"))
  }

  @Test func bodyHTMLWithBaseDirectoryInlinesImagesWithoutDocWrapper() throws {
    try withTempImageDir { dir in
      let png = try #require(Data(base64Encoded: "iVBORw0KGgo="))
      try png.write(to: dir.appendingPathComponent("logo.png"))
      let body = renderer.bodyHTML(for: "![logo](logo.png)", baseDirectory: dir)
      #expect(body.contains("data:image/png;base64,iVBORw0KGgo="))
      #expect(!body.contains("<!DOCTYPE"))
      #expect(!body.contains("<html"))
    }
  }

  @Test func inlinedImagesAreLazyLoaded() throws {
    try withTempImageDir { dir in
      let png = try #require(Data(base64Encoded: "iVBORw0KGgo="))
      try png.write(to: dir.appendingPathComponent("logo.png"))
      let html = renderer.htmlDocument(
        for: "![logo](logo.png)",
        css: "", highlightCSS: "", highlightJS: "",
        baseDirectory: dir
      )
      #expect(html.contains(#"loading="lazy""#))
    }
  }
}
