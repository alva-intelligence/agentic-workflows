# Video Editor — Directory Restructure — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-08-09
> **Services:** web only (api, ai-service untouched)
> **Topic slug:** video-editor-dir-restructure
> **Related:** `2026-08-02-kv-motion-timeline-editor-design.md` (built the engine being moved)

## Overview

Move the generic timeline/video engine out from under the name `motion` and
into `video-editor`, so that its name states what it is:

```
src/lib/motion/               →  src/lib/video-editor/          (21 files)
src/components/motion-editor/ →  src/components/video-editor/   (13 files)
```

This is a **pure rename**. No behaviour changes, no data-model changes, no API
changes. Any observable difference in runtime behaviour after this change is a
bug introduced by the move, not an intended outcome.

## Rationale

Two problems, one of which is active today rather than hypothetical.

**1. `motion` is a real npm package in this repo.** `web/package.json` ships
both `"motion": "^12.23.24"` and `"framer-motion": "^11.18.2"`. So `src/lib/motion/`
collides head-on with an installed animation library. A reader — human or LLM
agent — who encounters `@/lib/motion/...` has every reason to assume it wraps
that package. It does not: it is a timeline engine with keyframes, a sampler,
and an MP4 encoder.

**2. The name undersells the thing and blocks reuse.** The directory holds a
general-purpose video editing core (timeline model, tracks, transport,
inspector, asset handling, MP4 encode). Naming it after the one KV feature that
currently consumes it makes it invisible to anyone looking for a video editor,
and invites a second, duplicate implementation the next time video editing is
needed.

The fix separates two distinct meanings of the word "motion" that are currently
conflated:

| Level | Name | Verdict |
|---|---|---|
| KV product feature | route `/motion/[projectId]`, table `kv_motion_projects`, model `KvMotionProject` | Stays `motion` — correct feature name, consistent through to api |
| KV binding layer | `components/studio/kv-generator/motion/` | Stays `motion` — it implements the KV Motion feature |
| Generic engine | `lib/motion/`, `components/motion-editor/` | Moves to `video-editor` — it is not a KV concept |

After this change: `motion` = the KV feature; `video-editor` = the reusable
engine. The ambiguity disappears without renaming anything user-facing.

## Current state (verified 2026-08-09 against `origin/develop`)

All 34 files are merged on `origin/develop`. No open branch touches either
directory, so the rename window is conflict-free at time of writing.

**Engine — `src/lib/motion/` (21 files, zero KV references):**
`timeline.ts`, `sample.ts`, `presets.ts`, `autokey.ts`, `blocks.ts`,
`camera.ts`, `audio.ts`, `encode.ts`, `previewRange.ts`, `videoSafeDims.ts`,
plus `audio/autokey/blocks/camera/encode/presets/previewRange/sample/
videoSafeDims` tests and `importBoundary.test.ts`,
`konvaPointerContract.test.ts`.

**Engine UI — `src/components/motion-editor/` (13 files):**
`TimelineDock.tsx`, `TimelineRuler.tsx`, `TrackRow.tsx`, `BlockTrackRow.tsx`,
`TrackNameCell.tsx`, `Transport.tsx`, `InspectorPanel.tsx`,
`useTimelineCommands.ts`, `types.ts`, plus tests.

**Consumers — 18 files, 47 import statements, all `@/`-aliased:**
16 in `src/components/studio/kv-generator/motion/`, plus
`src/services/kv/motionProjects.ts` and `src/types/kv/motionProject.ts`.

Every consumer is KV. That is the point: the engine's boundary is already
clean — only its name is wrong. There are no barrel files (`index.ts`) in
either directory and no relative imports crossing the boundary, so the move
has no hidden re-export surface.

## Scope

### In scope

- `git mv` both directories to their new names.
- Rewrite the 47 import specifiers in the 18 consumer files:
  - `@/lib/motion/` → `@/lib/video-editor/`
  - `@/components/motion-editor/` → `@/components/video-editor/`
- Add `src/lib/video-editor/README.md` (see below).

### Explicitly out of scope

