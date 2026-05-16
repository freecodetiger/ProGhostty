# Ghostty HTML Compatibility Layer

## Positioning

ProGhostty does not use the HTML path as a general-purpose browser renderer and it does not parse ANSI or PTY bytes in the UI layer.

The intended boundary is:

```text
PTY bytes -> libghostty-vt terminal state -> Ghostty HTML formatter -> GhosttyHTMLAttributedAdapter -> NSTextView
```

`libghostty-vt` remains responsible for terminal semantics: VT parsing, SGR state, palette state, scrollback, cursor state, and shell/plugin ecosystem output. The compatibility layer only adapts the restricted HTML/CSS subset emitted by Ghostty's formatter into AppKit attributed text.

## Why This Exists

`NSTextView` gives ProGhostty native macOS text behavior: pixel-level scrolling, selection, copy/paste, text services, and accessibility behavior. Ghostty's HTML formatter gives a practical bridge from terminal state to a document-like text model.

The tradeoff is that `NSAttributedString`'s HTML importer is not reliable enough for terminal styling. It does not consistently preserve CSS variables or opacity, and it is more general than ProGhostty needs. A small explicit adapter is easier to test and keeps the terminal boundary clear.

## Implemented Compatibility

`GhosttyHTMLAttributedAdapter` currently supports the Ghostty formatter subset that matters most for terminal readability:

- palette CSS variables: `var(--vt-palette-N)` is resolved from Ghostty's emitted `:root` palette block into concrete `rgb(r, g, b)` values.
- foreground colors: `color: rgb(...)` and `color: #RRGGBB`.
- background colors: `background-color: rgb(...)` and `background-color: #RRGGBB`.
- faint text: `opacity: 0.5` is blended toward the terminal background.
- bold text: `font-weight: bold`.
- italic text: `font-style: italic`.
- underline and strikethrough: `text-decoration-line: underline line-through`.
- rich underline styles: `text-decoration-style` is recognized and currently degrades unsupported variants to readable single underline.
- inverse video: `filter: invert(100%)` swaps foreground and background.
- invisible text: `visibility: hidden` renders foreground as background.
- hyperlinks: `<a href="...">` is mapped into AppKit `.link` attributes.
- HTML entities used by Ghostty output, including named entities and decimal/hex numeric entities.
- copy preserves the selected document text exactly, including hard line breaks, trailing spaces, wide characters, and composed characters.
- wide and composed characters are preserved as text; grid width remains a libghostty concern.
- inactive pane dimming by blending foreground toward the terminal background without changing pane backgrounds.
- a last-input cache avoids reparsing identical HTML snapshots with the same focus state.

## Red Lines

The adapter must not become a second terminal emulator.

It must not:

- interpret ANSI, OSC, CSI, or PTY bytes.
- infer terminal state that `libghostty-vt` has not already formatted.
- implement shell integration or autosuggestion behavior.
- parse arbitrary web HTML/CSS beyond Ghostty formatter output.
- own scrollback semantics.

If a needed behavior requires terminal semantics rather than formatted style adaptation, the implementation should move toward `libghostty-vt` cell/style APIs instead of expanding string heuristics.

## Worth Doing Next

These are the most valuable compatible additions that stay inside the boundary:

1. Grid-aware selection and copy semantics

   Current copy preserves document selection text exactly. Remaining work is terminal-grid-aware behavior for soft wraps, rectangular selection, and copied newline policy. That should be based on libghostty cell/grid information, not HTML string inference.

2. Deeper wide-character interaction tests

   The adapter preserves CJK, emoji, and combining marks as text. The remaining work is interaction-level regression coverage for selection, cursor hit-testing, copy, and pane resize behavior around those characters.

3. Performance containment

   Avoid growing the compatibility layer into a full renderer. A last-input cache exists; the next performance steps should be snapshot diffing, attributed run reuse across changed ranges, and bounded scrollback memory.

## Testing Contract

The compatibility layer is covered by `GhosttyHTMLAttributedAdapterTests`. Terminal integration behavior is covered by `TerminalSurfaceTests`.

When adding support for a new Ghostty HTML feature, add a focused adapter test first, then add a terminal surface test only if the feature affects live pane behavior.
