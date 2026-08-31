# Motion "Build" Tab — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-08-31
> **Services:** web only (api, ai-service untouched)
> **Topic slug:** motion-build-tab
> **Depends on:** `2026-08-31-motion-prop-lane-drag-design.md`

## Overview

Add a **Build** tab to the timeline's empty-slot menus, composing a layer's
animation by picking which property channels take part — Move, Scale, Rotate,
Opacity — instead of picking one canned preset.

This is the half of thebrief.ai's model we do not have. Their Build list lets
a layer animate several properties at once, each landing as its own timeline
row. Our presets can only write what their author baked in: `Slide in left` is
x + opacity and nothing else, and there is no way to say "Scale **and** Rotate,
in this slot".

The dependency on the lane-drag spec is not cosmetic. Every channel a single
Build writes lands in the same time window; what makes them independent
afterwards is dragging their lanes apart. Build without that produces a
composition the user cannot tune.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Where it lives | **Slot chips only** (`+ In` / `+ Emphasis` / `+ Out`) | A channel needs a time window, and the chip is the one surface where the window is explicit. The ✨ menu and the segment right-click menu keep two tabs. |
| What a pick writes | **Defaults, tuned afterwards** | Consistent with how presets already behave: plain keyframes the user then edits via lanes, canvas drag and the Inspector. A parameter form would duplicate controls that already exist. |
| Keyframe label | **None** | The bar falls back to its property list (`position · scale`), which says more than "Build yours" would. `presetFamilyForLabel` needs no new label class. |
| Selection model | **Multi-select, one write** | Picking Scale + Rotate is the entire point; writing them in one action keeps it a single undo step. |

## Architecture

### 1. Channel writers — `src/lib/video-editor/presets.ts`

```ts
export type BuildChannelId = "move" | "scale" | "rotate" | "opacity";
export const BUILD_CHANNEL_IDS: BuildChannelId[];

export function applyBuildChannels(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  overlayId: string,
  slot: SlotKind,
  channels: BuildChannelId[],
  atMs: number,          // playhead; only consulted for "emphasis"
): MotionTimeline | null; // null when an emphasis window has no room
```

**Windows** — identical to what a preset from the same chip would use, so
there is no second timing rule to learn:

| Slot | Window |
| --- | --- |
| `in` | `[0, ENTRANCE_MS]` (500ms) |
| `out` | `[duration_ms − ENTRANCE_MS, duration_ms]` |
| `emphasis` | `[atMs, atMs + min(EMPHASIS_WINDOW_MS, room)]`, rejected when `room < EMPHASIS_MIN_WINDOW_MS` (200ms) — the same guard emphasis presets use, so the chip's disabled state stays consistent |

**What each channel writes.** Existing constants and writers are reused
wherever one exists, so Build output feels like the rest of the editor:

| Channel | In | Out | Emphasis |
| --- | --- | --- | --- |
| Move | `x = base.x − SLIDE_OFFSET` → `base.x` | `base.x` → `base.x + SLIDE_OFFSET` | reuses the `shake` writer (x ±0.008) |
| Scale | `POP_FROM_SCALE` (0.6) → `base.scale` | `base.scale` → `POP_FROM_SCALE` | reuses the `pulse` writer (×1.08) |
| Rotate | `base.rotation − BUILD_ROTATE_DEG` → `base.rotation` | `base.rotation` → `+ BUILD_ROTATE_DEG` | reuses the `spin` writer (+360°) |
| Opacity | `0` → `base.opacity` | `base.opacity` → `0` | `base.opacity` → `× BUILD_BLINK_OPACITY` → `base.opacity` |

Two new constants, both because no preset covers that motion today:
`BUILD_ROTATE_DEG = 15`, `BUILD_BLINK_OPACITY = 0.4`.

**Emphasis reads the sampled pose, not the rest pose** — `sampleTimelineAt` at
`atMs`, exactly as `applyEmphasisPreset` does, so an emphasis composed on top
of an existing entrance starts from where the layer actually is.

**Composition.** Each selected channel produces its own keyframes; they are
merged by `t_ms`, so channels sharing a time land in one keyframe carrying
several props. Insertion follows `applyEmphasisPreset`'s pattern: strip **only
the props being written**, and only inside the window, leaving hand-authored
keyframes on other properties intact.

### 2. UI — the Build tab

The slot popover becomes `Default | Build | Saved`, reusing
`MotionSourceTabRow` (already shared by the ✨ menu, the slot chips and the
segment menu).

Tab body: four preview cards through the existing `MotionPresetGrid`, each
animating its own channel default, plus a primary button labelled per slot
("Add to Emphasis"), disabled until at least one card is selected.

`MotionPresetGrid` gains an optional multi-select mode (`selectedIds` +
`onToggle`). It already models a per-option `active` flag for the stagger
menu's checkmark, so this is a small extension rather than a second grid.

### 3. Plumbing

```ts
// TimelineDockProps
buildChannels?: MotionPresetOption[];   // preview cards, built by the adapter
onApplyBuild?: (
  trackId: string, slot: SlotKind, channels: string[], atMs: number,
) => void;
```

Optional, like `savedMotions`: a host that omits them gets no Build tab.
`KvMotionEditor` wires `onApplyBuild` to a new
`useMotionEditorState.applyBuild`, which calls `applyBuildChannels` through
`push()` — one undo step for the whole composition — and shows the existing
"not enough room" toast on `null`.

## Analytics

New event `kv_generator.motion_build_applied` with
`{ project_id, slot, channels: string[] }`. Which **combinations** people
actually reach for is the question that decides whether Build earns its place,
and no preset event can answer it.

## Testing

| File | Covers |
| --- | --- |
| `presets.channels.test.ts` (new) | per-slot windows, per-channel keyframes, merge at shared `t_ms`, additive strip touching only written props, emphasis room rejection, emphasis sampling the current pose |
| `TimelineDock.buildtab.test.tsx` (new) | tab present on slot chips and absent from the ✨ / segment menus, multi-select toggling, button disabled while empty, one commit carrying every selected channel |

## Non-Goals

- Parameter fields (direction, distance, duration, easing) — defaults only
- Blur, Path, Resize channels — they need new props in `MotionProps`, plus
  renderer and exporter work
- Build on an occupied slot: chips only render for empty slots, so there is no
  overwrite flow to design
- A saved "Build" object that can be edited as a unit — the output is plain
  keyframes, by design

## Risks

- **Emphasis writes at the playhead**, so a Build there can partially overwrite
  a block already sitting under it. Identical to how emphasis presets behave
  today; called out here so it is a known property rather than a surprise.
- **Two invented constants** (`BUILD_ROTATE_DEG`, `BUILD_BLINK_OPACITY`) have no
  preset precedent to calibrate against. Expect to tune them after the first
  manual pass.
- **Duplication with presets is intentional** — Move-in alone is `Slide in
  left` minus the opacity. The value is in combinations, so if telemetry shows
  only single-channel Builds, the tab is not paying for itself.
