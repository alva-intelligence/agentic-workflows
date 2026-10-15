# KV Motion — mark without export (web) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "Mark ready to share" on a Motion size renders + uploads the MP4 in the background when there is no up-to-date export, and a marked size whose design changed shows "Outdated" with an Update action.

**Architecture:** A pure fingerprint (`motionExportFingerprint`) hashes exactly what one size's render consumes; it is stored on each export (`source_hash`, api plan) and compared with the live design. The render → upload → record steps move out of `KvMotionExportDialog` into `motionExportRun.ts`, shared by the dialog and a new background queue hook (`useBackgroundMotionExport`) that the tile chip drives. Marks are untouched: the api already serves the newest export of a marked (project, size).

**Tech Stack:** Next.js 16, React 19, TypeScript, TanStack Query v5, Zustand (toasts), bun test + Testing Library, WebCodecs/Mediabunny (via the existing `exportMotionRatio`).

**Spec:** `docs/superpowers/specs/2026-10-15-kv-motion-mark-without-export-design.md`

## Global Constraints

- Repo `web/` (alva-intelligence/frnd-web). Branch `feature/daffa/vc-kv-motion-mark-without-export` cut from latest `develop`.
- Depends on the api plan (`…-api.md`): export JSON carries `source_hash: string | null`; store accepts optional lower-case 64-hex `source_hash`.
- An export with `sourceHash === null` is **unknown → treated as current**, never "Outdated".
- One render at a time across the whole editor (dialog runs and background runs never overlap).
- Copy, verbatim: chip `Mark ready to share`, `Ready to share`, `Queued`, `Preparing… NN%`, badge `Outdated`, action `Update`.
- No infinite CSS/WAAPI animation (no `animate-spin`, no pulse) on anything shown while a render runs — it starves the encoder (`lesson_export_starved_by_page_animations`).
- Tests: `bun test <file>` per file — never a directory (memory blow-up). DI seams, not `mock.module` (process-global binding capture). Query via `within(document.body)`, not `screen`.
- No type gate exists (`ignoreBuildErrors`, ~777-error tsc baseline): check new errors with `bunx tsc --noEmit -p . 2>&1 | grep <file>`.
- Lint touched files: `bunx eslint <files>`.
- Commits: `<type>(web): …`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- **Mark clicked inside the fingerprint debounce window right after an edit** — must render a new MP4, not mark the stale export. Pinned in Task 1 (`resolveMarkAction` hashes at click time) and used in Task 8.
- **Size marked elsewhere while its background render runs** (dialog toggle, projects panel) — finishing the render must not UNMARK it. Pinned in Task 6 (`markIdAfterExport`).
- **Size removed from the project while its job is queued** — job fails with a toast, nothing crashes, queue moves on. Pinned in Task 5.
- **Dialog export started while a background render runs (or vice versa)** — never two encoders at once. Pinned in Task 5 (`paused`) and Task 7 (`backgroundBusy`).
- **Leaving the editor mid-render** — render aborted, nothing uploaded or marked. Pinned in Task 5.

---

### Task 1: Fingerprint module

**Files:**
- Create: `web/src/components/studio/kv-generator/motion/motionExportFingerprint.ts`
- Test: `web/src/components/studio/kv-generator/motion/motionExportFingerprint.test.ts`

**Interfaces:**
- Produces:
  - `type MotionExportInputs`
  - `motionExportInputsFor(opts: { snapshot: KvMotionSnapshot; timeline: MotionTimeline; audioUrl: string | null; tile: KvMotionTile }): MotionExportInputs`
  - `motionExportFingerprint(inputs: MotionExportInputs): Promise<string>` — 64 lower-case hex
  - `isExportOutdated(latest: { sourceHash: string | null } | null, currentHash: string | null): boolean`
  - `resolveMarkAction(latest: { sourceHash: string | null } | null, inputs: MotionExportInputs): Promise<"mark_existing" | "render_then_mark">`

- [ ] **Step 1: Create the branch**

```bash
cd web
git checkout develop && git pull --ff-only origin develop
git checkout -b feature/daffa/vc-kv-motion-mark-without-export
```

- [ ] **Step 2: Write the failing tests**

`motionExportFingerprint.test.ts`:

```ts
import { describe, expect, it } from "bun:test";

import type { MotionTimeline } from "@/lib/video-editor/timeline";
import type { KvMotionSnapshot, KvMotionTile } from "@/types/kv/motionProject";

import {
  isExportOutdated,
  motionExportFingerprint,
  motionExportInputsFor,
  resolveMarkAction,
} from "./motionExportFingerprint";

const TILE_A: KvMotionTile = {
  key: "tile-a",
  platform_id: "instagram-story",
  label: "9:16",
  source: "resize",
  base_image_url: "https://cdn.example.com/a.png",
  width: 1080,
  height: 1920,
  overlays: null,
  timeline: null,
};
const TILE_B: KvMotionTile = {
  ...TILE_A,
  key: "tile-b",
  platform_id: "square-poster",
  base_image_url: "https://cdn.example.com/b.png",
  width: 1080,
  height: 1080,
};
const snapshot: KvMotionSnapshot = {
  base_image_url: "https://cdn.example.com/board.png",
  board_width: 1080,
  board_height: 1920,
  overlays: [],
  tiles: [TILE_A, TILE_B],
};
const timeline: MotionTimeline = {
  version: 1,
  duration_ms: 2000,
  fps: 30,
  tracks: [
    {
      kind: "overlay",
      overlay_id: "o1",
      keyframes: [{ t_ms: 0, props: { x: 0 }, easing: "linear" }],
    },
  ],
} as unknown as MotionTimeline;

const hashFor = (over: {
  snapshot?: KvMotionSnapshot;
  timeline?: MotionTimeline;
  audioUrl?: string | null;
  tile?: KvMotionTile;
}) =>
  motionExportFingerprint(
    motionExportInputsFor({
      snapshot: over.snapshot ?? snapshot,
      timeline: over.timeline ?? timeline,
      audioUrl: over.audioUrl === undefined ? null : over.audioUrl,
      tile: over.tile ?? TILE_A,
    })
  );

describe("motionExportFingerprint", () => {
  it("is 64 lower-case hex", async () => {
    expect(await hashFor({})).toMatch(/^[0-9a-f]{64}$/);
  });

  it("ignores key order", async () => {
    const reordered = { tracks: timeline.tracks, fps: 30, duration_ms: 2000, version: 1 } as MotionTimeline;
    expect(await hashFor({ timeline: reordered })).toBe(await hashFor({}));
  });

  it("changes when the timeline changes", async () => {
    const moved = {
      ...timeline,
      tracks: [{ ...timeline.tracks[0], keyframes: [{ t_ms: 100, props: { x: 0 }, easing: "linear" }] }],
    } as unknown as MotionTimeline;
    expect(await hashFor({ timeline: moved })).not.toBe(await hashFor({}));
  });

  it("changes when THIS tile's artwork changes", async () => {
    expect(await hashFor({ tile: { ...TILE_A, base_image_url: "https://cdn.example.com/a2.png" } }))
      .not.toBe(await hashFor({}));
  });

  it("does NOT change when ANOTHER tile changes", async () => {
    const otherEdited: KvMotionSnapshot = {
      ...snapshot,
      tiles: [TILE_A, { ...TILE_B, base_image_url: "https://cdn.example.com/b2.png" }],
    };
    expect(await hashFor({ snapshot: otherEdited })).toBe(await hashFor({}));
  });

  it("changes when the project audio changes", async () => {
    expect(await hashFor({ audioUrl: "https://cdn.example.com/song.mp3" })).not.toBe(await hashFor({}));
  });
});

describe("isExportOutdated", () => {
  it("is false with no export, no stored hash, or no current hash", () => {
    expect(isExportOutdated(null, "a")).toBe(false);
    expect(isExportOutdated({ sourceHash: null }, "a")).toBe(false);
    expect(isExportOutdated({ sourceHash: "a" }, null)).toBe(false);
  });

  it("is true only when both hashes exist and differ", () => {
    expect(isExportOutdated({ sourceHash: "a" }, "a")).toBe(false);
    expect(isExportOutdated({ sourceHash: "a" }, "b")).toBe(true);
  });
});

describe("resolveMarkAction", () => {
  it("renders when there is no export yet", async () => {
    const inputs = motionExportInputsFor({ snapshot, timeline, audioUrl: null, tile: TILE_A });
    expect(await resolveMarkAction(null, inputs)).toBe("render_then_mark");
  });

  it("marks the existing export when it matches the design", async () => {
    const inputs = motionExportInputsFor({ snapshot, timeline, audioUrl: null, tile: TILE_A });
    const hash = await motionExportFingerprint(inputs);
    expect(await resolveMarkAction({ sourceHash: hash }, inputs)).toBe("mark_existing");
  });

  it("renders when the design moved on since the export", async () => {
    const inputs = motionExportInputsFor({ snapshot, timeline, audioUrl: null, tile: TILE_A });
    expect(await resolveMarkAction({ sourceHash: "0".repeat(64) }, inputs)).toBe("render_then_mark");
  });

  it("treats a legacy export (no hash) as current", async () => {
    const inputs = motionExportInputsFor({ snapshot, timeline, audioUrl: null, tile: TILE_A });
    expect(await resolveMarkAction({ sourceHash: null }, inputs)).toBe("mark_existing");
  });
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/motionExportFingerprint.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 4: Implement**

`motionExportFingerprint.ts`:

```ts
/**
 * The fingerprint of what ONE size's MP4 render consumes (spec 2026-10-15
 * §4.1). Stored on each export as `source_hash`; the editor compares it with
 * the live design to tell a shared size is "Outdated".
 *
 * Inputs mirror `exportMotionRatio`'s arguments: the snapshot WITHOUT its
 * `tiles` list (another size's artwork does not change this size's MP4), the
 * whole timeline (every field in it is render-relevant), the project audio
 * url, and this tile's own artwork + output size. Different hash ⇒ the MP4
 * would differ.
 */
import type { MotionTimeline } from "@/lib/video-editor/timeline";
import type { KvMotionSnapshot, KvMotionTile } from "@/types/kv/motionProject";

export type MotionExportInputs = {
  snapshot: Omit<KvMotionSnapshot, "tiles">;
  timeline: MotionTimeline;
  audioUrl: string | null;
  tile: Pick<
    KvMotionTile,
    "key" | "platform_id" | "width" | "height" | "base_image_url" | "overlays" | "source"
  >;
};

