# KV Resize Tile Version History — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tile's clock icon (and its right-click menu) opens the Version History panel for that tile; picking a version previews it on the tile; "Restore this version" makes it current; a rendering / failed / cancelled tile keeps showing its image.

**Architecture:** `KvVersionHistoryPanel` becomes a generic list of items; the board keeps its behaviour through an adapter, tiles get a second adapter. Layout state moves from `versionHistoryOpen: boolean` to a target (`board` | `tile`). The strip draws a tile's `imageUrl` whenever it exists and accepts one image override for the preview. New api calls: list versions, restore, cancel.

**Tech Stack:** Next.js 16, React 19, TypeScript, TanStack Query v5, bun test.

**Spec:** `docs/superpowers/specs/2026-09-24-kv-resize-tile-version-history-design.md` (workspace repo). **Depends on:** `docs/superpowers/plans/2026-09-24-kv-resize-tile-versions-api.md` (its routes and JSON shapes below).

## Global Constraints

- Repo `web/`, branch `feature/daffa/vc-kv-craft-resize-strip`; commit per task; push at the end. No PR. Never `git stash`. Never `bun test` a directory — explicit files only.
- Gate per task: `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"` ≤ the baseline recorded in Task 1 (currently 933); `bunx eslint --fix <touched files>` adds no warnings (`KvGeneratorLayout.tsx` has 13, `KvChat.tsx` 1); `node ./node_modules/next/dist/bin/next build` at the end of Tasks 6 and 8.
- No RTL/component tests for canvas or panels (track policy); pure tests only.
- API contract (from the api plan), under `v1/studio/files/{fileId}/resize-exports/{exportId}`:
  - `GET  …/versions` → `{data: [{id, version_number, image_url, kind, prompt, model, restored_from_version_number, created_by_name, created_at}]}` newest first.
  - `POST …/versions/{versionId}/restore` → `{data: <resize export>}`; 409 `{message}` while rendering.
  - `POST …/cancel` → 200 `{data: <resize export>}` (reverted) or 204 (first render deleted).
  - Resize export JSON gains `current_version_id: string | null`, `version_count: number`.
- Kinds → labels, verbatim: `create` "Created", `regenerate` "Regenerated", `region_edit` "Region edit", `separate` "Separated layers", `restore` "Restored from v{N}".
- Events, verbatim: `kv_generator.resize_tile_versions_opened` `{export_id, version_count, source: "header" | "menu"}`; `kv_generator.resize_tile_version_restored` `{export_id, from_version_number, new_version_number, restored_kind}`.
- Icons: tile header "Version history" = `ClockCounterClockwise`; "Reset to master" = `ArrowCounterClockwise`.

## Review Focus

1. **Older server / SSE row without the new fields** — `current_version_id` / `version_count` missing must map to `null` / `0`, not `undefined`. Pinned in Task 1.
2. **Preview of the CURRENT version** — must not set an override (no flicker, restore disabled). Pinned in Task 3 (`tilePreviewFor`).
3. **Tile deleted while its history is open** (cancel of a first render, remove) — the panel must close instead of showing an empty tile history. Pinned in Task 3 (`resolveVersionHistoryTarget`).
4. **Failed tile with an image** — the image must stay drawn under the failed chip; "Discard" goes through cancel (revert), not delete. Pinned in Task 2 (strip) + Task 5 (cancel call).
5. **Board Version History unchanged** — same items, same "Current" rule, same restore. Pinned in Task 3 (`boardVersionItems`).

---

## File Structure

| File | Responsibility |
|---|---|
| `src/types/kv/resize.ts` | `KvResizeExport.currentVersionId?/versionCount?`, `KvResizeExportVersion` |
| `src/services/kv/api.ts` | mapper fields; `listResizeExportVersions`, `restoreResizeExportVersion`, `cancelResizeExport` |
| `src/services/kv/resize-stream.ts` | SSE mapper fields |
| `src/services/kv/resizeTileVersions.api.test.ts` (new) | api function tests |
| `src/components/studio/kv-generator/resizeStrip.ts` (+test) | draw image when present; `imageOverride` |
| `src/lib/studio/kv/versionHistoryItems.ts` (new, +test) | `VersionHistoryItem`, `boardVersionItems`, `tileVersionItems`, `VersionHistoryTarget`, `resolveVersionHistoryTarget`, `tilePreviewFor` |
| `src/components/studio/kv-generator/KvVersionHistoryPanel.tsx` | generic items |
| `src/lib/studio/kv/useResizeExportVersions.ts` (new) | query hook |
| `src/lib/studio/kv/useResizeTileActions.ts`, `useResizeExports.ts` | cancel → cancel endpoint |
| `src/components/studio/kv-generator/KvResizeStripChrome.tsx`, `KvResizeTileContextMenu.tsx`, `KvCanvas.tsx` | icons, menu item, props |
| `src/lib/analytics/kv-generator-events.ts` (+test) | 2 events |
| `src/components/studio/kv-generator/KvGeneratorLayout.tsx` | target state, panel wiring, preview, restore |
| `docs/tracks/kv-craft-resize-strip.track.md` | log + checklist |

---

### Task 1: Types and api client

**Files:**
- Modify: `src/types/kv/resize.ts`, `src/services/kv/api.ts` (≈805-857 mapper; new functions after `deleteResizeExport` ≈1009), `src/services/kv/resize-stream.ts` (≈36-56)
- Test: `src/services/kv/resizeTileVersions.api.test.ts`

