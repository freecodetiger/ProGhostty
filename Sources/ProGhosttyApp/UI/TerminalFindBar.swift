import AppKit
import ProGhosttyCore
import SwiftUI

/// Compact find bar overlaid at the top of a terminal window. Owns no search
/// logic — it binds the query to `AppModel.updateSearchQuery` (debounced) and
/// delegates navigation to `nextSearchMatch` / `previousSearchMatch`.
struct TerminalFindBar: View {
  @EnvironmentObject private var model: AppModel
  @FocusState private var isFocused: Bool

  private var searchText: Binding<String> {
    Binding(
      get: { model.searchState.query },
      set: { model.updateSearchQuery($0) }
    )
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)

      TextField("Find", text: searchText)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .focused($isFocused)
        .onSubmit { model.nextSearchMatch() }

      Text(matchCountLabel)
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 34, alignment: .trailing)

      Button(action: { model.previousSearchMatch() }) {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.plain)
      .disabled(model.searchState.matches.isEmpty)

      Button(action: { model.nextSearchMatch() }) {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.plain)
      .disabled(model.searchState.matches.isEmpty)

      Button(action: { model.toggleSearchCaseSensitivity() }) {
        Text("Aa")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(model.searchState.caseSensitive ? Color(nsColor: model.terminalPalette.accent) : Color.secondary)
      }
      .buttonStyle(.plain)
      .help("Match case")

      Button(action: { model.closeFindBar() }) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 14))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(width: 320)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(model.usesDarkAppearance ? 0.30 : 0.12), radius: 12, x: 0, y: 8)
    .onAppear { isFocused = true }
  }

  private var matchCountLabel: String {
    if model.searchState.matches.isEmpty {
      return model.searchState.query.isEmpty ? "" : "0"
    }
    guard let current = model.searchState.currentIndex else {
      return "\(model.searchState.matches.count)"
    }
    let suffix = model.searchState.truncated ? "+" : ""
    return "\(current + 1)/\(model.searchState.matches.count)\(suffix)"
  }
}
