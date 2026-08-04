---
title: KV Resize — overlay multi-select
slug: kv-resize-multi-select
author: daffa
created: 2026-08-04
status: draft
services: [web]
---

# KV Resize — overlay multi-select

## Problem

On the Craft surface you can shift-click several overlays and move, scale, or
delete them as a group. On a Resize tile you cannot: the surface tracks a single
`selectedId`, and shift-clicking a second overlay just replaces the first.

This is not a regression — it was never built. The two surfaces run different
canvas engines:

- **Craft** renders through Fabric (`KvFabricCanvas`). Multi-select is native:
  `canvas.selection = tool === "cursor"` enables the rubber-band, shift-click is
  Fabric's own behaviour, and `fabric.ActiveSelection` gives group move / scale /
  rotate for free.
- **Resize** renders each tile through Konva (`KvTileOverlayEditor`). Konva has
  no `ActiveSelection`; a multi-selection has to be modelled by hand.

The shared `KvLayersPanel` already implements multi-select (shift-click range,
cmd/ctrl toggle) behind two optional props. Craft passes them; Resize does not,
so the panel's multi-select branch — gated on `if (onSelectMany && (toggleKey ||
rangeKey))` — never runs there.

## Goals

Within a single Resize tile:

1. Shift-click on the canvas adds/removes an overlay from the selection.
2. Shift-click and cmd/ctrl-click in the overlay (Layers) panel do the same.
3. `Cmd/Ctrl+A` selects every eligible overlay on the active tile.
4. Dragging any selected overlay moves the whole selection together.
5. The Transformer wraps the whole selection; scaling/rotating it applies to
   every member.
6. `Delete`/`Backspace` removes every selected overlay in one undo step.

Locked and hidden overlays are never included in a selection.

## Non-goals

- Marquee / rubber-band selection. Craft gets it free from Fabric; on Konva it
  needs hand-rolled hit-testing that would fight the tile's pan and place-tool
  gestures. Out of scope.
- Cross-tile selection. Each tile owns an independent overlay snapshot
  (`row.overlays`), so a selection spanning tiles has no coherent meaning for
  move or transform.
- Group align / distribute.
- Backporting `Cmd+A` to Craft.

## Design

### Selection state

`KvResizeCanvas` replaces `selectedId: string | null` with
`selectedIds: string[]`, and derives:

```ts
const primarySelectedId = selectedIds.length === 1 ? selectedIds[0] : null;
```

Every existing single-selection consumer — the Image/Shape/Text style sections
and `KvTransformPanel` — reads `primarySelectedId`. When 2+ overlays are
selected they receive `null`, which is the disabled state they already render
correctly. No changes are needed inside those components.

The selection belongs to the active tile. Changing `activeTileId` clears it.

### Pure module: `src/lib/studio/kv/overlaySelection.ts`

The decision logic lives in a pure module so it is unit-testable without a
canvas context (jsdom provides no 2D context, and component tests in this repo
currently fail on an unrelated RTL/bun issue).

```ts
/** Click semantics: shift toggles, plain click replaces. */
applyClickSelection(current: string[], id: string, additive: boolean): string[]

/** Eligible overlays on a tile: not locked, not hidden. */
selectableOverlayIds(overlays: StudioOverlay[]): string[]
```

`applyClickSelection` never admits an id twice, and toggling the last selected
id yields `[]`.

### Canvas: `KvTileOverlayEditor`

**Hit handling.** The per-overlay click handler calls
`applyClickSelection(selectedIds, id, e.evt.shiftKey)`. Locked overlays remain
unclickable via the existing `payload.locked` guard, so they cannot enter a
selection and cannot be dragged as part of a group.

**Transformer.** An `id → Konva.Node` map replaces the single
`selectedNodeRef`. The Transformer is bound with
`transformer.nodes(selectedIds.map(...).filter(Boolean))`. Konva draws one
bounding box across the selection and handles group scale/rotate itself.

**Group drag.** *(Corrected during implementation.)* The design originally
assumed Konva does not move siblings and planned hand-written delta
propagation. Wrong: `Transformer._proxyDrag` calls `startDrag` on every
attached node, so each member becomes a real Konva drag and follows the
pointer natively — and, crucially, **each member fires its own `dragend` on
mouseup**. The implementation therefore does no repositioning of its own.
It keeps a per-gesture guard (opened on the first `dragstart`, closed by the
first `dragend`): the first `dragend` reads every selected node's live
position and folds them into a single `commitTileOverlays` call — one undo
entry — while the remaining `dragend`s of the same gesture are swallowed.
Without the guard, each extra `dragend` recomputed a single-node commit over
the stale props array and snapped the other members back to their pre-drag
positions. A planned `translateOverlays` helper became unnecessary and was
removed.

**Transform commit.** `onTransformEnd` iterates the bound nodes instead of the
single node, converting each back to normalized coords, and commits once.

**Delete.** The handler at `KvTileOverlayEditor.tsx:224` iterates `selectedIds`
rather than testing a single `selectedId`, committing once.

### Select-all

Added to the existing window `keydown` effect in `KvResizeCanvas`, which already
guards `INPUT`/`TEXTAREA`. On `Cmd/Ctrl+A`:

- no active tile → no-op;
- `editingOverlayId` set → no-op, so Cmd+A selects characters inside the text
  overlay being edited rather than hijacking to select every overlay;
- otherwise `preventDefault()` (else the browser also select-alls the page text
  behind the canvas) and set `selectedIds` to `selectableOverlayIds(...)` of the
  active tile.

### Layers panel

No component changes. The Resize call site adds the two props Craft already
passes:

```tsx
selectedIds={selectedIds}
onSelectMany={setSelectedIds}
```

Shift-click range selection and cmd/ctrl toggle come with them.

### Transform panel

`isMultiSelect={selectedIds.length > 1}`, replacing the hardcoded `false`. The
panel already blanks its fields to `—` and disables input in that state.

> Note: Craft also hardcodes `isMultiSelect={false}`, so during a Craft
> multi-select the panel shows one member's values as if it were the only
> selection. That is a pre-existing Craft bug, out of scope here.

## Testing

Unit tests (`bun test`) for `overlaySelection.ts`:

- `applyClickSelection`: plain click replaces; shift adds; shift on an
  already-selected id removes it; removing the last leaves `[]`.
- `selectableOverlayIds`: excludes locked, excludes hidden, keeps order.
- `translateOverlays`: moves only the named ids, preserves relative offsets,
  leaves non-members untouched.

Component-level coverage is deliberately thin: every component test in
`src/components/studio/kv-generator/` currently fails on a pre-existing
`@testing-library` + bun issue unrelated to this work.

Manual verification on a Resize tile: shift-click two overlays, drag one and
confirm both move together and one Cmd+Z restores both; scale the group; press
Delete and confirm both vanish in one undo step; Cmd+A with a locked and a
hidden layer present and confirm neither is selected.

## Risks

- **Undo granularity.** Every group operation must land as exactly one
  `commitTileOverlays` call; committing per member would make one drag take N
  undos to reverse.