**Interfaces:**
- Produces:
  - `KvResizeExport` gains `currentVersionId?: string | null; versionCount?: number` (optional so the 12 existing test literals still type-check; mappers always set them).
  - `type KvResizeExportVersionKind = "create" | "regenerate" | "region_edit" | "separate" | "restore"`
  - `type KvResizeExportVersion = { id: string; versionNumber: number; imageUrl: string; kind: KvResizeExportVersionKind; prompt: string | null; model: string | null; restoredFromVersionNumber: number | null; createdByName: string | null; createdAt: string }`
  - `listResizeExportVersions(fileId, exportId): Promise<KvResizeExportVersion[]>`
  - `restoreResizeExportVersion(fileId, exportId, versionId): Promise<KvResizeExport>`
  - `cancelResizeExport(fileId, exportId): Promise<KvResizeExport | null>` (null on 204)

- [ ] **Step 0:** `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"` → record as baseline in the ledger.

- [ ] **Step 1: Failing test** (axios mock pattern from `editResizeExportRegion.test.ts`)

```ts
import { beforeEach, describe, expect, it, mock } from "bun:test";

const WIRE_ROW = {
  id: "exp-1",
  studio_file_id: "file-1",
  parent_generation_id: "gen-1",
  platform_id: "instagram-story",
  name: null,
  platform_label: "Instagram Story",
  platform_group: "social-media",
  width: 1080,
  height: 1920,
  image_url: "https://cdn.test/v1.png",
  current_version_id: "ver-3",
  version_count: 3,
  status: "done",
  crop_window: null,
  overlays: null,
  error_message: null,
  created_at: "2026-09-24T00:00:00Z",
  updated_at: "2026-09-24T00:00:00Z",
};

const get = mock(async () => ({
  data: {
    data: [
      {
        id: "ver-3",
        version_number: 3,
        image_url: "https://cdn.test/v1.png",
        kind: "restore",
        prompt: null,
        model: null,
        restored_from_version_number: 1,
        created_by_name: "Daffa",
        created_at: "2026-09-24T10:00:00Z",
      },
    ],
  },
}));
const post = mock(async (url: string) =>
  url.endsWith("/cancel") && url.includes("first")
    ? { status: 204, data: "" }
    : { status: 200, data: { data: WIRE_ROW } }
);

const actualAxios = await import("@/services/axios");
mock.module("@/services/axios", () => ({
  ...actualAxios,
  default: { get, post },
}));

const {
  cancelResizeExport,
  listResizeExportVersions,
  restoreResizeExportVersion,
} = await import("./api");

describe("resize tile versions api", () => {
  beforeEach(() => {
    get.mockClear();
    post.mockClear();
  });

  it("lists versions and maps them to camelCase", async () => {
    const rows = await listResizeExportVersions("file-1", "exp-1");
    expect(get).toHaveBeenCalledWith(
      "v1/studio/files/file-1/resize-exports/exp-1/versions"
    );
    expect(rows[0]).toEqual({
      id: "ver-3",
      versionNumber: 3,
      imageUrl: "https://cdn.test/v1.png",
      kind: "restore",
      prompt: null,
      model: null,
      restoredFromVersionNumber: 1,
      createdByName: "Daffa",
      createdAt: "2026-09-24T10:00:00Z",
    });
  });

  it("restores a version and maps the tile with its version fields", async () => {
    const row = await restoreResizeExportVersion("file-1", "exp-1", "ver-1");
    expect(post).toHaveBeenCalledWith(
      "v1/studio/files/file-1/resize-exports/exp-1/versions/ver-1/restore",
      {}
    );
    expect(row.currentVersionId).toBe("ver-3");
    expect(row.versionCount).toBe(3);
  });

  it("cancel returns the reverted tile, or null when the server deleted it", async () => {
    const reverted = await cancelResizeExport("file-1", "exp-1");
    expect(reverted?.imageUrl).toBe("https://cdn.test/v1.png");
    expect(await cancelResizeExport("file-1", "first")).toBeNull();
  });
});
```

- [ ] **Step 2: Run** `bun test src/services/kv/resizeTileVersions.api.test.ts` — expect FAIL (functions missing).

- [ ] **Step 3: Implement**

`resize.ts` — add to `KvResizeExport` after `imageUrl`:

```ts
  /** The version `imageUrl` is (spec 2026-09-24); null for a tile with no
   *  image yet or a layer-composed tile. Optional only so old test literals
   *  type-check — both mappers always set it. */
  currentVersionId?: string | null;
  /** Number of recorded versions — 0 hides the history icon. */
  versionCount?: number;
```
and after the type:

```ts
export type KvResizeExportVersionKind =
  | "create"
  | "regenerate"
  | "region_edit"
  | "separate"
  | "restore";

export type KvResizeExportVersion = {
  id: string;
  versionNumber: number;
  imageUrl: string;
  kind: KvResizeExportVersionKind;
  prompt: string | null;
  model: string | null;
  restoredFromVersionNumber: number | null;
  createdByName: string | null;
  createdAt: string;
};
```

`api.ts` — `WireResizeExport` gains `current_version_id?: string | null; version_count?: number;`; `toResizeExport` gains
```ts
    currentVersionId: w.current_version_id ?? null,
    versionCount: w.version_count ?? 0,
```
`resize-stream.ts` hand-built mapper gains the same two lines (`wire.current_version_id ?? null`, `wire.version_count ?? 0`).

New functions after `deleteResizeExport` (add `KvResizeExportVersion` to the resize type import):

