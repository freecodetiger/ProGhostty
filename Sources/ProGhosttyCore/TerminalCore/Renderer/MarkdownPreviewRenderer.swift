import Foundation
import Markdown
import UniformTypeIdentifiers

/// Converts markdown into a GitHub-README-style HTML document. Uses swift-markdown's
/// `HTMLFormatter` (the CommonMark/GFM parser family GitHub itself uses) for the
/// body, then wraps it with the real `github-markdown-css` stylesheet and
/// highlight.js — the same rendering stack GitHub READMEs use, displayed in a
/// no-focus WKWebView (spec: 2026-08-18-markdown-preview-float).
///
/// Pure Foundation work — no AppKit/WebKit, so ProGhosttyCore stays UI-free.
public final class MarkdownPreviewRenderer {
  public init() {}

  /// The `<div class="markdown-body">` inner HTML for a markdown string. With a
  /// `baseDirectory`, local relative images are inlined as base64 data URLs; the
  /// float's live-render path uses this form and injects it into the shared
  /// shell. Without one the body is left raw (the renderer tests use this form).
  public func bodyHTML(for markdown: String, baseDirectory: URL? = nil) -> String {
    let body = addHeadingIDs(escapeCodeBlocks(HTMLFormatter.format(markdown)))
    guard let baseDirectory else { return body }
    return inlineImages(in: body, baseDirectory: baseDirectory)
  }

  /// Static document shell: github-markdown-css + highlight.js + an empty
  /// `.markdown-body`. Loaded ONCE into the preview webView; every render after
  /// that swaps only the `.markdown-body` innerHTML via JS, so the identical
  /// ~140KB of CSS/JS is never re-parsed per document — the dominant cost of the
  /// old full-document `loadHTMLString` on every open and file save.
  public func shellHTML(css: String, highlightCSS: String, highlightJS: String) -> String {
    """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>\(css)</style>
    <style>\(highlightCSS)</style>
    <style>html,body{background:#ffffff}</style>
    <script>\(highlightJS)</script>
    </head>
    <body>
    <div class="markdown-body"></div>
    </body>
    </html>
    """
  }