- **Type names stay `Motion*`.** `MotionTimeline`, `MotionTrack`, `MotionProps`,
  `MotionKeyframe`, `MotionAudio`, `MotionEasing`, `MotionPresetId` are
  unchanged — 293 occurrences left untouched. What collided with the npm
  package was the *import path*, and `import type { MotionTimeline } from
  "@/lib/video-editor/timeline"` carries no ambiguity: the path says video
  editor, the type says motion data. "Motion" is also standard vocabulary for
  animation data inside a video editor (motion graphics). Renaming would add
  293 lines of churn that serve no reader.
- **The persisted contract is untouched.** `MotionTrack.kind: "overlay"` and
  `overlay_id` stay as-is. This JSON is stored opaquely by api in
  `kv_motion_projects.timeline`; generalising it to `layer_id` would require a
  version bump plus backward-compatible reads for zero present-day benefit.
  `timeline.ts` already reserves `kind: "clip"` for video-as-layer, so the
  extension point survives.
- **The KV binding layer keeps its name.** `studio/kv-generator/motion/` is the
  KV Motion feature implementation, and `motion` is its correct name.
- **`web/AGENTS.md` is not edited.** It carries a
  `Do not edit manually — regenerated by generate-agents.sh` banner. If an
  agent-level pointer stronger than the README is wanted, it has to go through
  the generator source — a separate decision.

## The README (the actual deliverable)

A rename relocates the guess; it does not answer it. `src/lib/video-editor/README.md`
states, in prose:

1. **What this is** — a generic timeline/video editing engine. KV Motion is its
   first consumer, not its owner.
2. **What this is not** — not the `motion` npm package. Readers looking for an
   animation library want `motion` / `framer-motion` from `package.json`.
3. **The extension point** — `MotionTrack.kind` is currently only `"overlay"`;
   `"clip"` is reserved for video-as-layer and not implemented.
4. **How to add a consumer** — point at `studio/kv-generator/motion/`
   (`applyTimeline`, `exportMotion`, `useMotionEditorState`) as the reference
   binding.

Point 2 is the one that pays for the file: it is the misconception the old name
actively taught, and the only place it can be corrected in words.

## Verification

The move is mechanical, so verification is about proving nothing moved that
should not have:

1. `bun run build` — the real gate. Catches every broken import path.
   (`tsc` is not the gate here; the build is.)
2. `bun test` — the 15 relocated test files (11 in the engine, 4 in the engine
   UI) must pass **with their contents unedited apart from import paths**. If a
   test needs a logic change to pass, the move broke something.
3. `grep -rE "@/(lib/motion|components/motion-editor)/" src` returns nothing.
4. `git log --follow src/lib/video-editor/timeline.ts` still shows pre-move
   history — confirms `git mv` was used rather than delete-and-add.

## Risks

**Merge conflicts — the only material risk.** 34 files move at once. The window
is clean today (no branch touches these paths), but that is a perishable fact.
Mitigation: land this as a single self-contained `refactor(web):` commit, merged
promptly, with no other changes riding along. Anything else in the same commit
makes the diff unreviewable — a reviewer's only real check is "is this purely a
move?", and unrelated edits destroy that check.

**History loss** if the move is staged as delete + add rather than `git mv`.
Mitigation: verification step 4.

## Acceptance criteria

- [ ] `src/lib/motion/` and `src/components/motion-editor/` no longer exist.
- [ ] `src/lib/video-editor/` (21 files) and `src/components/video-editor/`
      (13 files) exist, byte-identical to their pre-move contents — the move
      changes no file inside either directory, since all intra-directory
      imports are relative (`./timeline`) and survive relocation untouched.
- [ ] 18 consumer files import from the new paths; no `@/lib/motion/` or
      `@/components/motion-editor/` specifier remains anywhere in `src/`.
- [ ] `src/lib/video-editor/README.md` exists and covers all four points above.
- [ ] `bun run build` passes.
- [ ] `bun test` passes with no test-body edits.
- [ ] `git log --follow` resolves history through the rename.
- [ ] No `Motion*` type was renamed; no persisted-contract field was renamed.
- [ ] `web/AGENTS.md` is unmodified.
