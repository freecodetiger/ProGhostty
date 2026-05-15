# Ghostty-Style Workspace UI Design

Date: 2026-05-15

## Product Direction

ProGhostty should use a Ghostty-like, terminal-first interface. The default window is a pure terminal canvas: no top tab strip, no permanent sidebar, no visible toolbar buttons, and no always-on workspace chrome.

Workspace management remains a first-class capability, but it appears only when the user asks for it through a low-friction native interaction: keyboard shortcut, right-click menu, titlebar workspace label, or menu bar command.

## Core Requirements

1. The app supports multiple workspaces at the same time.
2. Each workspace owns its own split tree, panes, terminal sessions, focus state, and history state.
3. The current window renders only the active workspace split layout.
4. Non-active workspace sessions keep running by default.
5. Switching workspaces detaches inactive workspace views from the visible layout without closing PTY sessions.
6. A Workspace Switcher floating overlay supports search, creation, keyboard navigation, and switching.
7. The titlebar shows the active workspace name as a subtle label.
8. Clicking the titlebar workspace label opens a workspace menu.
9. The default interface has no visible tab bar, no sidebar, and no obvious command buttons.

## Recommended Shortcut Policy

Terminal apps should avoid stealing shortcuts that users expect to reach the shell or terminal ecosystem. In particular, ProGhostty should not use `Cmd+K` for workspace switching because many terminal users associate it with clearing the screen or scrollback.

Default workspace shortcuts:

- Open Workspace Switcher: `Cmd+Shift+O`
- New Workspace: `Cmd+Option+N`
- Next Workspace: `Cmd+Option+Shift+Right`
- Previous Workspace: `Cmd+Option+Shift+Left`
- Manage Workspaces: `Cmd+Option+Shift+O`

Existing pane shortcuts can remain:

- Split Right: `Cmd+D`
- Split Down: `Cmd+Shift+D`
- Close Pane: `Cmd+W`
- Focus Previous Pane: `Cmd+Option+Left`
- Focus Next Pane: `Cmd+Option+Right`

Rationale: `Cmd+Option+Left/Right` stays assigned to pane focus because pane navigation is more frequent than workspace navigation. Workspace previous/next adds `Shift` to avoid that conflict.

All shortcuts should be user-configurable later through Preferences.

## Data Model

The current tab-oriented structure should be replaced or wrapped by a workspace runtime model.

```text
WorkspaceRuntime
- id
- metadata
- root: PaneNode
- outputBySession
- cwdBySession
- lastBlockBySession
- focusedPaneID
- history scope
- lifecycle state
```

`AppModel` should move toward:

```text
workspaces: [WorkspaceRuntime]
activeWorkspaceID
workspaceSwitcherState
```

The active workspace is the only workspace whose split tree is mounted into the visible terminal layout. Inactive workspaces keep their sessions alive and retain their split tree and focus state.

## Session Lifecycle

Switching workspace must not close PTY sessions. The lifecycle rules are:

- Creating a workspace creates an initial terminal session for that workspace.
- Splitting a pane creates exactly one new terminal session inside the active workspace.
- Closing a pane closes only that pane's session.
- Closing a workspace closes all sessions owned by that workspace.
- Switching workspaces does not close or restart sessions.

The surface registry should support detach/attach semantics:

- Active workspace: session surfaces are attached to the recursive split layout.
- Inactive workspaces: session surfaces remain owned by the registry but are not mounted in the current layout.

## Main Window Layout

The main window should render:

```text
TerminalCanvas
  ActiveWorkspaceSplitLayout
  WorkspaceSwitcherOverlay, when open
```

The terminal canvas should not include a top bar. History, plugins, settings, and workspace management should not be reached through visible in-window tabs.

## Titlebar Workspace Label

The titlebar should show a subtle active workspace label. It should behave like a native titlebar control, not like an in-content button.

Behavior:

- Displays active workspace name.
- Clicking opens a workspace menu.
- Menu includes switch workspace, new workspace, manage workspaces, and close workspace.
- Visual weight stays below terminal content.

## Workspace Switcher Overlay

The Workspace Switcher is a transient floating overlay.

Layout:

- Centered in the window.
- Width around 520-640 px.
- Uses native material or a restrained opaque dark surface.
- No decorative gradients, cards, or large buttons.
- Search field at the top.
- List of workspaces below.

Each row shows:

- Workspace name.
- Root path or cwd.
- Running session count.
- Active indicator using a minimal checkmark or subtle tint.

Interactions:

- Type to filter.
- Up/down arrows move selection.
- Enter switches to selected workspace.
- Escape closes switcher.
- `Cmd+Option+N` creates a new workspace.
- If search has no exact match, an inline "Create workspace" action appears as a list row.

## Right-Click Menu

Pane context menu should remain native `NSMenu`.

Items:

- Split Right
- Split Down
- Close Pane
- Switch Workspace...
- New Workspace
- Manage Workspaces...
- Settings...

The menu should not duplicate visible buttons because the default UI has no visible command surface.

## Error Handling

Workspace switching should be defensive:

- If a workspace has no panes, create one terminal session before activation.
- If a session surface cannot be found, show a small non-blocking failure state and keep the workspace active.
- If creating a workspace fails, keep the current workspace visible.
- If switching fails, do not close existing sessions.

## Tests

Core tests should cover:

- Multiple workspaces can coexist.
- Each workspace owns independent split trees.
- Switching active workspace preserves inactive sessions.
- Splitting affects only the active workspace.
- Closing a pane closes only that pane's session.
- Closing a workspace closes all owned sessions.
- Workspace focus is independent per workspace.

UI-level tests should cover:

- Default terminal view has no tab strip or sidebar.
- Workspace Switcher opens with the configured shortcut.
- Search filters workspace rows.
- Enter activates the selected workspace.
- Escape dismisses the switcher.

## Implementation Boundaries

Do not couple special product behavior into the terminal rendering layer. Terminal rendering remains driven by PTY output and the terminal parser/renderer chain. Workspace UI only coordinates which split tree is attached to the window.

Do not turn the default interface into an IDE. Workspace management should be powerful, but visible only on demand.
