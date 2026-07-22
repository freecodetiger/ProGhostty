# Design Spec · Terminal URL as a Semantic Object

> Status: **Design (not implemented)**
> Branch: `feat/link-underline-animation`
> Supersedes: the current static hover underline (`MetalOverlayBuffer` `.linkHover`)

---

## 0. North Star

> **React to intention, not motion.**

The terminal does not light up because a cursor passed over a link. It lights up
because the user is *about to act* — they dwelled, they held ⌘, they right-clicked.
Motion is noise; intention is signal. Every rule below exists to serve this line.

Second principle, equal weight:

> **Everything is interactive, but quiet by default.**

A URL is not a web link. It is a **Semantic Object** living inside a monospace
grid — indistinguishable from surrounding text until the user asks it to wake up.

---

## 1. Design Tenets (ranked — resolve conflicts top-down)

1. **Intention over motion** — never react to fast pass-through; require dwell / modifier / explicit action.
2. **Quiet by default** — a link is byte-for-byte identical to plain text at rest. No blue, no underline, no button, no persistent affordance.
3. **Progressive disclosure** — capability is revealed in graded stages only as intent strengthens.
4. **Semantic continuity** — a wrapped URL is *one* object, never a set of rectangles. Feedback covers it as a whole, continuously.
5. **Imperceptible motion** — the user should feel "smooth," never "animated." No scale, bounce, or glow. ~5% of perceptible motion, no more.
6. **Terminal-native, not web-native** — the reference languages are Apple & Linear, not the browser.

> **Craft priority:** among all visuals, the **feathered, background-derived
> Semantic Halo (§4.2)** is the single highest bar. Get it right or the feature
> reads as a web highlight.

---

## 2. State Machine

```
        dwell 200ms                 dwell 400ms                  click
Rest ───────────────► Hover ───────────────► ActionHint ───────────────► Popover
  ▲                     │                         │                          │
  └─────────────────────┴─────────────────────────┴──────────────────────────┘
              pointer leaves object  /  Esc  /  dismiss   →  Rest (fade out)
```

Key: dwell timers are **cumulative on the same semantic object**. Moving the
pointer *within* the same URL (including across its wrapped rows) does **not**
reset the timer. Leaving the object cancels and reverses.

| State | Enter condition | Visual |
|-------|-----------------|--------|
| **Rest** | default | identical to plain text |
| **Hover** | pointer still over object ≥ **200ms** | +3–5% text luminance · Semantic Halo fades in |
| **ActionHint** | still over object ≥ **400ms** (200ms after Hover) | trailing `↗` glyph fades in at logical end of URL |
| **Popover** | click (primary) on object in Hover/ActionHint, or ⌘-click from any state | actions Popover anchored at pointer |

---

## 3. Rest State

- No color shift, no underline, no weight change, no background.
- The URL contributes **zero** visual noise. If a screenshot at rest reveals
  where the links are, the design has failed.
- Hit-testing still runs (we already know the semantic ranges) — we just draw nothing.

---

## 4. Hover (dwell ≥ 200ms)

Fast fly-over must produce **nothing**. Only a genuine pause triggers Hover.

Two simultaneous, extremely gentle signals:

### 4.1 Text luminance lift
- Raise the URL glyph luminance by **3–5%** (perceptual, not linear RGB).
- Dark themes lift toward white; light themes deepen slightly toward foreground —
  whichever *increases contrast* against the local background.
- This is the "it's alive" cue. It must be barely nameable.

### 4.2 Semantic Halo — *the single highest design priority*

The feathered halo is **the** signature of this feature. If any one thing must be
gotten right, it is this. A hard-edged box is an automatic failure regardless of
how correct everything else is.

- A **soft, borderless** wash behind the URL's glyphs.
- **Not** a rectangle. **Not** a stroke/outline. **Not** a filled cell block.
- Implementation intent: a low-alpha fill with **feathered edges** (radial/gaussian
  falloff) hugging the text run — "a warm breath behind the words," not a highlight box.