export function motionExportInputsFor(opts: {
  snapshot: KvMotionSnapshot;
  timeline: MotionTimeline;
  audioUrl: string | null;
  tile: KvMotionTile;
}): MotionExportInputs {
  const { tiles: _otherSizes, ...snapshot } = opts.snapshot;
  const t = opts.tile;
  return {
    snapshot,
    timeline: opts.timeline,
    audioUrl: opts.audioUrl,
    tile: {
      key: t.key,
      platform_id: t.platform_id,
      width: t.width,
      height: t.height,
      base_image_url: t.base_image_url,
      overlays: t.overlays,
      source: t.source,
    },
  };
}

/** Sorted keys, `undefined` dropped — so key order and absent-vs-undefined
 *  never change the hash. */
function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") {
    return JSON.stringify(value) ?? "null";
  }
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, v]) => v !== undefined)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return `{${entries
    .map(([k, v]) => `${JSON.stringify(k)}:${stableStringify(v)}`)
    .join(",")}}`;
}

export async function motionExportFingerprint(
  inputs: MotionExportInputs
): Promise<string> {
  const bytes = new TextEncoder().encode(stableStringify(inputs));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) =>
    b.toString(16).padStart(2, "0")
  ).join("");
}

/** A stored export with no hash (made before fingerprints existed) is
 *  UNKNOWN, never outdated — the feature launches with no false alarms. */
export function isExportOutdated(
  latest: { sourceHash: string | null } | null,
  currentHash: string | null
): boolean {
  return (
    latest !== null &&
    latest.sourceHash !== null &&
    currentHash !== null &&
    latest.sourceHash !== currentHash
  );
}

/**
 * What "Mark ready to share" on an UNMARKED size should do. Hashes the design
 * at CLICK time rather than trusting the editor's debounced display hashes —
 * a click right after an edit would otherwise mark the stale export.
 */
