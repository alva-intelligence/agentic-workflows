# KV Motion editor — adopt the KV Studio design language

**Date:** 2026-08-03
**Author:** daffa
**Service:** web
**Branch:** `feature/daffa/vc-kv-motion-timeline-editor`
**Status:** design approved, not implemented

## Problem

The motion timeline editor (`/brands/[id]/studio/kv-generator/[file_id]/motion/[projectId]`)
already uses the frndOS design tokens — `bg-app`, `border-border-default`,
`text-text-inverse`, `font-geist`, and even `frndos-float-panel` /
`frndos-panel-header`. Colour and typography are therefore already in family.

What breaks the family resemblance is **structure**, not palette. KV Studio is a
full-viewport dot-grid canvas with every piece of chrome floating above it as a
`position: fixed` overlay. The motion editor is a conventional IDE pane layout:
an edge-to-edge top bar with a bottom border, a `w-56` left rail with
`border-r`, a `w-72` right inspector with `border-l`, and a docked timeline.
Opening the motion editor from KV reads as leaving the product.

Two secondary gaps:

- The motion editor hardcodes the midnight surface. KV is appearance-theme
  aware — `globals.css:668–679` re-skins `.frndos-panel-header` and
  `.frndos-float-panel` under `[data-theme="aurora"]`, and
  `KvGeneratorLayout.tsx:4037–4040` swaps the canvas background and dot colour.
  With the theme switched to aurora, the motion editor stays dark while the rest
  of the app turns indigo.
- `TimelineDock`'s root is already `rounded-2xl border bg-app-panel`
  (`TimelineDock.tsx:71`) — it was authored as a card — but the editor renders it
  flush against the viewport edges, so the rounding never reads.

## Comparison of the two surfaces

| Aspect | KV Studio (`KvGeneratorLayout`) | Motion editor (current) |
|---|---|---|
| Shell | `relative h-screen w-screen overflow-hidden` + dot-grid background (`:4032`) | `bg-app flex h-screen flex-col` (`KvMotionEditor.tsx:821`) |
| Chrome | `position: fixed` overlays above the canvas (`:4256`, `:4602`) | in-flow panes separated by 1px borders |
| Top nav | no background at all; child pills float over the canvas (`:4247`) | solid bar with `border-b` (`:823`) |
| Side panels | floating cards, e.g. layers panel pinned at `left:24 bottom:96` (`:4601`) | `border-r` / `border-l` columns (`:952`, `:1010`) |
| Theme | aurora-aware background and dot colour (`:4037–4040`) | hardcoded midnight |

## Decisions

Three decisions were taken during brainstorming; each is recorded with the
option that was rejected and why.

**D1 — Hybrid scope.** The stage adopts the KV canvas and the rail and inspector
become floating cards; the timeline dock stays docked full-width.

Rejected: converting the dock into a floating pill like `KvCanvasBottomNav`. The
dock genuinely needs the full viewport width for the timeline, and
`TimelineDock.tsx` / `BlockTrackRow.tsx` are under active edit in a parallel
session (commits `0c596b9c` … `3a7eaf84`). Leaving them untouched removes the
merge-conflict risk entirely.

**D2 — Panels reserve space; they do not occlude the stage.** The rail and
inspector look like they float (rounded, blurred, shadowed, gapped from the
viewport edge) but the stage width is computed between them.

Rejected: KV's literal full-bleed overlay. KV can do that because its canvas
pans and zooms — anything hidden under a panel can be moved out. The motion
preview is a fixed-size, centred stage; occluding it on a narrow viewport would
leave the user no recourse.

**D3 — Top bar follows the KV pattern: transparent, controls become pills.**

Rejected: keeping a solid bordered bar. The transparent nav with floating pills
is the single most recognisable KV signature; without it the page still reads as
a different product.

Resolved without asking, from the code:

- **Aurora support is in scope.** Adopting the KV design language means adopting
  its theme behaviour; the existing `[data-theme="aurora"]` rules do most of the
  work once the classes are applied.
- **`KvCanvasTopNav` is copied in pattern, not reused.** At 31KB it is bound to
  KV's canvas modes, tools, and generation state — none of which the motion
  editor has.
- **`InspectorPanel` needs no change.** Its root is `flex flex-col gap-3 p-4`
  (`InspectorPanel.tsx:110`) with no height assumption; scrolling belongs to the
  wrapper in `KvMotionEditor.tsx:1010`.

## Design

All changes live in the shell section of
`web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx`, lines
820–1057. No other file is modified.

### 1. Root shell becomes the KV canvas

`KvMotionEditor.tsx:821` changes from `bg-app flex h-screen flex-col font-geist
text-text-inverse` to `relative flex h-screen w-screen flex-col overflow-hidden`,
carrying the dot-grid as an inline style.