```ts
type WireResizeExportVersion = {
  id: string;
  version_number: number;
  image_url: string;
  kind: KvResizeExportVersion["kind"];
  prompt: string | null;
  model: string | null;
  restored_from_version_number: number | null;
  created_by_name: string | null;
  created_at: string;
};

export async function listResizeExportVersions(
  fileId: string,
  exportId: string,
): Promise<KvResizeExportVersion[]> {
  const { data } = await axiosInstance.get(
    `v1/studio/files/${fileId}/resize-exports/${exportId}/versions`,
  );
  const rows: WireResizeExportVersion[] = unwrap(data);
  return rows.map((w) => ({
    id: w.id,
    versionNumber: w.version_number,
    imageUrl: w.image_url,
    kind: w.kind,
    prompt: w.prompt ?? null,
    model: w.model ?? null,
    restoredFromVersionNumber: w.restored_from_version_number ?? null,
    createdByName: w.created_by_name ?? null,
    createdAt: w.created_at,
  }));
}

/** Make an old version the tile's image again — the server APPENDS a
 *  `restore` version, history is never rewritten. 409 while rendering. */
export async function restoreResizeExportVersion(
  fileId: string,
  exportId: string,
  versionId: string,
): Promise<KvResizeExport> {
  const { data } = await axiosInstance.post(
    `v1/studio/files/${fileId}/resize-exports/${exportId}/versions/${versionId}/restore`,
    {},
  );
  return toResizeExport(unwrap<WireResizeExport>(data));
}

/** Stop a render. A tile with a version reverts to it (200 + row); a first
 *  render is deleted (204 → null). */
export async function cancelResizeExport(
  fileId: string,
  exportId: string,
): Promise<KvResizeExport | null> {
  const res = await axiosInstance.post(
    `v1/studio/files/${fileId}/resize-exports/${exportId}/cancel`,
  );
  if (res.status === 204 || !res.data) return null;
  return toResizeExport(unwrap<WireResizeExport>(res.data));
}
```
Before writing, check how `axiosInstance` is imported in `api.ts` and how `unwrap` handles `{data}` — follow them exactly. If the `post` call with no body fails the mock's `toHaveBeenCalledWith` shape, keep the call and adjust nothing else (the cancel test does not assert args).

- [ ] **Step 4: Run** the new test + `src/services/kv/editResizeExportRegion.test.ts src/services/kv/resize-stream.test.ts src/services/kv/createResizeExports.test.ts` — PASS.
- [ ] **Step 5: Gates + commit** — `git commit -m "feat(web): resize tile version types + list/restore/cancel api"`

---

### Task 2: Strip draws the image while rendering; preview override

**Files:**
- Modify: `src/components/studio/kv-generator/resizeStrip.ts` (≈42-100)
- Test: `src/components/studio/kv-generator/resizeStrip.test.ts`

**Interfaces:**
- Produces: `computeResizeStrip(args & { imageOverride?: { exportId: string; imageUrl: string } | null })`.

- [ ] **Step 1: Failing tests** (append to `resizeStrip.test.ts`, using its `parent` / `exp` / `sq` / `W` helpers)

```ts
describe("computeResizeStrip — images while rendering (tile versions)", () => {
  const run = (
    rows: KvResizeExport[],
    imageOverride?: { exportId: string; imageUrl: string } | null
  ) =>
    computeResizeStrip({
      craftRects: [sq],
      groups: [{ parent: parent("g1"), exports: rows }],
      boardWorldWidth: W,
      imageOverride,
    });

  it("keeps drawing a pending or failed tile's current image", () => {
    const out = run([
      exp("a", 1080, 1080, { status: "pending", imageUrl: "https://x/cur.png" }),
      exp("b", 1080, 1080, { status: "failed", imageUrl: "https://x/old.png" }),
    ]);
    expect(out.surfaces.map((s) => s.imageUrl)).toEqual([
      "https://x/cur.png",
      "https://x/old.png",
    ]);
    expect(out.surfaces.every((s) => !s.blank)).toBe(true);
  });

  it("draws nothing for a first render that has no image yet", () => {
    const out = run([exp("a", 1080, 1080, { status: "pending", imageUrl: null })]);
    expect(out.surfaces[0].imageUrl).toBeNull();
    expect(out.surfaces[0].blank).toBe(false);
  });

  it("still marks a done tile without an image as blank (layer-composed)", () => {
    const out = run([exp("a", 1080, 1080, { status: "done", imageUrl: null })]);
    expect(out.surfaces[0].blank).toBe(true);
  });

  it("applies the preview override to ONE tile only", () => {
    const out = run(
      [
        exp("a", 1080, 1080, { imageUrl: "https://x/a.png" }),
        exp("b", 1080, 1080, { imageUrl: "https://x/b.png" }),
      ],
      { exportId: "b", imageUrl: "https://x/b-v1.png" }
    );
    expect(out.surfaces.map((s) => s.imageUrl)).toEqual([
      "https://x/a.png",
      "https://x/b-v1.png",
    ]);
  });
});
```

- [ ] **Step 2: Run** `bun test src/components/studio/kv-generator/resizeStrip.test.ts` — FAIL (pending/failed drawn as null; no override).

- [ ] **Step 3: Implement** — add `imageOverride?: { exportId: string; imageUrl: string } | null;` to the args type, destructure it, and in the surface push:

```ts
      // A tile keeps showing its current image while it renders or after a
      // failure (spec 2026-09-24) — a regenerate no longer blanks it. The
      // history panel's preview swaps ONE tile's image.
      const imageUrl =
        imageOverride?.exportId === ex.id
          ? imageOverride.imageUrl
          : ex.imageUrl;
      surfaces.push({
        id: ex.id,
        docBoardId: null,
        layout: "view",
        imageUrl,
        blank: ex.status === "done" && !ex.imageUrl,
```