export async function resolveMarkAction(
  latest: { sourceHash: string | null } | null,
  inputs: MotionExportInputs
): Promise<"mark_existing" | "render_then_mark"> {
  if (latest === null) return "render_then_mark";
  const current = await motionExportFingerprint(inputs);
  return isExportOutdated(latest, current) ? "render_then_mark" : "mark_existing";
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/motion/motionExportFingerprint.test.ts`
Expected: all PASS. Then temporarily break `stableStringify`'s sort (comment the `.sort(...)` line), confirm "ignores key order" FAILS, restore it — the test must be able to fail.

- [ ] **Step 6: Lint + commit**

```bash
cd web
bunx eslint src/components/studio/kv-generator/motion/motionExportFingerprint.ts src/components/studio/kv-generator/motion/motionExportFingerprint.test.ts
git add src/components/studio/kv-generator/motion/motionExportFingerprint.ts src/components/studio/kv-generator/motion/motionExportFingerprint.test.ts
git commit -m "feat(web): fingerprint what a Motion size's export renders

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `sourceHash` on export rows

**Files:**
- Modify: `web/src/types/kv/motionProject.ts` (`KvMotionExportRow`)
- Modify: `web/src/services/kv/motionProjects.ts` (`WireMotionExportRow`, `toMotionExportRow`, `createMotionExport`)
- Test: `web/src/services/kv/motionProjects.test.ts` (create)

**Interfaces:**
- Consumes: api export JSON `source_hash: string | null` (api plan Task 1).
- Produces: `KvMotionExportRow.sourceHash: string | null`; `createMotionExport(fileId, projectId, body: { ratio; url; width; height; durationMs; sourceHash?: string | null })`; exported pure helpers `toMotionExportRow(w)` and `motionExportBody(body)`.

- [ ] **Step 1: Write the failing test**

`web/src/services/kv/motionProjects.test.ts`:

```ts
import { describe, expect, it } from "bun:test";

import { motionExportBody, toMotionExportRow } from "./motionProjects";

describe("motion export wire mapping", () => {
  const wire = {
    id: "e1",
    kv_motion_project_id: "p1",
    ratio: "9:16",
    url: "https://cdn.example.com/m.mp4",
    width: 1080,
    height: 1920,
    duration_ms: 5000,
    created_at: "2026-10-15T00:00:00Z",
  };

  it("maps source_hash to sourceHash", () => {
    expect(toMotionExportRow({ ...wire, source_hash: "ab".repeat(32) }).sourceHash).toBe("ab".repeat(32));
  });

  it("reads a missing source_hash (old api) as null, never undefined", () => {
    expect(toMotionExportRow(wire).sourceHash).toBeNull();
  });

  it("sends source_hash, and null when the caller has none", () => {
    const base = { ratio: "9:16", url: "u", width: 1, height: 2, durationMs: 3 };
    expect(motionExportBody({ ...base, sourceHash: "cd".repeat(32) })).toEqual({
      ratio: "9:16", url: "u", width: 1, height: 2, duration_ms: 3, source_hash: "cd".repeat(32),
    });
    expect(motionExportBody(base).source_hash).toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bun test src/services/kv/motionProjects.test.ts`
Expected: FAIL — `motionExportBody` / `toMotionExportRow` not exported.

- [ ] **Step 3: Implement**

`motionProject.ts` — add to `KvMotionExportRow` after `createdAt`:

```ts
  /** Fingerprint of the design this MP4 rendered (spec 2026-10-15 §4.1).
   *  `null` = made before fingerprints existed: unknown, never "outdated". */
  sourceHash: string | null;
```

`motionProjects.ts`:
- `WireMotionExportRow`: add `source_hash?: string | null;`
- `function toMotionExportRow` → `export function toMotionExportRow`, add `sourceHash: w.source_hash ?? null,`
- Add, above `createMotionExport`:

```ts
type MotionExportBody = {
  ratio: string;
  url: string;
  width: number;
  height: number;
  durationMs: number;
  sourceHash?: string | null;
};

/** The store payload. `source_hash` is always sent — `null` when the caller
 *  has none, which the api stores as "unknown". */
export function motionExportBody(body: MotionExportBody) {
  return {
    ratio: body.ratio,
    url: body.url,
    width: body.width,
    height: body.height,
    duration_ms: body.durationMs,
    source_hash: body.sourceHash ?? null,
  };
}
```

- Change `createMotionExport`'s `body` param type to `MotionExportBody` and its post payload to `motionExportBody(body)`.

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && bun test src/services/kv/motionProjects.test.ts src/components/studio/kv-generator/motion/KvMotionProjectExports.test.ts`
Expected: PASS.

- [ ] **Step 5: Lint + commit**

```bash
cd web
bunx eslint src/types/kv/motionProject.ts src/services/kv/motionProjects.ts src/services/kv/motionProjects.test.ts
git add src/types/kv/motionProject.ts src/services/kv/motionProjects.ts src/services/kv/motionProjects.test.ts
git commit -m "feat(web): carry source_hash on Motion export rows

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Analytics events

**Files:**
- Modify: `web/src/lib/analytics/kv-generator-events.ts`

**Interfaces:**
- Produces:
  - `type KvMotionExportTrigger = "dialog" | "mark" | "update"`
  - optional `trigger?: KvMotionExportTrigger` on `KvMotionExportCompletedProps` and `KvMotionExportFailedProps`
  - `trackKvMotionExportStarted(p: { project_id: string; ratio: string; trigger: "mark" | "update" })` → `kv_generator.motion_export_started`
  - `trackKvMotionShareUpdateClicked(p: { file_id: string; project_id: string; ratio: string; surface: "chip" | "export_dialog" })` → `kv_generator.motion_share_update_clicked`

- [ ] **Step 1: Read the skill**

Read `web/.claude/skills/frndos-analytics-events/SKILL.md` and its `references/event-conventions.md`. Confirm neither new name appears in the taxonomy doc's Removed/Deprecated tables (ask Daffa to check the Lark taxonomy if you cannot open it).

- [ ] **Step 2: Implement**

In `kv-generator-events.ts`, above `KvMotionExportCompletedProps`:

```ts
/** What started a Motion render: the Export dialog, "Mark ready to share" on a
 *  size with no current export, or "Update" on an outdated shared size
 *  (spec 2026-10-15). Optional on the completed/failed events so rows from
 *  before it existed stay valid. */
export type KvMotionExportTrigger = "dialog" | "mark" | "update";
```

Add `trigger?: KvMotionExportTrigger;` as the last field of both `KvMotionExportCompletedProps` and `KvMotionExportFailedProps`.

After `trackKvMotionExportFailed`:

```ts
/** A BACKGROUND render began (spec 2026-10-15) — the attempt leg for renders
 *  that never open the Export dialog (whose own attempt leg is
 *  `motion_export_dialog_opened`). */
export const trackKvMotionExportStarted = (p: {
  project_id: string;
  ratio: string;
  trigger: "mark" | "update";
}) => safeCapture("kv_generator.motion_export_started", p);

/** "Update" on an outdated shared Motion size. */
export const trackKvMotionShareUpdateClicked = (p: {
  file_id: string;
  project_id: string;
  ratio: string;
  surface: "chip" | "export_dialog";
}) => safeCapture("kv_generator.motion_share_update_clicked", p);
```

- [ ] **Step 3: Lint + commit**

```bash
cd web
bunx eslint src/lib/analytics/kv-generator-events.ts
git add src/lib/analytics/kv-generator-events.ts
git commit -m "feat(web): analytics for background Motion renders and Update

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Shared export runner; dialog sends the hash

Behaviour-preserving extraction first (the dialog's ~20 existing tests are the safety net), then the hash.

**Files:**
- Create: `web/src/components/studio/kv-generator/motion/motionExportRun.ts`
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx`
- Test: `web/src/components/studio/kv-generator/motion/KvMotionExportDialog.test.tsx` (add one case)
- Test (unchanged, must stay green): `KvMotionExportDialog.bumpers.test.tsx`, `KvMotionExportDialog.encodable.test.tsx`

**Interfaces:**
- Consumes: Task 1 `motionExportInputsFor`, `motionExportFingerprint`; Task 2 `createMotionExport` body `sourceHash`; Task 3 `trigger`.
- Produces (`motionExportRun.ts`):
  - `decodeAudioFile(file: Response): Promise<AudioBuffer>` (moved from the dialog)
  - `type MotionExportRun = { audioBuffer: AudioBuffer | null; openBumperVideo: (url: string) => Promise<BumperVideoSource>; dispose: () => void }`
  - `prepareMotionExportRun(opts: { timeline: MotionTimeline; audioUrl: string | null; openBumperVideoFn: typeof openBumperVideo; onAudioDropped: () => void }): Promise<MotionExportRun>`
  - `renderMotionTile(opts: { run: MotionExportRun; snapshot: KvMotionSnapshot; timeline: MotionTimeline; tile: KvMotionTile; signal: AbortSignal; onProgress: (frac: number) => void; onFinalizing: () => void; exportRatioFn: typeof exportMotionRatio }): Promise<Blob>`
  - `recordMotionExport(opts: { studioFileId: string; projectId: string; tile: KvMotionTile; timeline: MotionTimeline; blob: Blob; sourceHash: string | null; uploadAssetFn: typeof uploadStudioOverlayAsset; createExportFn: typeof createMotionExport }): Promise<KvMotionExportRow>`

- [ ] **Step 1: Baseline the dialog tests**

Run each file on its own:

```bash
cd web
bun test src/components/studio/kv-generator/motion/KvMotionExportDialog.test.tsx
bun test src/components/studio/kv-generator/motion/KvMotionExportDialog.bumpers.test.tsx
bun test src/components/studio/kv-generator/motion/KvMotionExportDialog.encodable.test.tsx
```

Record the pass counts. All must stay at least this green after Step 3.

- [ ] **Step 2: Create `motionExportRun.ts`**

Move code VERBATIM from `KvMotionExportDialog.tsx` (comments included), adapting only what is shown:

```ts
/**
 * One Motion render run, shared by the Export dialog and the background
 * queue (spec 2026-10-15 §4.2) so an MP4 from "Mark ready to share" goes
 * through exactly the pipeline an MP4 from Export does.
 */
import { renderAudioMix } from "@/lib/video-editor/audio";
import { bumperLayout } from "@/lib/video-editor/bumpers";
import { bumperAudioClip, shiftClipsForBumpers } from "@/lib/video-editor/bumperAudio";
import {
  normalizeTimelineAudio,
  type MotionTimeline,
  type ResolvedMotionAudio,
} from "@/lib/video-editor/timeline";
import { uploadStudioOverlayAsset } from "@/services/kv/api";
import { createMotionExport } from "@/services/kv/motionProjects";
import type { KvMotionExportRow, KvMotionSnapshot, KvMotionTile } from "@/types/kv/motionProject";

import { openBumperVideo, type BumperVideoSource } from "./bumperVideoSource";
import { fetchAudioForExport } from "./exportAudioFetch";
import { exportMotionRatio } from "./exportMotion";

// ← paste `decodeAudioFile` here unchanged, now `export function`.

export type MotionExportRun = {
  audioBuffer: AudioBuffer | null;
  /** The run's shared bumper source (one download per bumper per run). */
  openBumperVideo: (url: string) => Promise<BumperVideoSource>;
  /** Dispose every bumper source the run opened. Call in a `finally`. */
  dispose: () => void;
};

export async function prepareMotionExportRun(opts: {
  timeline: MotionTimeline;
  audioUrl: string | null;
  openBumperVideoFn: typeof openBumperVideo;
  /** The audio could not be loaded; the run continues silent. */
  onAudioDropped: () => void;
}): Promise<MotionExportRun> {
  const { timeline, audioUrl } = opts;
  // ← paste the dialog's `bumperVideoSources` map + `bumperVideoFor`
  //   (with their comments), using `opts.openBumperVideoFn`.
  const dispose = () => {
    for (const promise of bumperVideoSources.values()) {
      promise.then(
        (source) => source.dispose(),
        () => {}
      );
    }
  };
  let audioBuffer: AudioBuffer | null = null;
  try {
    // ← paste the dialog's audio block VERBATIM: from
    //   `const layout = bumperLayout(timeline);` through the end of the
    //   `if (audioClips.length > 0 || bumperSources.length > 0) { … }` block.
    //   In its catch, replace the `showToast("Exporting without audio", …)`
    //   call with `opts.onAudioDropped();` (keep the console.warn and the
    //   comments).
  } catch (err) {
    dispose();
    throw err;
  }
  return { audioBuffer, openBumperVideo: bumperVideoFor, dispose };
}

export function renderMotionTile(opts: {
  run: MotionExportRun;
  snapshot: KvMotionSnapshot;
  timeline: MotionTimeline;
  tile: KvMotionTile;
  signal: AbortSignal;
  onProgress: (frac: number) => void;
  onFinalizing: () => void;
  exportRatioFn: typeof exportMotionRatio;
}): Promise<Blob> {
  const { run, tile } = opts;
  // Carry over the dialog's comments on `tile`, `onFinalizing` and `deps`
  // from its old inline `exportRatioFn({...})` call.
  return opts.exportRatioFn({
    snapshot: opts.snapshot,
    timeline: opts.timeline,
    ratio: { id: tile.platform_id, w: tile.width, h: tile.height },
    tile: {
      baseImageUrl: tile.base_image_url,
      overlays: tile.overlays,
      source: tile.source,
    },
    audioBuffer: run.audioBuffer,
    signal: opts.signal,
    onProgress: opts.onProgress,
    onFinalizing: opts.onFinalizing,
    deps: {
      openBumperVideo: async (url) => {
        const source = await run.openBumperVideo(url);
        return { ...source, dispose: () => {} };
      },
    },
  });
}

/** Upload the MP4 and write its `kv_motion_exports` row. */
export async function recordMotionExport(opts: {
  studioFileId: string;
  projectId: string;
  tile: KvMotionTile;
  timeline: MotionTimeline;
  blob: Blob;
  sourceHash: string | null;
  uploadAssetFn: typeof uploadStudioOverlayAsset;
  createExportFn: typeof createMotionExport;
}): Promise<KvMotionExportRow> {
  const { tile } = opts;
  const file = new File([opts.blob], `motion-${tile.platform_id}.mp4`, {
    type: "video/mp4",
  });
  const uploaded = await opts.uploadAssetFn(opts.studioFileId, file);
  // ← move the dialog's `ratio: tile.key` comment here unchanged.
  return opts.createExportFn(opts.studioFileId, opts.projectId, {
    ratio: tile.key,
    url: uploaded.asset_url,
    width: tile.width,
    height: tile.height,
    durationMs: bumperLayout(opts.timeline).totalMs,
    sourceHash: opts.sourceHash,
  });
}
```

The `← paste` markers point at exact existing code in the dialog; they are moves, not new logic. Remove each moved block from the dialog.

- [ ] **Step 3: Rewire the dialog onto the runner**

In `KvMotionExportDialog.tsx`:

1. Delete `decodeAudioFile` and the now-unused imports; import `prepareMotionExportRun`, `renderMotionTile`, `recordMotionExport`, `type MotionExportRun` from `./motionExportRun`.
2. `uploadAndRecord(tile, blob)` → `uploadAndRecord(tile, blob, sourceHash: string | null)`. Replace its upload + `createExportFn` lines with:

```ts
        const row = await recordMotionExport({
          studioFileId,
          projectId,
          tile,
          timeline,
          blob,
          sourceHash,
          uploadAssetFn,
          createExportFn,
        });
```

   Keep its state patches, invalidation and analytics, and add `trigger: runTriggerRef.current` to the three `trackKvMotionExport*` calls in it.
3. In `handleExport`: drop the inline `bumperVideoSources`/`bumperVideoFor` and audio block. Inside `withImageRunCache`, replace them with:

```ts
        run = await prepareMotionExportRun({
          timeline,
          audioUrl,
          openBumperVideoFn,
          onAudioDropped: () =>
            showToast(
              "Exporting without audio",
              "The audio couldn't be loaded, so the video will have no sound.",
              "warning"
            ),
        });
```

   with `let run: MotionExportRun | null = null;` declared before the `try`, and `run?.dispose();` in the `finally` in place of the old bumper-dispose loop.
4. In the per-tile loop, before the render, compute the hash; replace the `exportRatioFn({...})` call with `renderMotionTile`:

```ts
          const sourceHash = await motionExportFingerprint(
            motionExportInputsFor({ snapshot, timeline, audioUrl, tile })
          );
          // …existing "rendering" patch…
          blob = await renderMotionTile({
            run,
            snapshot,
            timeline,
            tile,
            signal: controller.signal,
            onProgress: (frac) => patchTileState(tile.key, { progress: frac }),
            onFinalizing: () =>
              patchTileState(tile.key, { status: "finalizing", progress: 1 }),
            exportRatioFn,
          });
```

   and `await uploadAndRecord(tile, blob, sourceHash);` after it. Add `trigger: runTriggerRef.current` to the `trackKvMotionExportFailed` call in the loop.
5. `RatioState` gains `sourceHash?: string | null` (comment: "kept with the blob so Retry records the hash of what was RENDERED, not of what the design is now"). Store it in the `uploading` patch inside `uploadAndRecord`, and in `handleRetryUpload` call `uploadAndRecord(tile, blob, state.get(tile.key)?.sourceHash ?? null)`.
6. Add `const runTriggerRef = useRef<"dialog" | "update">("dialog");` (Task 7 sets it to `"update"`).

- [ ] **Step 4: Run the baseline tests**

Re-run the three commands from Step 1. Expected: same pass counts, zero new failures. If a bumper "opened once" test fails, the run's `openBumperVideo` is not being reused between the audio decode and the render — fix before continuing.

- [ ] **Step 5: Write the hash test**

Add to `KvMotionExportDialog.test.tsx` (inside the main `describe`):

```ts
  it("records the design fingerprint with each export", async () => {
    const { body, createExportFn } = renderDialog();
    fireEvent.click(within(body).getByRole("button", { name: /^Export/ }));
    await waitFor(() => expect(createExportFn.mock.calls.length).toBe(3));
    const hashes = createExportFn.mock.calls.map(
      (c) => (c[2] as { sourceHash?: string | null }).sourceHash
    );
    for (const h of hashes) expect(h).toMatch(/^[0-9a-f]{64}$/);
    // Three different sizes → three different fingerprints.
    expect(new Set(hashes).size).toBe(3);
  });
```

Match the Export button query to the one the file's existing "renders sequentially" test uses if `/^Export/` does not resolve uniquely. Widen the `createExportFn` mock's `body` type in `renderDialog` with `sourceHash?: string | null` and return `sourceHash: body.sourceHash ?? null` in its row.

- [ ] **Step 6: Run it**

Run: `cd web && bun test src/components/studio/kv-generator/motion/KvMotionExportDialog.test.tsx`
Expected: PASS. Temporarily pass `sourceHash: null` in `recordMotionExport`; confirm the new test FAILS; restore.

- [ ] **Step 7: Lint, tsc, commit**

```bash
cd web
bunx eslint src/components/studio/kv-generator/motion/motionExportRun.ts src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx src/components/studio/kv-generator/motion/KvMotionExportDialog.test.tsx
bunx tsc --noEmit -p . 2>&1 | grep -E "motionExportRun|KvMotionExportDialog\.tsx"
git add src/components/studio/kv-generator/motion/motionExportRun.ts src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx src/components/studio/kv-generator/motion/KvMotionExportDialog.test.tsx
git commit -m "refactor(web): share the Motion render pipeline; record source_hash

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: the tsc grep prints nothing.

---

### Task 5: Background render queue

**Files:**
- Create: `web/src/components/studio/kv-generator/motion/useBackgroundMotionExport.ts`
- Test: `web/src/components/studio/kv-generator/motion/useBackgroundMotionExport.test.tsx`

**Interfaces:**
- Consumes: Task 1 (`motionExportInputsFor`, `motionExportFingerprint`), Task 3 (`trackKvMotionExportStarted`, `trackKvMotionExportCompleted`, `trackKvMotionExportFailed`), Task 4 (`prepareMotionExportRun`, `renderMotionTile`, `recordMotionExport`), `resolveMotionTiles` (`./motionSnapshot`).
- Produces:
  - `type BackgroundMotionJob = { tileKey: string; then: "mark" | "none"; trigger: "mark" | "update" }`
  - `type BackgroundMotionJobState = { status: "queued" | "running"; progress: number }`
  - `useBackgroundMotionExport(opts): { jobs: ReadonlyMap<string, BackgroundMotionJobState>; enqueue: (job: BackgroundMotionJob) => void }` where `opts = { studioFileId: string; projectId: string; snapshot: KvMotionSnapshot; timeline: MotionTimeline; audioUrl: string | null; paused: boolean; onExported: (row: KvMotionExportRow, job: BackgroundMotionJob) => void; deps?: Partial<BackgroundMotionExportDeps> }`
  - `type BackgroundMotionExportDeps = { exportRatioFn: typeof exportMotionRatio; uploadAssetFn: typeof uploadStudioOverlayAsset; createExportFn: typeof createMotionExport; openBumperVideoFn: typeof openBumperVideo; canEncodeSizeFn: (w: number, h: number) => Promise<boolean> }`

- [ ] **Step 1: Write the failing tests**

`useBackgroundMotionExport.test.tsx`:

```tsx
import { beforeEach, describe, expect, it, mock } from "bun:test";
import { act, renderHook, waitFor } from "@testing-library/react";

import type { MotionTimeline } from "@/lib/video-editor/timeline";
import { useToastStore } from "@/store/useToast";
import type { KvMotionExportRow, KvMotionSnapshot, KvMotionTile } from "@/types/kv/motionProject";

import {
  useBackgroundMotionExport,
  type BackgroundMotionJob,
} from "./useBackgroundMotionExport";

const tile = (key: string, w = 1080, h = 1920): KvMotionTile => ({
  key,
  platform_id: "instagram-story",
  label: key,
  source: "resize",
  base_image_url: `https://cdn.example.com/${key}.png`,
  width: w,
  height: h,
  overlays: null,
  timeline: null,
});
const snapshotWith = (tiles: KvMotionTile[]): KvMotionSnapshot => ({
  base_image_url: "https://cdn.example.com/board.png",
  board_width: 1080,
  board_height: 1920,
  overlays: [],
  tiles,
});
const timeline: MotionTimeline = { version: 1, duration_ms: 1000, fps: 30, tracks: [] };

function deferred<T>() {
  let resolve!: (v: T) => void;
  let reject!: (e: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function setup(over: { tiles?: KvMotionTile[]; paused?: boolean; render?: () => Promise<Blob>; canEncode?: boolean } = {}) {
  const exportRatioFn = mock(
    over.render ?? (async () => new Blob(["mp4"], { type: "video/mp4" }))
  );
  const uploadAssetFn = mock(async () => ({
    asset_url: "https://cdn.example.com/m.mp4",
    mime_type: "video/mp4",
    file_size: 3,
    file_name: "m.mp4",
  }));
  const createExportFn = mock(
    async (_f: string, _p: string, body: { ratio: string; url: string; width: number; height: number; durationMs: number; sourceHash?: string | null }): Promise<KvMotionExportRow> => ({
      id: `exp-${body.ratio}`,
      ratio: body.ratio,
      url: body.url,
      width: body.width,
      height: body.height,
      durationMs: body.durationMs,
      createdAt: "2026-10-15T00:00:00Z",
      sourceHash: body.sourceHash ?? null,
    })
  );
  const onExported = mock((_row: KvMotionExportRow, _job: BackgroundMotionJob) => {});
  const props = {
    studioFileId: "f1",
    projectId: "p1",
    snapshot: snapshotWith(over.tiles ?? [tile("a"), tile("b")]),
    timeline,
    audioUrl: null as string | null,
    paused: over.paused ?? false,
    onExported,
    deps: {
      exportRatioFn: exportRatioFn as never,
      uploadAssetFn: uploadAssetFn as never,
      createExportFn: createExportFn as never,
      openBumperVideoFn: mock(async () => { throw new Error("no bumpers"); }) as never,
      canEncodeSizeFn: async () => over.canEncode ?? true,
    },
  };
  const hook = renderHook((p: typeof props) => useBackgroundMotionExport(p), { initialProps: props });
  return { hook, props, exportRatioFn, createExportFn, onExported };
}

const markA: BackgroundMotionJob = { tileKey: "a", then: "mark", trigger: "mark" };
const markB: BackgroundMotionJob = { tileKey: "b", then: "mark", trigger: "mark" };

describe("useBackgroundMotionExport", () => {
  it("renders, records the fingerprint, hands back the row, and clears the job", async () => {
    const { hook, createExportFn, onExported } = setup();
    act(() => hook.result.current.enqueue(markA));
    await waitFor(() => expect(onExported.mock.calls.length).toBe(1));
    const body = createExportFn.mock.calls[0][2];
    expect(body.ratio).toBe("a");
    expect(body.sourceHash).toMatch(/^[0-9a-f]{64}$/);
    expect(onExported.mock.calls[0][1]).toEqual(markA);
    await waitFor(() => expect(hook.result.current.jobs.size).toBe(0));
  });

  it("runs one render at a time, first in first out", async () => {
    const first = deferred<Blob>();
    let calls = 0;
    const { hook, exportRatioFn, createExportFn } = setup({
      render: () => (++calls === 1 ? first.promise : Promise.resolve(new Blob(["x"]))),
    });
    act(() => {
      hook.result.current.enqueue(markA);
      hook.result.current.enqueue(markB);
    });
    await waitFor(() => expect(exportRatioFn.mock.calls.length).toBe(1));
    expect(hook.result.current.jobs.get("a")?.status).toBe("running");
    expect(hook.result.current.jobs.get("b")?.status).toBe("queued");
    first.resolve(new Blob(["x"]));
    await waitFor(() => expect(createExportFn.mock.calls.length).toBe(2));
    expect(createExportFn.mock.calls.map((c) => c[2].ratio)).toEqual(["a", "b"]);
  });

  it("ignores a size that is already queued or running", async () => {
    const first = deferred<Blob>();
    const { hook, exportRatioFn } = setup({ render: () => first.promise });
    act(() => {
      hook.result.current.enqueue(markA);
      hook.result.current.enqueue(markA);
    });
    first.resolve(new Blob(["x"]));
    await waitFor(() => expect(hook.result.current.jobs.size).toBe(0));
    expect(exportRatioFn.mock.calls.length).toBe(1);
  });

  it("holds the queue while paused (the Export dialog is rendering)", async () => {
    const { hook, props, exportRatioFn } = setup({ paused: true });
    act(() => hook.result.current.enqueue(markA));
    await new Promise((r) => setTimeout(r, 20));
    expect(exportRatioFn.mock.calls.length).toBe(0);
    expect(hook.result.current.jobs.get("a")?.status).toBe("queued");
    hook.rerender({ ...props, paused: false });
    await waitFor(() => expect(exportRatioFn.mock.calls.length).toBe(1));
  });

  it("a failed render toasts, records nothing, and frees the queue", async () => {
    const { hook, createExportFn, onExported } = setup({
      render: async () => { throw new Error("Encoder exploded"); },
    });
    act(() => hook.result.current.enqueue(markA));
    await waitFor(() => expect(hook.result.current.jobs.size).toBe(0));
    expect(createExportFn.mock.calls.length).toBe(0);
    expect(onExported.mock.calls.length).toBe(0);
    expect(JSON.stringify(useToastStore.getState())).toContain("Encoder exploded");
  });

  it("a size removed from the project fails gracefully", async () => {
    const { hook, exportRatioFn } = setup();
    act(() => hook.result.current.enqueue({ tileKey: "gone", then: "mark", trigger: "mark" }));
    await waitFor(() => expect(hook.result.current.jobs.size).toBe(0));
    expect(exportRatioFn.mock.calls.length).toBe(0);
    expect(JSON.stringify(useToastStore.getState())).toContain("no longer");
  });

  it("refuses a size this browser cannot encode", async () => {
    const { hook, exportRatioFn } = setup({ tiles: [tile("a", 4096, 4096)], canEncode: false });
    act(() => hook.result.current.enqueue(markA));
    await waitFor(() => expect(hook.result.current.jobs.size).toBe(0));
    expect(exportRatioFn.mock.calls.length).toBe(0);
    expect(JSON.stringify(useToastStore.getState())).toContain("4096");
  });

  it("aborts the render and records nothing when the editor closes", async () => {
    let seen: AbortSignal | undefined;
    const never = deferred<Blob>();
    const { hook, exportRatioFn, createExportFn } = setup({
      render: (async (...args: unknown[]) => {
        seen = (args[0] as { signal: AbortSignal }).signal;
        return never.promise;
      }) as never,
    });
    act(() => hook.result.current.enqueue(markA));
    await waitFor(() => expect(exportRatioFn.mock.calls.length).toBe(1));
    hook.unmount();
    expect(seen?.aborted).toBe(true);
    never.resolve(new Blob(["late"]));
    await new Promise((r) => setTimeout(r, 20));
    expect(createExportFn.mock.calls.length).toBe(0);
  });
});
```

The store keeps visible toasts in `useToastStore.getState().toasts` (stacked, capped). Add `beforeEach(() => useToastStore.setState({ toasts: [] }))` so one test's toast cannot satisfy another's assertion.

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/useBackgroundMotionExport.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

`useBackgroundMotionExport.ts`:

```ts
"use client";

/**
 * Background Motion renders for "Mark ready to share" and "Update" (spec
 * 2026-10-15 §4.3). FIFO, ONE render at a time — WebCodecs allows one active
 * encoder in practice and each render saturates the machine. `paused` holds
 * the queue while the Export dialog runs its own render, so the two never
 * overlap. Reads the design at the moment a job STARTS (not when it was
 * queued), so the MP4 is the newest cut.
 */
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";

import { withImageRunCache } from "@/components/studio/kv-generator/imageLoader";
import {
  trackKvMotionExportCompleted,
  trackKvMotionExportFailed,
  trackKvMotionExportStarted,
} from "@/lib/analytics/kv-generator-events";
import { bumperLayout } from "@/lib/video-editor/bumpers";
import { canEncodeAvcAt } from "@/lib/video-editor/encode";
import { pauseInfiniteAnimations } from "@/lib/video-editor/pauseInfiniteAnimations";
import type { MotionTimeline } from "@/lib/video-editor/timeline";
import { MAX_VIDEO_EDGE } from "@/lib/video-editor/videoSafeDims";
import { motionUploadErrorMessage } from "@/lib/studio/kv/motionExportError";
import { uploadStudioOverlayAsset } from "@/services/kv/api";
import { createMotionExport } from "@/services/kv/motionProjects";
import { useToastStore } from "@/store/useToast";
import type { KvMotionExportRow, KvMotionSnapshot } from "@/types/kv/motionProject";

import { openBumperVideo } from "./bumperVideoSource";
import { exportMotionRatio, MotionAssetError } from "./exportMotion";
import { motionExportFingerprint, motionExportInputsFor } from "./motionExportFingerprint";
import {
  prepareMotionExportRun,
  recordMotionExport,
  renderMotionTile,
  type MotionExportRun,
} from "./motionExportRun";
import { resolveMotionTiles } from "./motionSnapshot";

export type BackgroundMotionJob = {
  tileKey: string;
  /** "mark": mark the new export once recorded. "none": Update — the mark
   *  already follows the newest export of the size. */
  then: "mark" | "none";
  trigger: "mark" | "update";
};

export type BackgroundMotionJobState = {
  status: "queued" | "running";
  progress: number;
};

export type BackgroundMotionExportDeps = {
  exportRatioFn: typeof exportMotionRatio;
  uploadAssetFn: typeof uploadStudioOverlayAsset;
  createExportFn: typeof createMotionExport;
  openBumperVideoFn: typeof openBumperVideo;
  canEncodeSizeFn: (w: number, h: number) => Promise<boolean>;
};

const DEFAULT_DEPS: BackgroundMotionExportDeps = {
  exportRatioFn: exportMotionRatio,
  uploadAssetFn: uploadStudioOverlayAsset,
  createExportFn: createMotionExport,
  openBumperVideoFn: openBumperVideo,
  canEncodeSizeFn: canEncodeAvcAt,
};

export function useBackgroundMotionExport(opts: {
  studioFileId: string;
  projectId: string;
  snapshot: KvMotionSnapshot;
  timeline: MotionTimeline;
  audioUrl: string | null;
  paused: boolean;
  onExported: (row: KvMotionExportRow, job: BackgroundMotionJob) => void;
  deps?: Partial<BackgroundMotionExportDeps>;
}) {
  const showToast = useToastStore((s) => s.showToast);
  const [jobs, setJobs] = useState<ReadonlyMap<string, BackgroundMotionJobState>>(
    () => new Map()
  );

  // Latest props, read when a job starts rather than when it was queued.
  const latest = useRef(opts);
  useLayoutEffect(() => {
    latest.current = opts;
  });

  const queue = useRef<BackgroundMotionJob[]>([]);
  // Keys queued or running, kept outside React state so two enqueues in one
  // tick cannot both slip past the duplicate check. Cleared by `pump` when a
  // job finishes — never re-derived from `jobs`, which lags a tick behind.
  const jobsRef = useRef(new Set<string>());
  const running = useRef(false);
  const mounted = useRef(true);
  const abort = useRef<AbortController | null>(null);

  const patch = useCallback((key: string, next: BackgroundMotionJobState | null) => {
    if (!mounted.current) return;
    setJobs((prev) => {
      const map = new Map(prev);
      if (next) map.set(key, next);
      else map.delete(key);
      return map;
    });
  }, []);

  const runJob = useCallback(
    async (job: BackgroundMotionJob) => {
      const o = latest.current;
      const deps = { ...DEFAULT_DEPS, ...o.deps };
      const tile = resolveMotionTiles(o.snapshot).find((t) => t.key === job.tileKey);
      if (!tile) {
        showToast("Couldn't prepare this size", "It's no longer part of this motion.", "error");
        return;
      }
      if (
        Math.max(tile.width, tile.height) > MAX_VIDEO_EDGE &&
        !(await deps.canEncodeSizeFn(tile.width, tile.height))
      ) {
        showToast(
          "Couldn't prepare this size",
          `This browser can't encode a ${tile.width} × ${tile.height} video. Try Chrome on a desktop.`,
          "error"
        );
        return;
      }

      const controller = new AbortController();
      abort.current = controller;
      patch(tile.key, { status: "running", progress: 0 });
      trackKvMotionExportStarted({ project_id: o.projectId, ratio: tile.key, trigger: job.trigger });
      const resumeAnimations = pauseInfiniteAnimations(() =>
        typeof document !== "undefined" && document.getAnimations
          ? document.getAnimations()
          : undefined
      );
      let run: MotionExportRun | null = null;
      let stage: "preload" | "render" | "upload" = "render";
      let blobSize = 0;
      try {
        const sourceHash = await motionExportFingerprint(
          motionExportInputsFor({ snapshot: o.snapshot, timeline: o.timeline, audioUrl: o.audioUrl, tile })
        );
        const row = await withImageRunCache(async () => {
          run = await prepareMotionExportRun({
            timeline: o.timeline,
            audioUrl: o.audioUrl,
            openBumperVideoFn: deps.openBumperVideoFn,
            onAudioDropped: () =>
              showToast(
                "Preparing without audio",
                "The audio couldn't be loaded, so the shared video will have no sound.",
                "warning"
              ),
          });
          const blob = await renderMotionTile({
            run,
            snapshot: o.snapshot,
            timeline: o.timeline,
            tile,
            signal: controller.signal,
            onProgress: (frac) => patch(tile.key, { status: "running", progress: frac }),
            onFinalizing: () => patch(tile.key, { status: "running", progress: 1 }),
            exportRatioFn: deps.exportRatioFn,
          });
          // A render can resolve its last frame in the same tick the editor
          // closes; never upload after an abort.
          if (controller.signal.aborted) return null;
          stage = "upload";
          blobSize = blob.size;
          return recordMotionExport({
            studioFileId: o.studioFileId,
            projectId: o.projectId,
            tile,
            timeline: o.timeline,
            blob,
            sourceHash,
            uploadAssetFn: deps.uploadAssetFn,
            createExportFn: deps.createExportFn,
          });
        });
        if (!row || controller.signal.aborted) return;
        const kinds = (["start", "end"] as const)
          .map((s) => o.timeline.bumpers?.[s]?.kind)
          .filter((k): k is "image" | "video" => k !== undefined);
        trackKvMotionExportCompleted({
          project_id: o.projectId,
          ratio: tile.key,
          width: tile.width,
          height: tile.height,
          duration_ms: bumperLayout(o.timeline).totalMs,
          upload_status: "uploaded",
          has_bumpers: kinds.length > 0,
          bumper_kinds: kinds,
          trigger: job.trigger,
        });
        latest.current.onExported(row, job);
      } catch (err) {
        if (controller.signal.aborted) return;
        if (err instanceof MotionAssetError) stage = "preload";
        const message =
          stage === "upload"
            ? motionUploadErrorMessage(err, blobSize)
            : err instanceof Error
              ? err.message
              : "Render failed.";
        trackKvMotionExportFailed({
          project_id: o.projectId,
          ratio: tile.key,
          stage,
          error_reason: message,
          trigger: job.trigger,
        });
        showToast("Couldn't prepare this size for sharing", message, "error");
      } finally {
        (run as MotionExportRun | null)?.dispose();
        resumeAnimations();
        abort.current = null;
      }
    },
    [patch, showToast]
  );

  const pump = useCallback(async () => {
    if (running.current || latest.current.paused || !mounted.current) return;
    const job = queue.current.shift();
    if (!job) return;
    running.current = true;
    try {
      await runJob(job);
    } finally {
      jobsRef.current.delete(job.tileKey);
      patch(job.tileKey, null);
      running.current = false;
      void pump();
    }
  }, [patch, runJob]);

  const enqueue = useCallback(
    (job: BackgroundMotionJob) => {
      if (jobsRef.current.has(job.tileKey)) return;
      jobsRef.current.add(job.tileKey);
      queue.current.push(job);
      patch(job.tileKey, { status: "queued", progress: 0 });
      void pump();
    },
    [patch, pump]
  );

  // Released when the dialog's own render ends.
  useEffect(() => {
    if (!opts.paused) void pump();
  }, [opts.paused, pump]);

  // A render in progress lives only in this tab.
  useEffect(() => {
    if (jobs.size === 0) return;
    const handler = (e: BeforeUnloadEvent) => {
      e.preventDefault();
      e.returnValue = "";
    };
    window.addEventListener("beforeunload", handler);
    return () => window.removeEventListener("beforeunload", handler);
  }, [jobs.size]);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      queue.current = [];
      abort.current?.abort();
    };
  }, []);

  return { jobs, enqueue };
}
```

Note: `pauseInfiniteAnimations` pauses only INFINITE animations (spinners, pulses), which is what we want while the user keeps editing — Konva playback is unaffected.

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/motion/useBackgroundMotionExport.test.tsx`
Expected: all PASS. Then mutation-check two of them: remove the `if (jobsRef.current.has(…)) return;` line → "ignores a size that is already queued" must FAIL; remove `abort.current?.abort();` from the unmount cleanup → "aborts the render" must FAIL. Restore both.