- The halo follows the text metrics, expanding to exactly the glyph run — including
  every wrapped segment (see §7).

#### 4.2.1 Halo color is derived from the local background, never a fixed white

The halo is **not** a uniform white/light wash. It is computed from the background
it sits on, so it reads as the same "breath" in every theme:

- **Light background → halo goes darker** than the background.
- **Dark background → halo goes lighter** than the background.
- The goal is a **slight, just-visible contrast** against the local background —
  present enough to sense, never enough to name as a "box" or "highlight."
- Derive from the *actual local background* under the run (respecting per-cell
  background, not just the theme default), so the halo stays coherent over colored
  or inverse cells.
- Alpha/contrast delta is small and tunable per theme; the ceiling should keep the
  halo in "barely perceptible" territory (starting point ~0.06–0.10 effective,
  refined against real backgrounds in §11).
- Direction rule of thumb: nudge the background's luminance **toward the opposite
  end** by a small fixed perceptual step, then feather — rather than blending
  toward a fixed color.

### 4.3 Explicitly forbidden in Hover
- ❌ Cross-line underline (the thing we are replacing).
- ❌ Any single-line underline.
- ❌ Hard-edged background rectangle.
- ❌ Immediate response to motion.

---

## 5. Action Hint (dwell ≥ 400ms)

The user has clearly settled. Now — and only now — reveal that this is operable.

- A **very small `↗`** glyph fades in at the **logical end** of the URL
  (the end of its last wrapped segment).
- Size: subordinate to text (≈ 0.7–0.8× cell), aligned to the glyph baseline/cap.
- Color: the Hover-lifted foreground, not accent-blue.
- It means **"operable"** — nothing more:
  - ❌ no tooltip
  - ❌ no menu preview
  - ❌ no URL string readout
- Fade in **120–180ms**, ease-out. Fade out equally soft when intent recedes.
- If the URL's last segment sits at the extreme right edge with no room, the `↗`
  may render just past the run or be omitted — never wrap it to a new line.

---

## 6. Click → Popover

- **Primary click** on a URL in Hover/ActionHint opens the actions Popover.
- **⌘-click opens the URL immediately**, from *any* state (even Rest, even before
  dwell). No Popover, no waiting — this is the power-user path and preserves today's
  muscle memory (`⌘-click → open`). **Decided.**
- Popover contents (top-to-bottom):
  1. **Open** — default action (opens with the system handler)
  2. **Copy URL**
  3. **Open in Browser**
  4. **QR Code** *(optional / feature-flagged)*
- **Anchor = pointer position**, not the URL's start cell. The menu appears where
  the user's attention already is.
- Dismiss: click-away / Esc → Popover closes, object fades back through Hover to Rest.
- This replaces the current `⌘-click → NSWorkspace.open` and generic right-click
  `NSMenu` path for URLs specifically.

---

## 7. Cross-line URLs — the Semantic Object rule

A wrapped URL is **one object**, never N rectangles.

- **Model**: the detector already yields per-row ranges for one logical URL
  (via `TerminalLogicalLine`). Group them under a single `SemanticLinkObject`
  with a stable identity, holding: the resolved URL, and its ordered row segments.
- **Hover is object-wide**: hovering *any* segment puts the *entire* object into
  Hover. The dwell timer belongs to the object, so moving between its own
  segments never resets it.
- **Halo continuity**: the Semantic Halo renders over **all** segments so the
  effect reads as one continuous, natural glow — even though the segments live on
  different rows.
- **No cross-line chrome**: ❌ no bounding box spanning rows, ❌ no underline on any
  row, ❌ no connector between rows. Continuity comes from the halo + shared state,
  not from drawn borders.
- The `↗` appears **once**, at the logical end of the whole object.

---

## 8. Animation Rules

