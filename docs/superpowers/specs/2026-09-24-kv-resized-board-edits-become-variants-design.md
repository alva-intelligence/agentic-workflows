# KV — edits on a resized board become a variant, not a version

**Status:** draft for review · **Date:** 2026-09-24 · **Owner:** daffa · **Service:** web only
**Branch:** `feature/daffa/vc-kv-craft-resize-strip`

## Problem

A Craft board's resizes (the strip tiles under it) are keyed to the board's
**tip generation** (`kv_resize_exports.parent_generation_id`). Any edit that
appends a version to the board — chat edit, region edit, Angles, regenerate —
rekeys the board to a new tip (`docRekeyBoardTip`), so the strip looks up
exports for the NEW tip, finds none, and every resize the user made
"disappears" (Daffa, 2026-09-24). The rows still exist, orphaned under the
old tip, reachable only through Version History.

## Decision (Daffa, 2026-09-24)

- **Rule:** if the board being edited **has resizes**, the edit does not
  append a version — it lands as a **new variant board** next to it, and
  the original board, its resizes and its version chain stay exactly as
  they were. A board without resizes keeps today's behaviour (new version).
- **Automatic**, no extra confirm step, but the user is told **before**
  generating: a notice in chat that the result will be a variant because
  the board has resizes.
- **All edit kinds** that would append a version are covered.
- **Layers:** the variant gets a **copy** of the parent board's overlay
  layers (text/logo/shape/image), with fresh ids, bound to the variant.
  Editing one board's layers never changes the other's.