- [ ] **Step 5: Lint, tsc, commit**

```bash
cd web
bunx eslint src/components/studio/kv-generator/motion/useBackgroundMotionExport.ts src/components/studio/kv-generator/motion/useBackgroundMotionExport.test.tsx
bunx tsc --noEmit -p . 2>&1 | grep useBackgroundMotionExport
git add src/components/studio/kv-generator/motion/useBackgroundMotionExport.ts src/components/studio/kv-generator/motion/useBackgroundMotionExport.test.tsx
git commit -m "feat(web): background render queue for Motion share

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Chip view model, display hashes, chip component

**Files:**
- Create: `web/src/components/studio/kv-generator/motion/motionShareChip.ts`
- Create: `web/src/components/studio/kv-generator/motion/useMotionTileFingerprints.ts`
- Create: `web/src/components/studio/kv-generator/motion/MotionShareChipButton.tsx`
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionTileStage.tsx` (prop type + render the new button)
- Test: `web/src/components/studio/kv-generator/motion/motionShareChip.test.ts`
- Test: `web/src/components/studio/kv-generator/motion/MotionShareChipButton.test.tsx`

**Interfaces:**
- Consumes: Task 1 (`isExportOutdated`, `motionExportFingerprint`, `motionExportInputsFor`), Task 5 (`BackgroundMotionJobState`), `isRatioReady` (`./KvMotionProjectExports`).
- Produces:
  - `motionShareChip(i: { isReady: boolean; latestExport: { sourceHash: string | null } | null; currentHash: string | null; job: BackgroundMotionJobState | null }): MotionShareChipView`
  - `type MotionShareChipView = { isReady: boolean; busyLabel: string | null; outdated: boolean; click: "unmark" | "mark" | "none" }`
  - `markIdAfterExport(chainIds: string[], readyIds: string[], newId: string): string | null`
  - `useMotionTileFingerprints(opts: { snapshot: KvMotionSnapshot; timeline: MotionTimeline; audioUrl: string | null; tiles: KvMotionTile[]; delayMs?: number }): ReadonlyMap<string, string>`
  - `MotionShareChipButton` props: `{ isReady: boolean; busyLabel?: string | null; outdated?: boolean; onClick: () => void; onUpdate?: () => void }`
  - `KvMotionTileStage` prop: `readyToShare?: { isReady: boolean; onClick: () => void; busyLabel?: string | null; outdated?: boolean; onUpdate?: () => void } | null`