Note this keeps `flex flex-col` — unlike KV, whose canvas has no in-flow
children at all. The motion editor still needs the column so the body row and
the docked timeline stack, and step 4 depends on the dock being the column's last
child. What changes is that the column is now painted with the KV canvas instead
of a flat `bg-app`.

The dot-grid reuses the exact values from `KvGeneratorLayout.tsx:4037–4042`:

- midnight — background `#0E0E0E`, dots `rgba(255,255,255,0.08)`
- aurora — background `transparent` (the body gradient shows through), dots
  `rgba(255,255,255,0.22)`
- both — `radial-gradient(circle, <dot> 1px, transparent 1px)`, `20px 20px`,
  position `0 0`

The theme is read with `useAppearanceStore((s) => s.theme) === "aurora"`, the
same selector KV uses at `KvGeneratorLayout.tsx:359`.

`font-geist` and `text-text-inverse` stay on this element.

### 2. Top bar becomes a transparent pill row

The bar at `:823` loses `frndos-panel-header`, `border-b`, and its horizontal
padding as a bar. It becomes the `pointer-events-none fixed inset-x-0 top-0
z-40` → `pointer-events-auto` pair that KV uses at `:4256`, with its controls
regrouped into floating pills styled `frndos-float-panel`, rounded,
`backdrop-blur`, and shadowed:

- **left pill** — the `← Back` link (`:824`) and the project name (`:831`),
  keeping the existing `bg-border-default` divider between them
- **right pills** — the preset + Stagger cluster (`:834–879`), the ratio group
  (`:880–896`), the Export button (`:897`), the save indicator (`:912`), and the
  `⋮` actions popover (`:924`)

Every handler, `aria-label`, `role`, `aria-pressed`, and `data-testid` is carried
over unchanged. This step is a re-wrap, not a rewrite.

### 3. Rail and inspector become floating cards

Because step 2 makes the top bar `fixed`, it leaves the normal flow and the body
row at `:950` would otherwise slide underneath the pills. The body therefore
becomes the full-height flex row and takes an explicit top offset that clears
them: `pt-20` (80px — the pill row is ~56px tall plus a 12px gap top and bottom).
Its remaining spacing is `px-3 pb-3 gap-3`, giving a 12px gutter between each
card and the viewport edge, and 12px between card and stage.

Rail (`:952`) and inspector (`:1010`) drop `border-r` / `border-l` and gain the
card treatment, matching the shadow already used by the in-KV motion panel at
`KvMotionPanel.tsx:90`:

```
frndos-float-panel rounded-2xl border border-border-default
backdrop-blur-[20px] shadow-[0_24px_48px_rgba(0,0,0,0.4)]
```

Both keep `overflow-y-auto` and their fixed widths (`w-56`, `w-72`).

The stage (`:993`) drops `bg-app-canvas` so the dot-grid shows through, and keeps
`flex-1` — which is what makes D2 hold: its width is whatever remains between the
two cards, so the preview is never covered. The `editingInTime` ring at `:999`
is preserved as-is.

### 4. Timeline dock gets breathing room

The `<TimelineDock>` call site at `:1021` is wrapped in a `px-3 pb-3` container —
the same 12px gutter as the side cards — so the card rounding that already exists
at `TimelineDock.tsx:71` becomes visible. `TimelineDock.tsx` itself is not
edited.

The root is `overflow-hidden` and the dock is the last child of a full-height
column, so the body row must be `min-h-0 flex-1` for the dock to keep its natural
height instead of being squeezed by a tall track list.

## Out of scope

- Any edit to `TimelineDock.tsx`, `BlockTrackRow.tsx`, `TrackRow.tsx`,
  `Transport.tsx`, `TimelineRuler.tsx`, `InspectorPanel.tsx`, `presets.ts`, or
  `useMotionEditorState.ts` — all owned by the parallel timeline-lane work.
- Collapsible side panels. Considered under D2 and dropped as behaviour, not
  restyling.
- `KvMotionProjectsPanel` (the motion list inside KV) — it already renders inside
  the KV shell and inherits the design language.
- Any change to motion behaviour: playback, keyframes, presets, export, autosave.

## Verification

The change is `className` and inline-`style` only; no component contract moves.

- `bun test` — the motion suites query by `data-testid`
  (`motion-preview-wrapper`, `timeline-dock`, `motion-save-indicator`,
  `inspector-panel`) and by `aria-label`, both preserved, so they should pass
  unchanged. Any failure here means a testid or label was dropped during the
  re-wrap.
- `bun run build` — the real gate for this repo.
- Manual: open the editor in midnight and again in aurora, confirming the dot
  grid, the pill surfaces, and the panel cards all switch, and that the stage is
  never overlapped by the rail or inspector at a narrow window width.