- [ ] **Step 4: Run** — PASS (existing + 4 new).
- [ ] **Step 5: Gates + commit** — `git commit -m "feat(web): strip keeps a tile's image while it renders; one-tile preview override"`

---

### Task 3: Panel items, target and preview rules (pure)

**Files:**
- Create: `src/lib/studio/kv/versionHistoryItems.ts`, `src/lib/studio/kv/versionHistoryItems.test.ts`

**Interfaces:**
- Produces:
  - `type VersionHistoryBadge = "sketch" | "craft" | "reference"`
  - `type VersionHistoryItem = { id: string; thumbnailUrl: string | null; title: string; detail: string | null; time: string; badge: VersionHistoryBadge | null }`
  - `boardVersionItems(generations: KvGeneration[]): VersionHistoryItem[]`
  - `tileVersionItems(versions: KvResizeExportVersion[]): VersionHistoryItem[]`
  - `type VersionHistoryTarget = { kind: "board" } | { kind: "tile"; exportId: string }`
  - `resolveVersionHistoryTarget(target: VersionHistoryTarget | null, tileIds: readonly string[]): VersionHistoryTarget | null` — a tile target whose tile is gone → null.
  - `tilePreviewFor(exportId: string, selected: KvResizeExportVersion | null, currentVersionId: string | null | undefined): { exportId: string; imageUrl: string } | null`
  - `TILE_VERSION_KIND_LABEL: Record<KvResizeExportVersionKind, string>` (restore label built per row)

- [ ] **Step 1: Failing tests**

```ts
import { describe, expect, it } from "bun:test";
import type { KvGeneration } from "@/types/studio";
import type { KvResizeExportVersion } from "@/types/kv/resize";
import {
  boardVersionItems,
  resolveVersionHistoryTarget,
  tilePreviewFor,
  tileVersionItems,
} from "./versionHistoryItems";

const gen = (o: Partial<KvGeneration> & { id: string }): KvGeneration =>
  ({
    studio_file_id: "f",
    version_number: 1,
    mode: "sketch",
    image_url: `https://x/${o.id}.png`,
    thumbnail_url: null,
    prompt_snapshot: "",
    model: "m",
    parent_generation_id: null,
    metadata: {},
    created_at: "2026-09-24T00:00:00Z",
    ...o,
  }) as KvGeneration;

const ver = (
  o: Partial<KvResizeExportVersion> & { id: string }
): KvResizeExportVersion => ({
  versionNumber: 1,
  imageUrl: `https://x/${o.id}.png`,
  kind: "create",
  prompt: null,
  model: null,
  restoredFromVersionNumber: null,
  createdByName: null,
  createdAt: "2026-09-24T00:00:00Z",
  ...o,
});

describe("boardVersionItems", () => {
  it("keeps today's board card: title, thumbnail fallback, mode badge", () => {
    const items = boardVersionItems([
      gen({ id: "g2", version_number: 2, mode: "craft", thumbnail_url: "https://x/t.png" }),
      gen({ id: "g1", version_number: 1, metadata: { imported_from_upload: true } }),
    ]);
    expect(items).toEqual([
      { id: "g2", thumbnailUrl: "https://x/t.png", title: "Version 2", detail: null, time: "2026-09-24T00:00:00Z", badge: "craft" },
      { id: "g1", thumbnailUrl: "https://x/g1.png", title: "Version 1", detail: null, time: "2026-09-24T00:00:00Z", badge: "reference" },
    ]);
  });
});

describe("tileVersionItems", () => {
  it("labels each kind and appends the prompt", () => {
    const items = tileVersionItems([
      ver({ id: "v4", versionNumber: 4, kind: "restore", restoredFromVersionNumber: 1 }),
      ver({ id: "v3", versionNumber: 3, kind: "region_edit", prompt: "remove logo" }),
      ver({ id: "v2", versionNumber: 2, kind: "regenerate", prompt: "warmer" }),
      ver({ id: "v1", versionNumber: 1, kind: "create" }),
    ]);
    expect(items.map((i) => [i.title, i.detail])).toEqual([
      ["Version 4", "Restored from v1"],
      ["Version 3", "Region edit · remove logo"],
      ["Version 2", "Regenerated · warmer"],
      ["Version 1", "Created"],
    ]);
    expect(items.every((i) => i.badge === null)).toBe(true);
    expect(items[0].thumbnailUrl).toBe("https://x/v4.png");
  });

  it("labels a separate-layers version", () => {
    expect(tileVersionItems([ver({ id: "v", kind: "separate" })])[0].detail).toBe(
      "Separated layers"
    );
  });
});

describe("resolveVersionHistoryTarget", () => {
  it("keeps a board target and a tile target whose tile exists", () => {
    expect(resolveVersionHistoryTarget({ kind: "board" }, [])).toEqual({ kind: "board" });
    expect(resolveVersionHistoryTarget({ kind: "tile", exportId: "a" }, ["a"])).toEqual({
      kind: "tile",
      exportId: "a",
    });
  });

  it("closes a tile target whose tile is gone", () => {
    expect(resolveVersionHistoryTarget({ kind: "tile", exportId: "a" }, ["b"])).toBeNull();
    expect(resolveVersionHistoryTarget(null, ["a"])).toBeNull();
  });
});

