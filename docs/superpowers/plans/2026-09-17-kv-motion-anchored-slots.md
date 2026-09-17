# KV Motion Anchored Slots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In/Out become anchored roles (not positions), the In block drags the whole track, the layer is hidden outside its In→Out range, Build bars read what was clicked.

**Architecture:** Label sets move below the sampler (`presetLabels.ts`) so `blocks.ts` and `sample.ts` can both resolve a segment's preset family. `blocks.ts` owns the bucket rule, the visible range and the drag walls; `sample.ts` applies the range as `opacity: 0` (one place for playback + export); `BlockTrackRow` changes only what each slot kind's bar may do; the editor gains `shiftTrack`.

**Tech Stack:** TypeScript, React 19, `bun test` (Testing Library, `within(document.body)`).

**Spec:** `docs/superpowers/specs/2026-09-17-kv-motion-anchored-slots-design.md`

**Branch:** `feature/daffa/vc-kv-motion-anchored-slots` already checked out in `web/.worktrees/kv-motion-path` (stacked on the Path branch; HEAD `31d1c7cc4` at start). All paths relative to `web/`.

## Global Constraints

- `src/lib/video-editor/` never imports kv/component code; `sample.ts` and `blocks.ts` must NOT import `presets.ts` (cycle: `presets → sample`). They import `./presetLabels` only.
- Bucket rule (exact): `in` = `startMs === 0` OR family `entrance`; `out` = `endMs === durationMs` OR family `exit`, and not already `in`; segment spanning `[0, durationMs]` is `in`; everything else `emphasis`. Segments processed in ascending `startMs`; at most one `in` and one `out` (first match wins; a second candidate falls to `emphasis`).
- Visible range: `startMs` = the `in` segment's `startMs` (else 0); `endMs` = the `out` segment's `endMs` (else `durationMs`). Sampler sets `opacity: 0` when `tMs < startMs || tMs > endMs`. A document with no `in`/`out` segment, or an `in` at 0 and `out` at `durationMs`, must sample **byte-for-byte** as before.
- Drag semantics: In bar → body-drag emits `onShiftTrack(trackId, deltaMs)`, left handle disabled, right handle stretch; Out bar → body-drag shifts the segment (today), right handle disabled, left handle stretch; Emphasis walls `[max(1, inEnd + 1), min(durationMs − 1, outStart − 1)]`.
- Build keyframes get `label: BUILD_CHANNEL_LABELS[channel]` (`Move`/`Scale`/`Rotate`/`Opacity`); `presetFamilyForLabel` returns `null` for them.
- Placeholders `+ In` / `+ Out` render whenever their bucket is empty. Band test id: `track-visible-band-<trackId>`.
- Tests: `bun test <path>`, `within(document.body)`, files < 45 KB. TDD per task. Commits `<type>(video-editor|kv-motion): …` ending with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`; no push.

---

### Task 1: `presetLabels.ts` — move the label→family rule below the sampler

**Files:** Create `src/lib/video-editor/presetLabels.ts`; Modify `src/lib/video-editor/presets.ts` (delete the moved declarations, add `export { … } from "./presetLabels"`); Test `src/lib/video-editor/presetLabels.test.ts`.

**Move verbatim:** `MotionPresetId`, `EmphasisPresetId`, `ENTRANCE_PRESET_IDS`, `EXIT_PRESET_IDS`, `EMPHASIS_PRESET_IDS`, `PRESET_LABELS`, `ENTRANCE_LABELS`, `EXIT_LABELS`, `EMPHASIS_LABELS`, `PresetFamily`, `presetFamilyForLabel`, `PATH_LABEL`. Anything in `presets.ts` that these depend on that is NOT pure data (writers, `PRESET_WRITERS`) stays. If `ENTRANCE_PRESET_IDS` is currently derived from `PRESET_WRITERS`' key order, replace it with a literal list in the same order and add a test asserting `Object.keys(PRESET_WRITERS)` equals `[...ENTRANCE_PRESET_IDS, ...EXIT_PRESET_IDS]` so the order cannot drift.

- [ ] Test: `presetLabels.test.ts` asserts `presetFamilyForLabel("Slide in left") === "entrance"`, `("Slide out right") === "exit"`, `("Pulse") === "emphasis"`, `("Path") === null`, `(undefined) === null`; and `import * as P from "./presets"` re-exports the same references (`P.PRESET_LABELS === L.PRESET_LABELS`).
- [ ] Implement the move; `presets.ts` re-exports so no other import changes.
- [ ] Run `bun test src/lib/video-editor` (whole dir) — everything that passed before still passes; `importBoundary.test.ts` green.
- [ ] Commit `refactor(video-editor): presetLabels — label sets and family lookup below the sampler`.

### Task 2: anchored bucket rule, visible range, emphasis walls

**Files:** Modify `src/lib/video-editor/blocks.ts` (`assignSegmentsToSlots` ~line 220; add `assignTrackSlots`, `trackVisibleRange`, `emphasisWalls`; keep `slotPlaceholderRegion` but make `in`/`out` return their region whenever `slots[kind].length === 0`); Test `src/lib/video-editor/blocks.slots.test.ts` (new).

**Interfaces produced:**
```ts
export function assignSegmentsToSlots(segments, durationMs, familyOf: (s: TrackSegment) => PresetFamily | null = () => null): Record<SlotKind, TrackSegment[]>;
export function assignTrackSlots(track: MotionTrack, durationMs: number): Record<SlotKind, TrackSegment[]>; // familyOf = presetFamilyForLabel(segmentLabel(track, s))
export function trackVisibleRange(track: MotionTrack, durationMs: number): { startMs: number; endMs: number };
export function emphasisWalls(track: MotionTrack, segment: TrackSegment, durationMs: number): { wallMin: number; wallMax: number };
```
- [ ] Tests (write first, derive expected values from the rule, not from running): lone emphasis-shaped segment at [1000,1600] with no label → `emphasis`, `in`/`out` empty; segment [300,800] labelled `Slide in left` → `in`; hand-authored [0,500] → `in`; [0,5000] → `in`; [4400,4900] labelled `Slide out right` → `out`; [4400,5000] unlabelled → `out`; two unlabelled mid segments → both `emphasis`; a second entrance-labelled segment after an `in` → `emphasis`. `trackVisibleRange`: no segments → `{0, 5000}`; in at [300,800] + out at [4400,5000] → `{300, 5000}`; only out at [4000,4500] → `{0, 4500}`. `emphasisWalls`: with in ending 500 and out starting 4400, segment [1000,1600] → `{501, 4399}`; with neither → `{1, 4999}`. `slotPlaceholderRegion("in")` returns a region when `in` is empty even though `emphasis` has a segment.
- [ ] Implement. Update the existing `blocks.test.ts` cases that encoded the elastic rule (a lone mid segment bucketed `in`) to the new rule — change the expectation, not the input, and say so in the commit body.
- [ ] Run `bun test src/lib/video-editor/blocks.slots.test.ts src/lib/video-editor/blocks.test.ts src/lib/video-editor/blocks.propGroups.test.ts src/lib/video-editor/blocks.propGroupDrag.test.ts`.
- [ ] Commit `feat(video-editor): anchored slot roles, track visible range, emphasis walls`.

### Task 3: sampler hides the layer outside its range; Build stamps labels

**Files:** Modify `src/lib/video-editor/sample.ts`, `src/lib/video-editor/presets.ts` (`applyBuildChannels` write + merge); Test `src/lib/video-editor/sample.visible.test.ts` (new), `src/lib/video-editor/presets.buildChannels.test.ts` (+2).

- [ ] Tests first. `sample.visible.test.ts`: (a) track with `Slide in left`-labelled [300,800] → `opacity` at 0 and 299 is `0`, at 300 equals the keyframe's own opacity (or rest), at 1000 rest; (b) out at [4400,4900] (`Slide out right`) → opacity 0 at 4901 and 5000; (c) **byte-for-byte**: for a track with an entrance at 0 and an emphasis, and for a track with no labels at all, `sampleTimelineAt` output `toEqual`s the output of a copy of the OLD function (paste the pre-change `sampleTimelineAt` body into the test as `legacySample` — it is ~40 lines); (d) a hand-authored first keyframe at 1000 (no label) hides nothing. `presets.buildChannels.test.ts`: one label per keyframe — the FIRST channel (host order) that wrote to it. Build `["move","scale"]` in `in` → both keyframes `label === "Move"`; `["scale"]` alone → `"Scale"`; `presetFamilyForLabel("Move") === null`.
- [ ] Implement: in `sampleTimelineAt`, after `resolved` is built for a track, `const range = trackVisibleRange(track, timeline.duration_ms); if (tMs < range.startMs || tMs > range.endMs) resolved.opacity = 0;`. Compute `range` once per track (hoist above the prop loop). In `applyBuildChannels`, stamp `label` on written keyframes (Path keeps `PATH_LABEL`); on merge keep the existing label if present.
- [ ] Run `bun test src/lib/video-editor` + `src/components/studio/kv-generator/motion/exportMotion.test.ts`. Add one export-level case there: a delayed entrance's frame at t=0 samples `opacity: 0` (through `remapTimelineForRatio` + `sampleTimelineAt`, as the file already does).
- [ ] Commit `feat(video-editor): layer hidden outside its In→Out range; Build bars read their channel`.

### Task 4: editor `shiftTrack`, dock drag semantics, placeholders, band

**Files:** Modify `src/components/video-editor/types.ts` (`onShiftTrack?: (trackId: string, deltaMs: number) => void`), `src/components/video-editor/TimelineDock.tsx` (pass-through), `src/components/video-editor/BlockTrackRow.tsx` (`SegmentBar`: per-slot handle/body rules + walls; lane: use `assignTrackSlots`, placeholders per rule, visibility band), `src/components/studio/kv-generator/motion/useMotionEditorState.ts` (`shiftTrack` via `shiftTrackKeyframes` + `push(next, `shift-track:${trackId}`)`), `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` (wire `onShiftTrack`); Tests `src/components/video-editor/TimelineDock.anchored.test.tsx` (new; copy helpers from `TimelineDock.slotmenu.test.tsx`), `src/components/studio/kv-generator/motion/useMotionEditorState.shiftTrack.test.ts` (new).

**`useBarDrag`** already takes `wallMin/wallMax`, `onShift`, `onStretch`. For the In bar pass `onShift: (…, delta) => onShiftTrack(trackId, delta)` and hide the left handle; for Out hide the right handle; walls from `emphasisWalls` for emphasis, `[0, durationMs]` for in/out stretch. Handles are the existing edge elements — render them conditionally per `slotKind`.

- [ ] Tests first. Dock: (1) a track with only Bounce at [1070,1670] renders `slot-placeholder-ov1-in` AND `slot-placeholder-ov1-out` AND the Bounce bar; (2) pointer-drag the In bar body by +200 ms → `onShiftTrack("ov1", 200)` called, `onShiftSegment` not; (3) emphasis bar dragged left past 0 → `onShiftSegment` delta clamps so `startMs` lands at `inEnd + 1` (or 1); (4) `track-visible-band-ov1` spans from In start to Out end (assert `style.left`/`width` percentages); (5) In bar has no left handle test id, Out bar no right handle. Hook: `shiftTrack("ov1", 300)` moves every keyframe by 300 and is one undo step.
- [ ] Implement. Copy for the band: none (aria-hidden decorative div); use `bg-white/[0.06]`-style tokens, no new hex.
- [ ] Run the two new tests + `TimelineDock.test.tsx`, `TimelineDock.slotmenu.test.tsx`, `TimelineDock.trackstretch.test.tsx`, `TimelineDock.pathpopover.test.tsx`, `TimelineDock.buildtab.test.tsx`; then the typecheck grep on touched files.
- [ ] Commit `feat(kv-motion): In drags the whole track; Out/Emphasis anchored; visibility band + always-present In/Out placeholders`.

### Task 5: full run + manual pass

- [ ] `bun test src/lib/video-editor src/components/video-editor src/components/studio/kv-generator/motion` — all green except the 3 pre-existing `useTimelineCommands` cases.
- [ ] Manual (dev server already serves this worktree): lone Bounce shows `+ In [Bounce] + Out`; drag In right → whole row moves, layer invisible before it, ⌘Z reverts; drag emphasis to the left edge → stops at 1 ms; Build Move in Emphasis → bar says `Move`; export MP4 of a delayed layer → blank before its entrance.
- [ ] Merge: `git checkout feature/daffa/vc-kv-motion-path && git merge --ff-only feature/daffa/vc-kv-motion-anchored-slots`.
