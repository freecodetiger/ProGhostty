# Command Click File Paths Design

Date: 2026-05-24

## Product Direction

ProGhostty should make command-click useful for both web links and local filesystem paths. Web URLs keep the existing behavior. Local paths should never open the file directly; they should reveal and select the target in Finder.

## Core Requirements

1. Command-click on `http` and `https` links keeps opening the URL normally.
2. Command-click on a local file path reveals and selects that file in Finder.
3. Command-click on a local directory path reveals and selects that directory in Finder.
4. Local paths are not opened in browser, Preview, editor, or their default app.
5. Supported local path text includes absolute paths, `~` paths, `./` paths, `../` paths, and cwd-relative paths.
6. Cwd-relative paths resolve against the clicked pane's current shell working directory.
7. If the clicked pane has no known cwd, relative paths are not opened.
8. Path suffixes like `:42` and `:42:3` are stripped before filesystem resolution.
9. Missing local paths do not open any fallback directory.
10. Missing or unresolvable local paths show a short non-blocking titlebar hint.

## Link Target Model

The current URL-only detector should evolve into a link target detector that can represent either:

```text
web URL target
local path target
```

The hit-test behavior remains cell based: `PTYGridView` asks the detector what target is under the clicked cell. The detector should return the visible text range and a normalized target payload. URL targets preserve the existing normalized URL behavior. Path targets carry the parsed path text and optional source metadata such as stripped line and column numbers.

This keeps terminal input handling separate from opening behavior. The grid view should not decide how to resolve cwd-relative paths or how to open Finder.

## Path Recognition

Supported local path forms:

- absolute paths: `/Users/me/project/README.md`
- home-relative paths: `~/project/README.md`
- dot-relative paths: `./README.md`, `../README.md`
- cwd-relative paths that look file-like: `Sources/App.swift`, `docs/readme.md`

The detector should avoid treating ordinary prose as a path. Cwd-relative paths should require path-like evidence such as a slash and a file-looking segment or extension. The existing URL behavior has priority over visible path detection, and OSC 8 hyperlink metadata keeps priority over visible text in overlapping ranges.

Trailing sentence punctuation should be stripped from paths in the same spirit as URL trimming. Line and column suffixes should be stripped only when numeric:

```text
Sources/App.swift:42      -> Sources/App.swift
/tmp/file.md:10:3         -> /tmp/file.md
```

## Cwd Resolution

Absolute and `~` paths can resolve without pane cwd. Relative paths require the clicked pane's current shell cwd. The app already tracks cwd by session, so the link-opening path should pass the clicked session ID along with the target.

Resolution order:

1. absolute path: use as-is
2. `~` path: expand using the current user's home directory
3. relative path: resolve against the clicked session's current cwd

If cwd is unavailable for a relative target, ProGhostty should not open anything and should show a short hint.

## Opening Behavior

Web URL target:

- call the existing URL-opening behavior

Local path target:

- resolve to a file URL
- check that the file or directory exists
- call Finder reveal/select behavior, equivalent to `NSWorkspace.shared.activateFileViewerSelecting([url])`

This applies to both files and directories. A directory click selects the directory in its parent Finder window; it does not navigate into the directory as the primary action.

## UI Feedback

Keep feedback minimal:

- valid URL: current behavior
- valid local path: Finder reveals/selects the item
- missing path: short titlebar hint such as `Path not found`
- relative path without cwd: short titlebar hint such as `No working directory for relative path`

No modal alerts and no terminal text should be written.

## Data Flow

```text
Command-click in PTYGridView
  -> hit-test terminal cells
  -> detector returns web URL or local path target
  -> grid view calls link target handler with clicked session context
  -> AppModel resolves cwd when needed
  -> URL target opens normally
  -> existing local path opens in Finder selection
  -> missing/unresolvable path shows titlebar hint
```

## Error Handling

Unsupported or ambiguous text should not produce a target. Existing text selection behavior should continue when command is not held or when no link target is under the click.

For local targets, failures should be non-blocking:

- no cwd for relative path: show hint
- expanded path does not exist: show hint
- Finder reveal call fails or cannot be performed: show hint and log debug detail

## Testing

Detector tests should cover:

- existing URL behavior remains unchanged
- absolute paths are detected
- `~` paths are detected
- `./` and `../` paths are detected
- cwd-relative file-looking paths are detected
- line and column suffixes are stripped
- URL hits remain preferred over visible path parsing when ranges overlap

Opening/resolution tests should cover:

- absolute path resolves without cwd
- `~` expands to the user's home directory
- relative path resolves against session cwd
- relative path without cwd is rejected
- missing paths are rejected instead of opening parent directories

Grid behavior tests should cover:

- command-click on a path calls the link target handler
- plain click on a path does not open anything
- command-click on URL still opens URL

Manual verification should cover:

- command-click real files, folders, markdown, HTML, and PDF paths
- Finder selects the item instead of opening it
- relative paths work from the pane's cwd
- missing paths show only a short hint

## Out Of Scope

This feature does not open files in editors, jump to line numbers, preview PDFs or markdown, change shell cwd, or create files. It also does not add user preferences for path-opening behavior.