describe("tilePreviewFor", () => {
  const v1 = ver({ id: "v1", imageUrl: "https://x/v1.png" });

  it("previews a non-current version on its tile", () => {
    expect(tilePreviewFor("a", v1, "v2")).toEqual({ exportId: "a", imageUrl: "https://x/v1.png" });
  });

  it("does not override for the current version or no selection", () => {
    expect(tilePreviewFor("a", v1, "v1")).toBeNull();
    expect(tilePreviewFor("a", null, "v1")).toBeNull();
  });
});
```

- [ ] **Step 2: Run** `bun test src/lib/studio/kv/versionHistoryItems.test.ts` — FAIL (module missing).

- [ ] **Step 3: Implement**

```ts
import type { KvGeneration } from "@/types/studio";
import type {
  KvResizeExportVersion,
  KvResizeExportVersionKind,
} from "@/types/kv/resize";

/** One card in the Version History panel — board or tile (spec 2026-09-24). */
export type VersionHistoryBadge = "sketch" | "craft" | "reference";
export type VersionHistoryItem = {
  id: string;
  thumbnailUrl: string | null;
  title: string;
  detail: string | null;
  time: string;
  badge: VersionHistoryBadge | null;
};

export type VersionHistoryTarget =
  | { kind: "board" }
  | { kind: "tile"; exportId: string };

export const TILE_VERSION_KIND_LABEL: Record<
  Exclude<KvResizeExportVersionKind, "restore">,
  string
> = {
  create: "Created",
  regenerate: "Regenerated",
  region_edit: "Region edit",
  separate: "Separated layers",
};

function boardBadge(g: KvGeneration): VersionHistoryBadge {
  const meta = g.metadata as Record<string, unknown> | null | undefined;
  if (meta?.imported_from_upload) return "reference";
  return (g.mode ?? "sketch") === "craft" ? "craft" : "sketch";
}

export function boardVersionItems(
  generations: KvGeneration[]
): VersionHistoryItem[] {
  return generations.map((g) => ({
    id: g.id,
    thumbnailUrl: g.thumbnail_url ?? g.image_url ?? null,
    title: `Version ${g.version_number}`,
    detail: null,
    time: g.created_at,
    badge: boardBadge(g),
  }));
}

export function tileVersionItems(
  versions: KvResizeExportVersion[]
): VersionHistoryItem[] {
  return versions.map((v) => {
    const action =
      v.kind === "restore"
        ? `Restored from v${v.restoredFromVersionNumber ?? "?"}`
        : TILE_VERSION_KIND_LABEL[v.kind];
    return {
      id: v.id,
      thumbnailUrl: v.imageUrl,
      title: `Version ${v.versionNumber}`,
      detail: v.prompt ? `${action} · ${v.prompt}` : action,
      time: v.createdAt,
      badge: null,
    };
  });
}

/** A tile's history closes itself when its tile disappears (a cancelled
 *  first render, a removed tile) instead of showing an orphaned list. */
export function resolveVersionHistoryTarget(
  target: VersionHistoryTarget | null,
  tileIds: readonly string[]
): VersionHistoryTarget | null {
  if (!target) return null;
  if (target.kind === "tile" && !tileIds.includes(target.exportId)) return null;
  return target;
}

/** The strip's image override while a tile version is previewed — none for
 *  the current version (it is already drawn). */
export function tilePreviewFor(
  exportId: string,
  selected: KvResizeExportVersion | null,
  currentVersionId: string | null | undefined
): { exportId: string; imageUrl: string } | null {
  if (!selected || selected.id === currentVersionId) return null;
  return { exportId, imageUrl: selected.imageUrl };
}
```
Check `KvGeneration`'s real field names/nullability (`thumbnail_url`, `mode`, `metadata`) in `src/types/studio.ts` and adjust the test fixture cast if a required field is missing.

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Gates + commit** — `git commit -m "feat(web): version history items + target/preview rules"`

---

### Task 4: Generic Version History panel

**Files:**
- Modify: `src/components/studio/kv-generator/KvVersionHistoryPanel.tsx`
- Modify (call site): `src/components/studio/kv-generator/KvGeneratorLayout.tsx` ≈7874 (board keeps working)

**Interfaces:**
- Consumes: `VersionHistoryItem`, `boardVersionItems` (Task 3).
- Produces: props `{ open; title: string; items: VersionHistoryItem[]; selectedId: string | null; onSelectVersion(id | null); onClose(); onRestore(id); restoring?: boolean; restoreDisabledReason?: string | null; emptyText: string }`. Current = `items[0]`.

No component test (policy); the mapping it renders is tested in Task 3.

- [ ] **Step 1: Rewrite props + card.** Replace `generations: KvGeneration[]` with `items: VersionHistoryItem[]`, add `title`, `emptyText`, `restoreDisabledReason`. `currentId = items[0]?.id ?? null`. `canRestore = !!selectedId && selectedId !== currentId && !restoring && !restoreDisabledReason`. Header text = `{title}`. Empty state text = `{emptyText}`. Under the Restore button, when `restoreDisabledReason`, render:

```tsx
        {restoreDisabledReason ? (
          <p className="pt-2 font-geist text-textXsRegular leading-[1.4] text-text-inverse-subtle">
            {restoreDisabledReason}
          </p>
        ) : null}
```
`VersionCard` takes `item: VersionHistoryItem`: thumbnail `item.thumbnailUrl`, alt `item.title`, title `item.title`, time `formatVersionTime(item.time)`, and below the time, when `item.detail`, a `<p className="line-clamp-2 font-geist text-textXsRegular leading-[1.4] text-text-inverse-subtle">{item.detail}</p>`. `RowModeBadge` becomes `RowBadge({ badge }: { badge: VersionHistoryBadge })` with the same three styled spans keyed by `badge` ("reference" / "craft" / "sketch"), rendered only when `item.badge` is non-null. Remove the `KvGeneration` import.

- [ ] **Step 2: Board call site** — in the layout:

```tsx
          <KvVersionHistoryPanel
            open={versionHistoryOpen}
            title="Version History"
            emptyText="No versions yet. Generate a KV first."
            items={boardVersionItems(versionHistoryGenerations)}
