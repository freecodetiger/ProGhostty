# Plan: Expose semantic_content from libghostty-vt and use it for click-to-position

## Overview

Replace the heuristic-based prompt detection with proper OSC 133 semantic markers
from libghostty-vt. The VT library already tracks per-cell `semantic_content`
(output/input/prompt) when the shell emits OSC 133 sequences. We just need to
pipe it through the C shim → Swift types → click-to-position logic.

## Changes

### 1. C shim header: add `semantic_content` to `ProGhosttyVTCell`

**File:** `Sources/ProGhosttyGhosttyVT/include/ProGhosttyGhosttyVT.h`

Add field after `wide`:
```c
uint8_t wide;
uint8_t semantic_content; // 0=output, 1=input, 2=prompt
```

### 2. C shim implementation: read semantic_content in both cell extraction paths

**File:** `Sources/ProGhosttyGhosttyVT/ProGhosttyGhosttyVT.c`

**In `blank_cell()`:** set `cell.semantic_content = 0;`

**In `cell_from_grid_ref()`:** after getting raw cell, add:
```c
GhosttyCellSemanticContent semantic = GHOSTTY_CELL_SEMANTIC_OUTPUT;
ghostty_cell_get(raw, GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, &semantic);
out.semantic_content = (uint8_t)semantic;
```

**In `proghostty_vt_snapshot()` loop:** after `apply_wide(cell, raw);`, add:
```c
GhosttyCellSemanticContent semantic = GHOSTTY_CELL_SEMANTIC_OUTPUT;
ghostty_cell_get(raw, GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, &semantic);
cell->semantic_content = (uint8_t)semantic;
```

### 3. Swift types: add `semanticContent` to `GhosttyTerminalFrame.Cell`

**File:** `Sources/ProGhosttyCore/TerminalCore/LibGhostty/GhosttyVTBridge.swift`

Add enum + property:
```swift
public enum CellSemanticContent: UInt8, Sendable {
  case output = 0
  case input = 1
  case prompt = 2
}
// In Cell struct:
public var semanticContent: CellSemanticContent
```

Update `cell(from:)` to read `rawCell.semantic_content`.

### 4. Rewrite `handleClickToPosition` to use semantic markers

**File:** `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`

New logic:
- If cells on the cursor row have `semanticContent == .input` → use semantic path
- Count only `.input` cells between cursor and click position (skip `.prompt`/`.output`)
- Skip `.spacerTail` within `.input` cells (wide char = 1 move)
- If no semantic data available (all cells are `.output`, meaning no shell integration) →
  fall back to simplified heuristic (current cursor-visible + same-row approach)

### 5. Remove `findPromptRow` and `promptLeftBound` heuristics

These are replaced by the semantic content check. The prompt left boundary is
implicitly defined: it's where `.input` cells begin on the row.

### 6. Keep ClickToPositionHandler for the non-semantic fallback path

The simple same-row fallback (cursor visible, no alt-screen, basic arrow math)
stays as fallback when shell integration is not installed.

## Architecture compliance

- semantic_content comes from libghostty-vt (the sole truth source)
- No ANSI parsing — we read structured data from the VT snapshot
- C shim addition follows the exact same pattern as existing cell data extraction
