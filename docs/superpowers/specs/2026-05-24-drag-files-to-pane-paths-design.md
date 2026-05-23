# Drag Files To Pane Paths Design

Date: 2026-05-24

## Product Direction

ProGhostty should support dragging local files or folders from Finder into a terminal pane and inserting their absolute paths into that pane. The behavior should feel like a terminal paste targeted at the pane under the mouse, without executing anything automatically.

## Core Requirements

1. Dragging one or more Finder files or folders over a terminal pane marks that pane as the drop target.
2. The drop target is the pane under the mouse, not the currently keyboard-focused pane.
3. While dragging over a valid pane, the pane shows a light hover affordance.
4. Dropping inserts the local absolute paths into the target pane.
5. Dropping also selects and focuses the target pane so subsequent typing continues there.
6. Inserted text uses shell-safe single-quoted path arguments.
7. Multiple dropped items are inserted as one space-separated line.
8. The inserted text does not include a trailing newline or carriage return.
9. The write path uses existing terminal paste handling, including bracketed paste encoding when active.
10. Drop completion does not show an extra success message because the inserted text is visible in the terminal.

## Path Formatting

Each dropped local file URL is converted to a standardized absolute filesystem path using the URL path. Each path is formatted as a POSIX shell single-quoted argument:

```text
'/Users/me/My Folder/a.txt'
```

If a path contains a single quote, it is escaped using the standard shell-safe sequence:

```text
'/Users/me/it'\''s file.txt'
```

Multiple paths are joined with a single ASCII space:

```text
'/Users/me/a file.txt' '/Users/me/folder b'
```

No newline is appended.

## Architecture

The drop target should be handled at the pane host layer. `TerminalPaneViewController` already knows the pane identity, owns the host view, and receives callbacks for pane selection and actions. That makes it the right boundary for drag hover state and drop routing.

`TerminalPaneHostView` should register for file URL dragging pasteboard types and expose closures for drag state changes and dropped file URLs. `TerminalPaneViewController` should translate those callbacks into pane actions:

- show or clear the pane hover affordance
- call the existing pane selection callback for the target pane
- call a new paste callback with the target pane ID and formatted text

The app model should resolve the target pane to its terminal session and call the existing `TerminalSessionManager.writePaste` path. This preserves the existing paste encoding behavior and avoids coupling drag-and-drop directly to PTY internals.

## Components

`TerminalPaneHostView`

- registers for local file URL drops
- validates that the pasteboard contains at least one local file URL
- tracks drag enter/update/exit to drive a hover state
- returns copy/link style drag operation for valid drags
- extracts dropped file URLs in pasteboard order

`TerminalPaneViewController`

- owns the hover visual state for its pane
- calls `onSelect(paneId)` before inserting dropped paths
- formats the dropped paths
- calls `onPastePaths(paneId, formattedText)`

`SplitContainerViewController` and `TerminalTreeLayoutView`

- pass the new paste callback through the existing recursive pane controller wiring

`AppModel`

- adds a pane-targeted paste method
- finds the pane's session ID in the active workspace split tree
- selects the pane if needed
- calls `sessionManager.writePaste(text, to: sessionID)`

## Hover Affordance

The drag hover affordance should be restrained: a subtle border or tint on the target pane only. It should not use a central text overlay, system notification, or post-drop toast. The goal is to show which pane will receive the path without covering terminal content.

The affordance must clear when:

- the drag exits the pane
- the drag operation ends
- the pane is rebuilt or reused for another session
- the drop is rejected

## Data Flow

```text
Finder drag
  -> TerminalPaneHostView drag callbacks
  -> TerminalPaneViewController hover state
  -> drop file URLs
  -> TerminalPaneViewController formats shell-safe path text
  -> onSelect(paneId)
  -> onPastePaths(paneId, text)
  -> AppModel resolves paneId to sessionId
  -> TerminalSessionManager.writePaste(text, to: sessionId)
  -> existing paste encoder writes to PTY
```

## Error Handling

Invalid or unsupported drops should be ignored without changing terminal content. Examples include non-file pasteboard data, remote URLs that do not resolve to local file paths, and empty pasteboard results.

If the target pane cannot be resolved to a session, ProGhostty should clear the hover state and log a debug message rather than writing to the selected pane as a fallback. Silent retargeting would be surprising in a split terminal.

If paste encoding fails, the existing paste error path should handle it. The drag feature should not add a separate modal or alert.

## Testing

Core tests should cover the path formatter:

- simple absolute paths
- paths containing spaces
- paths containing single quotes
- multiple paths joined with one space
- no trailing newline

UI-facing tests should cover pane-level drop routing where practical:

- a drop on a pane calls selection for that pane
- a drop on a pane calls the paste callback with formatted text
- drag hover state is applied and cleared
- unsupported pasteboard data does not paste

Manual verification should cover a real Finder drag into a split layout:

- dragging over each pane highlights only that pane
- dropping into an unfocused pane selects it
- inserted paths appear in the pane under the mouse
- dropped folders and files both produce absolute paths
- paths are inserted without executing a command

## Out Of Scope

This feature does not open files, change the terminal working directory, create workspaces, create panes, upload file contents, or append Enter after insertion. It also does not implement custom sorting for multiple items; ProGhostty uses the order provided by the system pasteboard.