```
(rest unchanged). Import `boardVersionItems` from `@/lib/studio/kv/versionHistoryItems`.

- [ ] **Step 3: Gates** — tsc ≤ baseline, eslint on both files no new warnings, `bun test src/lib/studio/kv/versionHistoryItems.test.ts` PASS.
- [ ] **Step 4: Commit** — `git commit -m "refactor(web): Version History panel renders generic items (board unchanged)"`

---

### Task 5: Data hooks — versions query, cancel reverts

**Files:**
- Create: `src/lib/studio/kv/useResizeExportVersions.ts`
- Modify: `src/lib/studio/kv/useResizeTileActions.ts` (`cancel` ≈75), `src/lib/studio/kv/useResizeExports.ts` (`cancel` ≈414)

**Interfaces:**
- Produces:
  - `resizeExportVersionsQueryKey(fileId: string, exportId: string) => ["kv-resize-export-versions", fileId, exportId]`
  - `useResizeExportVersions(fileId: string | null, exportId: string | null, currentVersionId: string | null | undefined)` → the `useQuery` result (`data: KvResizeExportVersion[] | undefined`). Key includes `currentVersionId` as a 4th element so a new version refetches.

- [ ] **Step 1: Implement the hook**

```ts
import { useQuery } from "@tanstack/react-query";
import { listResizeExportVersions } from "@/services/kv/api";

export const resizeExportVersionsQueryKey = (fileId: string, exportId: string) =>
  ["kv-resize-export-versions", fileId, exportId] as const;

/** A tile's versions, newest first (spec 2026-09-24). Keyed on the tile's
 *  current version too, so a render, restore or separate that lands while the
 *  panel is open refetches without any extra wiring. */
export function useResizeExportVersions(
  fileId: string | null,
  exportId: string | null,
  currentVersionId: string | null | undefined
) {
  return useQuery({
    queryKey: [
      ...resizeExportVersionsQueryKey(fileId ?? "", exportId ?? ""),
      currentVersionId ?? null,
    ],
    queryFn: () => listResizeExportVersions(fileId as string, exportId as string),
    enabled: !!fileId && !!exportId,
    staleTime: 30_000,
  });
}
```

- [ ] **Step 2: Cancel → cancel endpoint.** In `useResizeTileActions.cancel`, replace `await deleteResizeExport(fileId, row.id);` with `await cancelResizeExport(fileId, row.id);` (import it; drop `deleteResizeExport` from the import if no longer used there) and update its doc comment: `/** Cancel a render: a tile with a version reverts to it, a first render is deleted (spec 2026-09-24). */`. In `useResizeExports.cancel`:

```ts
  const cancel = useMutation({
    mutationFn: (exportId: string) => cancelResizeExport(fileId, exportId),
    onSuccess: (row, exportId) => {
      qc.setQueryData<KvResizeExport[]>(
        QUERY_KEY(fileId, parentGenerationId),
        (prev) =>
          row
            ? (prev ?? []).map((r) => (r.id === row.id ? row : r))
            : (prev ?? []).filter((r) => r.id !== exportId)
      );
    },
  });
```

- [ ] **Step 3: Gates** — tsc, eslint on the three files; `bun test src/lib/studio/kv/useResizeExports.test.ts` (if it asserts cancel → DELETE, update that assertion to the cancel endpoint and ledger a Ruling citing spec decision 4).
- [ ] **Step 4: Commit** — `git commit -m "feat(web): tile versions query; cancel reverts to the last version"`

---

### Task 6: Header icons, menu item, canvas props

**Files:**
- Modify: `KvResizeStripChrome.tsx` (≈4 imports, props ≈78-100, icons ≈179-189), `KvResizeTileContextMenu.tsx` (props + item after Regenerate…), `KvCanvas.tsx` (props ≈462-480 + destructure ≈592; `computeResizeStrip` call ≈693; strip chrome ≈1400; tile menu ≈1827)

**Interfaces:**
- Produces (KvCanvas props): `onOpenTileVersionHistory?: (row: KvResizeExport, source: "header" | "menu") => void`; `tileImageOverride?: { exportId: string; imageUrl: string } | null`.
- Strip chrome prop: `onOpenVersionHistory?: (row: KvResizeExport) => void`. Menu prop: `onOpenVersionHistory?: (row: KvResizeExport) => void`.

- [ ] **Step 1: Strip chrome.** Import `ArrowCounterClockwise`. Replace the reset button's icon with `<ArrowCounterClockwise size={16} />`, `aria-label`/`title` = `"Reset to master"`. Before it, add:

```tsx
                      {(row.versionCount ?? 0) > 0 && onOpenVersionHistory && (
                        <button
                          type="button"
                          aria-label="Version history"
                          title="Version history"
                          className="rounded p-1 text-white/70 transition-colors hover:text-white"
                          onClick={() => onOpenVersionHistory(row)}
                        >
                          <ClockCounterClockwise size={16} />
                        </button>
                      )}
```
- [ ] **Step 2: Menu.** Add prop `onOpenVersionHistory?: (row: KvResizeExport) => void;` and, right after the Regenerate block:

```tsx
        {onOpenVersionHistory && (row.versionCount ?? 0) > 0 && (
          <ContextMenuItem
            label="Version history"
            icon={kvMenuIcons.history}
            onClick={() => {
              onClose();
              onOpenVersionHistory(row);
            }}
          />
        )}
