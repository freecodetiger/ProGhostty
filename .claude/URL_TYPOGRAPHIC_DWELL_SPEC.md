# Design Spec · Semantic Object Reveal — Typographic Dwell

> Status: **Design (not implemented)**
> Branch: `feat/link-underline-animation`
> Supersedes the *reveal visual* of `URL_SEMANTIC_OBJECT_SPEC.md` §4–§5:
> replaces float / halo / flashlight-proximity with a **single dwell-gated cue: font weight**.
> Everything else in that spec (Semantic Object model §7, Popover §6, Explore Mode §13)
> stays authoritative.

---

## 0. North Star

> **React to intention, not motion. Reveal through typography, not movement.**

The previous reveals failed for nameable reasons:

- **Float-up** was *movement* → reads as "animated" → cheap. Nothing should translate in space.
- **Flashlight proximity** reacted to *the cursor being near* → still motion, not intent.
- **Luminance lift** was *unreliable* → white text has no headroom, and pushing colored
  text toward white desaturates it. Cut entirely.
- **Font-size increase** would break the monospace grid (reflow / overflow) and is itself
  a form of motion (glyphs growing). Cut entirely.

The correct signal is **dwell**: the user stopped here, on purpose. And the correct
response is a **single, color-independent, in-place cue — the text gets heavier.**
The same word, more present. No glyph moves. No box. No glow. No color change. No resize.

---

## 1. Tenets (ranked — resolve conflicts top-down)

1. **Dwell, not proximity, not motion.** Fast pass-through produces *nothing*. Only a genuine pause on the same object wakes it.
2. **One cue: weight.** The sole reveal is font-weight gain. No color, no luminance, no size, no position — all cut as unreliable or motion-like.
3. **Reveal in place.** Only stroke thickness changes; glyph origin, advance, color, and size never do. Zero translation, zero scale, zero reflow.
4. **Quiet at rest.** Byte-for-byte identical to plain text until dwell. No persistent affordance.
5. **Object-wide, continuous.** A wrapped URL is one Semantic Object; dwell on any segment wakes the whole thing (reuse existing `SemanticLinkObject`).
6. **Imperceptible transition.** The text *settling into focus*, never an effect firing.

---

## 2. State Machine

```
        dwell 100ms                 dwell 300ms                  click
Rest ───────────────► Awake ───────────────► ActionHint ───────────────► Popover
  ▲                     │                         │                          │
  └─────────────────────┴─────────────────────────┴──────────────────────────┘
       pointer leaves object  /  Esc  /  dismiss   →  Rest (settle back)
```

- Dwell timers are **cumulative on the same Semantic Object**. Moving *within* the
  object (including across its wrapped rows) does **not** reset. Leaving cancels and reverses.
- "Dwell" = pointer is over the object **and effectively still**. A small motion
  tolerance (a few px) counts as still; leaving the object's cells resets to Rest.

| State | Enter condition | Visual |
|-------|-----------------|--------|
| **Rest** | default | identical to plain text |
| **Awake** | pointer still over object ≥ **100ms** | glyph **weight gain** (SDF faux-weight, tunable amount) — the only cue |
| **ActionHint** | still over object ≥ **300ms** (200ms after Awake) | trailing `↗`, extremely faint, at logical end |
| **Popover** | primary click on object in Awake/ActionHint, or ⌘-click from any state | pointer-anchored actions Popover |

---

## 3. Rest State

- No color, no weight change, no underline, no background, no motion.
- Hit-testing still runs (semantic ranges are known) — we simply draw the object
  exactly as plain text.
- Screenshot test: a still frame at Rest must not reveal where the links are.

---

## 4. Awake (dwell ≥ 100ms) — weight is the whole signature

**One cue, nothing else moves or shifts color.** The object's glyphs gain font weight.

### 4.1 Weight gain — the sole, universal cue

- The object's glyphs gain font weight — start near **+20 (Regular→Medium feel)**, but
  the amount is a **single tunable** we will dial up in hand-test (up to Bold-ish) if the
  reveal reads too subtle. It is the only knob.
- **This is the one signal that always works.** It is *color-independent*: white text,
  colored text, dim text — all thicken identically. No other cue is needed or wanted.
- **Implementation — alpha-coverage dilation, no bold font needed.** `MetalDirectRenderEngine`
  draws each glyph as a rasterized **alpha bitmap** (not an SDF). Faux-weight is done in
  the glyph fragment shader by **multi-tap dilation**: sample the glyph alpha at a few
  small neighbor offsets and take the max, so strokes thicken outward. The offset
  magnitude is driven by a per-glyph `weightBoost ∈ [0,1]` uniform (carried per-vertex),
  so it is:
  - **continuous** — `weightBoost` ramps `0 → boost` smoothly with the dwell tween;
  - **in place** — the glyph quad's origin/advance/size are unchanged; only sampled
    coverage grows, so text does not reflow, shift, or resize;
  - **color-preserving** — the glyph's fill color is untouched; only alpha coverage changes;
  - **zero-cost at rest** — `weightBoost == 0` collapses to today's single tap; no second
    atlas, no bold face, no relayout.
