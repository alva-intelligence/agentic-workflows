# KV Motion Layer Copy/Paste Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user duplicate a layer inside a KV Motion project — the overlay *and* its animation — via right-click and real `Cmd+C` / `Cmd+V`, with one-step undo.

**Architecture:** A Motion layer is two records in two stores: a `StudioOverlay` in `snapshot.overlays` (REST PATCH) and a `MotionTrack` keyed by `overlay_id` in `timeline` (undo stack + debounced autosave). Every layer operation must write both or it half-works. The undo stack is therefore generalized from `MotionTimeline` to a document `{ snapshot, timeline }`, keeping the existing `push()` as sugar so ~20 call sites stay untouched. React-query remains the only place snapshot is *read* from; the hook mirrors into it.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Zustand (clipboard store), TanStack Query v5, `bun test` + @testing-library/react.

**Spec:** `docs/superpowers/specs/2026-09-03-kv-motion-layer-copy-paste-design.md`

## Global Constraints

- **Repo:** `web/` only, branch `develop`. **The api is not touched** — `UpdateKvMotionProjectRequest` already validates `snapshot` as `['sometimes', 'array', new MaxJsonBytes]`.
- **Test runner:** `bun test <exact file path>`. NEVER `bunx vitest`. NEVER point `bun test` at a directory — it has blown up to 26 GB of memory doing that.
- **Test files stay well under ~51KB.** Past that cliff a file dies with a bogus SCSS error naming `base.module.scss`. Add a new file rather than growing one near the limit.
- **RTL:** use `within(document.body).getBy…`, never the bare `screen` export — `screen` is broken under bun in this repo and one misuse fails ~129 unrelated component tests.
- **No type gate.** `bun run build` is broken (use `node` if you must build) and `tsc` has a ~777-error baseline. Do not treat a pre-existing type error as yours.
- **Pasted overlay ids are `mo_<ts>_<rand>`.** Never `tmp_` — in Craft that prefix means "the server will rekey this to a ULID" (`KvGeneratorLayout.tsx:3604`), and a motion snapshot is never rewritten by the api.
- **`Cmd+A` is never claimed** by the motion editor. Motion has no multi-select.
- **A shortcut that cannot act does not `preventDefault`.**

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `src/lib/video-editor/timeline.ts` | pure timeline document types + helpers | add `cloneTrackForOverlay` |
| `src/lib/studio/kv/overlayClipboard.ts` | pure copy/paste decision logic, shared by Craft/Resize | add `"motion"` to the surface union |
| `src/components/video-editor/useTimelineCommands.ts` | undo/redo stack | hold a `MotionDoc`, add `pushDoc` + `pushSaved` |
| `src/components/studio/kv-generator/motion/useMotionEditorState.ts` | editor state, autosave, layer actions | document-aware autosave, snapshot mirror, copy/paste/delete/flag actions |
| `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` | page composition | keyboard, menu wiring, resync, remove bespoke snapshot PATCH |
| `src/components/studio/kv-generator/motion/TrackPresetMenu.tsx` | per-row menu | two optional layer-lifecycle items, anchored mode only |
| `src/lib/analytics/kv-generator-events.ts` | PostHog events | three events |

New test files (each small, none near the size cliff):

- `src/lib/video-editor/cloneTrackForOverlay.test.ts`
- `src/lib/studio/kv/overlayClipboard.motion.test.ts`
- `src/components/video-editor/useTimelineCommands.doc.test.tsx`
- `src/components/studio/kv-generator/motion/useMotionEditorState.docautosave.test.tsx`
- `src/components/studio/kv-generator/motion/useMotionEditorState.layers.test.tsx`
- `src/components/studio/kv-generator/motion/KvMotionEditor.clipboardkeys.test.tsx`

---

### Task 1: `cloneTrackForOverlay`

**Files:**
- Modify: `web/src/lib/video-editor/timeline.ts` (append at end of file)
- Test: `web/src/lib/video-editor/cloneTrackForOverlay.test.ts` (create)

**Interfaces:**
- Consumes: `MotionTimeline`, `MotionTrack` (already exported from this file)
- Produces: `cloneTrackForOverlay(timeline: MotionTimeline, fromOverlayId: string, toOverlayId: string): MotionTrack | null`

Note: `pruneTimelineToOverlays` — the closest sibling helper — lives in `useMotionEditorState.ts`, a hook file. Do NOT put this one there. It belongs in the pure module so it is testable without React.

- [ ] **Step 1: Write the failing test**

Create `web/src/lib/video-editor/cloneTrackForOverlay.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import { cloneTrackForOverlay } from "./timeline";
import type { MotionTimeline } from "./timeline";

const timeline: MotionTimeline = {
  version: 1,
  duration_ms: 5000,
  fps: 30,
  tracks: [
    {
      kind: "overlay",
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 0, props: { opacity: 0 }, easing: "out", label: "Fade in" },
        { t_ms: 500, props: { opacity: 1, scale: 1.2 }, easing: "in-out" },
      ],
    },
  ],
};

describe("cloneTrackForOverlay", () => {
  it("remaps overlay_id and keeps every keyframe verbatim", () => {
    const cloned = cloneTrackForOverlay(timeline, "ov1", "mo_1_abc");
    expect(cloned).not.toBeNull();
    expect(cloned!.overlay_id).toBe("mo_1_abc");
    expect(cloned!.keyframes).toEqual(timeline.tracks[0]!.keyframes);
  });

  it("preserves the preset label a keyframe was stamped with", () => {
    const cloned = cloneTrackForOverlay(timeline, "ov1", "mo_1_abc");
    expect(cloned!.keyframes[0]!.label).toBe("Fade in");
  });

  it("deep-copies props so editing the clone cannot mutate the source", () => {
    const cloned = cloneTrackForOverlay(timeline, "ov1", "mo_1_abc")!;
    cloned.keyframes[0]!.props.opacity = 0.5;
    expect(timeline.tracks[0]!.keyframes[0]!.props.opacity).toBe(0);
  });

  it("returns null for a layer that has no track yet", () => {
    expect(cloneTrackForOverlay(timeline, "ov-none", "mo_1_abc")).toBeNull();
  });

  it("does not mutate the source timeline", () => {
    const before = JSON.stringify(timeline);
    cloneTrackForOverlay(timeline, "ov1", "mo_1_abc");
    expect(JSON.stringify(timeline)).toBe(before);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/lib/video-editor/cloneTrackForOverlay.test.ts`
Expected: FAIL — `cloneTrackForOverlay is not a function` / not exported.

- [ ] **Step 3: Write minimal implementation**

Append to `web/src/lib/video-editor/timeline.ts`:

```ts
/** Clone one overlay's track under a NEW overlay id — the animation half of
 *  layer duplication (the overlay half is `pasteOverlays`).
 *
 *  Keyframes are copied verbatim, including each one's preset `label`: a
 *  duplicated layer must animate exactly like the layer it came from, and the
 *  label is what the Blocks/Slots bar shows as the motion's name.
 *
 *  Returns null when the source layer has no track. A layer with no animation
 *  is a perfectly normal thing to duplicate, and it must yield NO track rather
 *  than an empty one — an empty track renders as a row promising an animation
 *  that isn't there.
 *
 *  Pure; the source timeline is never mutated. */
export function cloneTrackForOverlay(
  timeline: MotionTimeline,
  fromOverlayId: string,
  toOverlayId: string
): MotionTrack | null {
  const source = timeline.tracks.find(
    (t) => t.kind === "overlay" && t.overlay_id === fromOverlayId
  );
  if (!source) return null;
  return {
    ...source,
    overlay_id: toOverlayId,
    keyframes: source.keyframes.map((k) => ({ ...k, props: { ...k.props } })),
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/lib/video-editor/cloneTrackForOverlay.test.ts`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/timeline.ts src/lib/video-editor/cloneTrackForOverlay.test.ts
git commit -m "feat(web): clone an overlay's motion track under a new id"
```

---

### Task 2: `"motion"` surface on the shared clipboard

**Files:**
- Modify: `web/src/lib/studio/kv/overlayClipboard.ts` (the `surface` field of `OverlayClipboardPayload`)
- Test: `web/src/lib/studio/kv/overlayClipboard.motion.test.ts` (create)

**Interfaces:**
- Produces: `OverlayClipboardPayload["surface"]` widened to `"craft" | "resize" | "motion"`. No other signature changes — `buildClipboardPayload`, `canPasteInto`, and `pasteOverlays` already take the surface as a parameter.

Why this is the whole change: scope is one project, so `targetFrameId === payload.sourceFrameId` always holds and paste always takes the existing **same-frame nudge** path (2% of frame, `clampNudged`). `preservePixelGeometry` never runs for Motion.

- [ ] **Step 1: Write the failing test**

Create `web/src/lib/studio/kv/overlayClipboard.motion.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import {
  buildClipboardPayload,
  canPasteInto,
  pasteOverlays,
} from "./overlayClipboard";
import type { StudioOverlay } from "@/types/studio";

function overlay(id: string, z: number): StudioOverlay {
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
    payload: { type: "text", content: "Headline", color: "#000000" },
    created_at: "t",
    updated_at: "t",
  };
}

