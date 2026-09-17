# KV Motion — anchored slots: In/Out as roles, layer visible range, In drags the whole line

**Date:** 2026-09-17
**Author:** Daffa (with Claude)
**Status:** approved design, not implemented
**Services:** web only
**Branch:** `feature/daffa/vc-kv-motion-anchored-slots`, stacked on `feature/daffa/vc-kv-motion-path`; merged back into the Path branch when done (one PR to `develop`).
**Supersedes:** the "elastic slots" rule of `2026-08-29-kv-motion-timeline-upgrades-design.md` (`assignSegmentsToSlots`, 2026-08-30).

---

## Problem

Three things a user hit in one session, all the same root cause:

1. `+ Emphasis` → Bounce on a layer with no entrance lands in the **In** slot (bar hugs the In region, `+ In` placeholder disappears). The block *is* a bounce, but it reads as "my emphasis became an entrance".
2. A Build **Move** in the Emphasis slot writes `shake` and the bar says `position` — nothing on screen says what was clicked.
3. There is no way to delay a layer: an entrance dragged right leaves the layer **visible, frozen at the entrance's start pose** (off to the left for Slide/Path, 0.6× for Pop) until the entrance begins.

The elastic rule ("In = the first segment wherever it sits") was introduced to stop a dragged-right entrance from turning into an emphasis and letting a second entrance overwrite the first. thebrief.ai never has that problem because its In and Out blocks **cannot be dragged** — they are anchored roles; dragging the In block moves the whole row (the layer's start), and the layer is hidden outside the tan visibility band.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Slot bucket | **Anchored roles**: `in` = starts at 0 **or** entrance preset family; `out` = ends at `duration` **or** exit family (and not already `in`); else `emphasis`. Full-span segment stays `in`. | A lone emphasis at 1 s is an emphasis. Preset-labelled entrances that were dragged (elastic era) stay In via their label. |
| In block drag | **Body-drag = shift the whole track** (`shiftTrackKeyframes`). Left handle disabled; right handle = duration. | This is "delay the layer" — every block on the row moves together, exactly like thebrief. It also makes "In drifts into Emphasis" unreachable, so the elastic rule is no longer needed. |
| Out block drag | Body-drag = shift the Out segment only (as today); right handle disabled; left handle = duration. | Out defines where the layer ends. |
| Emphasis drag | As today, but walls become `[inEnd + 1, outStart − 1]` — and at least `[1, duration − 1]`. | An emphasis can never reach 0 or the end, so it can never be mistaken for an entrance/exit (thebrief prevents it too). |
| Visible range | Derived, no persisted field: `[start of the in segment, end of the out segment]`, defaulting to `[0, duration]` when a side has no segment. **Applied in `sampleTimelineAt` as `opacity: 0`** outside the range. | One place ⇒ playback, poster tiles, preview cards and **export** agree (four-renderer-drift lesson). No migration. |
| Build labels | Build stamps `label` = channel label (`Move`, `Scale`, `Rotate`, `Opacity`) on the keyframes it writes; Path already stamps `Path`. `presetFamilyForLabel` maps them to `null`. | The bar reads what was clicked. |
| Placeholders | `+ In` / `+ Out` render whenever their bucket is empty (they no longer vanish because another bucket is occupied). `+ Emphasis` unchanged. A thin visibility band is drawn along the track from In start to Out end. | A track with only a Bounce shows `+ In  [Bounce]  + Out`. |
| Label sets | `PRESET_LABELS`, the id lists and `presetFamilyForLabel` move to `src/lib/video-editor/presetLabels.ts` (no imports beyond types); `presets.ts` re-exports them. | `presets.ts` imports `sample.ts`; the sampler and `blocks.ts` need the label→family rule, so it must live below both. |

## Behaviour change (export)

A document whose **preset-labelled entrance was dragged off 0** during the elastic era now hides its layer before that entrance (opacity 0) instead of showing it frozen at the entrance's start pose. Hand-authored first keyframes (no label) are not entrances and hide nothing. Recorded here on purpose: this is a rendering/export change, not only UI.

## Design

1. `presetLabels.ts` — extraction only, behaviour-neutral (`presets.test.ts` unchanged and green).
2. `blocks.ts`
   - `assignSegmentsToSlots(segments, durationMs, familyOf?: (s) => PresetFamily | null)` — new rule above; `familyOf` defaults to `() => null` (positional only).
   - `assignTrackSlots(track, durationMs)` — wraps it with `familyOf = s => presetFamilyForLabel(segmentLabel(track, s))`. All UI callers use this.
   - `trackVisibleRange(track, durationMs): { startMs, endMs }` from `assignTrackSlots`.
   - `emphasisWalls(track, segment, durationMs)` for the drag clamp.
3. `sample.ts` — per track, after resolving props: `if (tMs < range.startMs || tMs > range.endMs) resolved.opacity = 0`. Range computed once per track per call.
4. `presets.ts` — `applyBuildChannels` stamps `label: BUILD_CHANNEL_LABELS[channel]` on every keyframe it writes (Path unchanged).
5. `BlockTrackRow.tsx` — `SegmentBar` gets `slotKind` (already) and: In → `draggable body = shift track`, handles per table; Out/Emphasis per table; walls per table. `TimelineDockProps.onShiftTrack(trackId, deltaMs)` (new, optional) → `useMotionEditorState.shiftTrack` → `shiftTrackKeyframes` via `push`.
6. Dock visuals — placeholders per table; visibility band (`data-testid="track-visible-band-<id>"`).

## Testing

`presetLabels` re-export equality; `blocks.slots.test.ts` (lone emphasis at 1 s → emphasis; dragged "Slide in left" at 0.3 s → in; hand-authored at 0 → in; full span → in; exit at 4.4 s → out; two emphases); `sample.visible.test.ts` (hidden before a dragged entrance, visible at/after; **byte-for-byte** equality with the old sampler for a doc with no entrance/exit or an entrance at 0; export frame at t=0 for a delayed layer has opacity 0); `presets.buildChannels` (labels); dock tests (In body-drag calls `onShiftTrack` not `onShiftSegment`; emphasis drag clamps at 1 ms; `+ In` present beside a lone Bounce; band rendered).

## Non-goals

Per-layer persisted start/end; delaying a layer that has no entrance (add one first); In/Out on the Keyframes view.
