# Video Editor Directory Restructure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the generic timeline/video engine out of `motion` (which collides with an installed npm package of that name) into `video-editor`, without changing any behaviour.

**Architecture:** Two `git mv` operations plus mechanical import-specifier rewrites across 28 files. The engine's architecture guard (`importBoundary.test.ts`) is repointed and hardened, because it locates its targets by hardcoded path and silently skips missing ones — the rename would otherwise leave it green-but-dead. A README is added stating what the engine is and, critically, what it is not.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Bun (runtime + test runner), `bun --bun next build`.

**Spec:** `docs/superpowers/specs/2026-08-09-video-editor-dir-restructure-design.md`

## Global Constraints

- **Repo:** `web/` only. `api/` and `ai-service/` are untouched.
- **This is a pure rename.** Any observable behaviour change is a bug introduced by the move, not an outcome. No logic edits, no refactors, no "while I'm here" cleanups.
- **Do NOT rename any `Motion*` type.** `MotionTimeline`, `MotionTrack`, `MotionProps`, `MotionKeyframe`, `MotionAudio`, `MotionEasing`, `MotionPresetId` stay exactly as they are (293 occurrences, untouched).
- **Do NOT touch the persisted contract.** `MotionTrack.kind: "overlay"` and `overlay_id` stay. api stores this JSON opaquely in `kv_motion_projects.timeline`.
- **Do NOT rename the KV binding directory.** `src/components/studio/kv-generator/motion/` keeps its name — `motion` is the correct name for the KV product feature.
- **Do NOT touch `src/lib/featureFlags/constants.ts`.** `KV_MOTION_EDITOR: "show-kv-motion-editor"` is a live PostHog flag key, not a path. Renaming it silently disables the flag in every environment.
- **Do NOT edit `web/AGENTS.md`.** It is generated (`generate-agents.sh`).
- **Use `git mv`,** never delete-and-add — `git log --follow` must survive.
- **Test runner is `bun test`** (bunfig preloads jest-dom). Not `bunx vitest`. There is no `test` script in `package.json`.
- **The build is the real gate:** `bun run build`. There is no `typecheck` script.
- **Branch:** work on a `refactor/` branch off latest `develop`; this must land as one self-contained commit series with nothing else riding along.

## File Structure

**Moved wholesale (via `git mv`):**

| From | To | Files |
|---|---|---|
| `src/lib/motion/` | `src/lib/video-editor/` | 21 |
| `src/components/motion-editor/` | `src/components/video-editor/` | 13 |

**Edited (28 files total, import specifiers only):**

- 9 files inside `src/components/video-editor/` — they import the engine via the `@/` alias, so the move does not fix them: `BlockTrackRow.tsx`, `InspectorPanel.tsx`, `InspectorPanel.test.tsx`, `TimelineDock.test.tsx`, `TimelineRuler.tsx`, `TrackRow.tsx`, `types.ts`, `useTimelineCommands.ts`, `useTimelineCommands.test.tsx` (12 specifiers).
- 18 external consumer files (36 specifiers): 16 in `src/components/studio/kv-generator/motion/`, plus `src/services/kv/motionProjects.ts` and `src/types/kv/motionProject.ts`. All 18 import the engine (30 specifiers); 3 of them also import the engine UI (6 specifiers).

**Specifier totals to verify against:** 42 `@/lib/motion/` (12 internal + 30 external) and 6 `@/components/motion-editor/` (all external) = 48 rewritten in total.
- `src/lib/video-editor/importBoundary.test.ts` — `ROOTS` constant + silent-skip fix (Task 3).

**Created:**

- `src/lib/video-editor/README.md` (Task 4).

## Task Ordering Rationale

Task 1 moves the engine and fixes everything that points at it. Task 2 moves the engine UI. They are split because the engine UI is itself a consumer of the engine — doing both at once means a single commit where nothing compiles mid-way and a reviewer cannot tell which rewrite broke what. Task 3 repairs the guard the first two tasks would have silently disabled. Task 4 is the README. Each task ends green.

---

### Task 1: Move the engine (`lib/motion` → `lib/video-editor`)

**Files:**
- Move: `src/lib/motion/` → `src/lib/video-editor/` (21 files)
- Modify: 9 files in `src/components/motion-editor/` (12 import specifiers)
- Modify: 18 consumer files (30 import specifiers) — 16 in `src/components/studio/kv-generator/motion/`, plus `src/services/kv/motionProjects.ts`, `src/types/kv/motionProject.ts`
- Total rewritten in this task: 42 `@/lib/motion/` specifiers across 27 files