- The dilation must stay **symmetric and small** so glyphs don't smear or merge; cap
  the boost well below the point where counters (holes in `a`, `e`) start closing.

### 4.2 Forbidden in Awake

- ❌ Any translation (no float, no rise, no drift).
- ❌ Any scale / font-size change / zoom (breaks the monospace grid; is motion).
- ❌ Any luminance or brightness change (unreliable: no headroom on white; desaturates color).
- ❌ Any color / hue shift, or blending toward white / any fixed color.
- ❌ Halo, glow, background wash, underline, box.
- ❌ Reacting to mere proximity or motion — dwell only.

---

## 5. Action Hint (dwell ≥ 300ms)

- A **very small, extremely faint `↗`** fades in at the **logical end** of the object
  (end of its last wrapped segment).
- ≈ 0.7–0.8× cell, baseline/cap aligned, colored with the Awake foreground (not accent).
- Means **"operable"** — no tooltip, no menu preview, no URL readout.
- Fades **in place** (opacity only — it does **not** float in, correcting the earlier
  arrow-float behavior). 120–180ms ease-out. Fades out equally softly on recede.
- At the extreme right edge with no room: render just past the run or omit — never wrap.

---

## 6. Motion & Transition Rules

| Property | Value |
|----------|-------|
| Weight ramp `0→boost` | tween over **120–180ms**, ease-out |
| `↗` opacity | own 120–180ms ease-out timer, starts at ActionHint |
| Curve | ease-out (`1 - (1-t)³`) |
| Exit | weight settles back, may be slightly faster than enter |
| Forbidden | translation, scale, color/luminance change, bounce, spring, **any looping/breathing** |
| Feel target | "the text came into focus," never "an animation played" |

- The only thing that animates is the *interpolation of weight (and the `↗` opacity)*
  after the dwell threshold is crossed — never position, size, or color.
- **No idle loop.** Display-link runs only while a tween is in flight; it stops when
  the state settles (honor performance invariants — no busy render loop).

### 6.1 Reduce Motion

- Respect `accessibilityDisplayShouldReduceMotion`.
- When on: **snap** weight / `↗` between states (no tween), but **keep the
  100ms / 300ms dwell delays** — the intention model is unchanged; only interpolation drops.

---

## 7. Semantic Object continuity (unchanged from base spec §7)

- A wrapped URL is **one** `SemanticLinkObject`; dwell on any segment wakes all segments.
- Weight + luminance apply to **every** segment together; the dwell timer belongs to
  the object, so moving between its own rows never resets it.
- `↗` appears **once**, at the logical end of the whole object.
- No cross-line box, underline, or connector — continuity comes from shared state.

---

## 8. Click / Popover / ⌘ / Explore Mode

Unchanged from `URL_SEMANTIC_OBJECT_SPEC.md`:

- **Primary click** (in Awake/ActionHint) → pointer-anchored Popover (2 items:
  Open in Browser / Copy Link for URLs; Reveal in Finder / Copy Path for paths).
- **⌘-click** → open immediately from any state.
- **Hold ⌘** → Explore Mode: all semantic objects wake together (same weight cue,
  faded in over 120–180ms). Release → all settle back. Explore Mode uses the
  **same weight reveal**, applied globally instead of per-dwell.

---

## 9. What this removes / replaces

| Concern | Previous (float / flashlight / luminance) | This spec |
|---------|-------------------------------------------|-----------|
| Reveal trigger | proximity distance / instant hover | **dwell 100ms** on object |
| Reveal visual | glyph float-up + halo + luminance lift | **font weight gain only, in place** |
| Action hint | `↗` floating up in sync | `↗` **fades** in place |
| Motion model | continuous flashlight strength | binary dwell-gated tween |
| Files touched | `LinkProximity`, float offset in engine | dwell timer + SDF `weightBoost` uniform |

- **Remove** the flashlight proximity path (`LinkProximity` strength driving float),
  the per-glyph vertical float offset, the `↗` float sync, and any halo/luminance remnants.
- **Add** a per-object dwell timer (pure, testable value type in `ProGhosttyCore`) and
  a `weightBoost` uniform through the glyph pipeline. Renderer stays a painter; no ANSI
  re-parse; state machine and timing live in Core.

---

## 10. Timing Summary

| Signal | Threshold |
|--------|-----------|
| Awake (weight gain) | dwell **100ms** |
| ActionHint (`↗`) | dwell **300ms** |
| Any transition tween | **120–180ms** ease-out |

Fast pass-through (< 100ms still on the object) → **no visual change at all.**