- Out of scope (separate future spec): a resize tile's OWN version history
  (regenerate / region edit overwriting a tile's image in place).

## Where the decision lives

The web alone decides version vs. board; api and ai-service only store a
generation with a `parent_generation_id`. Every version append in the app
goes through ONE call: `docRekeyBoardTip(kvDoc, parentId, top.id)` in the
completion effect's develop-in-place branch
(`KvGeneratorLayout.tsx` ≈1941-1966). That is the only call site in `src/`.

So the rule is enforced there, once, and every trigger is covered without
touching each one: KvChat sends (composer, `ModeSuggestion` card,
`GenerateBar`, question card), region edit with a frame, Craft pill
(`handleStartCrafting`), Angles (`handleGenerateAngleNow`), draft replay,
and any future caller.

Paths that are **not** version appends and stay untouched: Expand and
remove-background (overlay patches), upscale (download), Separate layers and
Duplicate (already new boards), the concept → craft **fork** (already adds a
new board and leaves the concept's key alone), plain completions (Branch 3).
Version restore creates a copy whose parent is the restored (older)
generation, which is not a board key, so it takes Branch 3 today; if it ever
reaches Branch 2 it is covered by the same guard.

## Design

### 1. Pure decision — `src/lib/studio/kv/editOutcome.ts`

```ts
export type EditOutcome = "rekey" | "fork" | "variant";
export function editOutcome(args: {
  parentIsConcept: boolean;   // parent tip mode !== "craft"
  parentResizeCount: number;  // strip rows under the parent tip
}): EditOutcome
```

- `parentIsConcept` → `"fork"` (unchanged; concept keeps its key, so its
  resizes survive anyway).
- else `parentResizeCount > 0` → `"variant"`.
- else `"rekey"`.

`boardResizeCount(rows: readonly unknown[] | undefined): number` — the
number of rows the strip would draw for that tip. `undefined` (query not
loaded) counts as 0: the strip draws nothing either, so the user saw no
resizes. Rows in any status count (an in-flight resize would otherwise be
orphaned the moment it lands).

**Source of `rows`:** the react-query cache the strip already fills —
`queryClient.getQueryData(resizeExportsQueryKey(fileId, tipId))`
(`useResizeExports.ts`). `KvCanvas` fetches exports for every board tip
whenever the canvas has ≥1 board, so the cache is warm for any board the
user can see. No new request.

### 2. Completion effect — the redirect

In Branch 2, replace the `parentIsConcept ? fork : rekey` fork with
`editOutcome(...)`. On `"variant"`:

- `boards = computeBoardLayout(stream.generations, current, { modeFilter: "craft" })`
- `center = adjacentFreeCenter(boards, parentBoard)` (fallback `nextFreeCenter`)
- `name = deriveVariantName("", priorVariants + 1)` — the same "Variant N"
  the "+" button falls back to.
- `nextState = canvasStateWithNewVariant(boards, current, top.id, center, { name })`
  — master is NOT moved (unlike a rekey, which moves master when it
  followed the old tip).
- Write the new board AND the copied layers in ONE Yjs transaction via a new
  `docAddVariantBoard(doc, nextState, newBoardId, overlays)` in
  `yjsSerializer.ts`, so one Cmd+Z removes both.
- `setViewingGenerationId(top.id)`; the camera behaves as it does for a "+"
  variant.
- Track `kv_generator.edit_became_variant` (see Analytics).

The decision is taken **at completion**, from the cache at that moment — the
state that matters for whether a rekey would orphan resizes. If resizes were
created or all deleted while the generation ran, completion follows the
current truth; the pre-send notice (below) reflects the truth at send time.

### 3. Copying layers — `overlaysForVariant`

Pure, in `overlayMutations.ts`:

```ts
export function overlaysForVariant(
  overlays: StudioOverlay[],
  parentChain: Set<string>,     // parent board's version_ids
  variantId: string,
  mintId: () => string          // newTileOverlayId
): KvOverlaySeed[]
```

Takes `overlaysForTile(overlays, parentChain)` (same rule the board renders
with), and for each: new `tmp_` id (the autosave's tmp→ULID remap handles
persistence, as for paste), `board_generation_id = variantId`, geometry,
rotation, z order and payload copied verbatim. Geometry needs no
re-projection: a craft edit keeps the base's aspect (the ai-service conforms
to it), so the variant has the parent's shape. Legacy overlays with a null
`board_generation_id` are not copied (they belong to no board).

### 4. The notice — before generating

Copy (English, like the rest of the KV UI):
**"This board has resizes — the result will be added as a new variant."**
*(Daffa's wording: "Dibuat sebagai variant karena board ini punya resize".)*

KvChat gets one prop, `editTargetHasResizes: boolean`, computed in the
layout for the board chat is editing (the `baseGenerationId` it already
passes, resolved to its board tip → `boardResizeCount(...) > 0`). When true:

- **Composer chip** "Editing {label}" (KvChat ≈2731-2770): a second muted
  line with the notice. This is the one surface EVERY chat edit passes
  through, including region edit with a frame, which sends straight from
  the composer.
- **`ModeSuggestion` card** (≈2000-2059): the notice line under the
  "Generate with … · ~N credits" estimate.
- **`GenerateBar`** and the **question card**: same line, same copy.

Canvas-only triggers (Angles, the Craft pill) show the same copy through the
existing `setTransientNotice` toast when fired on a resized board.

The copy lives in one constant (`RESIZED_EDIT_NOTICE` in `editOutcome.ts`)
so every surface says the same thing.

## Invariants

- A board with ≥1 strip tile is never rekeyed by an edit.
- The parent board after a redirected edit is byte-identical in the doc:
  same key, center, name, version chain, master flag, overlays.
- The variant's layers are copies: no overlay id is shared between the two
  boards.
- Boards without resizes behave exactly as today (rekey, master follows).
- The concept → craft fork path is unchanged.
- No api or ai-service change.

## Analytics

`kv_generator.edit_became_variant` — `{ file_id, parent_generation_id,
generation_id, resize_count, copied_layer_count }`, fired once per redirect
from the completion effect. Taxonomy row added via frndos-analytics-events.
The notice itself is not tracked (it is passive text).

## Testing

Pure, test-first (bun test, explicit files):

- `editOutcome`: concept → fork regardless of resizes; craft + 0 → rekey;
  craft + ≥1 → variant; `boardResizeCount(undefined) === 0`.
- `overlaysForVariant`: copies only chain-bound overlays; fresh ids, none
  shared with the source; `board_generation_id` = variant; geometry/z/payload
  equal; null-bound legacy overlays skipped; empty input → empty.
- `docAddVariantBoard`: one transaction (a single undo step removes board
  and layers); parent board map untouched; master unchanged.

No RTL/component tests for canvas or chat (track policy). Gates as usual:
tsc ≤ baseline, eslint no new warnings in touched files, explicit
`bun test` files, `node next build` at the end.

Manual (Daffa): on a board with resizes, (a) chat edit, (b) region edit,
(c) Angles — notice shows before sending; result lands as a new board
beside it with the same layers; the original board still shows all its
resizes; Cmd+Z once removes the variant and its layers. On a board without
resizes, the same edits still append versions.

## Risks

- **Strip width vs. adjacent slot.** `adjacentFreeCenter` steps by
  `ARTBOARD_STEP`; a parent whose strip row is wider than one step could sit
  under the variant. `computeResizeStrip` lays strips out from the board
  rects; the plan verifies it keeps groups apart, and if not, places the
  variant past the parent group's strip width.
- **Cold cache.** A board whose exports never loaded (strip disabled) counts
  as "no resizes" and gets a version — same as what the user sees.