```
- [ ] **Step 3: KvCanvas.** Add both props (doc comments: "spec 2026-09-24 tile versions"), destructure, pass `imageOverride: tileImageOverride ?? null` into `computeResizeStrip({...})` and add `tileImageOverride` to that `useMemo`'s deps; pass `onOpenVersionHistory={onOpenTileVersionHistory ? (row) => onOpenTileVersionHistory(row, "header") : undefined}` to `KvResizeStripChrome`, and `onOpenVersionHistory={onOpenTileVersionHistory ? (row) => onOpenTileVersionHistory(row, "menu") : undefined}` to `KvResizeTileContextMenu`.
- [ ] **Step 4: Gates + build** — tsc ≤ baseline; eslint on the three files no new warnings; `bun test src/components/studio/kv-generator/resizeStrip.test.ts`; `node ./node_modules/next/dist/bin/next build` (log to the scratchpad) exit 0.
- [ ] **Step 5: Commit** — `git commit -m "feat(web): tile header Version history icon + menu item; Reset to master gets its own icon"`

---

### Task 7: Analytics events

**Files:**
- Modify: `src/lib/analytics/kv-generator-events.ts` (after `trackKvResizeTileResetToMaster`)
- Test: `src/lib/analytics/kv-generator-events.tileVersions.test.ts` (same prototype-preserving posthog mock as `kv-generator-events.bumpers.test.ts`)

**Interfaces:**
- Produces: `trackKvResizeTileVersionsOpened(p: { export_id: string; version_count: number; source: "header" | "menu" })`, `trackKvResizeTileVersionRestored(p: { export_id: string; from_version_number: number; new_version_number: number; restored_kind: string })`.

- [ ] **Step 1: Failing test** — copy the header (mock block) of `kv-generator-events.bumpers.test.ts` verbatim, import the two new functions, and assert:

```ts
describe("tile version events", () => {
  it("versions_opened carries export, count and source", () => {
    trackKvResizeTileVersionsOpened({ export_id: "e1", version_count: 3, source: "menu" });
    expect(capture).toHaveBeenCalledWith(
      "kv_generator.resize_tile_versions_opened",
      expect.objectContaining({ export_id: "e1", version_count: 3, source: "menu" })
    );
  });

  it("version_restored carries from/new numbers and the restored kind", () => {
    trackKvResizeTileVersionRestored({
      export_id: "e1",
      from_version_number: 1,
      new_version_number: 4,
      restored_kind: "create",
    });
    expect(capture).toHaveBeenCalledWith(
      "kv_generator.resize_tile_version_restored",
      expect.objectContaining({ from_version_number: 1, new_version_number: 4, restored_kind: "create" })
    );
  });
});
```
- [ ] **Step 2: Run — FAIL.** **Step 3:** implement both with `safeCapture` and doc comments. **Step 4:** run it + the bumpers test — PASS. **Step 5:** commit `feat(web): tile version history events`.

---

### Task 8: Layout — target state, tile panel, preview, restore

**Files:**
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (state ≈2132 and its readers — lines listed by `grep -n "versionHistoryOpen\|setVersionHistoryOpen"`; `<KvCanvas` ≈7449; panel ≈7874)

**Interfaces:**
- Consumes: Tasks 1, 3, 4, 5, 6, 7.

No unit test (layout/canvas policy); rules are covered by Task 3.

- [ ] **Step 1: State.** Replace

```ts
  const [versionHistoryOpen, setVersionHistoryOpen] = useState(false);
```
with

```ts
  // Board OR one tile's history — one panel at a time (spec 2026-09-24).
  const [versionHistoryTargetRaw, setVersionHistoryTarget] =
    useState<VersionHistoryTarget | null>(null);
  const [tileVersionSelectedId, setTileVersionSelectedId] = useState<
    string | null
  >(null);
```
After `stripExports` is declared (≈2743), add:

```ts
  const versionHistoryTarget = resolveVersionHistoryTarget(
    versionHistoryTargetRaw,
    stripExports.map((r) => r.id)
  );
  const versionHistoryOpen = versionHistoryTarget !== null;
```
Then replace every `setVersionHistoryOpen(true)` with `setVersionHistoryTarget({ kind: "board" })` and every `setVersionHistoryOpen(false)` with `setVersionHistoryTarget(null)`. If any reader of `versionHistoryOpen` sits ABOVE ≈2743 (TDZ), move that reader's computation below, or read `versionHistoryTargetRaw !== null` there; ledger which.

- [ ] **Step 2: Tile history data.**

```ts
  const historyTile =
    versionHistoryTarget?.kind === "tile"
      ? (stripExports.find((r) => r.id === versionHistoryTarget.exportId) ??
        null)
      : null;
  const tileVersionsQuery = useResizeExportVersions(
    historyTile ? fileId : null,
    historyTile?.id ?? null,
    historyTile?.currentVersionId
  );
  const tileVersions = tileVersionsQuery.data ?? [];
  const selectedTileVersion =
    tileVersions.find((v) => v.id === tileVersionSelectedId) ?? null;
  const tileImageOverride = historyTile
    ? tilePreviewFor(historyTile.id, selectedTileVersion, historyTile.currentVersionId)
    : null;
