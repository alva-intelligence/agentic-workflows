# KV Canvas Unification — Handoff

> **Written:** 2026-08-12 · **For:** whoever picks this up in a new session
> **Read this first.** It is the whole state of the project in one place.

## What this project is

KV renders the same thing — a board with a base image and a stack of overlays — through several separate implementations. Every drawing rule has to be restated in each one, and each restatement is a chance for the on-screen preview to stop matching the downloaded file. That has already shipped bugs.

The goal: **one live engine (Fabric) with two views (Craft and Resize)**, so a drawing rule lives in one place. The download/flatten path stays Konva and is already shared — it is not being touched.

Konva does **not** disappear. After the whole project: Fabric for what you see and edit, Konva for what you download and for the Motion editor.

**Governing spec:** `docs/superpowers/specs/2026-08-10-kv-canvas-surface-unification-design.md` (in this repo, `agentic-workflows`). Read it before touching anything.

## Where things stand

### Shipped to `frnd-web` develop

| What | How |
|---|---|
| Two board-name data-loss bugs | commits `4f99689b`, `0cc89935` — merged straight to develop |
| Step 1 + 2a — one geometry module, five renderers on it, `KvSurface` | **PR #425, merged** |

### Open

**PR #426** — `improvement/daffa/vc-kv-board-doc-participation` → develop. Board-doc participation: a surface declares `docBoardId` + `layout`, two gates consume the rules. Review is clean (Critical 0 / High 0 / Medium 0 / Security 0), all threads resolved. **Waiting on merge.** 8 commits ahead of develop.

### Not started

Steps 3 and 4. Step 2b was **absorbed into step 3** — see the spec; the layout seam turned out to already exist.

## Outstanding debts — read before adding features

1. **No manual browser verification has ever been done**, for any of this. `KvFabricCanvas.tsx` cannot be component-tested (Fabric needs a real 2D canvas context; jsdom has none), so the canvas people use daily rests on type-check, build, and reading. **This is the single biggest risk in the project.**
2. **A user-visible change is already live on develop and unverified:** legacy text overlays (created before `payload.fontSize` existed) now render at full box height instead of `0.8 ×`, so they look ~25% larger in the editor. That is correct — it matches what those files have always downloaded as — but nobody has looked at it.
3. `docMoveBoard` and `docSetMasterBoard` write the doc with no participation check. Unreachable today; step 3 must not wire `onResetBoardPosition` / `onSetMaster` to a view-positioned surface.
4. A stray lead never chased: `docRenameBoard` was once observed being called with an empty string just before the real name. Harmless in the observed ordering; the trigger is unknown.
5. `data-service` does not start — its ClickHouse credential check fails although the endpoint itself answers. Owner: kemal/iru. Unrelated to this project.

## Next: step 3a

Step 3 is too large for one cycle. Split it three ways; **do 3a first.**

### 3a — render Resize tiles as boards, read-only

**Why this one first, and not more:** the two gates PR #426 built have never actually run. Nothing in production produces a surface with `docBoardId: null` or `layout: "view"` — they are proven only through pure functions. 3a creates the first such surface. If Craft's `canvas_state` stays clean after opening the Resize tab, the gates are proven in the real world.

**Scope:** Resize's tiles appear as boards in the Fabric world, laid out as a vertical column, read-only. No chrome, no editing, no actions. The old Resize surfaces stay in place — this renders alongside, or behind a flag, so nothing is removed yet.

**What it needs:**
- A pure column-layout function: given surfaces in order, produce centres. Same x, increasing y, spaced by each board's height plus a gap. (`BOARD_WORLD_WIDTH` already gives every board the same world width with height from aspect — which is exactly how Resize lays rows out today.)
- A producer that builds `KvSurface` values from resize exports: `docBoardId: null`, `layout: "view"`, `imageUrl` from the export, `fallbackAspect` from its target width/height, `label` from the platform name. Note `KvResizeExport` in `src/types/kv/resize.ts` maps onto `KvSurface` field-for-field already.
- The master row is a **Craft board**: `docBoardId` = its generation id, `layout: "view"`. That combination is the whole reason the model has two fields — do not collapse it.
- A per-view "boards are not draggable" switch. Board dragging is already gated on `selectable: tool === "cursor"`, so this is a prop, not a mechanism.

**Definition of done for 3a:**
- Opening the Resize tab renders every tile as a board in a vertical column, master on top, in the same order as today's rows.
- Each tile shows its own image at its own aspect ratio.
- **`metadata.kv_canvas.artboards` gains no entry for any export id.** Verify directly in Postgres, not by reading code — see the query below. This is the acceptance test for the whole of PR #426.
- Craft's artboard centres are unchanged after opening and closing the Resize tab. Verify in Postgres.
- Boards cannot be dragged in the Resize view.
- A pure test covers the column layout: order, spacing, and that a tile's centre never depends on persisted artboard state.
- Test suite shows no new failures against the develop baseline; `bun run build` clean.
- Craft is untouched — open a multi-board KV, confirm positions, captions and drag-persist all still work.

### 3b — chrome and actions

Per-tile chrome as DOM positioned via `worldPointToScreen`: platform label, download dropdown, regenerate toggle, generating skeleton, failed-state card with Retry/Discard. Wire the existing handlers.

**DoD:** every action that works in Resize today works in the new view — regenerate, cancel, retry, discard, download one, download all — and the existing PostHog events still fire.

### 3c — editing

