# KV Motion Multi-Select Apply Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user Cmd/Shift-click several layers in the Motion editor's Layers rail or timeline rows and apply one motion (entrance/exit preset, emphasis, saved template, pasted motion, or a stagger) to all of them in one gesture and one undo step.

**Architecture:** `useMotionEditorState` grows a `selectedTrackIds` array (rail z-order) beside the existing `selectedKeyframe`, which stays the *primary* so the Inspector, Konva Transformer and keyboard shortcuts are untouched. Bulk writers reduce the existing pure preset/template/paste functions across the ids and `push()` once. The rail rows and the dock's row click pass a `SelectMode` derived from the click's modifier keys; `TrackPresetMenu` takes `targetTrackIds` and, when it has more than one, renders an "N layers" header, hides single-layer lifecycle items and offers a Stagger toggle.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, `bun test` (RTL — `screen` is broken, use `within(document.body)`), PostHog via `safeCapture`.

**Spec:** `docs/superpowers/specs/2026-09-20-kv-motion-multi-select-apply-design.md`

## Global Constraints

- Web only. All paths below are relative to `web/`. Branch: `feature/daffa/vc-kv-motion-multi-select` from `develop`.
- Gesture: plain click = `replace`, Cmd/Ctrl-click = `toggle`, Shift-click = `range` in rail z-order (highest `z` first, base row excluded).
- `selectedTrackIds` is always in rail z-order; `selectedKeyframe.trackId` is a member whenever non-null; empty ⇔ `selectedKeyframe === null`.
- Every bulk action is exactly one `push()`; zero members written ⇒ no push.
- `__base__`, locked and hidden overlays never join a multi-selection.
- Canvas stays single-select. Copy / Save / Duplicate / Delete stay primary-only and are hidden while N > 1.
- Analytics `motion_preset_applied.source` gains `"multi" | "multi_stagger"`; `track_count` = members actually written.
- Tests: `bun test <file>` (never `bunx vitest`, never a whole directory). Keep any test file under ~50 KB — split rather than grow (bun's transpiler cliff).
- No new dark hex colours; reuse the row tint/hover values the rail and dock already use.
- Commit message format `<type>(<scope>): <description>`, scope `kv-motion`, ending with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

## Deviation from the spec

The spec lists an RTL test on `KvMotionEditor`. That component (2.5k lines, Konva stage, React Query, three stores) has no component test in the repo and would need the whole stage mocked; the wiring it would cover is instead pinned by (a) pure helpers with their own tests (`selectionMode.ts`, `bulkTargetIds` in Task 8), (b) the hook, dock and menu tests below, and (c) the manual preview checklist in Task 10.

---

## File map

| File | Responsibility |
| --- | --- |
| `src/components/video-editor/selectionMode.ts` (new) | `SelectMode` + `modeFromEvent`. Lives in `video-editor/` because the dock must not import from `studio/`. |
| `src/components/studio/kv-generator/motion/useMotionEditorState.ts` | `selectedTrackIds`, `selectTrack(id, mode)`, `clearSelection`, bulk writers, `pasteMotionInto` extraction. |
| `src/components/studio/kv-generator/motion/bulkTargetIds.ts` (new) | Pure: which ids a menu opened on `trackId` should target. |
| `src/components/video-editor/types.ts` | `TimelineDockProps.selectedTrackIds?`, `onFocusTrack(trackId, mode)`. |
| `src/components/video-editor/TimelineDock.tsx`, `TrackRow.tsx`, `BlockTrackRow.tsx`, `TrackNameCell.tsx` | Modifier-aware row click, membership tint, primary ring. |
| `src/components/video-editor/MotionPanelHeader.tsx` | Optional icon override for the "N layers" strip. |
| `src/components/studio/kv-generator/motion/TrackPresetMenu.tsx` | `targetTrackIds`, `onApplyStagger`, `onOpen`, multi header, hidden items, Stagger toggle. |
| `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` | Rail click modes + highlight, menu wiring, toasts, toolbar Stagger, Esc, hint. |
| `src/lib/analytics/kv-generator-events.ts` | New `source` values. |

---

### Task 0: Branch

- [ ] **Step 1: Create the branch from an up-to-date develop**

```bash
cd web && git checkout develop && git pull --rebase origin develop && git checkout -b feature/daffa/vc-kv-motion-multi-select
```

Expected: `Switched to a new branch 'feature/daffa/vc-kv-motion-multi-select'`.

---

### Task 1: `modeFromEvent`

**Files:**
- Create: `src/components/video-editor/selectionMode.ts`
- Test: `src/components/video-editor/selectionMode.test.ts`

**Interfaces:**
- Produces: `export type SelectMode = "replace" | "toggle" | "range"`; `export function modeFromEvent(e: { shiftKey: boolean; metaKey: boolean; ctrlKey: boolean }): SelectMode`.

- [ ] **Step 1: Write the failing test**

```ts
// src/components/video-editor/selectionMode.test.ts
/** Modifier → selection mode, shared by the layers rail and the dock rows so
 *  the two surfaces can never disagree about what Shift-click means. */
import { describe, expect, it } from "bun:test";
import { modeFromEvent } from "./selectionMode";

const ev = (o: Partial<{ shiftKey: boolean; metaKey: boolean; ctrlKey: boolean }>) => ({
  shiftKey: false,
  metaKey: false,
  ctrlKey: false,
  ...o,
});

describe("modeFromEvent", () => {
  it("plain click replaces", () => {
    expect(modeFromEvent(ev({}))).toBe("replace");
  });
  it("Cmd (mac) or Ctrl (win) toggles", () => {
    expect(modeFromEvent(ev({ metaKey: true }))).toBe("toggle");
    expect(modeFromEvent(ev({ ctrlKey: true }))).toBe("toggle");
  });
  it("Shift ranges, and wins over Cmd when both are held", () => {
    expect(modeFromEvent(ev({ shiftKey: true }))).toBe("range");
    expect(modeFromEvent(ev({ shiftKey: true, metaKey: true }))).toBe("range");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bun test src/components/video-editor/selectionMode.test.ts`
Expected: FAIL — cannot resolve `./selectionMode`.

- [ ] **Step 3: Implement**

```ts
// src/components/video-editor/selectionMode.ts
/** How a row click changes the layer selection. Derived from the click's
 *  modifier keys in ONE place so the layers rail and the timeline rows agree:
 *  Shift = extend a range from the primary, Cmd/Ctrl = toggle this row,
 *  nothing = select only this row. Shift wins when both are held — a range
 *  is the larger intent, and Figma resolves the same combination that way. */
export type SelectMode = "replace" | "toggle" | "range";

export function modeFromEvent(e: {
  shiftKey: boolean;
  metaKey: boolean;
  ctrlKey: boolean;
}): SelectMode {
  if (e.shiftKey) return "range";
  if (e.metaKey || e.ctrlKey) return "toggle";
  return "replace";
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bun test src/components/video-editor/selectionMode.test.ts`
Expected: 3 pass.

- [ ] **Step 5: Commit**

```bash
git add src/components/video-editor/selectionMode.ts src/components/video-editor/selectionMode.test.ts
git commit -m "feat(kv-motion): modeFromEvent — one modifier→SelectMode rule for rail and dock

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Multi-selection state in `useMotionEditorState`

**Files:**
- Modify: `src/components/studio/kv-generator/motion/useMotionEditorState.ts` (state near line 267, `selectKeyframe`/`selectTrack` near lines 562–576, `deleteLayer` near line 383, return object near line 1480)
- Test: `src/components/studio/kv-generator/motion/useMotionEditorState.selection.test.tsx` (new)

**Interfaces:**
- Consumes: `SelectMode` from Task 1.
- Produces on the hook's return: `selectedTrackIds: string[]`; `selectTrack(trackId: string, mode?: SelectMode): void` (default `"replace"`, same behaviour as today for callers that pass one arg); `clearSelection(): void`.

- [ ] **Step 1: Write the failing tests**

```tsx
// src/components/studio/kv-generator/motion/useMotionEditorState.selection.test.tsx
/** Multi-select: `selectedTrackIds` (rail z-order) beside `selectedKeyframe`
 *  (the primary). Fixture and wrapper copied from
 *  `useMotionEditorState.shiftTrack.test.ts`; three overlays so a range has
 *  something in the middle to pick up. */
import { createElement, type ReactNode } from "react";
import { describe, expect, it } from "bun:test";
import { act, renderHook } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { KvMotionProject } from "@/types/kv/motionProject";
import type { StudioOverlay } from "@/types/studio";
import { useMotionEditorState } from "./useMotionEditorState";

function overlay(id: string, z: number, extra: Partial<StudioOverlay["payload"]> = {}): StudioOverlay {
  return {
    id,
    studio_file_id: "f1",
    type: "text",
    x: 0.1,
    y: 0.2,
    width: 0.3,
    height: 0.1,
    rotation: 0,
    z,
    payload: { type: "text", content: id, color: "#000000", ...extra },
    created_at: "t",
    updated_at: "t",
  };
}

const qcWrapper = ({ children }: { children: ReactNode }) =>
  createElement(
    QueryClientProvider,
    { client: new QueryClient({ defaultOptions: { queries: { retry: false } } }) },
    children
  );

/** Rail order (highest z first): top, mid, low, then the hidden and locked
 *  ones, which never join a multi-selection. */
function makeProject(): KvMotionProject {
  return {
    id: "p1",
    studioFileId: "f1",
    boardGenerationId: "g1",
    name: "Test",
    audioUrl: null,
    durationMs: 5000,
    fps: 30,
    createdAt: "",
    updatedAt: "",
    snapshot: {
      base_image_url: "https://x/y.png",
      board_width: 1080,
      board_height: 1080,
      overlays: [
        overlay("low", 1),
        overlay("top", 3),
        overlay("mid", 2),
        overlay("hid", 0, { hidden: true }),
        overlay("lock", -1, { locked: true }),
      ],
    },
    timeline: { version: 1, duration_ms: 5000, fps: 30, tracks: [] },
  };
}

function setup() {
  return renderHook(() => useMotionEditorState(makeProject(), { autosave: false }), {
    wrapper: qcWrapper,
  });
}

describe("useMotionEditorState — multi-select", () => {
  it("starts empty, and a plain selectTrack is a single member that is also the primary", () => {
    const { result } = setup();
    expect(result.current.selectedTrackIds).toEqual([]);
    expect(result.current.selectedKeyframe).toBeNull();

    act(() => result.current.selectTrack("mid"));

    expect(result.current.selectedTrackIds).toEqual(["mid"]);
    expect(result.current.selectedKeyframe?.trackId).toBe("mid");
  });

  it("toggle adds in rail z-order regardless of click order, primary = last clicked", () => {
    const { result } = setup();
    act(() => result.current.selectTrack("low"));
    act(() => result.current.selectTrack("top", "toggle"));

    expect(result.current.selectedTrackIds).toEqual(["top", "low"]);
    expect(result.current.selectedKeyframe?.trackId).toBe("top");
  });

  it("toggle removes a member; the primary hands off to the nearest remaining row", () => {
    const { result } = setup();
    act(() => result.current.selectTrack("top"));
    act(() => result.current.selectTrack("mid", "toggle"));
    act(() => result.current.selectTrack("low", "toggle"));
    expect(result.current.selectedKeyframe?.trackId).toBe("low");

    act(() => result.current.selectTrack("low", "toggle"));

    expect(result.current.selectedTrackIds).toEqual(["top", "mid"]);
    expect(result.current.selectedKeyframe?.trackId).toBe("mid");
  });

  it("toggling the only member empties the selection", () => {
    const { result } = setup();
    act(() => result.current.selectTrack("top"));
    act(() => result.current.selectTrack("top", "toggle"));

    expect(result.current.selectedTrackIds).toEqual([]);
    expect(result.current.selectedKeyframe).toBeNull();
  });

  it("range fills between the primary and the clicked row, unions with the current set, and moves the primary", () => {
    const { result } = setup();
    act(() => result.current.selectTrack("top"));
    act(() => result.current.selectTrack("low", "range"));

    expect(result.current.selectedTrackIds).toEqual(["top", "mid", "low"]);
    expect(result.current.selectedKeyframe?.trackId).toBe("low");
  });

  it("range with no primary behaves as replace", () => {
    const { result } = setup();
    act(() => result.current.selectTrack("mid", "range"));
    expect(result.current.selectedTrackIds).toEqual(["mid"]);
  });

  it("hidden and locked overlays are ignored by toggle/range, but a plain click still selects them", () => {
    const { result } = setup();
    act(() => result.current.selectTrack("top"));
    act(() => result.current.selectTrack("hid", "toggle"));
    act(() => result.current.selectTrack("lock", "toggle"));
    expect(result.current.selectedTrackIds).toEqual(["top"]);

    act(() => result.current.selectTrack("lock"));
    expect(result.current.selectedTrackIds).toEqual(["lock"]);
    expect(result.current.selectedKeyframe?.trackId).toBe("lock");
  });

  it("selectKeyframe and selectTrackAtStart collapse to that one track", () => {
    const { result } = setup();
    act(() => result.current.selectTrack("top"));
    act(() => result.current.selectTrack("low", "range"));

    act(() => result.current.selectKeyframe("mid", 0));
    expect(result.current.selectedTrackIds).toEqual(["mid"]);

    act(() => result.current.selectTrack("top", "toggle"));
    act(() => result.current.selectTrackAtStart("low"));
    expect(result.current.selectedTrackIds).toEqual(["low"]);
  });

  it("clearSelection empties both", () => {
    const { result } = setup();
    act(() => result.current.selectTrack("top"));
    act(() => result.current.selectTrack("mid", "toggle"));
    act(() => result.current.clearSelection());
    expect(result.current.selectedTrackIds).toEqual([]);
    expect(result.current.selectedKeyframe).toBeNull();
  });

  it("undo/redo of a timeline edit leaves the selection alone", () => {
    const { result } = setup();
    act(() => result.current.selectTrack("top"));
    act(() => result.current.selectTrack("mid", "toggle"));
    act(() => result.current.insertKeyframe("top", 100));
    expect(result.current.canUndo).toBe(true);
    act(() => result.current.undo());
    expect(result.current.selectedTrackIds).toEqual(["top", "mid"]);
    expect(result.current.selectedKeyframe?.trackId).toBe("mid");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/motion/useMotionEditorState.selection.test.tsx`
Expected: FAIL — `selectedTrackIds` undefined / `clearSelection is not a function`.

- [ ] **Step 3: Implement the state**

In `useMotionEditorState.ts`:

a) Add the import at the top (next to the `types` import):

```ts
import type { SelectMode } from "@/components/video-editor/selectionMode";
```

b) Directly under the existing `selectedKeyframe` `useState` (line ~267):

```ts
  // Multi-select (2026-09-20). `selectedTrackIds` is every selected layer in
  // RAIL z-order (highest z first, never click order — a stagger dealt across
  // the selection has to be deterministic). `selectedKeyframe` stays the
  // PRIMARY: the one the Inspector, the Transformer and the keyboard act on.
  // Invariants: the primary is always a member; empty ⇔ primary null.
  const [selectedTrackIds, setSelectedTrackIds] = useState<string[]>([]);
```

c) After `const base = useMemo(...)` (line ~482), add the eligibility order. It reads the DOC's snapshot (the one `copyLayer`/`deleteLayer` read), so a pasted layer is selectable too:

```ts
  // Rows a multi-selection may contain, in rail order — the same sort
  // `buildTracks` in KvMotionEditor uses, minus what can't be animated
  // (hidden: no rest pose; locked: the menu is never offered). The synthetic
  // "__base__" row is not an overlay, so it is never here either.
  const multiSelectOrder = useMemo(
    () =>
      [...snapshot.overlays]
        .sort((a, b) => b.z - a.z)
        .filter(
          (o) => o.payload.hidden !== true && o.payload.locked !== true
        )
        .map((o) => o.id),
    [snapshot.overlays]
  );
```

d) Replace `selectKeyframe` and `selectTrack` (lines ~562–576) with:

```ts
  const selectKeyframe = useCallback(
    (trackId: string, tMs: number) => {
      setPreviewOnce(null);
      setSelectedKeyframe({ trackId, tMs });
      // A diamond / bar click means THIS one — it collapses any multi-select.
      setSelectedTrackIds([trackId]);
      seek(tMs);
    },
    [seek]
  );

  // Selecting a track (no keyframe click yet, e.g. from the layers rail)
  // anchors selection at the CURRENT playhead — if no keyframe sits exactly
  // there, the Inspector reads this as "between keyframes" and offers "make
  // keyframe here", which is the desired affordance.
  //
  // `mode` (default "replace") is the rail/dock modifier-click contract —
  // see `modeFromEvent`. Toggle and range only ever admit ids from
  // `multiSelectOrder`; a plain click on anything (locked, hidden, base) is
  // still a single select, exactly as before.
  const selectTrack = useCallback(
    (trackId: string, mode: SelectMode = "replace") => {
      const single = () => {
        setSelectedTrackIds([trackId]);
        setSelectedKeyframe({ trackId, tMs: playheadMs });
      };
      if (mode === "replace" || !multiSelectOrder.includes(trackId)) {
        single();
        return;
      }
      const current = selectedTrackIds.filter((id) =>
        multiSelectOrder.includes(id)
      );
      const next = new Set(current);
      let primary: string | null = trackId;
      if (mode === "toggle") {
        if (next.has(trackId)) {
          next.delete(trackId);
          // Hand the primary to the nearest surviving row (ties → the one
          // above), or clear when nothing is left.
          const i = multiSelectOrder.indexOf(trackId);
          const survivors = multiSelectOrder.filter((id) => next.has(id));
          primary =
            survivors.reduce<string | null>((best, id) => {
              if (best === null) return id;
              const d = Math.abs(multiSelectOrder.indexOf(id) - i);
              const bd = Math.abs(multiSelectOrder.indexOf(best) - i);
              return d < bd ? id : best;
            }, null) ?? null;
        } else {
          next.add(trackId);
        }
      } else {
        const anchor = selectedKeyframe?.trackId ?? null;
        const a = anchor ? multiSelectOrder.indexOf(anchor) : -1;
        if (a < 0) {
          single();
          return;
        }
        const b = multiSelectOrder.indexOf(trackId);
        for (const id of multiSelectOrder.slice(
          Math.min(a, b),
          Math.max(a, b) + 1
        )) {
          next.add(id);
        }
      }
      setSelectedTrackIds(multiSelectOrder.filter((id) => next.has(id)));
      setSelectedKeyframe(
        primary ? { trackId: primary, tMs: playheadMs } : null
      );
    },
    [multiSelectOrder, selectedTrackIds, selectedKeyframe, playheadMs]
  );

  const clearSelection = useCallback(() => {
    setSelectedTrackIds([]);
    setSelectedKeyframe(null);
  }, []);
```

e) In `deleteLayer` (line ~383), next to `setSelectedKeyframe(null)`:

```ts
      if (selectedKeyframe?.trackId === overlayId) {
        setSelectedKeyframe(null);
      }
      setSelectedTrackIds((prev) => prev.filter((id) => id !== overlayId));
```

If the deleted layer was the primary but other members remain, that leaves the primary null with members present. Accept for now — the next click resets it — but ALSO make it consistent: replace the two statements with:

```ts
      // `deleteLayer` (line ~363) is declared BEFORE `playheadMs` (~418) and
      // `playheadRef` (~423) — reading either here is the temporal-dead-zone
      // trap this file already documents for `selectedKeyframe`. Anchor the
      // handed-off primary at 0; the next click re-anchors it anyway.
      setSelectedTrackIds((prev) => {
        const rest = prev.filter((id) => id !== overlayId);
        if (selectedKeyframe?.trackId === overlayId) {
          setSelectedKeyframe(rest.length ? { trackId: rest[0], tMs: 0 } : null);
        }
        return rest;
      });
```

f) Add `selectedTrackIds`, `clearSelection` to the return object (next to `selectedKeyframe` / `selectTrack`).

- [ ] **Step 4: Run to verify it passes, plus the neighbours**

Run: `bun test src/components/studio/kv-generator/motion/useMotionEditorState.selection.test.tsx src/components/studio/kv-generator/motion/useMotionEditorState.test.ts src/components/studio/kv-generator/motion/useMotionEditorState.layers.test.tsx`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/useMotionEditorState.selection.test.tsx
git commit -m "feat(kv-motion): selectedTrackIds beside the primary — toggle/range in rail order, collapse on keyframe click

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Bulk writers — presets, emphasis, template, stagger

**Files:**
- Modify: `src/components/studio/kv-generator/motion/useMotionEditorState.ts` (after `applyTemplate`, line ~915; return object)
- Test: `src/components/studio/kv-generator/motion/useMotionEditorState.bulk.test.tsx` (new)

**Interfaces:**
- Consumes: `applyPreset`, `applyEmphasisPreset`, `applyStagger` from `@/lib/video-editor/presets`; `bakeTemplateToTrack` from `@/lib/video-editor/templates` (all already imported except `applyStagger` — add it).
- Produces on the hook: `applyPresetToTracks(ids: string[], preset: MotionPresetId, atMs: number): number`; `applyEmphasisToTracks(ids: string[], preset: EmphasisPresetId): number`; `applyTemplateToTracks(ids: string[], body: MotionTemplateBody): number`; `applyStaggerToTracks(ids: string[], preset: MotionPresetId): number`. Each returns the number of tracks written and pushes at most once.

- [ ] **Step 1: Write the failing tests**

```tsx
// src/components/studio/kv-generator/motion/useMotionEditorState.bulk.test.tsx
/** Bulk writers: one gesture over N layers = one push (one undo step), a
 *  member that can't take the motion is skipped, zero written = no push.
 *  Fixture copied from `useMotionEditorState.selection.test.tsx`. */
import { createElement, type ReactNode } from "react";
import { describe, expect, it } from "bun:test";
import { act, renderHook } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { KvMotionProject } from "@/types/kv/motionProject";
import type { StudioOverlay } from "@/types/studio";
import type { MotionTemplateBody } from "@/lib/video-editor/templates";
import { useMotionEditorState } from "./useMotionEditorState";

function overlay(id: string, z: number, extra: Partial<StudioOverlay["payload"]> = {}): StudioOverlay {
  return {
    id, studio_file_id: "f1", type: "text",
    x: 0.1, y: 0.2, width: 0.3, height: 0.1, rotation: 0, z,
    payload: { type: "text", content: id, color: "#000000", ...extra },
    created_at: "t", updated_at: "t",
  };
}

const qcWrapper = ({ children }: { children: ReactNode }) =>
  createElement(
    QueryClientProvider,
    { client: new QueryClient({ defaultOptions: { queries: { retry: false } } }) },
    children
  );

function makeProject(durationMs = 5000): KvMotionProject {
  return {
    id: "p1", studioFileId: "f1", boardGenerationId: "g1", name: "Test",
    audioUrl: null, durationMs, fps: 30, createdAt: "", updatedAt: "",
    snapshot: {
      base_image_url: "https://x/y.png", board_width: 1080, board_height: 1080,
      overlays: [overlay("top", 3), overlay("mid", 2), overlay("low", 1), overlay("hid", 0, { hidden: true })],
    },
    timeline: { version: 1, duration_ms: durationMs, fps: 30, tracks: [] },
  };
}

const kfs = (r: { timeline: KvMotionProject["timeline"] }, id: string) =>
  r.timeline.tracks.find((t) => t.kind === "overlay" && t.overlay_id === id)?.keyframes ?? [];

function setup(durationMs?: number) {
  return renderHook(() => useMotionEditorState(makeProject(durationMs), { autosave: false }), {
    wrapper: qcWrapper,
  });
}

describe("applyPresetToTracks", () => {
  it("writes the same entrance on every id at the same anchor, as ONE undo step", () => {
    const { result } = setup();
    let n = 0;
    act(() => { n = result.current.applyPresetToTracks(["top", "mid", "low"], "fade-in", 0); });

    expect(n).toBe(3);
    for (const id of ["top", "mid", "low"]) {
      expect(kfs(result.current, id).map((k) => k.t_ms)).toEqual(kfs(result.current, "top").map((k) => k.t_ms));
      expect(kfs(result.current, id).length).toBeGreaterThan(0);
    }
    act(() => result.current.undo());
    expect(result.current.timeline.tracks).toEqual([]);
    expect(result.current.canUndo).toBe(false);
  });

  it("skips an id with no rest pose (hidden) and reports only what it wrote; nothing written = no push", () => {
    const { result } = setup();
    let n = -1;
    act(() => { n = result.current.applyPresetToTracks(["hid", "top"], "fade-in", 0); });
    expect(n).toBe(1);
    expect(kfs(result.current, "hid")).toEqual([]);

    act(() => result.current.undo());
    act(() => { n = result.current.applyPresetToTracks(["hid"], "fade-in", 0); });
    expect(n).toBe(0);
    expect(result.current.canUndo).toBe(false);
  });
});

describe("applyEmphasisToTracks", () => {
  it("writes on every id when there is room, one push", () => {
    const { result } = setup();
    let n = 0;
    act(() => { n = result.current.applyEmphasisToTracks(["top", "mid"], "pulse"); });
    expect(n).toBe(2);
    expect(kfs(result.current, "top").length).toBeGreaterThan(0);
    expect(kfs(result.current, "mid").length).toBeGreaterThan(0);
    act(() => result.current.undo());
    expect(result.current.canUndo).toBe(false);
  });

  it("returns 0 and pushes nothing when the playhead leaves no room", () => {
    const { result } = setup(1000);
    act(() => result.current.seek(950));
    let n = -1;
    act(() => { n = result.current.applyEmphasisToTracks(["top", "mid"], "pulse"); });
    expect(n).toBe(0);
    expect(result.current.canUndo).toBe(false);
  });
});

describe("applyTemplateToTracks", () => {
  const body: MotionTemplateBody = {
    version: 1,
    source_duration_ms: 5000,
    keyframes: [
      { t_ms: 0, props: { opacity: 0 }, easing: "linear" },
      { t_ms: 400, props: { opacity: 1 }, easing: "out" },
    ],
    absolute_props: [],
  };

  it("replaces every id's track with the baked template, one push", () => {
    const { result } = setup();
    act(() => result.current.applyPresetToTracks(["top"], "pop-in", 0));
    let n = 0;
    act(() => { n = result.current.applyTemplateToTracks(["top", "low"], body); });
    expect(n).toBe(2);
    expect(kfs(result.current, "top").map((k) => k.t_ms)).toEqual([0, 400]);
    expect(kfs(result.current, "low").map((k) => k.t_ms)).toEqual([0, 400]);
    act(() => result.current.undo());
    expect(kfs(result.current, "low")).toEqual([]);
  });

  it("skips a body this build can't bake and pushes nothing when every id is skipped", () => {
    const { result } = setup();
    let n = -1;
    act(() => {
      n = result.current.applyTemplateToTracks(["top"], { ...body, version: 99 as 1 });
    });
    expect(n).toBe(0);
    expect(result.current.canUndo).toBe(false);
  });
});

describe("applyStaggerToTracks", () => {
  it("deals the preset across ONLY the given ids, later ids later, one push", () => {
    const { result } = setup();
    let n = 0;
    act(() => { n = result.current.applyStaggerToTracks(["top", "low"], "fade-in"); });
    expect(n).toBe(2);
    const topStart = Math.min(...kfs(result.current, "top").map((k) => k.t_ms));
    const lowStart = Math.min(...kfs(result.current, "low").map((k) => k.t_ms));
    expect(lowStart).toBeGreaterThan(topStart);
    expect(kfs(result.current, "mid")).toEqual([]);
    act(() => result.current.undo());
    expect(result.current.canUndo).toBe(false);
  });
});
```

Check the preset ids exist: `grep -n 'fade_in\|pop_in\|"pulse"' src/lib/video-editor/presets.ts` — use whatever the real `MotionPresetId` / `EmphasisPresetId` literals are if these differ.

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/motion/useMotionEditorState.bulk.test.tsx`
Expected: FAIL — `applyPresetToTracks is not a function`.

- [ ] **Step 3: Implement**

a) Add `applyStagger` to the `@/lib/video-editor/presets` import.

b) After `applyTemplate` (line ~915) add:

```ts
  // ── Bulk writers (multi-select, 2026-09-20) ──
  // Each one is the single-layer writer reduced over `ids`, pushed ONCE: the
  // user made one decision, so it is one undo step — the same rule
  // `applyStagger` and `applyBuild` follow. A member that can't take the
  // motion (no rest pose, no room, an unbakeable body) is skipped rather
  // than failing the whole gesture; the return value is how many were
  // written, so the caller can say "Applied to 3 of 4 layers". Zero written
  // ⇒ no push, so undo never has an empty step to swallow.
  const applyPresetToTracks = useCallback(
    (ids: string[], preset: MotionPresetId, atMs: number): number => {
      const targets = ids.filter((id) => base.has(id));
      if (targets.length === 0) return 0;
      push(
        targets.reduce(
          (tl, id) => applyPreset(tl, base, id, preset, atMs),
          timeline
        )
      );
      return targets.length;
    },
    [timeline, base, push]
  );

  const applyEmphasisToTracks = useCallback(
    (ids: string[], preset: EmphasisPresetId): number => {
      let tl = timeline;
      let written = 0;
      for (const id of ids) {
        const next = applyEmphasisPreset(tl, base, id, preset, playheadMs);
        if (!next) continue;
        tl = next;
        written++;
      }
      if (written > 0) push(tl);
      return written;
    },
    [timeline, base, playheadMs, push]
  );

  const applyTemplateToTracks = useCallback(
    (ids: string[], body: MotionTemplateBody): number => {
      let tracks = timeline.tracks;
      let written = 0;
      for (const id of ids) {
        const restPose = base.get(id);
        if (!restPose) continue;
        const track = bakeTemplateToTrack(
          body,
          id,
          restPose,
          timeline.duration_ms
        );
        if (!track) continue;
        tracks = [
          ...tracks.filter(
            (t) => !(t.kind === "overlay" && t.overlay_id === id)
          ),
          track,
        ];
        written++;
      }
      if (written > 0) push({ ...timeline, tracks });
      return written;
    },
    [timeline, base, push]
  );

  const applyStaggerToTracks = useCallback(
    (ids: string[], preset: MotionPresetId): number => {
      const targets = ids.filter((id) => base.has(id));
      if (targets.length === 0) return 0;
      push(applyStagger(timeline, base, targets, preset));
      return targets.length;
    },
    [timeline, base, push]
  );
```

c) Add the four to the return object next to `applyTemplate`.

- [ ] **Step 4: Run to verify it passes**

Run: `bun test src/components/studio/kv-generator/motion/useMotionEditorState.bulk.test.tsx`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/useMotionEditorState.bulk.test.tsx
git commit -m "feat(kv-motion): bulk preset/emphasis/template/stagger writers — N layers, one push, skip what can't take it

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `pasteMotionInto` extraction + `pasteMotionToTracks`

**Files:**
- Modify: `src/components/studio/kv-generator/motion/useMotionEditorState.ts` (`pasteMotion`, lines ~968–1045; module-level pure fn near `pruneTimelineToOverlays`, line ~115)
- Test: `src/components/studio/kv-generator/motion/useMotionEditorState.pasteInto.test.tsx` (new)

**Interfaces:**
- Produces (module export): `pasteMotionInto(timeline: MotionTimeline, base: Map<string, MotionProps>, trackId: string, clip: MotionClip, mode: PasteMotionMode, playheadMs: number, target?: MotionPasteTarget): MotionTimeline | null` — pure; `null` when the clip can't be placed or the id has no rest pose.
- Produces (hook): `pasteMotionToTracks(ids: string[], mode: PasteMotionMode): number`.

- [ ] **Step 1: Write the failing tests**

```tsx
// src/components/studio/kv-generator/motion/useMotionEditorState.pasteInto.test.tsx
/** `pasteMotionInto` is the pure body of `pasteMotion`, extracted so the
 *  bulk paste can reduce it. Pin: the single-layer path is byte-for-byte
 *  what it was, and the bulk path is one push over N layers. */
import { createElement, type ReactNode } from "react";
import { beforeEach, describe, expect, it } from "bun:test";
import { act, renderHook } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { KvMotionProject } from "@/types/kv/motionProject";
import type { StudioOverlay } from "@/types/studio";
import { useKvMotionClipStore } from "@/store/kv/useKvMotionClipStore";
import { baseProps } from "./applyTimeline";
import { pasteMotionInto, useMotionEditorState } from "./useMotionEditorState";

function overlay(id: string, z: number): StudioOverlay {
  return {
    id, studio_file_id: "f1", type: "text",
    x: 0.1, y: 0.2, width: 0.3, height: 0.1, rotation: 0, z,
    payload: { type: "text", content: id, color: "#000000" },
    created_at: "t", updated_at: "t",
  };
}

const qcWrapper = ({ children }: { children: ReactNode }) =>
  createElement(
    QueryClientProvider,
    { client: new QueryClient({ defaultOptions: { queries: { retry: false } } }) },
    children
  );

function makeProject(): KvMotionProject {
  return {
    id: "p1", studioFileId: "f1", boardGenerationId: "g1", name: "Test",
    audioUrl: null, durationMs: 5000, fps: 30, createdAt: "", updatedAt: "",
    snapshot: {
      base_image_url: "https://x/y.png", board_width: 1080, board_height: 1080,
      overlays: [overlay("src", 3), overlay("a", 2), overlay("b", 1)],
    },
    timeline: {
      version: 1, duration_ms: 5000, fps: 30,
      tracks: [{
        kind: "overlay", overlay_id: "src",
        keyframes: [
          { t_ms: 0, props: { opacity: 0 }, easing: "linear" },
          { t_ms: 500, props: { opacity: 1 }, easing: "out" },
        ],
      }],
    },
  };
}

const kfs = (r: { timeline: KvMotionProject["timeline"] }, id: string) =>
  r.timeline.tracks.find((t) => t.kind === "overlay" && t.overlay_id === id)?.keyframes ?? [];

beforeEach(() => useKvMotionClipStore.getState().clear());

describe("pasteMotionInto", () => {
  it("single-layer pasteMotion produces the same timeline as the pure function", () => {
    const project = makeProject();
    const { result } = renderHook(() => useMotionEditorState(project, { autosave: false }), { wrapper: qcWrapper });
    act(() => { result.current.copyMotion("src", "menu"); });
    const clip = useKvMotionClipStore.getState().clip;
    expect(clip).not.toBeNull();

    const expected = pasteMotionInto(
      result.current.timeline, baseProps(project.snapshot.overlays), "a", clip!, "follow", 0
    );
    act(() => { result.current.pasteMotion("a", "follow", "menu"); });

    expect(result.current.timeline).toEqual(expected);
  });

  it("returns null for an id with no rest pose", () => {
    const project = makeProject();
    const { result } = renderHook(() => useMotionEditorState(project, { autosave: false }), { wrapper: qcWrapper });
    act(() => { result.current.copyMotion("src", "menu"); });
    const clip = useKvMotionClipStore.getState().clip!;
    expect(pasteMotionInto(result.current.timeline, new Map(), "a", clip, "follow", 0)).toBeNull();
  });
});

describe("pasteMotionToTracks", () => {
  it("pastes onto every id as one undo step and reports the count", () => {
    const { result } = renderHook(() => useMotionEditorState(makeProject(), { autosave: false }), { wrapper: qcWrapper });
    act(() => { result.current.copyMotion("src", "menu"); });
    let n = 0;
    act(() => { n = result.current.pasteMotionToTracks(["a", "b"], "follow"); });
    expect(n).toBe(2);
    expect(kfs(result.current, "a").map((k) => k.t_ms)).toEqual([0, 500]);
    expect(kfs(result.current, "b").map((k) => k.t_ms)).toEqual([0, 500]);
    act(() => result.current.undo());
    expect(kfs(result.current, "a")).toEqual([]);
    expect(kfs(result.current, "b")).toEqual([]);
  });

  it("returns 0 and pushes nothing with an empty clipboard", () => {
    const { result } = renderHook(() => useMotionEditorState(makeProject(), { autosave: false }), { wrapper: qcWrapper });
    let n = -1;
    act(() => { n = result.current.pasteMotionToTracks(["a"], "follow"); });
    expect(n).toBe(0);
    expect(result.current.canUndo).toBe(false);
  });
});
```

If `useKvMotionClipStore` has no `clear`, check its actions (`grep -n 'clear\|reset' src/store/kv/useKvMotionClipStore.ts`) and use the one that empties `clip`.

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/motion/useMotionEditorState.pasteInto.test.tsx`
Expected: FAIL — `pasteMotionInto` is not exported.

- [ ] **Step 3: Implement**

a) Add `type MotionClip` to the `@/lib/video-editor/motionClip` import.

b) Below `pruneTimelineToOverlays` (line ~115) add the pure function — this is the body of today's `pasteMotion` between `const restPose = base.get(trackId)` and `push(next)`, moved verbatim, with `playheadRef.current` replaced by the `playheadMs` parameter:

```ts
/** The pure half of `pasteMotion`: where a clip lands on `trackId` and what
 *  the timeline becomes. `null` when the layer has no rest pose or the clip
 *  can't be placed. Extracted so the bulk paste (`pasteMotionToTracks`) can
 *  reduce it over several layers into one push; the single-layer
 *  `pasteMotion` calls the same function so the two can't drift. */
export function pasteMotionInto(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  trackId: string,
  clip: MotionClip,
  mode: PasteMotionMode,
  playheadMs: number,
  target?: MotionPasteTarget
): MotionTimeline | null {
  const restPose = base.get(trackId);
  if (!restPose) return null;

  if (clip.scope === "segment") {
    const atMs =
      target?.kind === "block"
        ? target.startMs
        : target?.kind === "slot"
          ? target.anchor === "end"
            ? Math.max(0, target.atMs - clip.source_duration_ms)
            : target.atMs
          : playheadMs;
    const placed = placeMotionClipAt(
      clip,
      trackId,
      restPose,
      timeline.duration_ms,
      atMs,
      mode
    );
    if (!placed) return null;
    const cleared =
      target?.kind === "block"
        ? deleteSegmentKeyframes(
            timeline,
            trackId,
            target.startMs,
            target.endMs
          )
        : timeline;
    return mergeKeyframesIntoTrack(cleared, trackId, placed);
  }

  const track = pasteMotionClip(
    clip,
    trackId,
    restPose,
    timeline.duration_ms,
    mode
  );
  if (!track) return null;
  const others = timeline.tracks.filter(
    (t) => !(t.kind === "overlay" && t.overlay_id === trackId)
  );
  return { ...timeline, tracks: [...others, track] };
}
```

Compare against the current inline body before deleting it — if the inline version differs in any way (a comment is fine; logic is not), keep the inline logic and adjust the function to match.

c) Rewrite `pasteMotion`'s body to:

```ts
      const { clip, sourceProjectId } = useKvMotionClipStore.getState();
      if (!clip) return false;
      const next = pasteMotionInto(
        timeline,
        base,
        trackId,
        clip,
        mode,
        playheadRef.current,
        target
      );
      if (!next) return false;
      push(next);
      // …the existing trackKvMotionClipPasted({...}) call and `return true` stay exactly as they are…
```

d) After `pasteMotion`, add:

```ts
  // Bulk paste — always at the playhead (a multi-select has no single block
  // or slot to target). One push; one `motion_clip_pasted` per layer written,
  // because the event is "a copied motion landed on a layer" and N layers
  // are N landings.
  const pasteMotionToTracks = useCallback(
    (ids: string[], mode: PasteMotionMode): number => {
      const { clip, sourceProjectId } = useKvMotionClipStore.getState();
      if (!clip) return 0;
      let tl = timeline;
      const written: string[] = [];
      for (const id of ids) {
        const next = pasteMotionInto(tl, base, id, clip, mode, playheadRef.current);
        if (!next) continue;
        tl = next;
        written.push(id);
      }
      if (written.length === 0) return 0;
      push(tl);
      for (const id of written) {
        const overlay = snapshot.overlays.find((o) => o.id === id);
        trackKvMotionClipPasted({
          project_id: project.id,
          overlay_type: overlay ? overlayTypeOf(overlay) : "shape",
          source: "menu",
          mode,
          scope: clip.scope,
          placement: clip.scope === "track" ? "replace_track" : "playhead",
          cross_project: sourceProjectId !== project.id,
        });
      }
      return written.length;
    },
    [base, timeline, push, snapshot.overlays, project.id]
  );
```

e) Add `pasteMotionToTracks` to the return object.

- [ ] **Step 4: Run to verify it passes, plus the paste neighbours**

Run: `bun test src/components/studio/kv-generator/motion/useMotionEditorState.pasteInto.test.tsx src/components/studio/kv-generator/motion/useMotionEditorState.copyPasteMotion.test.tsx src/components/studio/kv-generator/motion/useMotionEditorState.copyPasteMotion.analytics.test.tsx`
Expected: all pass (the copyPaste suites are the regression guard for the extraction).

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/useMotionEditorState.pasteInto.test.tsx
git commit -m "refactor(kv-motion): extract pasteMotionInto; add pasteMotionToTracks (one push over N layers)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Analytics source values

**Files:**
- Modify: `src/lib/analytics/kv-generator-events.ts:1170-1195`

- [ ] **Step 1: Extend the union and its comment**

Replace the `source` line and the `track_count` comment in `KvMotionPresetAppliedProps`:

```ts
  /** "track" = one layer's own preset menu; "stagger" = the toolbar control
   *  that deals the same preset across every layer; "replace" = the Slots
   *  view's segment context menu "Change motion" — swapping the preset
   *  behind an EXISTING block while keeping its tuned span, rather than
   *  authoring a fresh one; "template" = the ✨ menu's Saved group, applying
   *  a brand-scoped saved recipe to a layer; "multi" = the same layer menu
   *  opened on a MULTI-selection, writing one motion (preset or template —
   *  `template_id` says which) to every selected layer at once;
   *  "multi_stagger" = that menu's Stagger toggle, or the toolbar Stagger
   *  while a multi-selection is active — a cascade over the selection only.
   *  Six different authoring habits, worth telling apart in one funnel
   *  rather than a parallel event. */
  source: "track" | "stagger" | "replace" | "template" | "multi" | "multi_stagger";
  /** Layers the action actually wrote to — always 1 for "track"/"template"/
   *  "replace"; the selection size (minus any member that could not take
   *  the motion) for "multi"/"multi_stagger". */
  track_count: number;
```

- [ ] **Step 2: Type-check the file's consumers**

Run: `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c 'kv-generator-events' || true`
Expected: `0` (the project has a ~777-error baseline elsewhere — only this file's count matters).

- [ ] **Step 3: Commit**

```bash
git add src/lib/analytics/kv-generator-events.ts
git commit -m "feat(analytics): motion_preset_applied sources multi / multi_stagger

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `TrackPresetMenu` — multi header, hidden items, Stagger toggle

**Files:**
- Modify: `src/components/video-editor/MotionPanelHeader.tsx` (icon override)
- Modify: `src/components/studio/kv-generator/motion/TrackPresetMenu.tsx`
- Test: `src/components/studio/kv-generator/motion/TrackPresetMenu.multi.test.tsx` (new — `TrackPresetMenu.test.tsx` is 10 KB, but keep the new cases separate anyway so the multi contract reads as one file)

**Interfaces:**
- Produces new props on `TrackPresetMenu`: `targetTrackIds?: string[]` (default `[]` → treated as single); `onApplyStagger?: (preset: MotionPresetId) => void`; `onOpen?: () => void` (fires when the ✨ popover opens — not for anchored mode).
- `MotionPanelHeader` gains `iconOverride?: ComponentType<{ className?: string }>`.

- [ ] **Step 1: Write the failing tests**

```tsx
// src/components/studio/kv-generator/motion/TrackPresetMenu.multi.test.tsx
/** The layer menu on a MULTI-selection: header counts layers, single-layer
 *  lifecycle items disappear, and a Stagger toggle routes entrance/exit
 *  picks through `onApplyStagger`. `screen` is broken under bun — everything
 *  goes through `within(document.body)`. */
import { describe, expect, it, mock } from "bun:test";
import { fireEvent, render, within } from "@testing-library/react";
import { TrackPresetMenu } from "./TrackPresetMenu";

const body = () => within(document.body);

function renderMenu(overrides: Partial<Parameters<typeof TrackPresetMenu>[0]> = {}) {
  const props = {
    trackName: "Headline",
    trackIcon: "text" as const,
    onApply: mock(() => {}),
    onApplyEmphasis: mock(() => {}),
    onApplyStagger: mock(() => {}),
    onOpen: mock(() => {}),
    playheadMs: 0,
    durationMs: 5000,
    templates: [],
    currentUserId: "user-1",
    hasKeyframes: true,
    onApplyTemplate: mock(() => {}),
    onSaveTemplate: mock(() => {}),
    onRenameTemplate: mock(() => {}),
    onDeleteTemplate: mock(() => {}),
    onCopyMotion: mock(() => {}),
    onPasteMotion: mock((_mode: "follow" | "exact") => {}),
    canPasteMotion: true,
    targetTrackIds: ["a", "b", "c"],
    ...overrides,
  };
  render(<TrackPresetMenu {...props} />);
  fireEvent.click(body().getByRole("button", { name: "Apply motion preset to Headline" }));
  return props;
}

describe("TrackPresetMenu on a multi-selection", () => {
  it("fires onOpen when the ✨ opens it", () => {
    const p = renderMenu();
    expect(p.onOpen).toHaveBeenCalledTimes(1);
  });

  it("headers with the count, and hides Copy and Save", () => {
    renderMenu();
    expect(body().getByText("3 layers")).toBeTruthy();
    expect(body().queryByTestId("copy-motion")).toBeNull();
    expect(body().queryByTestId("save-motion-template")).toBeNull();
  });

  it("still offers Paste", () => {
    renderMenu();
    expect(body().getByTestId("paste-motion-toggle")).toBeTruthy();
  });

  it("with Stagger off, an entrance pick goes through onApply", () => {
    const p = renderMenu();
    fireEvent.click(body().getByTestId("rail-preset-fade-in"));
    expect(p.onApply).toHaveBeenCalledWith("fade-in");
    expect(p.onApplyStagger).not.toHaveBeenCalled();
  });

  it("with Stagger on, the same pick goes through onApplyStagger", () => {
    const p = renderMenu();
    fireEvent.click(body().getByRole("switch", { name: "Stagger across 3 layers" }));
    fireEvent.click(body().getByTestId("rail-preset-fade-in"));
    expect(p.onApplyStagger).toHaveBeenCalledWith("fade-in");
    expect(p.onApply).not.toHaveBeenCalled();
  });

  it("hides Duplicate/Delete in anchored mode while multi", () => {
    render(
      <TrackPresetMenu
        {...({
          trackName: "Headline", trackIcon: "text", onApply: mock(() => {}), onApplyEmphasis: mock(() => {}),
          playheadMs: 0, durationMs: 5000, templates: [], currentUserId: "u", hasKeyframes: true,
          onApplyTemplate: mock(() => {}), onSaveTemplate: mock(() => {}), onRenameTemplate: mock(() => {}),
          onDeleteTemplate: mock(() => {}), onCopyMotion: mock(() => {}), onPasteMotion: mock(() => {}),
          canPasteMotion: false, targetTrackIds: ["a", "b"],
          anchor: { x: 10, y: 10 }, onCloseAnchored: mock(() => {}),
          onDuplicateLayer: mock(() => {}), onDeleteLayer: mock(() => {}),
        } as Parameters<typeof TrackPresetMenu>[0])}
      />
    );
    expect(body().queryByRole("menuitem", { name: "Duplicate layer" })).toBeNull();
    expect(body().queryByRole("menuitem", { name: "Delete layer" })).toBeNull();
    expect(body().getByText("2 layers")).toBeTruthy();
  });

  it("a single target renders exactly the old menu", () => {
    renderMenu({ targetTrackIds: ["a"] });
    expect(body().getByText("Headline")).toBeTruthy();
    expect(body().getByTestId("copy-motion")).toBeTruthy();
    expect(body().queryByRole("switch", { name: /Stagger/ })).toBeNull();
  });
});
```

Check the grid's test id for the first entrance preset: `grep -n 'testIdPrefix\|data-testid' src/components/video-editor/MotionPresetGrid.tsx` and the first id in `ENTRANCE_PRESET_IDS`; the tests above assume `rail-preset-<id>` and an id of `fade_in`. Adjust the literal to the real one.

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/motion/TrackPresetMenu.multi.test.tsx`
Expected: FAIL — "3 layers" not found / `onOpen` not called.

- [ ] **Step 3: `MotionPanelHeader` icon override**

In `MotionPanelHeader.tsx`, add to the props type and destructuring:

```ts
  /** Replaces the layer glyph — the multi-select strip has no single layer
   *  type to show, so it shows a stack. */
  iconOverride?: ComponentType<{ className?: string }>;
```

and change the icon resolution to:

```ts
  const Icon = iconOverride ?? (icon ? (TRACK_ICONS[icon] ?? Shapes) : ClipboardText);
```

Add `import type { ComponentType } from "react";`.

- [ ] **Step 4: `TrackPresetMenu` changes**

a) Imports: add `Stack` to the `@phosphor-icons/react` import.

b) Props — add to the destructuring and the type:

```ts
  /** The layers this menu writes to. One id (or omitted) is the classic
   *  per-layer menu. More than one — the host's multi-selection — turns the
   *  header into a count, hides the single-layer actions (Copy, Save,
   *  Duplicate, Delete) and offers a Stagger toggle. */
  targetTrackIds?: string[];
  /** Entrance/exit pick while the Stagger toggle is on: deal the preset
   *  across the targets instead of writing it on each at the same time. */
  onApplyStagger?: (preset: MotionPresetId) => void;
  /** The ✨ popover just opened (not fired in anchored mode — the host opened
   *  that itself). The host uses it to collapse a multi-selection when the
   *  ✨ belongs to a layer outside it. */
  onOpen?: () => void;
```

c) Inside the component, after `const [tab, setTab]`:

```ts
  const multi = (targetTrackIds?.length ?? 0) > 1;
  const count = targetTrackIds?.length ?? 1;
  const [stagger, setStagger] = useState(false);
```

d) In `onOpenChange`, before the `anchored` branch:

```ts
        if (next && !anchored) onOpen?.();
        if (!next) setStagger(false);
```

e) `MotionPanelHeader` call: make `name` and copy props conditional:

```tsx
          <MotionPanelHeader
            icon={trackIcon}
            iconOverride={multi ? Stack : undefined}
            name={multi ? `${count} layers` : trackName}
            copyLabel={multi ? undefined : "Copy motion"}
            pasteLabel="Paste motion"
            canCopy={hasKeyframes}
            copyDisabledReason="This layer has no animation yet"
            canPaste={canPasteMotion}
            onCopy={
              multi
                ? undefined
                : () => {
                    onCopyMotion();
                    closeMenu();
                  }
            }
            onPaste={(mode) => {
              onPasteMotion(mode);
              closeMenu();
            }}
          />
```

(`MotionPanelHeader` already renders the Copy button only when `onCopy` is given.)

f) Directly under the header, the Stagger toggle (only when `multi`):

```tsx
          {multi && (
            <label className="mb-1 flex items-center justify-between rounded-lg px-2 py-1 text-textXs text-text-inverse-subtle">
              <span>Stagger across {count} layers</span>
              <button
                type="button"
                role="switch"
                aria-checked={stagger}
                aria-label={`Stagger across ${count} layers`}
                onClick={() => setStagger((v) => !v)}
                className={cn(
                  "relative h-4 w-7 rounded-full transition-colors",
                  stagger ? "bg-white/60" : "bg-white/15"
                )}
              >
                <span
                  className={cn(
                    "absolute top-0.5 size-3 rounded-full bg-black transition-transform",
                    stagger ? "translate-x-3.5" : "translate-x-0.5"
                  )}
                />
              </button>
            </label>
          )}
```

Check `@/components/frndos/Toggle` first (`grep -n 'export' src/components/frndos/Toggle.tsx`); if it renders `role="switch"` and takes `checked`/`onChange`/`aria-label`, use it instead of the hand-rolled button.

g) "Save as template…" button: wrap in `{!multi && ( … )}`.

h) The entrance/exit grid's `onPick`:

```ts
                onPick={(id) => {
                  if (multi && stagger && onApplyStagger) {
                    onApplyStagger(id as MotionPresetId);
                  } else {
                    onApply(id as MotionPresetId);
                  }
                  closeMenu();
                  setTab("default");
                }}
```

i) The anchored `Layer actions` block: change its condition to `{anchored && !multi && (onDuplicateLayer || onDeleteLayer) && (`.

j) `aria-label` on the wrapper `div` and the ✨ button stay keyed on `trackName` (the ✨ belongs to a row; tests find it by that).

- [ ] **Step 5: Run to verify it passes, plus the old suite**

Run: `bun test src/components/studio/kv-generator/motion/TrackPresetMenu.multi.test.tsx src/components/studio/kv-generator/motion/TrackPresetMenu.test.tsx`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/components/video-editor/MotionPanelHeader.tsx src/components/studio/kv-generator/motion/TrackPresetMenu.tsx src/components/studio/kv-generator/motion/TrackPresetMenu.multi.test.tsx
git commit -m "feat(kv-motion): TrackPresetMenu targets N layers — count header, Stagger toggle, single-layer items hidden

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Dock rows — modifier-aware focus, membership tint, primary ring

**Files:**
- Modify: `src/components/video-editor/types.ts:80,316`
- Modify: `src/components/video-editor/TimelineDock.tsx:455-515`
- Modify: `src/components/video-editor/BlockTrackRow.tsx` (row `onClick` ~line 1893; `TrackNameCell` call ~1919; props ~84, 224)
- Modify: `src/components/video-editor/TrackRow.tsx` (row `onClick` ~line 148; `TrackNameCell` call ~166; props ~28)
- Modify: `src/components/video-editor/TrackNameCell.tsx` (`primary` prop)
- Modify: `src/components/video-editor/TimelineDock.rowfocus.test.tsx` (one assertion)
- Test: `src/components/video-editor/TimelineDock.multiselect.test.tsx` (new)

**Interfaces:**
- `TimelineDockProps.selectedTrackIds?: string[]` — when omitted, membership = `[selectedKeyframe.trackId]` (so every existing caller/test is unchanged).
- `TimelineDockProps.onFocusTrack?: (trackId: string, mode: SelectMode) => void`.
- `TrackNameCell` gains `primary?: boolean`.

- [ ] **Step 1: Write the failing tests**

```tsx
// src/components/video-editor/TimelineDock.multiselect.test.tsx
/** Multi-select on the dock: a row click carries its modifier as a
 *  SelectMode, every member is tinted, only the primary is ringed, and a
 *  block click stays a plain (collapsing) select. Harness copied from
 *  `TimelineDock.rowfocus.test.tsx`; `screen` is broken under bun. */
import { describe, expect, it, mock } from "bun:test";
import { fireEvent, render, within } from "@testing-library/react";
import { DEFAULT_TIMELINE } from "@/lib/video-editor/timeline";
import { TimelineDock } from "./TimelineDock";

const body = () => within(document.body);

const TRACKS = [
  { id: "ov1", name: "Headline", icon: "text" as const },
  { id: "ov2", name: "Sticker", icon: "image" as const },
  { id: "ov3", name: "Badge", icon: "shape" as const },
];

const tl = () => ({
  ...DEFAULT_TIMELINE(),
  tracks: [
    {
      kind: "overlay" as const,
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 1000, props: { opacity: 0 }, easing: "linear" as const },
        { t_ms: 1500, props: { opacity: 1 }, easing: "out" as const },
      ],
    },
  ],
});

function handlers() {
  return {
    onSeek: mock(), onTogglePlay: mock(), onSelectKeyframe: mock(), onMoveKeyframe: mock(),
    onDeleteKeyframe: mock(), onInsertKeyframe: mock(), onDurationChange: mock(), onToggleLoop: mock(),
    onViewChange: mock(), onShiftSegment: mock(), onStretchSegment: mock(), onStretchTrack: mock(),
    onSelectTrack: mock(), onPreviewRangeChange: mock(), onDeleteSegment: mock(), onReplaceSegment: mock(),
    onApplySlotPreset: mock(), onToggleTrackLocked: mock(), onToggleTrackHidden: mock(), onZoomChange: mock(),
    onFocusTrack: mock(), onTrackContextMenu: mock(),
  };
}

function renderDock(overrides: Record<string, unknown> = {}, view: "slots" | "keyframes" = "slots") {
  const h = handlers();
  render(
    <TimelineDock
      tracks={TRACKS}
      timeline={tl()}
      playheadMs={0}
      playing={false}
      selectedKeyframe={null}
      loop={false}
      view={view}
      previewRange={null}
      {...h}
      {...overrides}
    />
  );
  return h;
}

describe("row click carries the modifier", () => {
  for (const view of ["slots", "keyframes"] as const) {
    it(`${view}: plain / Cmd / Shift → replace / toggle / range`, () => {
      const h = renderDock({}, view);
      const row = body().getByTestId("track-row-ov2");
      fireEvent.click(row);
      fireEvent.click(row, { metaKey: true });
      fireEvent.click(row, { ctrlKey: true });
      fireEvent.click(row, { shiftKey: true });
      expect(h.onFocusTrack.mock.calls).toEqual([
        ["ov2", "replace"], ["ov2", "toggle"], ["ov2", "toggle"], ["ov2", "range"],
      ]);
    });
  }

  it("a block click stays on onSelectTrack — it is a collapse, never a toggle", () => {
    const h = renderDock();
    fireEvent.click(body().getByTestId("block-bar-ov1-0"), { metaKey: true });
    expect(h.onSelectTrack).toHaveBeenCalledWith("ov1");
    expect(h.onFocusTrack).not.toHaveBeenCalled();
  });
});

describe("membership tint and primary ring", () => {
  it("tints every member, rings only the primary", () => {
    renderDock({
      selectedTrackIds: ["ov1", "ov3"],
      selectedKeyframe: { trackId: "ov3", tMs: 0 },
    });
    expect(body().getByTestId("track-row-ov1").className).toContain("bg-white/[0.1]");
    expect(body().getByTestId("track-row-ov3").className).toContain("bg-white/[0.1]");
    expect(body().getByTestId("track-row-ov2").className).not.toContain("bg-white/[0.1]");
    expect(body().getByTestId("track-name-ov3").getAttribute("data-primary")).toBe("true");
    expect(body().getByTestId("track-name-ov1").getAttribute("data-primary")).toBe("false");
  });

  it("without selectedTrackIds, membership is the primary alone (old callers unchanged)", () => {
    renderDock({ selectedKeyframe: { trackId: "ov2", tMs: 0 } });
    expect(body().getByTestId("track-row-ov2").className).toContain("bg-white/[0.1]");
    expect(body().getByTestId("track-row-ov1").className).not.toContain("bg-white/[0.1]");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/video-editor/TimelineDock.multiselect.test.tsx`
Expected: FAIL — `onFocusTrack` called with one arg; `track-name-ov3` not found.

- [ ] **Step 3: Implement**

a) `types.ts`: add `import type { SelectMode } from "./selectionMode";`. Under `selectedKeyframe: SelectedKeyframe;` (line 80):

```ts
  /** Every selected layer (multi-select) — the row tint. Optional: a host
   *  without multi-select omits it and the primary (`selectedKeyframe`) is
   *  the only member. The primary additionally gets the ring. */
  selectedTrackIds?: string[];
```

Change `onFocusTrack` (line 316) to `onFocusTrack?: (trackId: string, mode: SelectMode) => void;` and extend its comment with: `\`mode\` is the click's modifier (\`modeFromEvent\`): Shift extends a range, Cmd/Ctrl toggles, plain replaces.`

b) `TimelineDock.tsx`: destructure `selectedTrackIds`; before the row map:

```ts
  const memberIds = useMemo(
    () =>
      new Set(
        selectedTrackIds ??
          (selectedKeyframe ? [selectedKeyframe.trackId] : [])
      ),
    [selectedTrackIds, selectedKeyframe]
  );
```

In the `BlockTrackRow` element: `selected={memberIds.has(track.id)}` and add `primary={selectedKeyframe?.trackId === track.id}`. In the `TrackRow` element add `selected={memberIds.has(track.id)}` and `primary={selectedKeyframe?.trackId === track.id}` (TrackRow currently derives `selected` itself from `selectedKeyframe` — find `const selected =` in `TrackRow.tsx` and replace it with the prop).

c) `BlockTrackRow.tsx`: add `import { modeFromEvent } from "./selectionMode";`. Props (`~line 84` and the inner row props `~342`): add `primary?: boolean;`, change `onFocusTrack?: (trackId: string, mode: SelectMode) => void;` (import the type). Row `onClick`:

```tsx
        onClick={(e) => {
          if (!locked) onFocusTrack?.(track.id, modeFromEvent(e));
        }}
```

Thread `primary` down to the `<TrackNameCell … primary={primary} />` call. If the inner component `BlockTrackRow` is wrapped by an outer one (line ~1379 destructures again), thread `primary` through both.

d) `TrackRow.tsx`: same import; props `selected: boolean; primary?: boolean;` and the `onFocusTrack` type; row `onClick={(e) => { if (!locked) onFocusTrack?.(track.id, modeFromEvent(e)); }}`; `<TrackNameCell … primary={primary} />`.

e) `TrackNameCell.tsx`: add `primary?: boolean;` to props and destructuring; on the outer `div` (the one with `onContextMenu`) add `data-testid={\`track-name-${track.id}\`}` and `data-primary={primary ? "true" : "false"}`; on the inner flex div add to the `cn(...)`:

```ts
          primary && "ring-1 ring-inset ring-white/25"
```

(a ring, not a border — the cell's height must not change; `ring-inset` keeps it inside the 36px row.)

f) `TimelineDock.rowfocus.test.tsx`: change `expect(h.onFocusTrack).toHaveBeenCalledWith("ov2");` to `expect(h.onFocusTrack).toHaveBeenCalledWith("ov2", "replace");`.

- [ ] **Step 4: Run to verify it passes, plus the dock suites that touch rows**

Run: `bun test src/components/video-editor/TimelineDock.multiselect.test.tsx src/components/video-editor/TimelineDock.rowfocus.test.tsx src/components/video-editor/TimelineDock.test.tsx src/components/video-editor/TimelineDock.subrows.test.tsx`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/components/video-editor/types.ts src/components/video-editor/TimelineDock.tsx src/components/video-editor/BlockTrackRow.tsx src/components/video-editor/TrackRow.tsx src/components/video-editor/TrackNameCell.tsx src/components/video-editor/TimelineDock.rowfocus.test.tsx src/components/video-editor/TimelineDock.multiselect.test.tsx
git commit -m "feat(kv-motion): dock rows carry the click modifier; members tinted, primary ringed

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: `bulkTargetIds` helper

**Files:**
- Create: `src/components/studio/kv-generator/motion/bulkTargetIds.ts`
- Test: `src/components/studio/kv-generator/motion/bulkTargetIds.test.ts`

**Interfaces:**
- Produces: `bulkTargetIds(trackId: string, selectedTrackIds: string[]): string[]` — the selection when `trackId` is a member of a multi-selection, else `[trackId]`.

- [ ] **Step 1: Write the failing test**

```ts
// src/components/studio/kv-generator/motion/bulkTargetIds.test.ts
/** Which layers a menu opened on `trackId` writes to. The one rule the
 *  rail ✨, the dock right-click and the toolbar all share. */
import { describe, expect, it } from "bun:test";
import { bulkTargetIds } from "./bulkTargetIds";

describe("bulkTargetIds", () => {
  it("a member of a multi-selection targets the whole selection, in its order", () => {
    expect(bulkTargetIds("b", ["a", "b", "c"])).toEqual(["a", "b", "c"]);
  });
  it("a non-member targets itself alone", () => {
    expect(bulkTargetIds("z", ["a", "b"])).toEqual(["z"]);
  });
  it("a single-member selection targets that one layer even when it is the member", () => {
    expect(bulkTargetIds("a", ["a"])).toEqual(["a"]);
    expect(bulkTargetIds("a", [])).toEqual(["a"]);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/motion/bulkTargetIds.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

```ts
// src/components/studio/kv-generator/motion/bulkTargetIds.ts
/** The layers a per-layer menu opened on `trackId` should write to: the
 *  whole multi-selection when `trackId` is one of its members, otherwise
 *  just `trackId`. A one-member selection is not "multi" — the classic
 *  single-layer menu, toasts and analytics apply. The host collapses the
 *  selection when a menu opens on a non-member (Figma's rule), so the
 *  second branch is what that menu then sees. */
export function bulkTargetIds(
  trackId: string,
  selectedTrackIds: string[]
): string[] {
  return selectedTrackIds.length > 1 && selectedTrackIds.includes(trackId)
    ? selectedTrackIds
    : [trackId];
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bun test src/components/studio/kv-generator/motion/bulkTargetIds.test.ts`
Expected: 3 pass.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/bulkTargetIds.ts src/components/studio/kv-generator/motion/bulkTargetIds.test.ts
git commit -m "feat(kv-motion): bulkTargetIds — which layers a menu on one row writes to

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Editor wiring — rail, menu, toasts, toolbar Stagger, Esc, hint

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` — `PanelHeader` (~207), `applyPresetTo` (~911), `applyToolbarStagger` (~931), `pasteMotionTo` (~645), `applyTemplateTo` (~680), keydown effect (~1540), `trackPresetMenuProps` (~1680), rail rows (~2075–2115), dock `onFocusTrack`/`onTrackContextMenu` (~2263–2271), dock `selectedTrackIds` prop (~2357), toolbar Stagger (~1786–1824).

**Interfaces:**
- Consumes: everything from Tasks 1–8.

- [ ] **Step 1: Imports**

```ts
import { bulkTargetIds } from "./bulkTargetIds";
import { modeFromEvent } from "@/components/video-editor/selectionMode";
```

- [ ] **Step 2: `PanelHeader` hint**

```tsx
function PanelHeader({ title, hint }: { title: string; hint?: string }) {
  return (
    <div className="flex shrink-0 items-baseline justify-between border-b border-[rgba(255,255,255,0.05)] px-4 py-3">
      <p className="font-geist text-textSmMedium font-medium leading-[1.4] tracking-[-0.14px] text-text-inverse">
        {title}
      </p>
      {hint && (
        <span className="font-geist text-textXs text-text-inverse-subtlest">
          {hint}
        </span>
      )}
    </div>
  );
}
```

and at the rail: `<PanelHeader title="Layers" hint="Shift / ⌘-click for multiple" />`.

- [ ] **Step 3: `applyPresetTo` becomes target-aware**

Replace the whole `applyPresetTo`:

```ts
  /** Entrance/exit preset onto `targetIds`. One id is the classic per-layer
   *  path (source "track"); several is a multi-selection written at the same
   *  anchor in one undo step (source "multi"). A member with no rest pose is
   *  skipped and the toast says so. */
  const applyPresetTo = useCallback(
    (targetIds: string[], preset: MotionPresetId) => {
      const atMs = EXIT_PRESETS.has(preset)
        ? state.timeline.duration_ms
        : state.playheadMs;
      if (targetIds.length === 1) {
        state.push(
          applyPreset(state.timeline, state.base, targetIds[0], preset, atMs)
        );
        trackKvMotionPresetApplied({
          project_id: projectId,
          preset_id: preset,
          source: "track",
          track_count: 1,
        });
        return;
      }
      const written = state.applyPresetToTracks(targetIds, preset, atMs);
      reportBulk(written, targetIds.length);
      if (written > 0) {
        trackKvMotionPresetApplied({
          project_id: projectId,
          preset_id: preset,
          source: "multi",
          track_count: written,
        });
      }
    },
    [state, projectId, reportBulk]
  );
```

Add `reportBulk` ABOVE it (it is a dep):

```ts
  /** One toast for every bulk writer: silent on a clean sweep, "3 of 4" on a
   *  partial, an error when nothing could take the motion. */
  const reportBulk = useCallback(
    (written: number, total: number) => {
      if (written === total) return;
      if (written === 0) {
        showToast(
          "Couldn't apply to those layers",
          "They may be hidden, locked, or there's no room before the end.",
          "error"
        );
        return;
      }
      showToast(
        `Applied to ${written} of ${total} layers`,
        "The rest are hidden, locked, or have no room before the end.",
        "success"
      );
    },
    [showToast]
  );
```

- [ ] **Step 4: Bulk emphasis, template, paste, stagger**

Add after `applyPresetTo`:

```ts
  const applyEmphasisTo = useCallback(
    (targetIds: string[], preset: EmphasisPresetId) => {
      if (targetIds.length === 1) {
        state.applyEmphasis(targetIds[0], preset);
        return;
      }
      reportBulk(state.applyEmphasisToTracks(targetIds, preset), targetIds.length);
    },
    [state, reportBulk]
  );

  const applyStaggerTo = useCallback(
    (targetIds: string[], preset: MotionPresetId, source: "multi_stagger" | "stagger") => {
      const written = state.applyStaggerToTracks(targetIds, preset);
      if (source === "multi_stagger") reportBulk(written, targetIds.length);
      if (written > 0) {
        trackKvMotionPresetApplied({
          project_id: projectId,
          preset_id: preset,
          source,
          track_count: written,
        });
      }
    },
    [state, projectId, reportBulk]
  );
```

Change `applyTemplateTo(trackId, template)` to `applyTemplateTo(targetIds: string[], template)`: keep the existing single-id body under `if (targetIds.length === 1) { const trackId = targetIds[0]; …existing body… return; }`, then:

```ts
    const written = state.applyTemplateToTracks(targetIds, template.body);
    reportBulk(written, targetIds.length);
    if (written > 0) {
      trackKvMotionPresetApplied({
        project_id: projectId,
        preset_id: "template",
        source: "multi",
        track_count: written,
        template_id: template.id,
      });
    }
```

(Check what the single path fires for analytics — `grep -n 'source: "template"'` — and mirror its `preset_id`.)

Change `pasteMotionTo(trackId, mode, source, target?)` to accept `targetIds: string[]` as its first parameter: keep the `canPasteMotion` toast; then `if (targetIds.length === 1) { const trackId = targetIds[0]; …existing body… }` else:

```ts
    const written = state.pasteMotionToTracks(targetIds, mode);
    reportBulk(written, targetIds.length);
    return written > 0;
```

Update the keyboard call: `pasteMotion: (overlayId) => pasteMotionTo([overlayId], "follow", "keyboard")`. Grep for every other `pasteMotionTo(` and `applyTemplateTo(` caller and wrap the id in `[…]`.

- [ ] **Step 5: Toolbar Stagger is selection-aware**

```ts
  const staggerIds = useMemo(
    () =>
      state.selectedTrackIds.length > 1
        ? state.selectedTrackIds
        : orderedOverlayIds,
    [state.selectedTrackIds, orderedOverlayIds]
  );
  const applyToolbarStagger = useCallback(() => {
    if (!toolbarPreset || staggerIds.length === 0) return;
    applyStaggerTo(
      staggerIds,
      toolbarPreset,
      state.selectedTrackIds.length > 1 ? "multi_stagger" : "stagger"
    );
    setToolbarPreset("");
  }, [toolbarPreset, staggerIds, applyStaggerTo, state.selectedTrackIds.length]);
```

Remove the old `applyStagger(...)` import usage in the editor if nothing else uses it. Button: `disabled={!toolbarPreset || staggerIds.length === 0}` and label:

```tsx
              {state.selectedTrackIds.length > 1
                ? `Stagger (${state.selectedTrackIds.length})`
                : "Stagger"}
```

- [ ] **Step 6: `trackPresetMenuProps` carries the targets**

Inside `trackPresetMenuProps(trackId, …)`, first line: `const targetIds = bulkTargetIds(trackId, state.selectedTrackIds);` and change:

```ts
      targetTrackIds: targetIds,
      onOpen: () => {
        if (!state.selectedTrackIds.includes(trackId)) state.selectTrack(trackId);
      },
      onApply: (preset: MotionPresetId) => applyPresetTo(targetIds, preset),
      onApplyEmphasis: (preset: EmphasisPresetId) => applyEmphasisTo(targetIds, preset),
      onApplyStagger: (preset: MotionPresetId) => applyStaggerTo(targetIds, preset, "multi_stagger"),
      onApplyTemplate: (tpl: KvMotionTemplate) => applyTemplateTo(targetIds, tpl),
      onPasteMotion: (mode: PasteMotionMode) => pasteMotionTo(targetIds, mode, "menu"),
      hasKeyframes: state.timeline.tracks.some(
        (tr) => tr.kind === "overlay" && targetIds.includes(tr.overlay_id) && tr.keyframes.length > 0
      ),
```

Copy / Save / Rename / Delete-template props stay as they are (they use `trackId`; the menu hides Copy/Save while multi).

- [ ] **Step 7: Rail rows**

At `const selected = state.selectedKeyframe?.trackId === t.id;` (~2075) change to:

```ts
            const selected = state.selectedTrackIds.includes(t.id);
            const primary = state.selectedKeyframe?.trackId === t.id;
```

Row `cn(...)`: keep `selected && "bg-[rgba(255,255,255,0.1)]"` and add `primary && "ring-1 ring-inset ring-white/25"`. The name `Button`: `onClick={(e) => state.selectTrack(t.id, modeFromEvent(e))}` (if the frndos `Button` doesn't forward the event to `onClick`, check its prop type — `grep -n 'onClick' src/components/frndos/v2/Button.tsx` — and if it doesn't, wrap the button in a `span` that owns the click).

- [ ] **Step 8: Dock wiring**

`onFocusTrack={state.selectTrack}` already has the right shape (`(trackId, mode)`) — leave it. `onTrackContextMenu`:

```ts
          onTrackContextMenu={(trackId, x, y) => {
            const t = tracks.find((tr) => tr.id === trackId);
            if (!t || t.id === "__base__" || t.locked || t.hidden) return;
            // A right-click outside the selection collapses it to that row
            // first (Figma's rule) — the menu then targets only that layer.
            if (!state.selectedTrackIds.includes(trackId)) state.selectTrack(trackId);
            setTrackMenu({ trackId, x, y });
          }}
```

Pass `selectedTrackIds={state.selectedTrackIds}` next to `selectedKeyframe={state.selectedKeyframe}` (~2357).

- [ ] **Step 9: Esc clears the selection**

In the page keydown effect (~1540), before `clipboardKeyHandler(e)`:

```ts
      if (e.key === "Escape" && state.selectedTrackIds.length > 0) {
        const target = e.target as HTMLElement | null;
        if (
          target &&
          (target.tagName === "INPUT" ||
            target.tagName === "TEXTAREA" ||
            target.isContentEditable ||
            target.closest('[role="dialog"]'))
        ) {
          return;
        }
        state.clearSelection();
        return;
      }
```

Add `state.selectedTrackIds.length`, `state.clearSelection` to the effect's deps.

- [ ] **Step 10: Type-check the touched files and run every motion + dock suite touched so far**

Run: `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'kv-generator/motion/|video-editor/' | grep -v '\.test\.' || echo "no new type errors"`
Expected: `no new type errors` (compare against `git stash`-free baseline: run the same grep on `develop` in a worktree if anything shows — never `git stash`).

Run: `for f in src/components/studio/kv-generator/motion/useMotionEditorState.selection.test.tsx src/components/studio/kv-generator/motion/useMotionEditorState.bulk.test.tsx src/components/studio/kv-generator/motion/useMotionEditorState.pasteInto.test.tsx src/components/studio/kv-generator/motion/useMotionEditorState.copyPasteMotion.test.tsx src/components/studio/kv-generator/motion/TrackPresetMenu.test.tsx src/components/studio/kv-generator/motion/TrackPresetMenu.multi.test.tsx src/components/studio/kv-generator/motion/motionClipboardKeys.test.ts src/components/video-editor/TimelineDock.multiselect.test.tsx src/components/video-editor/TimelineDock.rowfocus.test.tsx src/components/video-editor/TimelineDock.test.tsx; do bun test "$f" || break; done`
Expected: every file passes.

- [ ] **Step 11: Commit**

```bash
git add src/components/studio/kv-generator/motion/KvMotionEditor.tsx
git commit -m "feat(kv-motion): wire multi-select — rail modifier clicks, menu targets the selection, toolbar Stagger (N), Esc clears

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: Manual verification in the preview + lint

- [ ] **Step 1: Lint the touched files**

Run: `bunx eslint src/components/studio/kv-generator/motion/KvMotionEditor.tsx src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/TrackPresetMenu.tsx src/components/video-editor/TimelineDock.tsx src/components/video-editor/BlockTrackRow.tsx src/components/video-editor/TrackRow.tsx src/components/video-editor/TrackNameCell.tsx src/components/video-editor/MotionPanelHeader.tsx`
Expected: no errors (warnings that pre-exist on `develop` are fine).

- [ ] **Step 2: Open a motion project in the preview** (`preview_start` with the `web` launch config; navigate to any `…/studio/kv-generator/<file_id>/motion/<projectId>`), then check each row and fix anything that fails before moving on:

| # | Do | Expect |
| --- | --- | --- |
| 1 | Click layer A in the rail, Cmd-click B, Cmd-click C | A, B, C tinted; C ringed; Inspector shows C |
| 2 | Click ✨ on B | Header "3 layers", no Copy / Save; Stagger toggle present |
| 3 | Pick "Pop in" | All three get the entrance at the playhead; ONE Cmd+Z removes all three |
| 4 | Reopen ✨ on B, toggle Stagger on, pick "Fade in" | A first, then B, then C; one undo |
| 5 | Right-click D (not selected) in the dock | Selection collapses to D; single-layer menu with Duplicate/Delete |
| 6 | Click A, Shift-click C in the dock rows | A, B, C selected (rows in between included) |
| 7 | Toolbar: pick a preset, button reads "Stagger (3)", click | Only A, B, C staggered |
| 8 | Esc | Selection cleared, Inspector empty |
| 9 | Select A, Cmd-click a hidden layer and the Base image row | Neither joins; A still alone |
| 10 | Multi-select, copy a motion from another layer first, then Paste on the selection | All members get it; one undo |
| 11 | Multi-select with the playhead at the very end, pick an emphasis | Error toast "Couldn't apply…", nothing pushed |

- [ ] **Step 3: Screenshot rows 1, 2 and 4 for the PR and confirm `kv_generator.motion_preset_applied` fired with `source: "multi"` / `"multi_stagger"` in the console (`read_console_messages` filtering `motion_preset_applied`, or the PostHog debug toggle if the project has one).**

- [ ] **Step 4: Final commit if the checklist forced fixes; then run the full touched-suite loop from Task 9 Step 10 once more.**

---

## Self-review

- **Spec coverage.** Gesture + surfaces (T1, T7, T9); selection shape + invariants (T2); simultaneous default + Stagger toggle (T3, T6, T9); fan-out set and hidden single-layer items (T6, T9); one push per bulk (T3, T4); skip-and-report (T3, T4, `reportBulk` in T9); eligibility (T2 `multiSelectOrder`); menu on non-member collapses (T6 `onOpen`, T9 dock `onTrackContextMenu`); collapse on keyframe/bar click, Esc, canvas click (T2 `selectKeyframe`; T9 Esc; the Konva stage calls `selectTrack(id)` with one arg = replace, so canvas click already collapses); toolbar Stagger (T9); analytics (T5, T9); hint (T9). `deleteLayer` keeping invariants (T2 e).
- **Placeholders.** None — every step has its code. The two "check the real literal" notes (preset ids in T3/T6 test, `Toggle` component in T6) are verification instructions, not gaps.
- **Type consistency.** `selectTrack(trackId, mode?)`, `selectedTrackIds`, `clearSelection`, `applyPresetToTracks(ids, preset, atMs)`, `applyEmphasisToTracks(ids, preset)`, `applyTemplateToTracks(ids, body)`, `applyStaggerToTracks(ids, preset)`, `pasteMotionToTracks(ids, mode)`, `pasteMotionInto(timeline, base, trackId, clip, mode, playheadMs, target?)`, `bulkTargetIds(trackId, selectedTrackIds)`, `modeFromEvent(e)`, menu props `targetTrackIds` / `onApplyStagger` / `onOpen`, dock props `selectedTrackIds?` / `onFocusTrack(trackId, mode)` / `primary` — used with the same names and arities in every task that references them.
