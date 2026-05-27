# ProGhostty Full-App Smoke Test

Date: 2026-05-24
Build: `.build/arm64-apple-macosx/debug/ProGhostty.app`

Legend:
- Auto: verified by command line, unit/integration tests, bundle inspection, or AppleScript where reliable.
- Manual: requires visual/interaction confirmation in the running macOS app.
- Hybrid: automated setup plus human visual confirmation.

| ID | Area | Scenario | Steps | Expected Result | Mode | Result |
| --- | --- | --- | --- | --- | --- | --- |
| SMK-001 | Build | Swift package compiles and test suite runs | Run `swift test` | All tests pass with no failures | Auto | Pending |
| SMK-002 | Bundle | Debug app bundle builds | Run `scripts/build-app-bundle.sh debug` | App bundle path is printed and codesign succeeds | Auto | Pending |
| SMK-003 | Bundle | Ghostty runtime resources are packaged | Check `Contents/Resources/ghostty/shell-integration/zsh/.zshenv` and `Contents/Resources/terminfo/78/xterm-ghostty` | Both files exist/readable | Auto | Pending |
| SMK-004 | Launch | Existing app can be restarted from debug bundle | Kill old `ProGhostty`, open debug app, check process | One live `ProGhostty` process from debug bundle | Auto | Pending |
| SMK-005 | Terminal | Shell starts and accepts input | In focused pane, run `pwd` and `echo PROGHOSTTY_SMOKE_OK` | Command output appears, prompt remains usable | Manual | Pending |
| SMK-006 | Titlebar | Workspace title is shown at right | Observe titlebar right side | Shows workspace name only, no default cwd suffix | Manual | Pending |
| SMK-007 | Titlebar CWD | Focused pane cwd is shown in center | Run `cd ~/projects/proghostty`, focus pane | Center titlebar shows folder name `proghostty`, tooltip/full state tracks cwd | Manual | Pending |
| SMK-008 | Titlebar CWD | CWD updates after changing directory again | Run `cd /tmp` | Center titlebar changes to `tmp` | Manual | Pending |
| SMK-009 | Split | Split right from menu/shortcut when space is available | Trigger right split | New pane appears, focus moves to new pane, no crash | Manual | Pending |
| SMK-010 | Split | Split down from menu/shortcut when space is available | Trigger down split | New pane appears below, no crash | Manual | Pending |
| SMK-011 | Split Limits | Down split is blocked when current pane is too small | Shrink pane/window, trigger down split repeatedly | Split stops at limit, toast/beep appears, no tiny unusable pane | Manual | Pending |
| SMK-012 | Split Resize | Drag divider preview updates during drag | Drag a divider slowly | Preview divider follows pointer, layout commits once on mouse up | Manual | Pending |
| SMK-013 | Split Resize | Window resize does not crash with many panes | Create several panes, shrink and enlarge window | No crash; panes remain usable or split is blocked before unusable state | Manual | Pending |
| SMK-014 | Drag Drop | Drop a file into a pane | Drag a local file over a pane and drop | Absolute quoted path is inserted as one input, no newline/submit | Manual | Pending |
| SMK-015 | Drag Drop | Drop a folder into a pane | Drag a local folder over a pane and drop | Absolute quoted path is inserted as one input, no newline/submit | Manual | Pending |
| SMK-016 | Drag Drop | Drag hover hint follows target pane | Drag file/folder over different panes without dropping | Lightweight drag hint appears on hovered target pane | Manual | Pending |
| SMK-017 | Links | Cmd-click URL opens browser | Print `https://example.com`, Cmd-click it | Browser opens URL; plain click does not | Manual | Pending |
| SMK-018 | File Links | Cmd-click absolute file path reveals in Finder | Print an existing local file path, Cmd-click it | Finder reveals containing location; file is not opened directly | Manual | Pending |
| SMK-019 | Wrapped Paths | Wrapped file path is detected as one path | Print a long existing path in a narrow pane, Cmd-click wrapped text | Finder reveal works, no false "path missing" from visual line break | Manual | Pending |
| SMK-020 | Workspaces | Workspace switcher opens and switches | Open workspace switcher, select/create another workspace | Active workspace changes; pane focus and titlebar update | Manual | Pending |
| SMK-021 | Focus | Clicking panes changes focused cwd title | Two panes in different cwd, click each pane | Center titlebar follows the clicked/focused pane cwd | Manual | Pending |
| SMK-022 | Settings | Settings window opens and persists a simple option | Open settings, change theme/language or renderer option, close/reopen | Setting persists and app remains responsive | Manual | Pending |
| SMK-023 | Plugin UI | Plugin manager opens without crashing | Open plugin manager from UI/command | Window appears; scanning state or plugin list renders | Manual | Pending |
| SMK-024 | Scroll/Render | Scrollback and selection remain usable | Generate output with `seq 1 200`, scroll, select/copy text | Scroll and selection behave normally | Manual | Pending |
| SMK-025 | IME/Input | Printable and composed input still works | Type normal text and Chinese input in pane | Text commits to terminal correctly | Manual | Pending |
| SMK-026 | Restart Persistence | App restores persisted workspace state | Quit and relaunch app | Workspace/pane layout restores or default workspace opens without error | Hybrid | Pending |

## Automation Commands

```sh
swift test
scripts/build-app-bundle.sh debug
test -r .build/arm64-apple-macosx/debug/ProGhostty.app/Contents/Resources/ghostty/shell-integration/zsh/.zshenv
test -e .build/arm64-apple-macosx/debug/ProGhostty.app/Contents/Resources/terminfo/78/xterm-ghostty
pgrep -fl ProGhostty
```

## Notes

- This suite intentionally mixes automated checks and visual interaction checks because ProGhostty is a native AppKit/SwiftUI terminal app.
- General computer-use desktop automation is not available in this session. Use AppleScript/Accessibility only for coarse app launch/process checks; keep terminal interaction validation manual unless a dedicated UI automation harness is added.
