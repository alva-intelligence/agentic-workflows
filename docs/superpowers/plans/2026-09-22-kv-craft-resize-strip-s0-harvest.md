# KV Craft Resize Strip — S0 Harvest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task (this project runs inline, no subagents). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the ten canvas-agnostic Resize modules (and their tests) from `feature/daffa/vc-kv-resize-unified-canvas` onto a fresh branch off `develop`, with no new consumers, so S1–S3 can import them.

**Architecture:** Straight file copy via `git checkout <branch> -- <paths>` (not commit cherry-pick — the branch commits also touch `KvResizeCanvas.tsx`, which is NOT harvested). `resizeBoardLayout.ts` is byte-identical on both branches, so every harvested import resolves on develop unchanged.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, `bun test` (bunfig preloads jest-dom), build via `node ./node_modules/next/dist/bin/next build`.

**Spec:** `docs/superpowers/specs/2026-09-22-kv-craft-resize-strip-design.md` §Slices → S0.

## Global Constraints

- Work inside `web/` (nested git repo). Branch: `feature/daffa/vc-kv-craft-resize-strip` off `origin/develop`.
- **Commit locally only. Never push, never open a PR** (Daffa's mandate 2026-09-22).
- **Never `git stash`.** Baselines come from a worktree.
- Tests: `bun test <explicit file paths>` — never a directory (memory blow-up). Build: `node ./node_modules/next/dist/bin/next build`, never `bun run build`.
- No import of any harvested module from `KvFabricCanvas.tsx` in this slice.
- Commit message format `<type>(web): <description>`, trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Branch + baseline

**Files:** none changed.

- [ ] **Step 1: Create the branch from up-to-date develop**

```bash
cd web && git fetch origin develop --quiet && git checkout -b feature/daffa/vc-kv-craft-resize-strip origin/develop
```
Expected: `Switched to a new branch 'feature/daffa/vc-kv-craft-resize-strip'`.

- [ ] **Step 2: Record the tsc baseline (repo-wide count; it is NOT clean at baseline)**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS" | tee /private/tmp/claude-501/-Users-alva-e202511001-Desktop-work-frndos-agentic/1680fa68-8110-48ef-be28-006eba99254f/scratchpad/tsc-baseline.txt
```
Expected: a number in the hundreds. Only NEW errors naming touched files matter later.

### Task 2: Copy the ten modules and their tests

**Files:**
- Create (from branch): `web/src/components/studio/kv-generator/{resizeWorldGeometry,resizeToolGesture,resizeBoardOverlays,resizeCommitRouting,resizeSelectionSource,resizeBoardCamera,resizeCandidatePick,resizeFrameGesture}.ts` + `.test.ts`
- Create (from branch): `web/src/components/studio/kv-generator/{KvBoardStatusLayer,KvFrameBoxLayer}.tsx` + `.test.tsx`

**Interfaces produced (used by S1–S3):**
- `resizeWorldGeometry.ts`: `absoluteTransformOf(obj: fabric.FabricObject): WorldTransform`, `normalizedFromWorld(...)` (wraps `overlayNormFromRect`).
- `resizeToolGesture.ts`: `type WorldPoint = {x,y}`, `boardAtWorldPoint(boards: ResizeBoard[], p: WorldPoint)`, `normalizedPointInBoard(board, p)`, `shapeRectFromDrag(input)`, `MIN_SHAPE_DRAG_SCREEN_PX = 12`.
- `resizeBoardOverlays.ts`: `resolveBoardOverlays(board, projectOverlays, sourceW, sourceH): StudioOverlay[]` — THE single resolver (inheriting vs snapshot).
- `resizeCommitRouting.ts`: `type ResizeCommitTarget = {kind:"master"} | {kind:"tile", row: KvResizeExport}`, `resolveCommitTarget(boards, boardId)`, `baselineOverlaysFor(board, projectOverlays, w, h)`.
- `resizeSelectionSource.ts`: `selectableIdsForBoard(...)`.
- `resizeBoardCamera.ts`: `cameraToRevealBoard(board, camera, viewport)`.
- `resizeFrameGesture.ts`: `frameBoxFromWorldDrag(...)`, `boardViewportRect(board, camera)`.
- `resizeCandidatePick.ts`: `nextBoxesForPick(...)`.
- `KvBoardStatusLayer.tsx`: `<KvBoardStatusLayer row={KvResizeExport} displayWidth displayHeight onRetry onCancel />` — returns null for `done`.
- `KvFrameBoxLayer.tsx`: frame-tool box chrome in display px.

- [ ] **Step 1: Copy the files**

```bash
cd web && K=src/components/studio/kv-generator && git checkout origin/feature/daffa/vc-kv-resize-unified-canvas -- \
  $K/resizeWorldGeometry.ts $K/resizeWorldGeometry.test.ts \
  $K/resizeToolGesture.ts $K/resizeToolGesture.test.ts \
  $K/resizeBoardOverlays.ts $K/resizeBoardOverlays.test.ts \
  $K/resizeCommitRouting.ts $K/resizeCommitRouting.test.ts \
  $K/resizeSelectionSource.ts $K/resizeSelectionSource.test.ts \
  $K/resizeBoardCamera.ts $K/resizeBoardCamera.test.ts \
  $K/resizeCandidatePick.ts $K/resizeCandidatePick.test.ts \
  $K/resizeFrameGesture.ts $K/resizeFrameGesture.test.ts \
  $K/KvBoardStatusLayer.tsx $K/KvBoardStatusLayer.test.tsx \
  $K/KvFrameBoxLayer.tsx $K/KvFrameBoxLayer.test.tsx && git status --porcelain | wc -l
```
Expected: `20` added files.

- [ ] **Step 2: Run the eight pure test files together**

```bash
cd web && K=src/components/studio/kv-generator && bun test $K/resizeWorldGeometry.test.ts $K/resizeToolGesture.test.ts $K/resizeBoardOverlays.test.ts $K/resizeCommitRouting.test.ts $K/resizeSelectionSource.test.ts $K/resizeBoardCamera.test.ts $K/resizeCandidatePick.test.ts $K/resizeFrameGesture.test.ts 2>&1 | tail -6
```
Expected: `0 fail`.

- [ ] **Step 3: Run the two component test files (separately — RTL under bun is fragile)**

```bash
cd web && K=src/components/studio/kv-generator && bun test $K/KvBoardStatusLayer.test.tsx 2>&1 | tail -4; bun test $K/KvFrameBoxLayer.test.tsx 2>&1 | tail -4
```
Expected: `0 fail` each. If a failure is the repo-wide `screen`-under-bun problem (error mentions `screen` / `getByRole` on `screen`), record it as baseline-class in the commit body and continue.

- [ ] **Step 4: tsc — no new errors naming the harvested files**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "resize(WorldGeometry|ToolGesture|BoardOverlays|CommitRouting|SelectionSource|BoardCamera|CandidatePick|FrameGesture)|KvBoardStatusLayer|KvFrameBoxLayer" | head
```
Expected: no output.

- [ ] **Step 5: Confirm nothing imports them yet**

```bash
cd web && grep -rl "resizeWorldGeometry\|resizeToolGesture\|resizeBoardOverlays\|resizeCommitRouting\|resizeSelectionSource\|resizeBoardCamera\|resizeCandidatePick\|resizeFrameGesture\|KvBoardStatusLayer\|KvFrameBoxLayer" src --include='*.ts' --include='*.tsx' | grep -v "\.test\." | grep -v "src/components/studio/kv-generator/\(resize\|Kv\(BoardStatus\|FrameBox\)Layer\)"
```
Expected: no output (only the modules themselves reference each other).

- [ ] **Step 6: Commit**

```bash
cd web && git add src/components/studio/kv-generator && git commit -q -m "chore(web): harvest the canvas-agnostic Resize modules from vc-kv-resize-unified-canvas

Ten modules + tests copied verbatim (git checkout <branch> -- paths); no
consumers yet. resizeBoardLayout.ts is identical on both branches so every
import resolves. The 3200-line KvResizeUnifiedCanvas is deliberately NOT
brought over — see docs/superpowers/specs/2026-09-22-kv-craft-resize-strip-design.md
decision 5.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" && git log -1 --format='%h %s'
```

### Task 3: Build gate

- [ ] **Step 1: Production build under node**

```bash
cd web && node ./node_modules/next/dist/bin/next build 2>&1 | tail -5
```
Expected: route table printed, exit 0. (Build does not type-check — Task 2 Step 4 is the type gate.)

---

## Self-review

- Spec coverage: S0 DoD = module tests green (T2 S2–S3), build clean (T3), no import from `KvFabricCanvas` (T2 S5). ✔
- Branch-B close-out note in its track file is deferred to S3's end (the track file lives on branch B; editing it means touching that branch — done once, at the end).
- No placeholders; all commands concrete.