Overlay selection and editing on tiles and on the master row, with the two sinks: tile overlays → REST per export (`updateOverlays.mutate({ exportId, overlays })`), master row overlays → the Yjs doc (`handleCommitProjectOverlays`).

**DoD:** an edit on a tile persists to REST and never reaches the doc; an edit on the master row reaches the doc and shows up in Craft. Verify both in the database.

### Step 4 — delete the old surfaces

`KvResizeTileStage`, `KvTileOverlayEditor`, the Konva half of `KvResizeResultRow`, and `KvKonvaCanvas` (~1,900 lines).

**Blocker:** `KvKonvaCanvas` exists as a kill switch a reviewer asked for when multi-board landed. Confirm with that reviewer before deleting it.

**Then, free:** ghosted overflow becomes one inverted clip, and the transform box of an overflowing layer becomes visible in Resize — the two things that started this whole project.

## How to resume in a new session

**1. Orient.** Read the governing spec, then `2026-08-11-kv-board-doc-participation-design.md`. Both are in `docs/superpowers/specs/` in this repo.

**2. Check what landed while you were away.**

```bash
cd web && git fetch origin --prune && gh pr view 426 --json state,mergedAt
```

If #426 merged, start 3a from a fresh branch off develop. If not, base 3a on `improvement/daffa/vc-kv-board-doc-participation`.

**3. Start services.** From the workspace root: `./run-all.sh`. Expect `data-service` to fail (debt 5 above); the others are enough. Health-check by process, not by curl — the sandboxed shell's HTTP probes are unreliable here:

```bash
lsof -nP -iTCP:3000 -sTCP:LISTEN
```

**4. The database query that matters.** This is how you verify the gates for real:

```bash
psql -h 127.0.0.1 -p 5432 -d frnd -tAc \
  "select jsonb_pretty(metadata->'kv_canvas') from studio_files where id='<file-id>';"
```

Compare `artboards` before and after opening the Resize tab. Any key that is an export id rather than a generation id is a failure.

**5. Process.** This project has used, in order: `superpowers:brainstorming` → `superpowers:writing-plans` → `superpowers:subagent-driven-development`. It has caught real defects at every stage, including two that per-task reviews structurally could not find. Keep using it.

## Things this codebase will bite you with

- Tests run with `bun test` from `web/`, **never** `bunx vitest`. There is no type gate in the build — run `bunx tsc --noEmit` separately, and it is **not clean at baseline** (~566 errors). Only new errors naming your files matter.
- The suite has ~122 pre-existing failures from a repo-wide problem (React Testing Library's `screen` is broken under bun). **Record the baseline before you start.** The bar is "no new failures", not green.
- **Never `git stash`** in this working tree. A stale stash once corrupted files with conflict markers. Use a worktree to compare against a baseline: there is already one at `.worktrees/web-baseline`.
- `web/` is a nested git repo. Run git with your cwd **inside** it, or you silently target the workspace repo.
- `develop` may be checked out in another worktree, so `git checkout develop` in `web/` can fail. That is not an error — check whether the ref is already current before reacting.
- The canvas renders from the **Yjs doc**, not from the database. When the screen and the database disagree, that is why. Query the database before believing either.
- The canvas-state PATCH is a **full replace**. Anything the doc does not know, the server forgets.

## The hardest-won lesson

Three separate bugs in this project were found by **instrumenting and reproducing**, not by reading code. Every time a hypothesis was formed from reading alone, it was wrong — three times in a row on the board-name bug. When the screen and the database disagree, add a log at the write point and the read point, reproduce once, and read the output. It is faster than it feels.

---

## 2026-09-22 — direction change: ONE view, the strip. Read this before anything above.

The "two views" framing above is superseded. Product decision (daffa, 2026-09-22, Figma
`KV-Generator` node `73-16650`): Resize tiles render INSIDE the Craft canvas as a vertical
"Resizes" strip below the Craft boards; the Resize tab goes away; the platform picker is a
Craft bottom-nav button for the active board. The per-surface participation model
(`docBoardId` + `layout`) is exactly what makes a shared view possible — so this lineage
continues; the standalone `KvResizeUnifiedCanvas` branch does not (its modules were harvested).

- Spec: `docs/superpowers/specs/2026-09-22-kv-craft-resize-strip-design.md`
- Plans: `docs/superpowers/plans/2026-09-22-kv-craft-resize-strip-s{0,1,2,3}-*.md`
- Track: `web/docs/tracks/kv-craft-resize-strip.track.md` (branch `feature/daffa/vc-kv-craft-resize-strip`, local only)
- S0–S3b implemented 2026-09-22/23. **S4 done 2026-09-23/24** on
  `feature/daffa/vc-kv-craft-resize-strip` (web, pushed; no PR yet by Daffa's decision): the
  Resize tab and the per-tile editor path (20 modules / 9.3k lines), the KV_RESIZE_UNIFIED_CANVAS
  and KV_RESIZE_MASTER_EDIT flags, and — on Daffa's call after the reviewer handed it back —
  `KvKonvaCanvas` + the KV_MULTI_BOARD kill switch are deleted. PRD re-signed (fahrizky + Jeff).
  The strip is the only Resize surface. Runtime checklist (AC-11) + PostHog live events are
  Daffa's. Tech debt still parked: the overflow part of a cover-scaled tile layer is clickable
  outside the tile clip (track file, "TECH DEBT").
- Step 3a/3b/3c above map onto S2/S2-chrome/S3; §"Keeping the list feel" is withdrawn
  (Craft's free camera applies to the strip).