- [ ] **Step 1: Write the failing view-model test**

`motionShareChip.test.ts`:

```ts
import { describe, expect, it } from "bun:test";

import { markIdAfterExport, motionShareChip } from "./motionShareChip";

const H = "a".repeat(64);
const H2 = "b".repeat(64);

describe("motionShareChip (spec §3.1)", () => {
  it("unmarked, no export → Mark", () => {
    expect(motionShareChip({ isReady: false, latestExport: null, currentHash: H, job: null }))
      .toEqual({ isReady: false, busyLabel: null, outdated: false, click: "mark" });
  });

  it("unmarked with an export → Mark (the click decides render vs mark)", () => {
    expect(motionShareChip({ isReady: false, latestExport: { sourceHash: H2 }, currentHash: H, job: null }).click)
      .toBe("mark");
  });

  it("queued → Queued, no action", () => {
    expect(motionShareChip({ isReady: false, latestExport: null, currentHash: H, job: { status: "queued", progress: 0 } }))
      .toEqual({ isReady: false, busyLabel: "Queued", outdated: false, click: "none" });
  });

  it("running → Preparing… NN%, no action", () => {
    expect(motionShareChip({ isReady: true, latestExport: { sourceHash: H2 }, currentHash: H, job: { status: "running", progress: 0.424 } }))
      .toEqual({ isReady: true, busyLabel: "Preparing… 42%", outdated: false, click: "none" });
  });

  it("marked and current → Ready, click unmarks", () => {
    expect(motionShareChip({ isReady: true, latestExport: { sourceHash: H }, currentHash: H, job: null }))
      .toEqual({ isReady: true, busyLabel: null, outdated: false, click: "unmark" });
  });

  it("marked and design moved on → Outdated", () => {
    expect(motionShareChip({ isReady: true, latestExport: { sourceHash: H2 }, currentHash: H, job: null }).outdated)
      .toBe(true);
  });

  it("marked legacy export (no hash) → never Outdated", () => {
    expect(motionShareChip({ isReady: true, latestExport: { sourceHash: null }, currentHash: H, job: null }).outdated)
      .toBe(false);
  });
});

describe("markIdAfterExport", () => {
  it("marks the new export when the size is still unmarked", () => {
    expect(markIdAfterExport(["e1"], [], "e2")).toBe("e2");
  });

  it("does nothing when the size got marked meanwhile — the mark follows the newest export", () => {
    expect(markIdAfterExport(["e1"], ["e1"], "e2")).toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/motionShareChip.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `motionShareChip.ts`**

```ts
/**
 * What a Motion size's share chip shows and does (spec 2026-10-15 §3.1).
 * Pure, and the single source for the tile chip — the Export dialog's rows use
 * `isExportOutdated` directly, so "Outdated" means the same thing in both.
 */
