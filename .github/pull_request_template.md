## Summary

<!-- One-line: what does this PR do? -->

## Layer touched

<!-- Check all that apply -->
- [ ] PTY / sessions
- [ ] VT bridge / terminal state
- [ ] Renderer (Metal / cell-grid / text)
- [ ] Smooth scroll / history browse
- [ ] Workspace / splits / panes
- [ ] Settings / themes / UI chrome
- [ ] AI CLI integration (notifications, side input)
- [ ] Docs / CI / scripts
- [ ] Tests only

## User-visible behavior

<!-- What changes from the user's perspective? If nothing visible, say so. -->

## How I tested

<!-- Run commands, manual test steps, screenshots if applicable -->

```bash
swift build && swift test && scripts/check-architecture.sh
# UI / renderer changes: also
./scripts/build-app-bundle.sh release
```

## Checklist

- [ ] `swift test` passes
- [ ] `scripts/check-architecture.sh` passes (Core does not import SwiftUI)
- [ ] Commit messages follow [Conventional Commits](docs/git-workflow.md)
- [ ] Docs updated if applicable
