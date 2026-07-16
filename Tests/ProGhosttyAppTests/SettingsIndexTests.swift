import Foundation
import Testing

@testable import ProGhosttyApp

@Suite("Settings index")
struct SettingsIndexTests {
  private let text = AppText(language: "en")

  @Test func emptyQueryReturnsNothing() {
    #expect(SettingsIndex.results(query: "", text: text).isEmpty)
    #expect(SettingsIndex.results(query: "   ", text: text).isEmpty)
  }

  @Test func matchesTitleCaseInsensitively() {
    let ids = SettingsIndex.results(query: "FONT", text: text).map(\.id)
    #expect(ids.contains("font.family"))
  }

  @Test func matchesKeywordAlias() {
    // "size" is a keyword of font.size; "cwd" a keyword of terminal.cwd.
    #expect(SettingsIndex.results(query: "size", text: text).map(\.id).contains("font.size"))
    #expect(SettingsIndex.results(query: "cwd", text: text).map(\.id).contains("terminal.cwd"))
  }

  @Test func matchesChineseKeywordRegardlessOfLanguage() {
    // English AppText, but Chinese keyword aliases still match.
    let ids = SettingsIndex.results(query: "通知", text: text).map(\.id)
    #expect(ids.contains("notifications.enable"))
  }

  @Test func shortcutsAreIndexed() {
    let results = SettingsIndex.results(query: "shortcut", text: text)
    #expect(results.allSatisfy { $0.category == .shortcuts })
    #expect(!results.isEmpty)
  }

  @Test func unknownQueryReturnsNothing() {
    #expect(SettingsIndex.results(query: "zzzznomatch", text: text).isEmpty)
  }

  @Test func everyItemHasStableUniqueID() {
    let ids = SettingsIndex.all.map(\.id)
    #expect(Set(ids).count == ids.count)
  }
}