import { isRatioReady } from "./KvMotionProjectExports";
import { isExportOutdated } from "./motionExportFingerprint";
import type { BackgroundMotionJobState } from "./useBackgroundMotionExport";

export type MotionShareChipView = {
  isReady: boolean;
  /** "Queued" / "Preparing… NN%" while a background render owns the size. */
  busyLabel: string | null;
  outdated: boolean;
  /** "mark" is resolved at click time (render vs mark-existing) — see
   *  `resolveMarkAction`; the display hash may be a debounce behind. */
  click: "unmark" | "mark" | "none";
};

export function motionShareChip(i: {
  isReady: boolean;
  latestExport: { sourceHash: string | null } | null;
  currentHash: string | null;
  job: BackgroundMotionJobState | null;
}): MotionShareChipView {
  if (i.job) {
    return {
      isReady: i.isReady,
      busyLabel:
        i.job.status === "queued"
          ? "Queued"
          : `Preparing… ${Math.round(i.job.progress * 100)}%`,
      outdated: false,
      click: "none",
    };
  }
  if (i.isReady) {
    return {
      isReady: true,
      busyLabel: null,
      outdated: isExportOutdated(i.latestExport, i.currentHash),
      click: "unmark",
    };
  }
  return { isReady: false, busyLabel: null, outdated: false, click: "mark" };
}

/** After a background render for "Mark": the id to mark, or null when the
 *  size was marked meanwhile (toggling then would UNMARK it — and the
 *  existing mark already follows the newest export). */