  /// The complete HTML document with github-markdown-css + highlight.js inlined,
  /// so the WKWebView needs no external file access. Local relative images are
  /// inlined as base64 data URLs against `baseDirectory` (the markdown file's
  /// directory) — WebKit refuses file:// subresources from a `loadHTMLString`
  /// page even with `allowFileAccessFromFileURLs`, so the document is made
  /// fully self-contained instead. Remote (http/https) and `data:` URLs are
  /// left as-is. (Kept for the renderer tests; the app renders via `shellHTML` +
  /// `bodyHTML` and swaps only the body.)
  public func htmlDocument(
    for markdown: String,
    css: String,
    highlightCSS: String,
    highlightJS: String,
    baseDirectory: URL? = nil
  ) -> String {
    let body = bodyHTML(for: markdown, baseDirectory: baseDirectory)
    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>\(css)</style>
    <style>\(highlightCSS)</style>
    <style>html,body{background:#ffffff}</style>
    <script>\(highlightJS)</script>
    </head>
    <body>
    <div class="markdown-body">
    \(body)
    </div>
    <script>if (window.hljs) hljs.highlightAll();</script>
    </body>
    </html>
    """
  }

  /// GitHub-style heading slug (`# Build From Source` → `build-from-source`),
  /// kept CJK-safe: non-ASCII letters/numbers are preserved so Chinese headings
  /// get usable ids (`## 安装` → `安装`). Matches the `#anchor` fragments links
  /// in the markdown reference.
  public static func headingSlug(_ heading: String) -> String {
    let lowered = heading.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // Whitespace runs become dashes; punctuation is dropped (GitHub keeps the
    // dash a space left behind); `-`/`_` survive; CJK survives.
    var slug = ""
    var pendingDash = false // a separator (whitespace / hyphen / punctuation gap) is queued
    var lastWasDash = false // collapse consecutive dashes
    for scalar in lowered.unicodeScalars {
      let ch = Character(scalar)
      if ch.isLetter || ch.isNumber || ch == "_" {
        if pendingDash && !lastWasDash { slug.append("-") }
        slug.append(ch)
        pendingDash = false
        lastWasDash = false
      } else if ch == "-" || ch.isWhitespace {
        pendingDash = true
      }
      // Other punctuation: GitHub drops it and joins the surrounding words.
    }
    if pendingDash && !lastWasDash { slug.append("-") }
    return slug
  }

  /// HTMLFormatter's headings carry no `id`, so `[docs](#anchor)` links have
  /// nothing to scroll to. Inject a GitHub-style slug id on each `<hN>`.
  private func addHeadingIDs(_ html: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"<h([1-6])>(.*?)</h\1>"#) else {
      return html
    }
    let ns = html as NSString
    var result = ""
    var last = 0
    for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
      result.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
      let level = ns.substring(with: match.range(at: 1))
      let text = ns.substring(with: match.range(at: 2))
      result.append("<h\(level) id=\"\(Self.headingSlug(text))\">\(text)</h\(level)>")
      last = match.range.location + match.range.length
    }
    result.append(ns.substring(from: last))
    return result
  }

  /// Replaces each `<img src="relative">` in the body with a base64 `data:` URL
  /// resolved against `baseDirectory`, so local images render without any WebKit
  /// file access. Only `<img>` tags are touched (code blocks stay escaped and
  /// their literal `src="…"` text is left alone); unresolvable paths and remote
  /// URLs keep their original `src`.
  private func inlineImages(in html: String, baseDirectory: URL) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"<img[^>]*\bsrc="([^"]*)""#) else {
      return html
    }
    let ns = html as NSString
    var result = ""
    var last = 0
    for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
      result.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
      let srcRange = match.range(at: 1)
      let src = ns.substring(with: srcRange)
      // Text between the tag start and the src value is `<img … src="` — keep it.
      result.append(ns.substring(with: NSRange(location: match.range.location, length: srcRange.location - match.range.location)))
      result.append(inlineDataSrc(for: src, baseDirectory: baseDirectory) ?? src)
      // Defer decode of images below the fold: the page's load event no longer
      // waits for every base64 image to decode, so a large README paints its top
      // while the rest load lazily. The char after the src value is its closing
      // quote; emit it + the lazy attribute and skip the quote.
      result.append(#"" loading="lazy""#)
      last = srcRange.location + srcRange.length + 1
    }
    result.append(ns.substring(from: last))
    return result
  }

  private func inlineDataSrc(for src: String, baseDirectory: URL) -> String? {
    let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    // Remote / data / blob URLs load fine in WebKit — leave them alone.
    if let scheme = URLComponents(string: trimmed)?.scheme?.lowercased() {
      if scheme != "file" { return nil }
    }
    // Strip query/fragment for the filesystem lookup (fragments are anchor
    // points, query strings are cache-busters — neither is part of the path).
    var pathOnly = trimmed
    if let q = pathOnly.firstIndex(of: "?") { pathOnly = String(pathOnly[..<q]) }
    else if let h = pathOnly.firstIndex(of: "#") { pathOnly = String(pathOnly[..<h]) }
    let decoded = pathOnly.removingPercentEncoding ?? pathOnly
    let url: URL
    if decoded.hasPrefix("/") {
      url = URL(fileURLWithPath: decoded).standardizedFileURL
    } else if let fileURL = URL(string: trimmed), fileURL.isFileURL {
      url = fileURL.standardizedFileURL
    } else {
      url = baseDirectory.appendingPathComponent(decoded).standardizedFileURL
    }
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    return "data:\(mime);base64,\(data.base64EncodedString())"
  }

  /// `HTMLFormatter` emits code block content raw (it escapes nothing); escape
  /// `&`, `<`, `>` inside `<pre><code>…</code></pre>` so code like `a < b`
  /// doesn't break the HTML.
  private func escapeCodeBlocks(_ html: String) -> String {
    guard let regex = try? NSRegularExpression(
      pattern: #"<pre><code[^>]*>(.*?)</code></pre>"#,
      options: [.dotMatchesLineSeparators]
    ) else {
      return html
    }
    let ns = html as NSString
    var result = ""
    var last = 0
    for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
      result.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
      let full = ns.substring(with: match.range)
      let codeRange = match.range(at: 1)
      let codeStart = codeRange.location - match.range.location
      let prefix = (full as NSString).substring(with: NSRange(location: 0, length: codeStart))
      let code = (full as NSString).substring(with: NSRange(location: codeStart, length: codeRange.length))
      let suffix = (full as NSString).substring(from: codeStart + codeRange.length)
      result.append(prefix)
      result.append(escapedCode(code))
      result.append(suffix)
      last = match.range.location + match.range.length
    }
    result.append(ns.substring(from: last))
    return result
  }

  private func escapedCode(_ code: String) -> String {
    code.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}
