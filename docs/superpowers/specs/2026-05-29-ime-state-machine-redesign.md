# IME State Machine Redesign

Date: 2026-05-29

## Goal

Rebuild the terminal input path around a single internal state machine so IME
composition, cursor visibility, marked text overlay placement, and presentation
synchronization are all derived from one consistent model.

The first validation baseline is:

- system Pinyin
- continuous input and backspace in a plain terminal

The design must also stay compatible with Claude Code and other terminal apps.

## Problem

The current input path is unstable because several responsibilities are split
across live view state, render timing, and ad hoc cursor inference:

- `keyDown`, `setMarkedText`, `insertText`, `unmarkText`, `firstRect`, and
  render callbacks all read and mutate overlapping state.
- presentation flushes can happen in the middle of IME setup.
- cursor suppression is tied to marked text state, but recovery is not fully
  deterministic.
- marked text placement can be recomputed from a newer frame than the one that
  produced the composition anchor.
- the visible cursor, candidate window anchor, and overlay rect can each be
  derived from different snapshots.

That creates the failure pattern already observed:

- initial IME entry can be correct
- cursor suppression can fail to restore after exit
- a later IME entry can reuse stale or shifted anchor data
- candidate windows drift even when the underlying terminal text is unchanged

## Non-Goals

- Do not change external terminal behavior unrelated to IME and cursor state.
- Do not change public API surface unless required for internal compatibility.
- Do not redesign shell integration, PTY parsing, or renderer selection.
- Do not add new user-facing IME settings in this phase.

## Proposed Architecture

Introduce one internal text-input state machine that owns the current answer to:

- are we in composition
- what is the active composition anchor
- what cursor rect should IME clients see
- should the terminal cursor be suppressed
- what marked text presentation should the renderer draw

The state machine is fed by events from:

- `keyDown`
- `setMarkedText`
- `insertText`
- `unmarkText`
- render/update callbacks
- focus changes
- presentation synchronization

Render code becomes a consumer of a resolved snapshot, not a second source of
truth.

## State Model

The internal model should keep at least these pieces of state:

- `compositionPhase`: idle, pendingStart, composing, committed, recovering
- `visibleCursorRect`: last known stable cursor rect from a rendered snapshot
- `compositionAnchorRect`: rect pinned for the current composition session
- `lastCommittedCursorRect`: cursor rect after a commit, before next render
- `inferredCursorRect`: rect inferred from a transient or home-cursor frame
- `markedText`: current composition string and selected range
- `cursorSuppressed`: whether the terminal cursor should be hidden
- `presentationGeneration`: monotonically increasing render generation
- `anchorGeneration`: generation that produced the current anchor

## Rules

1. Composition always starts from a stable cursor rect if one exists.
2. Once a composition session has an anchor, that anchor does not move because a
   newer frame happened to arrive during the same session.
3. Render timing may update the stable cursor rect, but not the active
   composition anchor unless the state machine explicitly allows it.
4. Cursor suppression is a derived state of composition phase, not a separate
   heuristic.
5. `firstRect` and `currentMarkedTextOverlay` must resolve from the same anchor
   snapshot.
6. If the app is not composing, the visible cursor must recover deterministically.
7. English input must not inherit IME suppression or composition anchors.

## Data Flow

```text
AppKit event
  -> PTYGridView / NSTextInputClient event handler
  -> IME state machine update
  -> resolved presentation snapshot
  -> renderer reads snapshot
  -> firstRect / characterIndex / overlay use same anchor
```

Presentation synchronization stays available, but it becomes an input to the
state machine rather than a place where anchor logic lives.

## Component Boundaries

### Input State Machine

Responsibility:

- own composition phase and anchor selection
- resolve cursor visibility
- accept render snapshots and event snapshots
- produce a single resolved presentation state

### Cursor / Anchor Resolver

Responsibility:

- choose the anchor rect for composition
- prefer visible stable cursor over inferred fallback when safe
- preserve committed composition anchors until a clean recovery point

### Marked Text Presentation

Responsibility:

- convert the active anchor into overlay rects and `firstRect` output
- keep anchor stable while trimming only the visible text span when needed
- handle right-edge and wide-character clipping without shifting the anchor

### Renderer Consumption

Responsibility:

- draw cursor, marked text, and selection from the resolved snapshot
- suppress cursor when the snapshot says composition is active
- never recompute IME anchor from raw render state during drawing

## Recovery Paths

The state machine must handle these cases explicitly:

- composition start after a transient render flush
- composition continuation after a commit
- composition exit followed by English typing
- lost focus and regained focus
- render updates that arrive while composing

Recovery should prefer correctness over clever inference. If a rect cannot be
resolved confidently, the state machine should fall back to the last stable
anchor instead of inventing a new one.

## Testing Strategy

### Unit Tests

Cover pure state transitions for:

- composition start from a stable cursor
- composition start after a transient home cursor frame
- cursor suppression on IME entry
- suppression clearing on unmark / non-IME typing
- commit followed by the next composition
- right-edge marked text trimming without anchor drift

### Integration Tests

Cover `PTYGridView` and renderer paths for:

- system Pinyin continuous typing
- backspace inside marked text
- firstRect and overlay consistency
- re-render during composition start
- re-render during composition continuation
- cursor recovery after IME exit

### Manual Baseline

Verify with:

- a plain terminal session
- Claude Code
- system Pinyin
- continuous input, deletion, commit, and re-entry

## Success Criteria

This redesign is done when:

- Chinese input starts cleanly in a plain terminal
- candidate windows do not drift during redraws
- the terminal cursor always returns after composition ends
- English input is unaffected after IME use
- the same behavior holds in Claude Code and other terminal apps
- the tests prove the same anchor is used for `firstRect` and overlay drawing

## Rollout

This should land as an internal refactor first, with compatibility preserved at
the view and renderer boundary. Once the state machine is in place, smaller
cleanup passes can remove the old heuristic paths instead of trying to keep both
models active long term.
