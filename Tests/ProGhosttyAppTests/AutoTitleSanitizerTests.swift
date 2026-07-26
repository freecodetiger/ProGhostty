import Foundation
import Testing

@testable import ProGhosttyApp

@Suite("Auto title sanitizer")
struct AutoTitleSanitizerTests {
  @Test func passesOrdinaryTitlesThrough() {
    #expect(AutoTitleSanitizer.sanitize("vim Package.swift") == "vim Package.swift")
    #expect(AutoTitleSanitizer.sanitize("✳ 修复滚动 bug…") == "✳ 修复滚动 bug…")
  }

  @Test func trimsSurroundingWhitespace() {
    #expect(AutoTitleSanitizer.sanitize("  hello \n") == "hello")
  }

  @Test func emptyOrInvisibleTitlesMeanClear() {
    #expect(AutoTitleSanitizer.sanitize("") == nil)
    #expect(AutoTitleSanitizer.sanitize("   ") == nil)
    #expect(AutoTitleSanitizer.sanitize("\u{07}\u{1B}\u{00}") == nil)
  }

  @Test func stripsControlCharactersInsideTitles() {
    #expect(AutoTitleSanitizer.sanitize("he\u{1B}[31mllo") == "he[31mllo")
    #expect(AutoTitleSanitizer.sanitize("a\u{9B}b\u{7F}c") == "abc")
  }

  @Test func middleTruncatesOverlongTitles() {
    let long = String(repeating: "a", count: 300) + String(repeating: "b", count: 300)
    let sanitized = AutoTitleSanitizer.sanitize(long)
    #expect(sanitized?.count == AutoTitleSanitizer.maxLength)
    #expect(sanitized?.hasPrefix("aaa") == true)
    #expect(sanitized?.hasSuffix("bbb") == true)
    #expect(sanitized?.contains("…") == true)
  }

  @Test func keepsWideCharactersIntactWhenTruncating() {
    let long = String(repeating: "汉", count: 400)
    let sanitized = AutoTitleSanitizer.sanitize(long)
    #expect(sanitized?.count == AutoTitleSanitizer.maxLength)
    #expect(sanitized?.hasPrefix("汉汉") == true)
    #expect(sanitized?.hasSuffix("汉汉") == true)
  }
}