| Property | Value |
|----------|-------|
| Duration | **120–180ms** (all transitions) |
| Curve | **Ease-out** (e.g. `1 - (1-t)³`) |
| Enter vs exit | exit may be slightly faster than enter (crisp departure), both within range |
| Forbidden | scale, bounce, spring overshoot, glow pulse, **any looping/breathing** |
| Feel target | "very smooth," never "animated." ~5% perceptible motion. |

- Halo & luminance fade in together on Hover-enter; `↗` fades on its own timer.
- On exit, all layers fade out together (no staggered choreography that draws the eye).
- **No idle/looping animation ever.** Once a state settles, it is static. The
  driving display-link must stop when no transition is in flight (honor the
  project's performance invariants — no busy render loop).

### 8.1 Reduce Motion
- Respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
- When on: **snap** between states (no tween), but keep the dwell delays — the
  *intention* model is unchanged; only the interpolation is removed.

---

## 9. Timing Summary

| Signal | Threshold | Notes |
|--------|-----------|-------|
| Hover luminance + halo | dwell **200ms** | resets only on leaving the object |
| Action Hint `↗` | dwell **400ms** | 200ms after Hover |
| Any transition tween | **120–180ms** | ease-out |
| Exit / fade back | within 120–180ms | may be at the faster end |

Fast pass-through (< 200ms over the object) → **no visual change at all**.

---

## 10. Explicit Non-Goals

- No web-style always-on link styling (color/underline).
- No hover tooltip or inline URL preview.
- No animated underline of any kind (this spec **removes** the current one).
- No persistent per-link affordance at Rest.
- No looping "breathing" glow — motion is transitional only.
- No feedback driven purely by pointer movement.

---

## 11. Open Questions (resolve before implementation)

1. ~~**Bare ⌘-click**~~ — **Decided**: ⌘-click opens the URL immediately (no
   Popover). Dwell + plain click opens the Popover.
2. **Halo rendering path** *(highest-risk item)*: the halo must be **borderless
   and feathered** with **background-derived color** (§4.2 / §4.2.1). Needs a
   feasibility spike — the current rect-based Metal overlay cannot express feathered
   falloff, so this likely needs a dedicated shader (radial/gaussian alpha) or a
   sampled soft mask. A hard rectangle is not acceptable as a fallback.
3. **Per-theme tuning**: the perceptual luminance step and alpha ceiling that keep
   the halo "just visible" on Default / Soft Dark / Soft Light — validated against
   real backgrounds, including colored and inverse cells.
4. **`↗` glyph source**: font glyph vs. drawn path; baseline alignment in the grid.
5. **Right-click**: does the generic context menu still apply over a URL, or does
   the URL Popover take precedence?
6. **QR Code**: **in v1.** Included in the Popover actions.

---

## 12. Impact Map (where this lands in code)

| Concern | Today | This spec |
|---------|-------|-----------|
| Hover detection | `updateLinkHover(at:)`, instant, boolean | dwell-timed, per **object** identity |
| Hover visual | static underline in `MetalOverlayBuffer` `.linkHover` | luminance lift + feathered Semantic Halo |
| Cross-line | per-row ranges (post-v0.4.4 `TerminalLogicalLine`) | grouped `SemanticLinkObject` |
| Click | `mouseDown` ⌘-click → open | ⌘-click → open (unchanged); dwell-click → pointer-anchored Popover |
| Actions surface | `NSMenu.popUpContextMenu` | pointer-anchored Popover |
| Motion | none | 120–180ms ease-out, reduce-motion aware, no idle loop |
| Halo color | n/a (static underline) | derived from local background: light→darker, dark→lighter, barely-visible |

> Pure logic (state machine, dwell timing, luminance math, halo geometry, object
> grouping) should live in testable value types in `ProGhosttyCore`, driven by the
> existing display-link + `transientOverlayDidChangeHandler` plumbing — no new
> ANSI parsing, renderer stays a painter.