export function markIdAfterExport(
  chainIds: string[],
  readyIds: string[],
  newId: string
): string | null {
  return isRatioReady(chainIds, readyIds) ? null : newId;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/motion/motionShareChip.test.ts`
Expected: PASS.

- [ ] **Step 5: Implement `useMotionTileFingerprints.ts`**

```ts
"use client";

import { useEffect, useState } from "react";

import type { MotionTimeline } from "@/lib/video-editor/timeline";
import type { KvMotionSnapshot, KvMotionTile } from "@/types/kv/motionProject";

import { motionExportFingerprint, motionExportInputsFor } from "./motionExportFingerprint";

/**
 * Each tile's CURRENT fingerprint, for the "Outdated" badge only. Debounced:
 * the editor re-renders ~60/s during playback and hashing every frame is
 * waste. Decisions that must be exact (Mark) hash at click time instead.
 */
export function useMotionTileFingerprints(opts: {
  snapshot: KvMotionSnapshot;
  timeline: MotionTimeline;
  audioUrl: string | null;
  tiles: KvMotionTile[];
  delayMs?: number;
}): ReadonlyMap<string, string> {
  const { snapshot, timeline, audioUrl, tiles, delayMs = 500 } = opts;
  const [hashes, setHashes] = useState<ReadonlyMap<string, string>>(() => new Map());
  useEffect(() => {
    let cancelled = false;
    const handle = setTimeout(() => {
      void Promise.all(
        tiles.map(
          async (tile) =>
            [
              tile.key,
              await motionExportFingerprint(
                motionExportInputsFor({ snapshot, timeline, audioUrl, tile })
              ),
            ] as const
        )
      ).then((entries) => {
        if (!cancelled) setHashes(new Map(entries));
      });
    }, delayMs);
    return () => {
      cancelled = true;
      clearTimeout(handle);
    };
  }, [snapshot, timeline, audioUrl, tiles, delayMs]);
  return hashes;
}
```

- [ ] **Step 6: Write the failing button test**

`MotionShareChipButton.test.tsx`:

```tsx
import { describe, expect, it, mock } from "bun:test";
import { fireEvent, render, within } from "@testing-library/react";

import { MotionShareChipButton } from "./MotionShareChipButton";

const body = () => within(document.body);

describe("MotionShareChipButton", () => {
  it("unmarked reads Mark ready to share", () => {
    const onClick = mock(() => {});
    render(<MotionShareChipButton isReady={false} onClick={onClick} />);
    fireEvent.click(body().getByRole("button", { name: "Mark ready to share" }));
    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it("busy shows the label and cannot be clicked", () => {
    const onClick = mock(() => {});
    render(<MotionShareChipButton isReady={false} busyLabel="Preparing… 42%" onClick={onClick} />);
    const chip = body().getByRole("button", { name: "Preparing… 42%" });
    expect(chip.hasAttribute("disabled")).toBe(true);
    fireEvent.click(chip);
    expect(onClick).not.toHaveBeenCalled();
  });

  it("marked + outdated shows Outdated and an Update action", () => {
    const onUpdate = mock(() => {});
    render(<MotionShareChipButton isReady outdated onClick={() => {}} onUpdate={onUpdate} />);
    expect(body().getByText("Outdated")).toBeTruthy();
    fireEvent.click(body().getByRole("button", { name: "Update" }));
    expect(onUpdate).toHaveBeenCalledTimes(1);
  });

  it("marked + current has no Update", () => {
    render(<MotionShareChipButton isReady onClick={() => {}} onUpdate={() => {}} />);
    expect(body().queryByRole("button", { name: "Update" })).toBeNull();
  });

  it("never draws an animated element while busy", () => {
    const { container } = render(
      <MotionShareChipButton isReady={false} busyLabel="Queued" onClick={() => {}} />
    );
    expect(container.innerHTML).not.toMatch(/animate-/);
  });
});
```

- [ ] **Step 7: Run to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/MotionShareChipButton.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 8: Implement `MotionShareChipButton.tsx` and use it in the tile stage**

Move the existing chip `<button>` from `KvMotionTileStage.tsx` (the `{readyToShare && (<button …>)}` block, with its comments and class recipes) into the new component, then extend it:

```tsx
"use client";

import { Bookmark, Check, HourglassMedium } from "@phosphor-icons/react";

import { cn } from "@/lib/utils";

/**
 * A Motion size's share chip (spec 2026-10-15 §3.1). Moved out of
 * KvMotionTileStage so it can be tested without a Konva stage.
 *
 * No spinner while busy, on purpose: an infinite animation on the page
 * starves the encoder doing the very render the chip reports on.
 */
export function MotionShareChipButton({
  isReady,
  busyLabel = null,
  outdated = false,
  onClick,
  onUpdate,
}: {
  isReady: boolean;
  busyLabel?: string | null;
  outdated?: boolean;
  onClick: () => void;
  onUpdate?: () => void;
}) {
  const busy = busyLabel !== null;
  return (
    <span className="pointer-events-auto flex items-center gap-1">
      <button
        type="button"
        disabled={busy}
        data-motion-ready={isReady || undefined}
        aria-pressed={isReady ? "true" : "false"}
        onClick={(e) => {
          // ← keep the moved stopPropagation comment
          e.stopPropagation();
          onClick();
        }}
        className={cn(
          "pointer-events-auto flex items-center gap-1 rounded-full border px-1.5 py-0.5 font-geist text-textXsMedium font-medium transition-colors disabled:cursor-default disabled:opacity-80",
          isReady
            ? // ← keep the moved "Exactly Resize's own Ready to share chip" comment
              "border-white/15 bg-[rgba(26,26,26,0.85)] text-text-inverse hover:bg-[rgba(26,26,26,0.95)]"
            : // ← keep the moved "Deliberately the opposite treatment" comment
              "border-white/20 bg-transparent text-text-inverse-subtlest hover:bg-white/5 hover:text-text-inverse-subtle"
        )}
      >
        {busy ? (
          <HourglassMedium size={12} />
        ) : isReady ? (
          <Check size={12} weight="bold" />
        ) : (
          <Bookmark size={12} />
        )}
        {busy ? busyLabel : isReady ? "Ready to share" : "Mark ready to share"}
      </button>
      {isReady && outdated && !busy && (
        <>
          <span className="rounded-full border border-amber-300/25 bg-amber-300/10 px-1.5 py-0.5 font-geist text-textXsMedium text-amber-200">
            Outdated
          </span>
          {onUpdate && (
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation();
                onUpdate();
              }}
              className="rounded-full border border-white/20 px-1.5 py-0.5 font-geist text-textXsMedium text-text-inverse transition-colors hover:bg-white/10"
            >
              Update
            </button>
          )}
        </>
      )}
    </span>
  );
}
```

The class strings above are the ones currently in `KvMotionTileStage.tsx`; if they changed on `develop` since this plan was written, use the file's current strings. `cn` is `@/lib/utils` and `HourglassMedium` exists in `@phosphor-icons/react` (both verified 2026-10-15).

In `KvMotionTileStage.tsx`: widen the `readyToShare` prop type to the Interfaces shape (update its doc comment: "busyLabel/outdated/onUpdate — spec 2026-10-15") and render:

```tsx
        {readyToShare && (
          <MotionShareChipButton
            isReady={readyToShare.isReady}
            busyLabel={readyToShare.busyLabel ?? null}
            outdated={readyToShare.outdated ?? false}
            onClick={readyToShare.onClick}
            onUpdate={readyToShare.onUpdate}
          />
        )}
```

- [ ] **Step 9: Run the tests**

```bash
cd web
bun test src/components/studio/kv-generator/motion/MotionShareChipButton.test.tsx
bun test src/components/studio/kv-generator/motion/motionShareChip.test.ts
bun test src/components/studio/kv-generator/motion/KvMotionTileStage.test.ts
```

Expected: all PASS.

- [ ] **Step 10: Lint, tsc, commit**

```bash
cd web
bunx eslint src/components/studio/kv-generator/motion/motionShareChip.ts src/components/studio/kv-generator/motion/useMotionTileFingerprints.ts src/components/studio/kv-generator/motion/MotionShareChipButton.tsx src/components/studio/kv-generator/motion/KvMotionTileStage.tsx src/components/studio/kv-generator/motion/motionShareChip.test.ts src/components/studio/kv-generator/motion/MotionShareChipButton.test.tsx
bunx tsc --noEmit -p . 2>&1 | grep -E "motionShareChip|useMotionTileFingerprints|MotionShareChipButton"
git add src/components/studio/kv-generator/motion/motionShareChip.ts src/components/studio/kv-generator/motion/useMotionTileFingerprints.ts src/components/studio/kv-generator/motion/MotionShareChipButton.tsx src/components/studio/kv-generator/motion/KvMotionTileStage.tsx src/components/studio/kv-generator/motion/motionShareChip.test.ts src/components/studio/kv-generator/motion/MotionShareChipButton.test.tsx
git commit -m "feat(web): Motion share chip — Preparing, Outdated, Update

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Export dialog — Outdated + Update, and never two renders at once

(The "Exported files" popover was folded into this dialog on 2026-09-22, so the dialog's stored-export rows ARE the popover surface the spec names in §3.2.)

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx`
- Test: `web/src/components/studio/kv-generator/motion/KvMotionExportDialog.test.tsx`

**Interfaces:**
- Consumes: Task 1 `isExportOutdated`; Task 3 `trackKvMotionShareUpdateClicked`; Task 4 `runTriggerRef`.
- Produces: new optional dialog props `currentHashes?: ReadonlyMap<string, string>`, `backgroundBusy?: boolean`, `onExportingChange?: (exporting: boolean) => void`.

- [ ] **Step 1: Write the failing tests**

Add to `KvMotionExportDialog.test.tsx`. Reuse the file's existing setup for "a size that already has a file, on open" (a `listExportsFn` returning a stored row) and for `readyIds`:

```tsx
  it("shows Outdated + Update on a shared size whose design changed", async () => {
    const stored: KvMotionExportRow = {
      id: "exp-tile-9", ratio: "tile-9", url: "https://cdn.example.com/m.mp4",
      width: 1080, height: 1920, durationMs: 2000,
      createdAt: "2026-01-01T00:00:00Z", sourceHash: "a".repeat(64),
    };
    const { body } = renderDialog({
      listExportsFn: mock(async () => [stored]),
      readyIds: ["exp-tile-9"],
      onToggleReady: mock(() => {}),
      currentHashes: new Map([["tile-9", "b".repeat(64)]]),
    });
    await waitFor(() => expect(within(body).getByText("Outdated")).toBeTruthy());
    expect(within(body).getByRole("button", { name: "Update" })).toBeTruthy();
  });

  it("Update re-renders only that size", async () => {
    const stored: KvMotionExportRow = {
      id: "exp-tile-9", ratio: "tile-9", url: "https://cdn.example.com/m.mp4",
      width: 1080, height: 1920, durationMs: 2000,
      createdAt: "2026-01-01T00:00:00Z", sourceHash: "a".repeat(64),
    };
    const { body, exportRatioFn } = renderDialog({
      listExportsFn: mock(async () => [stored]),
      readyIds: ["exp-tile-9"],
      onToggleReady: mock(() => {}),
      currentHashes: new Map([["tile-9", "b".repeat(64)]]),
    });
    fireEvent.click(await within(body).findByRole("button", { name: "Update" }));
    await waitFor(() => expect(exportRatioFn.mock.calls.length).toBe(1));
    expect(exportRatioFn.mock.calls[0][0].ratio).toMatchObject({ w: 1080, h: 1920 });
  });

  it("no Outdated for an export made before fingerprints, or a size not shared", async () => {
    const legacy: KvMotionExportRow = {
      id: "exp-tile-9", ratio: "tile-9", url: "https://cdn.example.com/m.mp4",
      width: 1080, height: 1920, durationMs: 2000,
      createdAt: "2026-01-01T00:00:00Z", sourceHash: null,
    };
    const { body } = renderDialog({
      listExportsFn: mock(async () => [legacy]),
      readyIds: ["exp-tile-9"],
      onToggleReady: mock(() => {}),
      currentHashes: new Map([["tile-9", "b".repeat(64)]]),
    });
    await waitFor(() => expect(within(body).getByText(/ago|just now/)).toBeTruthy());
    expect(within(body).queryByText("Outdated")).toBeNull();
  });

  it("will not start while a background render is running", () => {
    const { body } = renderDialog({ backgroundBusy: true });
    const exportButton = within(body).getByRole("button", { name: /^Export/ });
    expect(exportButton.hasAttribute("disabled") || exportButton.getAttribute("aria-disabled") === "true").toBe(true);
    expect(within(body).getByText(/preparing a size for sharing/i)).toBeTruthy();
  });

  it("reports its own run so the background queue can wait", async () => {
    const onExportingChange = mock((_b: boolean) => {});
    const { body } = renderDialog({ onExportingChange });
    fireEvent.click(within(body).getByRole("button", { name: /^Export/ }));
    await waitFor(() => expect(onExportingChange.mock.calls.map((c) => c[0])).toEqual([true, false]));
  });
```

Use whatever Export-button query the existing tests use if `/^Export/` is ambiguous.

- [ ] **Step 2: Run to verify they fail**

Run: `cd web && bun test src/components/studio/kv-generator/motion/KvMotionExportDialog.test.tsx`
Expected: the five new tests FAIL; all older ones PASS.

- [ ] **Step 3: Implement**

1. Props: add `currentHashes`, `backgroundBusy`, `onExportingChange` (doc each in one line; reference spec 2026-10-15).
2. `useEffect(() => { onExportingChange?.(exporting); }, [exporting, onExportingChange]);` — skip the initial `false` by tracking the previous value in a ref so the callback fires only on changes (`[true, false]` in the test).
3. `ExportRowHistory` gains `outdated?: boolean` and `onUpdate?: () => void`. When `ready && outdated`, render before the age stamp:

```tsx
      {outdated && (
        <span className="shrink-0 rounded-full border border-amber-300/25 bg-amber-300/10 px-1.5 py-0.5 font-geist text-[10px] font-medium uppercase tracking-wide text-amber-200">
          Outdated
        </span>
      )}
```

   and after the ready toggle:

```tsx
      {outdated && onUpdate && (
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            onUpdate();
          }}
          className="shrink-0 rounded-md px-2 py-1 font-geist text-textXsMedium text-text-inverse transition-colors hover:bg-white/[0.08]"
        >
          Update
        </button>
      )}