```
(Hooks must not be conditional — `useResizeExportVersions` is always called; `enabled` handles the rest.)

- [ ] **Step 3: Open handler + restore mutation.**

```ts
  const handleOpenTileVersionHistory = useCallback(
    (row: KvResizeExport, source: "header" | "menu") => {
      setViewingGenerationId(null);
      setTileVersionSelectedId(null);
      setVersionHistoryTarget({ kind: "tile", exportId: row.id });
      trackKvResizeTileVersionsOpened({
        export_id: row.id,
        version_count: row.versionCount ?? 0,
        source,
      });
    },
    [setViewingGenerationId]
  );

  const restoreTileVersionMutation = useMutation({
    mutationFn: (args: { row: KvResizeExport; version: KvResizeExportVersion }) =>
      restoreResizeExportVersion(fileId, args.row.id, args.version.id),
    onSuccess: (updated, { row, version }) => {
      setTileVersionSelectedId(null);
      void qc.invalidateQueries({
        queryKey: resizeExportsQueryKey(fileId, row.parentGenerationId),
      });
      void qc.invalidateQueries({
        queryKey: resizeExportVersionsQueryKey(fileId, row.id),
      });
      trackKvResizeTileVersionRestored({
        export_id: row.id,
        from_version_number: version.versionNumber,
        new_version_number: updated.versionCount ?? version.versionNumber,
        restored_kind: version.kind,
      });
    },
    onError: (err) => {
      setTransientNotice(
        (err as { response?: { data?: { message?: string } } }).response?.data
          ?.message ?? "Couldn't restore this version — try again."
      );
    },
  });
```
Declare the mutation after `setTransientNotice` exists (≈4135) or move the notice call into a later-declared callback — check order and ledger any move. The board's own handler (`handleShowVersionHistory`) must also clear the tile selection: add `setTileVersionSelectedId(null);`.

- [ ] **Step 4: Panel.** Replace the single panel render with a target switch:

```tsx
          {versionHistoryTarget?.kind === "tile" && historyTile ? (
            <KvVersionHistoryPanel
              open
              title={`Version History · ${historyTile.platformLabel}`}
              emptyText={
                tileVersionsQuery.isLoading
                  ? "Loading versions…"
                  : "No versions yet."
              }
              items={tileVersionItems(tileVersions)}
              selectedId={tileVersionSelectedId}
              onSelectVersion={setTileVersionSelectedId}
              onClose={() => {
                setVersionHistoryTarget(null);
                setTileVersionSelectedId(null);
              }}
              onRestore={(versionId) => {
                const version = tileVersions.find((v) => v.id === versionId);
                if (version)
                  restoreTileVersionMutation.mutate({ row: historyTile, version });
              }}
              restoring={restoreTileVersionMutation.isPending}
              restoreDisabledReason={
                historyTile.status === "pending" ||
                historyTile.status === "generating"
                  ? "This tile is still rendering — restore when it finishes."
                  : null
              }
            />
          ) : (
            <KvVersionHistoryPanel
              open={versionHistoryTarget?.kind === "board"}
              title="Version History"
              emptyText="No versions yet. Generate a KV first."
              items={boardVersionItems(versionHistoryGenerations)}
              selectedId={viewingGenerationId}
              onSelectVersion={setViewingGenerationId}
              onClose={() => {
                setVersionHistoryTarget(null);
                setViewingGenerationId(null);
              }}
              onRestore={(generationId) =>
                restoreGenerationMutation.mutate(generationId)
              }
              restoring={restoreGenerationMutation.isPending}
            />
          )}
```

- [ ] **Step 5: Canvas wiring.** On `<KvCanvas`: `onOpenTileVersionHistory={handleOpenTileVersionHistory}` and `tileImageOverride={tileImageOverride}`.

- [ ] **Step 6: Imports.** `VersionHistoryTarget, resolveVersionHistoryTarget, tilePreviewFor, tileVersionItems, boardVersionItems` from `@/lib/studio/kv/versionHistoryItems`; `useResizeExportVersions, resizeExportVersionsQueryKey` from `@/lib/studio/kv/useResizeExportVersions`; `restoreResizeExportVersion` from `@/services/kv/api`; `KvResizeExportVersion` type; the two track functions.

- [ ] **Step 7: Gates + build** — tsc ≤ baseline; eslint layout = 13 warnings (no new; if an effect dep warning changes wording, fix the deps); the pure tests of Tasks 1–3 and 7; `node ./node_modules/next/dist/bin/next build` exit 0.
- [ ] **Step 8: Commit** — `git commit -m "feat(web): tile Version History — open from the tile, preview on it, restore"`

---

### Task 9: Track file + push

- [ ] **Step 1:** Append a session-log entry to `docs/tracks/kv-craft-resize-strip.track.md` (spec/plans, what changed, events — taxonomy rows pending, gates) and this checklist:

```
## Manual checklist — tile version history (needs `php artisan migrate`)
- [ ] Existing tile shows the clock icon; history lists "Version 1 · Created"
- [ ] Regenerate with a prompt → tile keeps its image while rendering; history gains "Regenerated · <prompt>"
- [ ] Region edit → "Region edit · <box prompts>"
- [ ] Pick an older version → only that tile shows it; close → back to current
- [ ] Restore → new "Restored from vN" on top, tile shows that image, layers unchanged
- [ ] Restore while rendering → disabled with the reason
- [ ] Regenerate then Cancel → tile keeps its image (no delete); failed render → image + Retry/Discard; Discard keeps the image
- [ ] Cancel a brand-new tile's first render → tile removed (as before)
- [ ] Upscale after a regenerate → upscales the new image
- [ ] Board Version History still works; opening a tile's history closes it and vice versa
- [ ] ↺ on a detached tile resets to master
```
- [ ] **Step 2:** commit `docs(web): track — tile version history`, then `git push origin feature/daffa/vc-kv-craft-resize-strip`.