**Interfaces:**
- Consumes: nothing (first task).
- Produces: every engine module is importable at `@/lib/video-editor/<name>`. Module names are unchanged: `timeline`, `sample`, `presets`, `autokey`, `blocks`, `camera`, `audio`, `encode`, `previewRange`, `videoSafeDims`. All exported symbols keep their current names (`MotionTimeline`, `MotionTrack`, `MotionProps`, `MotionKeyframe`, `MotionAudio`, `MotionEasing`, `MotionPresetId`, `DEFAULT_TIMELINE`, …).

- [ ] **Step 1: Branch off latest develop**

```bash
cd web
git checkout develop && git pull origin develop
git checkout -b refactor/daffa/vc-video-editor-dir
```

- [ ] **Step 2: Record the pre-move baseline**

The suite must be green *before* the move, or a pre-existing red gets blamed on the rename.

```bash
bun test 2>&1 | tail -20
```

Write down the pass/fail counts. Expected: all green. If anything is already red, STOP and report it — do not proceed on a red baseline.

- [ ] **Step 3: Move the directory with git mv**

```bash
git mv src/lib/motion src/lib/video-editor
```

- [ ] **Step 4: Verify the move is staged as a rename, not delete+add**

```bash
git status --short | head -25
```

Expected: lines beginning with `R` (rename), e.g. `R  src/lib/motion/timeline.ts -> src/lib/video-editor/timeline.ts`. If you see `D` + `??` pairs instead, undo (`git reset && git checkout .`) and redo with `git mv`.

- [ ] **Step 5: Rewrite every `@/lib/motion/` import specifier**

This covers all three groups at once (engine UI, KV binding, services/types):

```bash
grep -rl '@/lib/motion/' src | xargs sed -i '' 's|@/lib/motion/|@/lib/video-editor/|g'
```

Note the `sed -i ''` form — this is macOS/BSD sed. On GNU sed use `sed -i` with no argument.

- [ ] **Step 6: Confirm zero remaining references**

```bash
grep -rn '@/lib/motion/' src
```

Expected: no output.

- [ ] **Step 7: Run the tests**

```bash
bun test 2>&1 | tail -20
```

Expected: same pass/fail counts as Step 2.

Note: `importBoundary.test.ts` will still pass here — but it is now silently checking nothing, because its `ROOTS` still names `src/lib/motion`, which no longer exists, and it swallows that with `catch { continue }`. Task 3 fixes this. Do not "fix" it here; keep this commit purely mechanical.

- [ ] **Step 8: Run the build**

```bash
bun run build
```

Expected: success. This is the gate that catches broken import paths.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor(web): move lib/motion to lib/video-editor

The directory collides with the installed "motion" npm package, so
@/lib/motion reads as an animation-library wrapper rather than the
timeline engine it is.