```

4. Where the dialog renders `ExportRowHistory` for a tile, compute `outdated = ready && isExportOutdated(latestRow, currentHashes?.get(tile.key) ?? null)` (latest row for that tile, as already computed for the row) and pass `onUpdate={() => updateSize(tile)}`.
5. Turn `handleExport` into `runExport(keys: ReadonlySet<string>, trigger: "dialog" | "update")`: it sets `runTriggerRef.current = trigger` and builds its queue from `tiles.filter((t) => keys.has(t.key))` instead of `selected`. `handleExport = () => runExport(selected, "dialog")`. `updateSize(tile)`:

```ts
  const updateSize = (tile: KvMotionTile) => {
    trackKvMotionShareUpdateClicked({
      file_id: studioFileId,
      project_id: projectId,
      ratio: tile.key,
      surface: "export_dialog",
    });
    void runExport(new Set([tile.key]), "update");
  };
```

6. Disable Export and every Update while `exporting || backgroundBusy`. When `backgroundBusy && !exporting`, show one line above the footer buttons: `Preparing a size for sharing — export will be available when it finishes.` (`font-geist text-textXs text-text-inverse-subtlest`).

- [ ] **Step 4: Run all dialog test files**

```bash
cd web
bun test src/components/studio/kv-generator/motion/KvMotionExportDialog.test.tsx
bun test src/components/studio/kv-generator/motion/KvMotionExportDialog.bumpers.test.tsx
bun test src/components/studio/kv-generator/motion/KvMotionExportDialog.encodable.test.tsx
```

Expected: all PASS. If `KvMotionExportDialog.test.tsx` passes ~51 KB, split the new tests into `KvMotionExportDialog.outdated.test.tsx` (bun's file-size cliff produces a bogus SCSS error).

- [ ] **Step 5: Lint, tsc, commit**

```bash
cd web
bunx eslint src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx src/components/studio/kv-generator/motion/KvMotionExportDialog*.test.tsx
bunx tsc --noEmit -p . 2>&1 | grep "KvMotionExportDialog.tsx"
git add src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx src/components/studio/kv-generator/motion/KvMotionExportDialog*.test.tsx
git commit -m "feat(web): Outdated + Update in the Motion export dialog

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Wire it into the Motion editor

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx` (≈225 KB — make targeted edits; never rewrite the file)

**Interfaces:**
- Consumes: Task 1 `resolveMarkAction`, `motionExportInputsFor`; Task 3 `trackKvMotionShareUpdateClicked`; Task 5 `useBackgroundMotionExport`; Task 6 `motionShareChip`, `markIdAfterExport`, `useMotionTileFingerprints`; Task 7 dialog props; existing `toggleReadyToShare`, `motionExportsQuery`, `exportsByTileKey`, `readyStateForTile`, `chainForRatio`, `motionExportsKey`, `tiles`, `project`, `state.timeline`, `motionReadyIds`.

- [ ] **Step 1: Hooks**

Near `toggleReadyToShare` / `motionExportsQuery` (after both are declared), add:

```tsx
  // Spec 2026-10-15: "Mark ready to share" renders a size that has no current
  // export, and a shared size whose design moved on shows Outdated · Update.
  const tileHashes = useMotionTileFingerprints({
    snapshot: project.snapshot,
    timeline: state.timeline,
    audioUrl: project.audioUrl,
    tiles,
  });
  const [dialogExporting, setDialogExporting] = useState(false);
  // Read inside the background completion callback, which outlives renders.
  const shareRefs = useRef({ rows: [] as KvMotionExportRow[], marks: [] as string[] });
  useEffect(() => {
    shareRefs.current = { rows: motionExportsQuery.data ?? [], marks: motionReadyIds };
  });
  const backgroundExport = useBackgroundMotionExport({
    studioFileId: project.studioFileId,
    projectId: project.id,
    snapshot: project.snapshot,
    timeline: state.timeline,
    audioUrl: project.audioUrl,
    paused: dialogExporting,
    onExported: (row, job) => {
      void qc.invalidateQueries({ queryKey: motionExportsKey(fileId, projectId) });
      if (job.then !== "mark") return;
      const chain = chainForRatio(shareRefs.current.rows, row.ratio);
      const markId = markIdAfterExport(chain, shareRefs.current.marks, row.id);
      if (markId) toggleReadyToShare(row, [...chain, row.id], "chip");
    },
  });
```

`tiles` must be declared before this block — if it is declared later in the file (it is at ~line 2289), place this block after it instead. Reuse the editor's existing `QueryClient` (`useQueryClient()`); add one only if the file has none. Import `KvMotionExportRow` type if not already imported.

- [ ] **Step 2: Chip wiring**

Replace the `readyToShare={…}` prop on the tile stage (the block ending in the "Export this size first" toast) with:

```tsx
                readyToShare={(() => {
                  if (motionExportsQuery.data === undefined) return undefined;
                  const chip = motionShareChip({
                    isReady: tileReady.isReady,
                    latestExport: tileReady.latestExport,
                    currentHash: tileHashes.get(d.tile.key) ?? null,
                    job: backgroundExport.jobs.get(d.tile.key) ?? null,
                  });
                  return {
                    isReady: chip.isReady,
                    busyLabel: chip.busyLabel,
                    outdated: chip.outdated,
                    onClick: () => {
                      if (chip.click === "none") return;
                      if (chip.click === "unmark" && tileReady.latestExport) {
                        toggleReadyToShare(tileReady.latestExport, tileReady.chainIds, "chip");
                        return;
                      }
                      void (async () => {
                        const action = await resolveMarkAction(
                          tileReady.latestExport,
                          motionExportInputsFor({
                            snapshot: project.snapshot,
                            timeline: state.timeline,
                            audioUrl: project.audioUrl,
                            tile: d.tile,
                          })
                        );
                        if (action === "mark_existing" && tileReady.latestExport) {
                          toggleReadyToShare(tileReady.latestExport, tileReady.chainIds, "chip");
                        } else if (motionExportsQuery.isError) {
                          showToast(
                            "Couldn't check this size's export status",
                            "Try reloading before marking it ready to share.",
                            "error"
                          );
                        } else {
                          backgroundExport.enqueue({ tileKey: d.tile.key, then: "mark", trigger: "mark" });
                        }
                      })();
                    },
                    onUpdate: () => {
                      trackKvMotionShareUpdateClicked({
                        file_id: fileId,
                        project_id: projectId,
                        ratio: d.tile.key,
                        surface: "chip",
                      });
                      backgroundExport.enqueue({ tileKey: d.tile.key, then: "none", trigger: "update" });
                    },
                  };
                })()}
```

Keep the existing comment above the prop (about hiding while there is no data) and add one line: `// Spec 2026-10-15: no more "Export this size first" — Mark renders it.` Confirm `d.tile` is the full `KvMotionTile` (it is passed to the stage as `tile`); if the loop variable differs, use the one the stage's `tile` prop receives.

- [ ] **Step 3: Dialog wiring**

On `<KvMotionExportDialog …>` add:

```tsx
        currentHashes={tileHashes}
        backgroundBusy={backgroundExport.jobs.size > 0}
        onExportingChange={setDialogExporting}
```

- [ ] **Step 4: Imports, lint, tsc, motion tests**

Add the imports (`useMotionTileFingerprints`, `useBackgroundMotionExport`, `motionShareChip`, `markIdAfterExport`, `resolveMarkAction`, `motionExportInputsFor`, `trackKvMotionShareUpdateClicked`). Then:

```bash
cd web
bunx eslint src/components/studio/kv-generator/motion/KvMotionEditor.tsx
bunx tsc --noEmit -p . 2>&1 | grep "KvMotionEditor.tsx"
```

Expected: no NEW tsc errors — compare against the known baseline (`useAuth().user` errors pre-exist in this file; record them before your edit with the same command on `develop`).

Run every motion test FILE that imports the editor or the touched modules, one file per command:

```bash
cd web
for f in $(grep -rl "KvMotionEditor\|KvMotionTileStage\|KvMotionExportDialog\|motionExportRun\|useBackgroundMotionExport\|motionShareChip" src --include='*.test.ts' --include='*.test.tsx'); do
  echo "== $f"; bun test "$f" 2>&1 | tail -3
done
```

Expected: no failures you did not have on `develop` (re-run any failing file on a `develop` worktree to confirm it is baseline — never `git stash`).

- [ ] **Step 5: Commit**

```bash
cd web
git add src/components/studio/kv-generator/motion/KvMotionEditor.tsx
git commit -m "feat(web): mark a Motion size ready to share without exporting first

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Manual e2e (Daffa, in a logged-in browser)**

With api migrated and both branches checked out, at `/brands/<brand>/studio/kv-generator/<file>/motion/<project>`:

1. A size never exported → **Mark ready to share** → chip shows `Queued`/`Preparing… NN%` → `Ready to share`. Network: one upload, one `POST …/exports` with a 64-hex `source_hash`, one ready-to-share mark.
2. Move a keyframe → within ~1 s the chip shows **Outdated · Update**. Open the share link: still the previous cut.
3. **Update** → Preparing → Ready (no Outdated). Reload the share link: the new cut. No second mark request.
4. Edit, then click Mark on an UNMARKED size within half a second → it renders (does not mark the old file).
5. Start a background render, open the Export dialog → Export disabled with the "Preparing a size for sharing" line; it re-enables when the chip turns Ready.
6. Start a background render and refresh → the browser's leave-page warning appears.
7. PostHog Live Events (project FRnD_OS / 389744): `kv_generator.motion_export_started`, `…motion_export_completed` with `trigger`, `…motion_share_update_clicked`.

- [ ] **Step 7: Taxonomy + memory**

Ask Daffa before editing the shared Lark taxonomy doc; on a yes, add rows for `kv_generator.motion_export_started`, `kv_generator.motion_share_update_clicked`, and the new `trigger` property on `motion_export_completed` / `motion_export_failed`.