const FRAME = { width: 1080, height: 1080 };

describe("overlayClipboard — motion surface", () => {
  it("builds a motion payload from one selected layer", () => {
    const payload = buildClipboardPayload(
      [overlay("ov1", 0)],
      ["ov1"],
      "motion",
      "project-1",
      FRAME
    );
    expect(payload).not.toBeNull();
    expect(payload!.surface).toBe("motion");
    expect(payload!.overlays).toHaveLength(1);
  });

  it("accepts a motion payload into motion", () => {
    const payload = buildClipboardPayload(
      [overlay("ov1", 0)], ["ov1"], "motion", "project-1", FRAME
    );
    expect(canPasteInto(payload, "motion")).toBe(true);
  });

  it("rejects craft and resize payloads into motion", () => {
    const craft = buildClipboardPayload(
      [overlay("ov1", 0)], ["ov1"], "craft", "board-1", FRAME
    );
    const resize = buildClipboardPayload(
      [overlay("ov1", 0)], ["ov1"], "resize", "row-1", FRAME
    );
    expect(canPasteInto(craft, "motion")).toBe(false);
    expect(canPasteInto(resize, "motion")).toBe(false);
  });

  it("rejects a motion payload into craft", () => {
    const payload = buildClipboardPayload(
      [overlay("ov1", 0)], ["ov1"], "motion", "project-1", FRAME
    );
    expect(canPasteInto(payload, "craft")).toBe(false);
  });

  it("nudges a same-project paste and stacks it on top", () => {
    const source = overlay("ov1", 0);
    const payload = buildClipboardPayload(
      [source], ["ov1"], "motion", "project-1", FRAME
    )!;
    const [pasted] = pasteOverlays({
      payload,
      targetFrameId: "project-1",
      targetFrame: FRAME,
      existing: [source],
      mintId: () => "mo_1_abc",
    });
    expect(pasted!.id).toBe("mo_1_abc");
    expect(pasted!.z).toBe(1);
    expect(pasted!.x).toBeCloseTo(0.12, 5);
    expect(pasted!.y).toBeCloseTo(0.22, 5);
    expect(pasted!.width).toBe(source.width);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/lib/studio/kv/overlayClipboard.motion.test.ts`
Expected: FAIL — TypeScript rejects `"motion"` as a surface argument (and under bun the runtime assertion on `payload!.surface` fails for the same reason the type does not exist).

- [ ] **Step 3: Write minimal implementation**

In `web/src/lib/studio/kv/overlayClipboard.ts`, widen the union and extend the existing doc comment on the `surface` field:

```ts
  /** Which surface the copy came from. Paste is same-surface only: a Craft
   *  overlay is doc state, a Resize tile overlay is a REST snapshot, and a
   *  Motion overlay is a FROZEN snapshot inside one motion project. Silently
   *  converting between them would move an edit into a storage layer the user
   *  never opened. A cross-surface paste is REJECTED (see {@link canPasteInto})
   *  instead of half-working. */
  surface: "craft" | "resize" | "motion";
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/lib/studio/kv/overlayClipboard.motion.test.ts`
Expected: PASS, 5 tests.

Then confirm you did not disturb the two existing surfaces:

Run: `cd web && bun test src/lib/studio/kv/overlayClipboard.test.ts`
Expected: PASS, unchanged count.

- [ ] **Step 5: Commit**

```bash
git add src/lib/studio/kv/overlayClipboard.ts src/lib/studio/kv/overlayClipboard.motion.test.ts
git commit -m "feat(web): add a motion surface to the overlay clipboard"
```

---

### Task 3: Generalize the undo stack to a document

**Files:**
- Modify: `web/src/components/video-editor/useTimelineCommands.ts` (whole file)
- Test: `web/src/components/video-editor/useTimelineCommands.doc.test.tsx` (create)

**Interfaces:**
- Consumes: `MotionTimeline` (`@/lib/video-editor/timeline`), `KvMotionSnapshot` (`@/types/kv/motionProject`)
- Produces:
  - `type MotionDoc = { snapshot: KvMotionSnapshot; timeline: MotionTimeline }`
  - `useTimelineCommands(initial: MotionDoc): TimelineCommandApi` — **the parameter type changes** from `MotionTimeline` to `MotionDoc`
  - `TimelineCommandApi = { doc, timeline, snapshot, push, pushDoc, pushSaved, undo, redo, canUndo, canRedo }`
  - `push(next: MotionTimeline, label?: string): void` — unchanged signature, means "same snapshot, new timeline"
  - `pushDoc(next: MotionDoc, label?: string): void`
  - `pushSaved(next: MotionDoc, label?: string): void` — pushes onto the undo stack and reports the doc through `onPushSaved` so autosave can mark it already-persisted (Task 4 supplies that callback; here it is an optional constructor option)

The only caller of `useTimelineCommands` is `useMotionEditorState`; Task 4 updates it. The ~20 `push(...)` call sites inside that hook are NOT touched.

- [ ] **Step 1: Write the failing test**

Create `web/src/components/video-editor/useTimelineCommands.doc.test.tsx`:

```tsx
import { describe, expect, it } from "bun:test";
import { act, renderHook } from "@testing-library/react";
import { useTimelineCommands } from "./useTimelineCommands";
import type { MotionDoc } from "./useTimelineCommands";
import type { KvMotionSnapshot } from "@/types/kv/motionProject";
import type { MotionTimeline } from "@/lib/video-editor/timeline";

const snapshot: KvMotionSnapshot = {
  base_image_url: "https://x/y.png",
  board_width: 1080,
  board_height: 1080,
  overlays: [],
};
const timeline: MotionTimeline = {
  version: 1,
  duration_ms: 5000,
  fps: 30,
  tracks: [],
};
const initial: MotionDoc = { snapshot, timeline };

describe("useTimelineCommands as a document stack", () => {
  it("push leaves the snapshot untouched", () => {
    const { result } = renderHook(() => useTimelineCommands(initial));
    const nextTimeline = { ...timeline, duration_ms: 6000 };
    act(() => result.current.push(nextTimeline));
    expect(result.current.timeline.duration_ms).toBe(6000);
    expect(result.current.snapshot).toBe(snapshot);
  });

  it("pushDoc then undo restores snapshot AND timeline in one step", () => {
    const { result } = renderHook(() => useTimelineCommands(initial));
    const nextSnapshot = { ...snapshot, board_width: 720 };
    const nextTimeline = { ...timeline, duration_ms: 6000 };
    act(() =>
      result.current.pushDoc({ snapshot: nextSnapshot, timeline: nextTimeline })
    );
    expect(result.current.snapshot.board_width).toBe(720);
    expect(result.current.timeline.duration_ms).toBe(6000);

    act(() => result.current.undo());
    expect(result.current.snapshot).toBe(snapshot);
    expect(result.current.timeline).toBe(timeline);
  });

  it("redo re-applies both halves", () => {
    const { result } = renderHook(() => useTimelineCommands(initial));
    const nextSnapshot = { ...snapshot, board_width: 720 };
    act(() =>
      result.current.pushDoc({ snapshot: nextSnapshot, timeline })
    );
    act(() => result.current.undo());
    act(() => result.current.redo());
    expect(result.current.snapshot.board_width).toBe(720);
  });

  it("still collapses consecutive same-label pushes into one undo step", () => {
    const { result } = renderHook(() => useTimelineCommands(initial));
    act(() => result.current.push({ ...timeline, duration_ms: 6000 }, "drag"));
    act(() => result.current.push({ ...timeline, duration_ms: 7000 }, "drag"));
    act(() => result.current.undo());
    expect(result.current.timeline).toBe(timeline);
  });

  it("pushSaved reports the pushed doc to onPushSaved", () => {
    const seen: MotionDoc[] = [];
    const { result } = renderHook(() =>
      useTimelineCommands(initial, { onPushSaved: (d) => seen.push(d) })
    );
    const doc = { snapshot: { ...snapshot, board_width: 720 }, timeline };
    act(() => result.current.pushSaved(doc, "resync"));
    expect(seen).toHaveLength(1);
    expect(seen[0]!.snapshot.board_width).toBe(720);
    expect(result.current.snapshot.board_width).toBe(720);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/video-editor/useTimelineCommands.doc.test.tsx`
Expected: FAIL — `result.current.pushDoc is not a function`.

- [ ] **Step 3: Write minimal implementation**

Replace the body of `web/src/components/video-editor/useTimelineCommands.ts`:

```ts
import { useCallback, useRef, useState } from "react";
import type { MotionTimeline } from "@/lib/video-editor/timeline";
import type { KvMotionSnapshot } from "@/types/kv/motionProject";

/** The editor's undoable document. A Motion LAYER is two records in two
 *  stores — a `StudioOverlay` in `snapshot.overlays` and a `MotionTrack` in
 *  `timeline.tracks` — so an undo stack that held only the timeline could
 *  undo a paste HALF: animation gone, duplicated layer left behind. */
export type MotionDoc = {
  snapshot: KvMotionSnapshot;
  timeline: MotionTimeline;
};

export type TimelineCommandOpts = {
  /** Called by `pushSaved` with the doc that was pushed. Lets the autosave
   *  owner mark a document as ALREADY persisted (the resync path PATCHes
   *  explicitly and then syncs the stack), so autosave does not immediately
   *  re-send what the server just accepted. */
  onPushSaved?: (doc: MotionDoc) => void;
};

export type TimelineCommandApi = {
  doc: MotionDoc;
  timeline: MotionTimeline;
  snapshot: KvMotionSnapshot;
  /** "Same snapshot, new timeline" — the original signature, kept verbatim so
   *  the ~20 timeline-only call sites in `useMotionEditorState` stay
   *  untouched. */
  push: (next: MotionTimeline, label?: string) => void;
  pushDoc: (next: MotionDoc, label?: string) => void;
  pushSaved: (next: MotionDoc, label?: string) => void;
  undo: () => void;
  redo: () => void;
  canUndo: boolean;
  canRedo: boolean;
};

/** Document-level undo: each push snapshots the whole document (small JSON).
 *  Same-label consecutive pushes collapse (a drag emits many intermediate
 *  documents but should undo in ONE step — spec: undo is one step per action).
 *
 *  Ref mutations happen OUTSIDE setState updaters to remain single-invoke under StrictMode. */
export function useTimelineCommands(
  initial: MotionDoc,
  opts: TimelineCommandOpts = {}
): TimelineCommandApi {
  const [doc, setDoc] = useState(initial);
  const current = useRef(initial);
  const past = useRef<MotionDoc[]>([]);
  const future = useRef<MotionDoc[]>([]);
  const lastLabel = useRef<string | undefined>(undefined);
  const onPushSavedRef = useRef(opts.onPushSaved);
  onPushSavedRef.current = opts.onPushSaved;

  const pushDoc = useCallback((next: MotionDoc, label?: string) => {
    const prev = current.current;
    const collapse = label !== undefined && label === lastLabel.current;
    if (!collapse) past.current.push(prev);
    lastLabel.current = label;
    future.current = [];
    current.current = next;
    setDoc(next);
  }, []);

  const push = useCallback(
    (next: MotionTimeline, label?: string) => {
      pushDoc({ snapshot: current.current.snapshot, timeline: next }, label);
    },
    [pushDoc]
  );

  const pushSaved = useCallback(
    (next: MotionDoc, label?: string) => {
      pushDoc(next, label);
      onPushSavedRef.current?.(next);
    },
    [pushDoc]
  );

  const undo = useCallback(() => {
    const prev = current.current;
    const last = past.current.pop();
    if (!last) return;
    future.current.push(prev);
    lastLabel.current = undefined;
    current.current = last;
    setDoc(last);
  }, []);

  const redo = useCallback(() => {
    const prev = current.current;
    const next = future.current.pop();
    if (!next) return;
    past.current.push(prev);
    lastLabel.current = undefined;
    current.current = next;
    setDoc(next);
  }, []);

  return {
    doc,
    timeline: doc.timeline,
    snapshot: doc.snapshot,
    push,
    pushDoc,
    pushSaved,
    undo,
    redo,
    canUndo: past.current.length > 0,
    canRedo: future.current.length > 0,
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/video-editor/useTimelineCommands.doc.test.tsx`
Expected: PASS, 5 tests.

The hook's only caller does not compile yet — Task 4 fixes it. That is expected; there is no type gate in CI.

- [ ] **Step 5: Commit**

```bash
git add src/components/video-editor/useTimelineCommands.ts src/components/video-editor/useTimelineCommands.doc.test.tsx
git commit -m "feat(web): make the motion undo stack hold a document, not just a timeline"
```

---

### Task 4: Document-aware autosave + snapshot mirror

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/useMotionEditorState.ts:103` (hook construction), `:625-700` (autosave block), and the returned object
- Test: `web/src/components/studio/kv-generator/motion/useMotionEditorState.docautosave.test.tsx` (create)

**Interfaces:**
- Consumes: `MotionDoc`, `pushDoc`, `pushSaved` (Task 3); `motionProjectKey` from `@/services/kv/motionProjects`
- Produces: the hook additionally returns `doc`, `snapshot`, `pushDoc`, `pushSaved`. `timeline`, `push`, `undo`, `redo`, `canUndo`, `canRedo` keep their current meaning.

Three rules this task encodes:
1. **One PATCH, not two.** A change that touches both halves sends `snapshot` and `timeline` in the same request.
2. **`snapshot` is only sent when it actually changed** — an ordinary keyframe drag must not re-upload the whole overlay array every 1.5s.
3. **React-query stays the only place snapshot is READ from.** All eight read sites memoize on `project.snapshot`; the hook mirrors the command state into that cache.

- [ ] **Step 1: Write the failing test**

Create `web/src/components/studio/kv-generator/motion/useMotionEditorState.docautosave.test.tsx`. Reuse the fixture style of the existing `useMotionEditorState.autosave.test.tsx` (same `asPatchFn` helper and `makeProject`):

```tsx
import { describe, expect, it, mock } from "bun:test";
import { act, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { KvMotionProject } from "@/types/kv/motionProject";
import type { StudioOverlay } from "@/types/studio";
import type { patchMotionProject } from "@/services/kv/motionProjects";
import { motionProjectKey } from "@/services/kv/motionProjects";
import { useMotionEditorState } from "./useMotionEditorState";

function asPatchFn(
  fn: (...args: unknown[]) => Promise<unknown>
): typeof patchMotionProject {
  return fn as unknown as typeof patchMotionProject;
}

const ov1: StudioOverlay = {
  id: "ov1",
  studio_file_id: "f1",
  type: "text",
  x: 0.1,
  y: 0.2,
  width: 0.3,
  height: 0.1,
  rotation: 0,
  z: 0,
  payload: { type: "text", content: "Headline", color: "#000000" },
  created_at: "t",
  updated_at: "t",
};

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
      overlays: [ov1],
    },
    timeline: { version: 1, duration_ms: 5000, fps: 30, tracks: [] },
  };
}

function wrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
  };
}

describe("useMotionEditorState — document-aware autosave", () => {
  it("sends snapshot AND timeline in ONE patch when the snapshot changed", async () => {
    const patchFn = mock(async () => makeProject());
    const qc = new QueryClient();
    const project = makeProject();
    const { result } = renderHook(
      () => useMotionEditorState(project, { patchFn: asPatchFn(patchFn) }),
      { wrapper: wrapper(qc) }
    );

    act(() =>
      result.current.pushDoc({
        snapshot: { ...result.current.snapshot, board_width: 720 },
        timeline: { ...result.current.timeline, duration_ms: 6000 },
      })
    );

    await waitFor(() => expect(patchFn).toHaveBeenCalledTimes(1), {
      timeout: 4000,
    });
    const body = (patchFn.mock.calls[0] as unknown[])[2] as Record<
      string,
      unknown
    >;
    expect(body.snapshot).toBeDefined();
    expect(body.timeline).toBeDefined();
  });

  it("omits snapshot for a timeline-only edit", async () => {
    const patchFn = mock(async () => makeProject());
    const qc = new QueryClient();
    const project = makeProject();
    const { result } = renderHook(
      () => useMotionEditorState(project, { patchFn: asPatchFn(patchFn) }),
      { wrapper: wrapper(qc) }
    );

    act(() =>
      result.current.push({ ...result.current.timeline, duration_ms: 6000 })
    );

    await waitFor(() => expect(patchFn).toHaveBeenCalledTimes(1), {
      timeout: 4000,
    });
    const body = (patchFn.mock.calls[0] as unknown[])[2] as Record<
      string,
      unknown
    >;
    expect(body.snapshot).toBeUndefined();
    expect(body.timeline).toBeDefined();
  });

  it("mirrors the command snapshot into the react-query cache", async () => {
    const patchFn = mock(async () => makeProject());
    const qc = new QueryClient();
    const project = makeProject();
    qc.setQueryData(motionProjectKey("f1", "p1"), project);

    const { result } = renderHook(
      () =>
        useMotionEditorState(project, {
          autosave: false,
          patchFn: asPatchFn(patchFn),
        }),
      { wrapper: wrapper(qc) }
    );

    act(() =>
      result.current.pushDoc({
        snapshot: { ...result.current.snapshot, board_width: 720 },
        timeline: result.current.timeline,
      })
    );

    await waitFor(() => {
      const cached = qc.getQueryData<KvMotionProject>(
        motionProjectKey("f1", "p1")
      );
      expect(cached?.snapshot.board_width).toBe(720);
    });
  });

  it("pushSaved does not trigger a patch — the caller already persisted it", async () => {
    const patchFn = mock(async () => makeProject());
    const qc = new QueryClient();
    const project = makeProject();
    const { result } = renderHook(
      () => useMotionEditorState(project, { patchFn: asPatchFn(patchFn) }),
      { wrapper: wrapper(qc) }
    );

    act(() =>
      result.current.pushSaved(
        {
          snapshot: { ...result.current.snapshot, board_width: 720 },
          timeline: result.current.timeline,
        },
        "resync"
      )
    );

    await new Promise((r) => setTimeout(r, 2500));
    expect(patchFn).toHaveBeenCalledTimes(0);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/useMotionEditorState.docautosave.test.tsx`
Expected: FAIL — `result.current.pushDoc is not a function`.

- [ ] **Step 3: Write minimal implementation**

In `web/src/components/studio/kv-generator/motion/useMotionEditorState.ts`:

(a) Add imports:

```ts
import type { MotionDoc } from "@/components/video-editor/useTimelineCommands";
import { motionProjectKey } from "@/services/kv/motionProjects";
```

(b) Replace the `useTimelineCommands` construction (currently at `:103`):

```ts
  // The doc identity handed to the command stack is ALSO autosave's
  // "nothing changed yet" sentinel (see `lastSavedRef`), so it must be stable
  // for the life of the editor. Re-deriving it when `project` changes identity
  // — a list invalidation refetch, say — would make the stack and the sentinel
  // disagree and fire a spurious PATCH of unedited content.
  const initialDoc = useMemo<MotionDoc>(
    () => ({ snapshot: project.snapshot, timeline: project.timeline }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    []
  );

  // `pushSaved` marks a doc the caller has ALREADY persisted (resync PATCHes
  // explicitly, because it also rebinds the board id and needs the error for
  // its dialog). Without this, the mirror below would look like a fresh edit
  // and autosave would immediately re-send what the server just accepted.
  const markSaved = useCallback((next: MotionDoc) => {
    lastSavedRef.current = next;
  }, []);

  const {
    doc,
    timeline,
    snapshot,
    push,
    pushDoc,
    pushSaved,
    undo,
    redo,
    canUndo,
    canRedo,
  } = useTimelineCommands(initialDoc, { onPushSaved: markSaved });
```

`lastSavedRef` is declared further down the file; hoist its declaration above
this block so `markSaved` can close over it:

```ts
  const lastSavedRef = useRef<MotionDoc>(initialDoc);
```

and DELETE the old `const lastSavedRef = useRef(project.timeline);` line in the
autosave section, keeping its explanatory comment attached to the new one.

(c) Replace `saveWithRetry` and the debounce effect:

```ts
  const saveWithRetry = useCallback(
    async (
      next: MotionDoc,
      includeSnapshot: boolean,
      attempt: number,
      generation: number
    ) => {
      if (saveSeqRef.current !== generation) return; // superseded already
      try {
        // ONE request, not two. A layer op changes both halves, and two
        // independent PATCHes can interleave with a third writer and land the
        // overlay without its animation.
        await patch(project.studioFileId, project.id, {
          timeline: next.timeline,
          ...(includeSnapshot ? { snapshot: next.snapshot } : {}),
        });
        if (saveSeqRef.current !== generation) return; // superseded mid-flight
        lastSavedRef.current = next;
        setSaveState("saved");
        void qc.invalidateQueries({
          queryKey: motionProjectsKey(project.studioFileId),
        });
      } catch {
        if (saveSeqRef.current !== generation) return; // superseded mid-flight
        if (attempt < RETRIES) {
          await sleep(RETRY_BASE_MS * 2 ** attempt);
          if (saveSeqRef.current !== generation) return; // superseded during backoff
          await saveWithRetry(next, includeSnapshot, attempt + 1, generation);
          return;
        }
        setSaveState("error");
      }
    },
    [patch, project.studioFileId, project.id, qc]
  );

  useEffect(() => {
    if (opts.autosave === false) return;
    if (doc === lastSavedRef.current) return; // nothing changed since mount/last save
    // Decided at SCHEDULE time, not per attempt: `lastSavedRef` moves when a
    // save lands, and a retry must keep sending the same body it was queued
    // with rather than silently dropping the snapshot half mid-backoff.
    const includeSnapshot = doc.snapshot !== lastSavedRef.current.snapshot;
    setSaveState("saving");
    const generation = ++saveSeqRef.current;
    const handle = setTimeout(() => {
      void saveWithRetry(doc, includeSnapshot, 0, generation);
    }, AUTOSAVE_DEBOUNCE_MS);
    return () => clearTimeout(handle);
  }, [doc, opts.autosave, saveWithRetry]);
```

(d) Update the unmount-flush refs — replace `timelineRef` with `docRef`:

```ts
  const docRef = useRef(doc);
  docRef.current = doc;
```

and inside the unmount cleanup:

```ts
      if (docRef.current === lastSavedRef.current) return; // nothing pending
      const includeSnapshot =
        docRef.current.snapshot !== lastSavedRef.current.snapshot;
      const generation = ++saveSeqRef.current;
      void saveWithRetryRef.current(docRef.current, includeSnapshot, 0, generation);
```

(e) Add the snapshot mirror effect, directly after the autosave effect:

```ts
  // React-query stays the ONLY place `snapshot` is read from: eight call sites
  // (buildTracks, resolveMotionTiles, deriveTileOverlays, baseProps, the
  // stages, the export dialog) all memoize on `project.snapshot`. Rather than
  // rewrite them to read command state — a second source of truth, and the
  // exact shape of the doc/REST divergence this codebase has been bitten by —
  // the command state is mirrored INTO the cache.
  //
  // Returning `prev` unchanged when the snapshot already matches is what keeps
  // this from looping: the write feeds `project` back in as a new prop.
  useEffect(() => {
    qc.setQueryData<KvMotionProject>(
      motionProjectKey(project.studioFileId, project.id),
      (prev) => (prev && prev.snapshot !== snapshot ? { ...prev, snapshot } : prev)
    );
  }, [snapshot, qc, project.studioFileId, project.id]);
```

(f) Add `doc`, `snapshot`, `pushDoc`, `pushSaved` to the hook's returned object.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web && bun test src/components/studio/kv-generator/motion/useMotionEditorState.docautosave.test.tsx`
Expected: PASS, 4 tests.

Then confirm no regression in the existing autosave behaviour:

Run: `cd web && bun test src/components/studio/kv-generator/motion/useMotionEditorState.autosave.test.tsx`
Expected: PASS, unchanged count.

Run: `cd web && bun test src/components/studio/kv-generator/motion/useMotionEditorState.test.ts src/components/studio/kv-generator/motion/useMotionEditorState.propGroup.test.ts`
Expected: PASS, unchanged counts.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/useMotionEditorState.docautosave.test.tsx
git commit -m "feat(web): autosave the motion snapshot alongside its timeline"
```

---

### Task 5: `copyLayer` / `pasteLayer` / `deleteLayer` + analytics

**Files:**
- Modify: `web/src/lib/analytics/kv-generator-events.ts` (append near `trackKvMotionTrackVisibilityToggled`, ~`:765`)
- Modify: `web/src/components/studio/kv-generator/motion/useMotionEditorState.ts` (new actions + exports)
- Test: `web/src/components/studio/kv-generator/motion/useMotionEditorState.layers.test.tsx` (create)

**Interfaces:**
- Consumes: `cloneTrackForOverlay` (Task 1); `buildClipboardPayload`, `canPasteInto`, `pasteOverlays` (Task 2); `pushDoc` (Tasks 3–4); `useKvOverlayClipboardStore` from `@/store/kv/useKvOverlayClipboardStore`; `pruneTimelineToOverlays` (already in this file)
- Produces, all returned from `useMotionEditorState`:
  - `copyLayer(overlayId: string): boolean` — true when the clipboard was written
  - `pasteLayer(): boolean` — true when a layer was added
  - `deleteLayer(overlayId: string): boolean` — true when a layer was removed
  - `isMotionAuthoredOverlay(id: string): boolean` — exported from the module (not the hook) so the menu and the resync counter share one definition

Every one returns a boolean because the keyboard handler in Task 7 uses it to decide whether to `preventDefault`.

- [ ] **Step 1: Write the failing test**

Create `web/src/components/studio/kv-generator/motion/useMotionEditorState.layers.test.tsx`. Use the same `makeProject`/`wrapper` fixtures as Task 4, plus a track on `ov1`:

```tsx
import { beforeEach, describe, expect, it, mock } from "bun:test";
import { act, renderHook } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { KvMotionProject } from "@/types/kv/motionProject";
import type { StudioOverlay } from "@/types/studio";
import type { patchMotionProject } from "@/services/kv/motionProjects";
import { useKvOverlayClipboardStore } from "@/store/kv/useKvOverlayClipboardStore";
import {
  isMotionAuthoredOverlay,
  useMotionEditorState,
} from "./useMotionEditorState";

function asPatchFn(
  fn: (...args: unknown[]) => Promise<unknown>
): typeof patchMotionProject {
  return fn as unknown as typeof patchMotionProject;
}

function overlay(id: string, extra: Partial<StudioOverlay> = {}): StudioOverlay {
  return {
    id,
    studio_file_id: "f1",
    type: "text",
    x: 0.1,
    y: 0.2,
    width: 0.3,
    height: 0.1,
    rotation: 0,
    z: 0,
    payload: { type: "text", content: "Headline", color: "#000000" },
    created_at: "t",
    updated_at: "t",
    ...extra,
  };
}

function makeProject(overlays: StudioOverlay[] = [overlay("ov1")]): KvMotionProject {
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
      overlays,
    },
    timeline: {
      version: 1,
      duration_ms: 5000,
      fps: 30,
      tracks: [
        {
          kind: "overlay",
          overlay_id: "ov1",
          keyframes: [{ t_ms: 0, props: { opacity: 0 }, easing: "out" }],
        },
      ],
    },
  };
}

function wrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
  };
}

function mount(project: KvMotionProject) {
  const patchFn = mock(async () => project);
  return renderHook(
    () =>
      useMotionEditorState(project, {
        autosave: false,
        patchFn: asPatchFn(patchFn),
      }),
    { wrapper: wrapper(new QueryClient()) }
  );
}

describe("motion layer copy/paste/delete", () => {
  beforeEach(() => {
    useKvOverlayClipboardStore.getState().clear();
  });

  it("copy then paste adds an overlay AND a cloned track", () => {
    const { result } = mount(makeProject());
    act(() => {
      result.current.copyLayer("ov1");
    });
    act(() => {
      result.current.pasteLayer();
    });

    expect(result.current.snapshot.overlays).toHaveLength(2);
    const added = result.current.snapshot.overlays[1]!;
    expect(added.id.startsWith("mo_")).toBe(true);
    expect(result.current.timeline.tracks).toHaveLength(2);
    expect(result.current.timeline.tracks[1]!.overlay_id).toBe(added.id);
  });

  it("undo removes the layer and its animation in ONE step", () => {
    const { result } = mount(makeProject());
    act(() => {
      result.current.copyLayer("ov1");
    });
    act(() => {
      result.current.pasteLayer();
    });
    act(() => result.current.undo());

    expect(result.current.snapshot.overlays).toHaveLength(1);
    expect(result.current.timeline.tracks).toHaveLength(1);
  });

  it("refuses to copy a locked or hidden layer", () => {
    const { result } = mount(
      makeProject([
        overlay("ov1", {
          payload: {
            type: "text",
            content: "H",
            color: "#000000",
            locked: true,
          } as StudioOverlay["payload"],
        }),
      ])
    );
    let ok = true;
    act(() => {
      ok = result.current.copyLayer("ov1");
    });
    expect(ok).toBe(false);
    expect(useKvOverlayClipboardStore.getState().payload).toBeNull();
  });

  it("pasteLayer returns false when the clipboard is empty", () => {
    const { result } = mount(makeProject());
    let ok = true;
    act(() => {
      ok = result.current.pasteLayer();
    });
    expect(ok).toBe(false);
    expect(result.current.snapshot.overlays).toHaveLength(1);
  });

  it("deletes only motion-authored layers", () => {
    const { result } = mount(makeProject());
    act(() => {
      result.current.copyLayer("ov1");
    });
    act(() => {
      result.current.pasteLayer();
    });
    const addedId = result.current.snapshot.overlays[1]!.id;

    let refused = true;
    act(() => {
      refused = result.current.deleteLayer("ov1");
    });
    expect(refused).toBe(false);
    expect(result.current.snapshot.overlays).toHaveLength(2);

    let ok = false;
    act(() => {
      ok = result.current.deleteLayer(addedId);
    });
    expect(ok).toBe(true);
    expect(result.current.snapshot.overlays).toHaveLength(1);
    expect(result.current.timeline.tracks).toHaveLength(1);
  });

  it("classifies ids by prefix", () => {
    expect(isMotionAuthoredOverlay("mo_1_abc")).toBe(true);
    expect(isMotionAuthoredOverlay("ov1")).toBe(false);
    expect(isMotionAuthoredOverlay("tmp_1_abc")).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/useMotionEditorState.layers.test.tsx`
Expected: FAIL — `isMotionAuthoredOverlay` is not exported / `copyLayer is not a function`.

- [ ] **Step 3a: Add the three analytics events**

Append to `web/src/lib/analytics/kv-generator-events.ts`, after `trackKvMotionTrackVisibilityToggled` (~`:765`):

```ts
export interface KvMotionLayerProps {
  project_id: string;
  /** Same vocabulary the rest of this module uses for overlays, so motion
   *  layer events group with canvas overlay events in analysis. */
  overlay_type: KvOverlayType;
}

/** A layer was put on the in-memory clipboard. Separated from the paste it
 *  usually precedes because a copy with no paste is the signal that the paste
 *  affordance is undiscoverable. */
export const trackKvMotionLayerCopied = (p: KvMotionLayerProps) =>
  safeCapture("kv_generator.motion_layer_copied", p);

/** A duplicated layer was added to the project. This is the event that says
 *  the feature worked. */
export const trackKvMotionLayerPasted = (p: KvMotionLayerProps) =>
  safeCapture("kv_generator.motion_layer_pasted", p);

/** A motion-authored layer was removed. Only `mo_` layers can reach this —
 *  KV-mirrored layers are not deletable from Motion — so a spike here is
 *  people undoing their own duplicates, not losing board content. */
export const trackKvMotionLayerDeleted = (p: KvMotionLayerProps) =>
  safeCapture("kv_generator.motion_layer_deleted", p);
```

- [ ] **Step 3b: Add the actions to the hook**

In `web/src/components/studio/kv-generator/motion/useMotionEditorState.ts`, add imports:

```ts
import {
  buildClipboardPayload,
  canPasteInto,
  pasteOverlays,
} from "@/lib/studio/kv/overlayClipboard";
import { cloneTrackForOverlay } from "@/lib/video-editor/timeline";
import { useKvOverlayClipboardStore } from "@/store/kv/useKvOverlayClipboardStore";
import {
  trackKvMotionLayerCopied,
  trackKvMotionLayerDeleted,
  trackKvMotionLayerPasted,
} from "@/lib/analytics/kv-generator-events";
import type { KvOverlayType } from "@/lib/analytics/kv-generator-events";
import type { MotionTrack } from "@/lib/video-editor/timeline";
// NOT currently imported by this file — `overlayTypeOf` below needs it.
import type { StudioOverlay } from "@/types/studio";
```

Add module-level helpers (beside `pruneTimelineToOverlays`):

```ts
/** Ids minted for layers CREATED in Motion. Deliberately not `tmp_`: that
 *  prefix means "the server will rekey this to a ULID" in Craft
 *  (`KvGeneratorLayout.tsx:3604`), and a motion snapshot is opaque JSON the
 *  api never rewrites — a `tmp_` id here would sit there forever advertising
 *  the opposite.
 *
 *  The prefix doubles as the "authored in Motion" marker. It is intrinsic to
 *  the record, so — unlike a separate list of ids kept beside the overlays —
 *  it cannot drift out of sync with what it describes. */
const MOTION_OVERLAY_ID_PREFIX = "mo_";

export function isMotionAuthoredOverlay(id: string): boolean {
  return id.startsWith(MOTION_OVERLAY_ID_PREFIX);
}

function mintMotionOverlayId(): string {
  return `${MOTION_OVERLAY_ID_PREFIX}${Date.now()}_${Math.random()
    .toString(36)
    .slice(2, 8)}`;
}

/** The analytics vocabulary for an overlay. Mirrors the inline narrowing
 *  `KvMotionEditor`'s flag toggle already does, lifted here so the layer
 *  events and the toggle events cannot disagree on what a shape is. */
function overlayTypeOf(overlay: StudioOverlay): KvOverlayType {
  if (overlay.payload.type === "text") return "text";
  if (overlay.payload.type === "image") return "image";
  return "shape";
}
```

Inside the hook, after `pushDoc` is available:

```ts
  const clipboardCopy = useKvOverlayClipboardStore((s) => s.copy);

  const copyLayer = useCallback(
    (overlayId: string): boolean => {
      const overlay = snapshot.overlays.find((o) => o.id === overlayId);
      if (!overlay) return false;
      // Same guard the row's context menu applies. A locked or hidden layer
      // offers no menu, so it must not be reachable by keystroke either.
      if (overlay.payload.locked === true || overlay.payload.hidden === true) {
        return false;
      }
      const payload = buildClipboardPayload(
        snapshot.overlays,
        [overlayId],
        "motion",
        // The motion PROJECT is the frame. Scope is one project, so a paste
        // always sees `targetFrameId === sourceFrameId` and takes the
        // same-frame nudge path; cross-frame projection never runs here.
        project.id,
        { width: snapshot.board_width, height: snapshot.board_height }
      );
      if (!payload) return false;
      clipboardCopy(payload);
      trackKvMotionLayerCopied({
        project_id: project.id,
        overlay_type: overlayTypeOf(overlay),
      });
      return true;
    },
    [snapshot, project.id, clipboardCopy]
  );

  const pasteLayer = useCallback((): boolean => {
    const payload = useKvOverlayClipboardStore.getState().payload;
    if (!canPasteInto(payload, "motion")) return false;
    // Cross-PROJECT paste is out of scope: the clipboard is per-tab, so a copy
    // made in another project is reachable here. Refuse it outright rather
    // than let it half-work through the projection path.
    if (payload.sourceFrameId !== project.id) return false;

    const added = pasteOverlays({
      payload,
      targetFrameId: project.id,
      targetFrame: { width: snapshot.board_width, height: snapshot.board_height },
      existing: snapshot.overlays,
      mintId: mintMotionOverlayId,
      // `boardGenerationId` is deliberately NOT passed: motion reads overlays
      // straight off the snapshot (`deriveTileOverlays`), so the binding is
      // inert here, and leaving the source's value keeps the copy identical to
      // what it was copied from.
    });
    if (added.length === 0) return false;

    const clonedTracks = added
      .map((ov, i) =>
        cloneTrackForOverlay(timeline, payload.overlays[i]!.id, ov.id)
      )
      .filter((t): t is MotionTrack => t !== null);

    pushDoc({
      snapshot: { ...snapshot, overlays: [...snapshot.overlays, ...added] },
      timeline: { ...timeline, tracks: [...timeline.tracks, ...clonedTracks] },
    });

    for (const ov of added) {
      trackKvMotionLayerPasted({
        project_id: project.id,
        overlay_type: overlayTypeOf(ov),
      });
    }
    return true;
  }, [snapshot, timeline, project.id, pushDoc]);

  const deleteLayer = useCallback(
    (overlayId: string): boolean => {
      // KV-mirrored layers stay non-deletable from Motion: removing one would
      // be a lie, because the next Resync brings it straight back.
      if (!isMotionAuthoredOverlay(overlayId)) return false;
      const overlay = snapshot.overlays.find((o) => o.id === overlayId);
      if (!overlay) return false;

      const remaining = snapshot.overlays.filter((o) => o.id !== overlayId);
      pushDoc({
        snapshot: { ...snapshot, overlays: remaining },
        timeline: pruneTimelineToOverlays(
          timeline,
          remaining.map((o) => o.id)
        ),
      });
      trackKvMotionLayerDeleted({
        project_id: project.id,
        overlay_type: overlayTypeOf(overlay),
      });
      return true;
    },
    [snapshot, timeline, project.id, pushDoc]
  );
```

Add `copyLayer`, `pasteLayer`, `deleteLayer` to the returned object.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/motion/useMotionEditorState.layers.test.tsx`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add src/lib/analytics/kv-generator-events.ts src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/useMotionEditorState.layers.test.tsx
git commit -m "feat(web): copy, paste and delete a motion layer with its animation"
```

---

### Task 6: Fold the lock/hide toggle into the document

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/useMotionEditorState.ts` (new `setOverlayFlag` action)
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx:700-800` (delete `toggleOverlayFlag`'s bespoke PATCH, call the hook)
- Test: extend `useMotionEditorState.layers.test.tsx` from Task 5

**Interfaces:**
- Produces: `setOverlayFlag(overlayId: string, flag: "locked" | "hidden"): boolean` on the hook

Why this is not optional cleanup: `toggleOverlayFlag` currently calls `patchMotionProject({ snapshot })` on its own, outside autosave. With Task 4 in place there would be **two independent snapshot writers**, and on a slow network the loser silently overwrites the winner. It also gets undo for free, which the spec's chosen option requires.

- [ ] **Step 1: Write the failing test**

Append to `web/src/components/studio/kv-generator/motion/useMotionEditorState.layers.test.tsx`:

```tsx
describe("motion layer flags", () => {
  it("toggles locked through the document, so undo restores it", () => {
    const { result } = mount(makeProject());
    act(() => {
      result.current.setOverlayFlag("ov1", "locked");
    });
    expect(result.current.snapshot.overlays[0]!.payload.locked).toBe(true);

    act(() => result.current.undo());
    expect(result.current.snapshot.overlays[0]!.payload.locked).toBeUndefined();
  });

  it("returns false for an overlay that is not in the snapshot", () => {
    const { result } = mount(makeProject());
    let ok = true;
    act(() => {
      ok = result.current.setOverlayFlag("nope", "hidden");
    });
    expect(ok).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/useMotionEditorState.layers.test.tsx`
Expected: FAIL — `result.current.setOverlayFlag is not a function`.

- [ ] **Step 3: Write minimal implementation**

Add to the hook, beside `deleteLayer`:

```ts
  const setOverlayFlag = useCallback(
    (overlayId: string, flag: "locked" | "hidden"): boolean => {
      const overlay = snapshot.overlays.find((o) => o.id === overlayId);
      if (!overlay) return false;
      const next = overlay.payload[flag] !== true;
      pushDoc({
        snapshot: {
          ...snapshot,
          overlays: snapshot.overlays.map((o) =>
            o.id === overlayId
              ? { ...o, payload: { ...o.payload, [flag]: next || undefined } }
              : o
          ),
        },
        timeline,
      });
      return true;
    },
    [snapshot, timeline, pushDoc]
  );
```

Note `next || undefined`: turning a flag OFF removes the key rather than writing `false`, which is what the un-toggled overlays already look like — otherwise undo comparisons and the payload shape drift apart.

Add `setOverlayFlag` to the returned object.

In `KvMotionEditor.tsx`, replace the whole `toggleOverlayFlag` callback body (the optimistic `setQueryData`, the `patchMotionProject`, and the rollback `catch`) with a call into the hook, keeping the analytics exactly where it is:

```ts
  const toggleOverlayFlag = useCallback(
    (overlayId: string, flag: "locked" | "hidden") => {
      const target = state.snapshot.overlays.find((o) => o.id === overlayId);
      if (!target) return;
      const overlayType: KvOverlayType =
        target.payload.type === "text"
          ? "text"
          : target.payload.type === "image"
            ? "image"
            : "shape";
      const props = {
        project_id: project.id,
        overlay_type: overlayType,
        new_state: target.payload[flag] !== true,
      };
      // Reports the INTERACTION, same as before — the write is now part of the
      // undoable document and is persisted by the shared autosave, so there is
      // no per-click PATCH to succeed or fail here.
      if (flag === "hidden") trackKvMotionTrackVisibilityToggled(props);
      else trackKvMotionTrackLockToggled(props);
      state.setOverlayFlag(overlayId, flag);
    },
    [state, project.id]
  );
```

Remove now-unused imports (`patchMotionProject` may still be used by rename/resync — check before deleting) and the two toast strings that only the deleted `catch` used.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web && bun test src/components/studio/kv-generator/motion/useMotionEditorState.layers.test.tsx`
Expected: PASS, 8 tests.

Run: `cd web && bun test src/components/video-editor/TimelineDock.test.tsx`
Expected: PASS, unchanged count.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/KvMotionEditor.tsx src/components/studio/kv-generator/motion/useMotionEditorState.layers.test.tsx
git commit -m "fix(web): make the motion lock/hide toggle undoable and single-writer"
```

---

### Task 7: `Cmd+C` / `Cmd+V`

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx:1215-1235` (the existing keydown effect)
- Test: `web/src/components/studio/kv-generator/motion/KvMotionEditor.clipboardkeys.test.tsx` (create)

**Interfaces:**
- Consumes: `clipboardShortcut`, `isTypingTarget` from `@/lib/studio/kv/keyboardGuards`; `copyLayer` / `pasteLayer` (Task 5); `state.selectedKeyframe` (already on the hook)

Three rules, all load-bearing:
- Registered in the **existing** effect, not a second `window` listener whose ordering relative to the first is unspecified.
- **`Cmd+A` is never claimed.** `clipboardShortcut` classifies it, but Motion has no multi-select; swallowing it would break the browser's own select-all.
- **`preventDefault` only when the action actually happened** — that is why the hook actions return booleans.

- [ ] **Step 1: Write the failing test**

Create `web/src/components/studio/kv-generator/motion/KvMotionEditor.clipboardkeys.test.tsx`. Test the handler in isolation rather than mounting the whole editor (it pulls in Konva, which has no jsdom canvas):

```tsx
import { describe, expect, it, mock } from "bun:test";
import { makeMotionClipboardKeyHandler } from "./KvMotionEditor";

function keyEvent(init: Partial<KeyboardEvent> & { key: string }): KeyboardEvent {
  const e = new KeyboardEvent("keydown", {
    key: init.key,
    metaKey: init.metaKey ?? false,
    shiftKey: init.shiftKey ?? false,
    altKey: init.altKey ?? false,
    cancelable: true,
  });
  return e;
}

describe("motion clipboard key handler", () => {
  it("copies the selected row on Cmd+C and claims the keystroke", () => {
    const copyLayer = mock(() => true);
    const pasteLayer = mock(() => false);
    const handler = makeMotionClipboardKeyHandler({
      selectedTrackId: () => "ov1",
      copyLayer,
      pasteLayer,
    });
    const e = keyEvent({ key: "c", metaKey: true });
    handler(e);
    expect(copyLayer).toHaveBeenCalledWith("ov1");
    expect(e.defaultPrevented).toBe(true);
  });

  it("does nothing on Cmd+C with no row selected", () => {
    const copyLayer = mock(() => true);
    const handler = makeMotionClipboardKeyHandler({
      selectedTrackId: () => null,
      copyLayer,
      pasteLayer: mock(() => false),
    });
    const e = keyEvent({ key: "c", metaKey: true });
    handler(e);
    expect(copyLayer).not.toHaveBeenCalled();
    expect(e.defaultPrevented).toBe(false);
  });

  it("does NOT claim Cmd+V when nothing can land", () => {
    const pasteLayer = mock(() => false);
    const handler = makeMotionClipboardKeyHandler({
      selectedTrackId: () => "ov1",
      copyLayer: mock(() => true),
      pasteLayer,
    });
    const e = keyEvent({ key: "v", metaKey: true });
    handler(e);
    expect(pasteLayer).toHaveBeenCalled();
    expect(e.defaultPrevented).toBe(false);
  });

  it("claims Cmd+V when a layer was added", () => {
    const handler = makeMotionClipboardKeyHandler({
      selectedTrackId: () => "ov1",
      copyLayer: mock(() => true),
      pasteLayer: mock(() => true),
    });
    const e = keyEvent({ key: "v", metaKey: true });
    handler(e);
    expect(e.defaultPrevented).toBe(true);
  });

  it("never claims Cmd+A", () => {
    const handler = makeMotionClipboardKeyHandler({
      selectedTrackId: () => "ov1",
      copyLayer: mock(() => true),
      pasteLayer: mock(() => true),
    });
    const e = keyEvent({ key: "a", metaKey: true });
    handler(e);
    expect(e.defaultPrevented).toBe(false);
  });

  it("ignores the keystroke while typing in a field", () => {
    const input = document.createElement("input");
    document.body.appendChild(input);
    input.focus();
    const copyLayer = mock(() => true);
    const handler = makeMotionClipboardKeyHandler({
      selectedTrackId: () => "ov1",
      copyLayer,
      pasteLayer: mock(() => true),
    });
    const e = keyEvent({ key: "c", metaKey: true });
    Object.defineProperty(e, "target", { value: input });
    handler(e);
    expect(copyLayer).not.toHaveBeenCalled();
    input.remove();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/KvMotionEditor.clipboardkeys.test.tsx`
Expected: FAIL — `makeMotionClipboardKeyHandler` is not exported.

- [ ] **Step 3: Write minimal implementation**

Export a pure factory from `KvMotionEditor.tsx` (above the component), so the rules are testable without mounting Konva:

```ts
/** The Cmd+C / Cmd+V half of the editor's keydown handler, extracted so its
 *  rules are testable without mounting the Konva stage (jsdom has no 2D
 *  context). Returns a handler; the caller owns registration. */
export function makeMotionClipboardKeyHandler(deps: {
  selectedTrackId: () => string | null;
  copyLayer: (overlayId: string) => boolean;
  pasteLayer: () => boolean;
}) {
  return function onClipboardKey(e: KeyboardEvent): void {
    if (isTypingTarget(e.target)) return;
    const shortcut = clipboardShortcut(e);
    // "select-all" is deliberately unhandled: Motion has no multi-select, and
    // swallowing Cmd+A without an answer makes it a dead key.
    if (shortcut !== "copy" && shortcut !== "paste") return;

    if (shortcut === "copy") {
      const trackId = deps.selectedTrackId();
      if (!trackId) return; // nothing selected — leave the keystroke alone
      if (deps.copyLayer(trackId)) e.preventDefault();
      return;
    }
    // Only claim the paste if a layer actually landed; otherwise Cmd+V would
    // become a dead key on an empty or foreign clipboard.
    if (deps.pasteLayer()) e.preventDefault();
  };
}
```

Add the imports at the top of the file:

```ts
import {
  clipboardShortcut,
  isTypingTarget,
} from "@/lib/studio/kv/keyboardGuards";
```

Then extend the **existing** keydown effect (`:1216`) — do not add a second listener:

```ts
  // ── Cmd+Z / Shift+Cmd+Z, Cmd+C / Cmd+V at the page level ──
  const clipboardKeyHandler = useMemo(
    () =>
      makeMotionClipboardKeyHandler({
        selectedTrackId: () => state.selectedKeyframe?.trackId ?? null,
        copyLayer: state.copyLayer,
        pasteLayer: state.pasteLayer,
      }),
    [state.selectedKeyframe, state.copyLayer, state.pasteLayer]
  );

  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      const isMeta = e.metaKey || e.ctrlKey;
      if (isMeta && e.key.toLowerCase() === "z") {
        const target = e.target as HTMLElement | null;
        if (
          target &&
          (target.tagName === "INPUT" ||
            target.tagName === "TEXTAREA" ||
            target.isContentEditable)
        ) {
          return;
        }
        e.preventDefault();
        if (e.shiftKey) state.redo();
        else state.undo();
        return;
      }
      clipboardKeyHandler(e);
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [state.undo, state.redo, clipboardKeyHandler]);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/motion/KvMotionEditor.clipboardkeys.test.tsx`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/KvMotionEditor.tsx src/components/studio/kv-generator/motion/KvMotionEditor.clipboardkeys.test.tsx
git commit -m "feat(web): Cmd+C and Cmd+V duplicate a motion layer"
```

---

### Task 8: Duplicate / Delete in the row's right-click menu

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/TrackPresetMenu.tsx` (two optional props, rendered in anchored mode only)
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx:1688-1699` (pass them)
- Test: `web/src/components/studio/kv-generator/motion/TrackPresetMenu.test.tsx` (extend the existing file — check its size first; if it is anywhere near 51KB, create `TrackPresetMenu.layeractions.test.tsx` instead)

**Interfaces:**
- Consumes: `copyLayer`/`pasteLayer`/`deleteLayer` (Task 5), `isMotionAuthoredOverlay` (Task 5)
- Produces on `TrackPresetMenu`: `onDuplicateLayer?: () => void`, `onDeleteLayer?: () => void`

Placement rationale: the ✨ rail trigger is explicitly "apply a motion" — a layer-lifecycle action there is a trash icon in the wrong place, exactly the reasoning the file's own `actionsFor` comment already gives. These items render **only** when the menu is anchored (opened by right-click), which is the row's general context menu.

- [ ] **Step 1: Write the failing test**

Append to the `TrackPresetMenu` test file:

```tsx
describe("TrackPresetMenu — layer actions", () => {
  it("shows Duplicate and Delete only when anchored", () => {
    const { rerender } = render(
      <TrackPresetMenu
        {...baseProps}
        onDuplicateLayer={() => {}}
        onDeleteLayer={() => {}}
      />
    );
    // Rail (✨) mode: closed popover, no layer actions.
    expect(
      within(document.body).queryByText("Duplicate layer")
    ).toBeNull();

    rerender(
      <TrackPresetMenu
        {...baseProps}
        anchor={{ x: 10, y: 10 }}
        onCloseAnchored={() => {}}
        onDuplicateLayer={() => {}}
        onDeleteLayer={() => {}}
      />
    );
    expect(
      within(document.body).getByText("Duplicate layer")
    ).toBeTruthy();
    expect(within(document.body).getByText("Delete layer")).toBeTruthy();
  });

  it("omits Delete when the handler is not supplied", () => {
    render(
      <TrackPresetMenu
        {...baseProps}
        anchor={{ x: 10, y: 10 }}
        onCloseAnchored={() => {}}
        onDuplicateLayer={() => {}}
      />
    );
    expect(within(document.body).getByText("Duplicate layer")).toBeTruthy();
    expect(within(document.body).queryByText("Delete layer")).toBeNull();
  });

  it("fires the handler and closes the menu", () => {
    const onDuplicateLayer = mock(() => {});
    const onCloseAnchored = mock(() => {});
    render(
      <TrackPresetMenu
        {...baseProps}
        anchor={{ x: 10, y: 10 }}
        onCloseAnchored={onCloseAnchored}
        onDuplicateLayer={onDuplicateLayer}
      />
    );
    fireEvent.click(within(document.body).getByText("Duplicate layer"));
    expect(onDuplicateLayer).toHaveBeenCalledTimes(1);
    expect(onCloseAnchored).toHaveBeenCalledTimes(1);
  });
});
```

Reuse whatever `baseProps` fixture the existing file already defines; if it has none, build one from the component's required props (`trackName`, `onApply`, `onApplyEmphasis`, `playheadMs`, `durationMs`, `templates: []`, `currentUserId: undefined`, `hasKeyframes: false`, `onApplyTemplate`, `onSaveTemplate`, `onRenameTemplate`, `onDeleteTemplate`).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/TrackPresetMenu.test.tsx`
Expected: FAIL — "Duplicate layer" is not in the document.

- [ ] **Step 3: Write minimal implementation**

Add to `TrackPresetMenu`'s props:

```ts
  /** Layer-lifecycle actions, rendered ONLY in anchored (right-click) mode.
   *  The ✨ rail trigger is "apply a motion" — a Delete there is a trash icon
   *  in the wrong place, the same reasoning `actionsFor` documents above.
   *  Omit `onDeleteLayer` for a layer that may not be deleted (anything
   *  mirrored from KV): the item is then not rendered at all, rather than
   *  rendered disabled. */
  onDuplicateLayer?: () => void;
  onDeleteLayer?: () => void;
```

Render at the bottom of the popover content, guarded by `anchored`:

```tsx
      {anchored && (onDuplicateLayer || onDeleteLayer) && (
        <div className="mt-2 border-t border-white/10 pt-2">
          {onDuplicateLayer && (
            <button
              type="button"
              className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-textXsMedium text-white/80 hover:bg-white/10"
              onClick={() => {
                onDuplicateLayer();
                closeMenu();
              }}
            >
              <CopySimple className="h-3.5 w-3.5" />
              Duplicate layer
            </button>
          )}
          {onDeleteLayer && (
            <button
              type="button"
              className="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-textXsMedium text-red-400 hover:bg-red-500/10"
              onClick={() => {
                onDeleteLayer();
                closeMenu();
              }}
            >
              <Trash className="h-3.5 w-3.5" />
              Delete layer
            </button>
          )}
        </div>
      )}
```

Add `CopySimple` to the existing `@phosphor-icons/react` import (`Trash` is already imported).

In `KvMotionEditor.tsx`, pass them where the anchored menu is rendered (`:1693`):

```tsx
            <TrackPresetMenu
              {...trackPresetMenuProps(t.id, t.name)}
              anchor={{ x: trackMenu.x, y: trackMenu.y }}
              onCloseAnchored={() => setTrackMenu(null)}
              onDuplicateLayer={() => {
                // Copy-then-paste rather than a third code path, so the menu
                // and Cmd+C/Cmd+V cannot drift on what a duplicate is.
                if (state.copyLayer(t.id)) state.pasteLayer();
              }}
              onDeleteLayer={
                isMotionAuthoredOverlay(t.id)
                  ? () => state.deleteLayer(t.id)
                  : undefined
              }
            />
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/motion/TrackPresetMenu.test.tsx`
Expected: PASS, existing tests plus 3 new.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/TrackPresetMenu.tsx src/components/studio/kv-generator/motion/KvMotionEditor.tsx src/components/studio/kv-generator/motion/TrackPresetMenu.test.tsx
git commit -m "feat(web): duplicate and delete a motion layer from its row menu"
```

---

### Task 9: Resync — one writer, and a counted warning

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx:1290-1340` (the resync handler) and `:1843-1847` (the dialog)
- Test: `web/src/components/studio/kv-generator/motion/motionResyncWarning.test.ts` (create) — the counter is extracted so it is testable without mounting the editor

**Interfaces:**
- Consumes: `isMotionAuthoredOverlay` (Task 5), `pushSaved` (Tasks 3–4)
- Produces: `countMotionAuthoredOverlays(overlays: StudioOverlay[]): number` and `resyncWarningText(count: number): string`, exported from `KvMotionEditor.tsx`

> **Merge warning:** the spawned task *"Fix resync dropping motion snapshot target/tiles"* edits the same `newSnapshot` literal. Whichever lands second must merge rather than overwrite — that fix preserves `target`/`tiles`, this task changes how the result is committed. They are compatible; a blind overwrite is not.

- [ ] **Step 1: Write the failing test**

Create `web/src/components/studio/kv-generator/motion/motionResyncWarning.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import {
  countMotionAuthoredOverlays,
  resyncWarningText,
} from "./KvMotionEditor";
import type { StudioOverlay } from "@/types/studio";

function overlay(id: string): StudioOverlay {
  return {
    id,
    studio_file_id: "f1",
    type: "text",
    x: 0,
    y: 0,
    width: 0.1,
    height: 0.1,
    rotation: 0,
    z: 0,
    payload: { type: "text", content: "H", color: "#000000" },
    created_at: "t",
    updated_at: "t",
  };
}

describe("resync warning", () => {
  it("counts only motion-authored layers", () => {
    expect(
      countMotionAuthoredOverlays([
        overlay("ov1"),
        overlay("mo_1_a"),
        overlay("mo_2_b"),
        overlay("tmp_9_c"),
      ])
    ).toBe(2);
  });

  it("leaves the copy unchanged when nothing was authored in Motion", () => {
    const base = resyncWarningText(0);
    expect(base).toBe(
      "Tracks for overlays deleted in KV will be removed; keyframes for surviving overlays are kept."
    );
  });

  it("names the number that will be destroyed", () => {
    expect(resyncWarningText(1)).toContain("1 layer you created in Motion");
    expect(resyncWarningText(3)).toContain("3 layers you created in Motion");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/motionResyncWarning.test.ts`
Expected: FAIL — `countMotionAuthoredOverlays` is not exported.

- [ ] **Step 3: Write minimal implementation**

Add near the top of `KvMotionEditor.tsx`. `StudioOverlay` and `KvOverlayType`
are already imported by this file (`:102`, `:73`); `isMotionAuthoredOverlay` is
not — add it to the existing `./useMotionEditorState` import:

```ts
import {
  isMotionAuthoredOverlay,
  useMotionEditorState,
} from "./useMotionEditorState";

const RESYNC_BASE_WARNING =
  "Tracks for overlays deleted in KV will be removed; keyframes for surviving overlays are kept.";

/** How many layers in this snapshot were created in Motion rather than
 *  mirrored from the KV board. Resync rebuilds `snapshot.overlays` from the
 *  board, so every one of these — and its animation — is destroyed. */
export function countMotionAuthoredOverlays(overlays: StudioOverlay[]): number {
  return overlays.filter((o) => isMotionAuthoredOverlay(o.id)).length;
}

/** Losing motion-authored layers on resync is the accepted design. The
 *  obligation that comes with it is that it must never be a surprise, so the
 *  dialog names the exact number instead of warning generically. */
export function resyncWarningText(count: number): string {
  if (count <= 0) return RESYNC_BASE_WARNING;
  const noun = count === 1 ? "layer" : "layers";
  return `${RESYNC_BASE_WARNING} ${count} ${noun} you created in Motion will be deleted.`;
}
```

In the resync handler, replace the `state.push(prunedTimeline, "resync")` line and the cache write. The explicit PATCH stays — it also rebinds the board id and its rejection drives the dialog's error — but the command state is now synced through `pushSaved`, so autosave does not immediately re-send what the server just accepted:

```ts
      const updated = await patchMotionProject(
        project.studioFileId,
        project.id,
        {
          snapshot: newSnapshot,
          timeline: prunedTimeline,
          ...(rebindBoard ? { boardGenerationId: rebindBoard } : {}),
        }
      );
      qc.setQueryData(motionProjectKey(fileId, projectId), updated);
      // Sync the undo stack to what the server now holds, and mark it saved:
      // this document is already persisted, so the debounced autosave must not
      // treat it as a fresh edit and PATCH it straight back.
      state.pushSaved(
        { snapshot: newSnapshot, timeline: prunedTimeline },
        "resync"
      );
```

Delete the now-superseded `state.push(prunedTimeline, "resync")` call earlier in the handler (it ran BEFORE the PATCH; the stack must only move once the server has accepted).

In the dialog:

```tsx
        description={resyncWarningText(
          countMotionAuthoredOverlays(project.snapshot.overlays)
        )}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/motion/motionResyncWarning.test.ts`
Expected: PASS, 3 tests.

- [ ] **Step 5: Run the full motion suite**

```bash
cd web && bun test \
  src/lib/video-editor/cloneTrackForOverlay.test.ts \
  src/lib/studio/kv/overlayClipboard.motion.test.ts \
  src/lib/studio/kv/overlayClipboard.test.ts \
  src/components/video-editor/useTimelineCommands.doc.test.tsx \
  src/components/studio/kv-generator/motion/useMotionEditorState.test.ts \
  src/components/studio/kv-generator/motion/useMotionEditorState.autosave.test.tsx \
  src/components/studio/kv-generator/motion/useMotionEditorState.docautosave.test.tsx \
  src/components/studio/kv-generator/motion/useMotionEditorState.layers.test.tsx \
  src/components/studio/kv-generator/motion/useMotionEditorState.propGroup.test.ts \
  src/components/studio/kv-generator/motion/KvMotionEditor.clipboardkeys.test.tsx \
  src/components/studio/kv-generator/motion/motionResyncWarning.test.ts \
  src/components/studio/kv-generator/motion/TrackPresetMenu.test.tsx
```

Expected: all PASS. Note the explicit file list — `bun test` on a directory has blown up to 26 GB here.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/motion/KvMotionEditor.tsx src/components/studio/kv-generator/motion/motionResyncWarning.test.ts
git commit -m "feat(web): warn with a count before resync destroys motion-authored layers"
```

---

## Manual verification (required before calling this done)

None of the following can be proven by the test suite — jsdom provides no 2D canvas context, so Konva rendering and MP4 export are invisible to it. Report them as unverified until a human has run them.

1. Right-click a layer row → **Duplicate layer**. The copy appears on the stage, nudged down-right, above the original.
2. `Cmd+Z`. Both the duplicate *and* its animation disappear in one press.
3. `Cmd+Shift+Z`. Both come back.
4. Select a row, `Cmd+C`, `Cmd+V`, `Cmd+V`. Three copies, each nudged from the last.
5. Play the timeline. The duplicate animates identically to its source.
6. Export. The duplicate is present in the MP4.
7. Type in the project-name field and press `Cmd+C`/`Cmd+V`. Text is copied and pasted — the canvas shortcut does not fire.
8. Press `Cmd+V` with an empty clipboard. Nothing happens and no error appears.
9. Right-click a KV-mirrored layer. **Delete layer** is absent. Right-click a duplicate. It is present and works.
10. With at least one duplicate present, open **Resync from KV**. The dialog names the exact number of layers that will be deleted. Confirm; they are gone and the remaining tracks survive.
11. Reload the page after a duplicate. The duplicate is still there (proves the snapshot half of the autosave landed).