Pure rename: no type renamed, no logic touched, no persisted field
changed."
```

---

### Task 2: Move the engine UI (`components/motion-editor` → `components/video-editor`)

**Files:**
- Move: `src/components/motion-editor/` → `src/components/video-editor/` (13 files)
- Modify: exactly 3 consumer files, all in `src/components/studio/kv-generator/motion/` — `useMotionEditorState.ts`, `KvMotionAudioRow.tsx`, `KvMotionEditor.tsx` (6 specifiers total, spanning `types`, `useTimelineCommands`, `TimelineDock`, `InspectorPanel`). Nothing inside the moved directory imports itself via the alias, so the move needs no internal fixups here.

**Interfaces:**
- Consumes: `@/lib/video-editor/*` from Task 1.
- Produces: engine UI importable at `@/components/video-editor/<name>` — `TimelineDock`, `TimelineRuler`, `TrackRow`, `BlockTrackRow`, `TrackNameCell`, `Transport`, `InspectorPanel`, `useTimelineCommands`, `types`. Component and hook names are unchanged.

- [ ] **Step 1: Move the directory with git mv**

```bash
git mv src/components/motion-editor src/components/video-editor
```

- [ ] **Step 2: Verify the move is staged as a rename**

```bash
git status --short | head -20
```

Expected: `R` lines only.

- [ ] **Step 3: Rewrite every `@/components/motion-editor/` import specifier**

```bash
grep -rl '@/components/motion-editor/' src | xargs sed -i '' 's|@/components/motion-editor/|@/components/video-editor/|g'
```

- [ ] **Step 4: Confirm zero remaining references**

```bash
grep -rn '@/components/motion-editor/' src
```

Expected: no output.

- [ ] **Step 5: Confirm the only surviving "motion-editor" string is the feature flag**

```bash
grep -rn 'motion-editor' src
```

Expected: exactly one line — `src/lib/featureFlags/constants.ts:20` with `KV_MOTION_EDITOR: "show-kv-motion-editor"`. That is a PostHog flag key and MUST NOT be changed. If anything else appears, rewrite it.

- [ ] **Step 6: Run the tests**

```bash
bun test 2>&1 | tail -20
```

Expected: same counts as Task 1 Step 2.

- [ ] **Step 7: Run the build**

```bash
bun run build
```

Expected: success.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor(web): move components/motion-editor to components/video-editor

Pairs with the lib move so both halves of the engine share one name.
Pure rename: no component renamed, no logic touched."
```

---

### Task 3: Repoint and harden the import-boundary guard

`src/lib/video-editor/importBoundary.test.ts` asserts that the engine never imports KV domain modules. It finds its targets by hardcoded path string and, on a missing directory, does `catch { continue }` — a silent skip. After Tasks 1–2 it therefore reports green while checking **nothing**. This task makes it check the right directories, and makes a missing directory a loud failure so the same trap cannot re-arm on the next rename.

**Files:**
- Modify: `src/lib/video-editor/importBoundary.test.ts:6` and its `try/catch` block

**Interfaces:**
- Consumes: the new directory layout from Tasks 1–2.
- Produces: a live guard asserting no file under `src/lib/video-editor` or `src/components/video-editor` contains the strings `components/studio/kv-generator` or `lib/studio/kv`.

- [ ] **Step 1: Prove the guard is currently dead**

Before changing anything, confirm the problem is real rather than assumed:

```bash
bun test src/lib/video-editor/importBoundary.test.ts
```

Expected: PASS. Now verify that pass is meaningless — the roots it walks do not exist:

```bash
grep -n 'ROOTS' src/lib/video-editor/importBoundary.test.ts
ls src/lib/motion src/components/motion-editor
```

Expected: `ROOTS` still names `src/lib/motion` / `src/components/motion-editor`, and `ls` reports both as missing. A green test over zero files is the bug.

- [ ] **Step 2: Repoint `ROOTS` and make a missing root fail**

Replace line 6 and the `try/catch` inside the loop.

Current:

```ts
const ROOTS = ["src/lib/motion", "src/components/motion-editor"];
```

```ts
      let files: string[] = [];
      try {
        files = walk(join(process.cwd(), root));
      } catch {
        continue; // root not created yet — fine while tasks land
      }
```

New:

```ts
const ROOTS = ["src/lib/video-editor", "src/components/video-editor"];
```

```ts
      // No try/catch: a missing root means this guard is silently checking
      // nothing, which is how it survived the motion -> video-editor rename
      // reporting green. Let walk() throw.
      const files = walk(join(process.cwd(), root));
```

- [ ] **Step 3: Run the guard**

```bash
bun test src/lib/video-editor/importBoundary.test.ts
```

Expected: PASS — and this time over 30 real files.

- [ ] **Step 4: Prove the guard is live (deliberate violation)**

A guard never observed failing is indistinguishable from a disabled one. Temporarily add this as the first line of `src/lib/video-editor/timeline.ts`:

```ts
import { OpacityField } from "@/components/studio/kv-generator/overlays/OpacityField";
```

(The guard reads files as text and matches on the substring
`components/studio/kv-generator` — it never imports or resolves anything, so
this line only has to *exist*, not type-check.)

Then:

```bash
bun test src/lib/video-editor/importBoundary.test.ts
```

Expected: **FAIL**, with a message naming `timeline.ts` and `components/studio/kv-generator`.

- [ ] **Step 5: Remove the deliberate violation and re-confirm green**

Delete the line added in Step 4, then:

```bash
bun test src/lib/video-editor/importBoundary.test.ts
git diff --stat src/lib/video-editor/timeline.ts
```

Expected: PASS, and `git diff` reports **no** changes to `timeline.ts` — the violation is fully removed.

- [ ] **Step 6: Prove the missing-root failure works**

```bash
git mv src/components/video-editor src/components/video-editor-tmp
bun test src/lib/video-editor/importBoundary.test.ts
```

Expected: **FAIL** (ENOENT from `walk`), not a silent pass. Then restore:

```bash
git mv src/components/video-editor-tmp src/components/video-editor
bun test src/lib/video-editor/importBoundary.test.ts
```

Expected: PASS.

- [ ] **Step 7: Run the full suite and build**

```bash
bun test 2>&1 | tail -20
bun run build
```

Expected: same counts as the Task 1 baseline; build succeeds.

- [ ] **Step 8: Commit**

```bash
git add src/lib/video-editor/importBoundary.test.ts
git commit -m "test(web): repoint the engine import guard, and fail on a missing root

The guard located its targets by hardcoded path and swallowed a missing
directory with catch/continue, so the rename left it green while walking
zero files. Repointed, and a missing root now throws — otherwise the same
trap re-arms for the next move."
```

---

### Task 4: Add the engine README

The rename relocates the reader's guess; it does not answer it. This file answers it — above all point 2, which corrects the misconception the old directory name actively taught.

**Files:**
- Create: `src/lib/video-editor/README.md`

**Interfaces:**
- Consumes: the final directory layout.
- Produces: documentation only. No code depends on this.

- [ ] **Step 1: Write the README**

```markdown
# video-editor

A generic timeline/video editing engine: a keyframe timeline model, a sampler,
presets, a preview camera, and client-side MP4 encode (WebCodecs via
Mediabunny).

## This is not the `motion` npm package

If you are looking for an animation library, you want `motion` or
`framer-motion` from `package.json`. This directory has nothing to do with
either. It used to be called `lib/motion`, which is exactly the confusion this
name exists to end.

## KV Motion is the first consumer, not the owner

Nothing in here is KV-specific, and it must stay that way —
`importBoundary.test.ts` enforces it by failing if any file here imports
`components/studio/kv-generator` or `lib/studio/kv`.

Today the only consumer is the KV Motion feature. That is a fact about the
present, not a constraint on the design.

## Layout

- `src/lib/video-editor/` — engine. `timeline.ts` (the document model),
  `sample.ts` (resolve props at time *t*), `presets.ts`, `autokey.ts`,
  `blocks.ts`, `camera.ts`, `audio.ts`, `encode.ts` (MP4), `previewRange.ts`,
  `videoSafeDims.ts`.
- `src/components/video-editor/` — engine UI. `TimelineDock`, `TimelineRuler`,
  `TrackRow`, `BlockTrackRow`, `TrackNameCell`, `Transport`, `InspectorPanel`,
  `useTimelineCommands`.

## Why the types are called `Motion*`

`MotionTimeline`, `MotionTrack`, `MotionProps` and friends keep the `Motion`
prefix on purpose. "Motion" is standard vocabulary for animation data inside a
video editor (motion graphics); what collided with the npm package was the
import path, and that is now fixed. `import type { MotionTimeline } from
"@/lib/video-editor/timeline"` is unambiguous.

## Extension point: `kind: "clip"`

`MotionTrack.kind` currently only admits `"overlay"` — a KV overlay layer
animated over a frozen base image. `"clip"` (video-as-layer) is reserved in the
type and **not implemented**. That is the seam to open for real video editing.

Note that `MotionTrack` is a **persisted** contract: api stores the timeline
document opaquely in `kv_motion_projects.timeline`. Renaming `overlay_id` or
adding a required field needs a `version` bump and backward-compatible reads.

## Adding a consumer

`src/components/studio/kv-generator/motion/` is the reference binding — it is
the whole integration surface, and it is small:

- `applyTimeline.ts` — sampled props onto the render target
- `exportMotion.ts` — drive `encode.ts` to an MP4
- `useMotionEditorState.ts` — editor state, undo, autosave
```

- [ ] **Step 2: Verify every factual claim in the README**

Do not commit documentation you have not checked. Confirm each:

```bash
grep -E '"(motion|framer-motion|mediabunny)"' package.json
grep -n 'kind' src/lib/video-editor/timeline.ts
grep -n 'FORBIDDEN\|ROOTS' src/lib/video-editor/importBoundary.test.ts
ls src/lib/video-editor src/components/video-editor
ls src/components/studio/kv-generator/motion/
```

Expected: `motion`/`framer-motion`/`mediabunny` all present; `kind: "overlay"` with the `"clip"` reservation comment; guard pointing at the new roots; both directories present with the listed files; the three reference-binding files present.

- [ ] **Step 3: Commit**

```bash
git add src/lib/video-editor/README.md
git commit -m "docs(web): explain what the video-editor engine is, and what it is not"
```

- [ ] **Step 4: Final whole-repo verification**

```bash
bun test 2>&1 | tail -20
bun run build
grep -rn 'lib/motion\|motion-editor' src
git log --follow --oneline src/lib/video-editor/timeline.ts | head -5
```

Expected, in order: suite green at the Task 1 baseline counts; build succeeds; `grep` returns **only** the `featureFlags/constants.ts` flag-key line; `git log --follow` shows commit history from before the rename.

- [ ] **Step 5: Push**

```bash
git push -u origin refactor/daffa/vc-video-editor-dir
```

Then open a PR against `develop`. In the PR body, state plainly that this is a pure rename and that the only non-mechanical change is the import-boundary guard in Task 3 — a reviewer's one real check is "is this purely a move?", so make that check easy to run.
