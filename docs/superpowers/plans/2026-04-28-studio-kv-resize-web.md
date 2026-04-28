# KV Generator — Resize Mode (Web) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the web layer of KV Resize: Platform picker (left rail), stacked result canvas, crop-adjust modal, SSE-driven live updates, and integration into `KvGeneratorLayout`. Spec: [`docs/superpowers/specs/2026-04-28-studio-kv-resize-design.md`](../specs/2026-04-28-studio-kv-resize-design.md).

**Architecture:** New `KvResizePanel` (left rail) + `KvResizeCanvas` (stacked rows) replace the layers panel + KvCanvas when `canvasMode === 'resize'`. State lives in a Zustand store (`useKvResizeStore`) keyed by `platform_id`. SSE delivers row updates; optimistic insert on POST. Crop math is pure (`cropMath.ts`) and unit-tested. Reuses existing `BaseModal` and frndos icon set.

**Tech Stack:** Next.js 16, React 19, TypeScript, Tailwind, Zustand, TanStack Query v5, EventSource API, vitest + @testing-library/react.

**Branch:** `feature/daffa/vc-studio-projects-kv-generator` (extension of in-flight feature; no new branch).

---

## File Structure

**New files:**
- `web/src/types/kv/resize.ts`
- `web/src/lib/studio/kv/resizePlatforms.ts`
- `web/src/lib/studio/kv/cropMath.ts`
- `web/src/lib/studio/kv/cropMath.test.ts`
- `web/src/lib/studio/kv/useResizeExports.ts`
- `web/src/lib/studio/kv/useResizeExports.test.ts`
- `web/src/services/kv/resize-stream.ts`
- `web/src/services/kv/resize-stream.test.ts`
- `web/src/store/kv/useKvResizeStore.ts`
- `web/src/components/studio/kv-generator/KvResizePanel.tsx`
- `web/src/components/studio/kv-generator/KvResizePanel.test.tsx`
- `web/src/components/studio/kv-generator/KvResizeCanvas.tsx`
- `web/src/components/studio/kv-generator/KvResizeOriginalRow.tsx`
- `web/src/components/studio/kv-generator/KvResizeResultRow.tsx`
- `web/src/components/studio/kv-generator/KvResizeResultRow.test.tsx`
- `web/src/components/studio/kv-generator/KvResizeCropModal.tsx`
- `web/src/components/studio/kv-generator/KvResizeCropModal.test.tsx`
- `web/src/components/studio/kv-generator/KvResizeEmptyState.tsx`

**Modified files:**
- `web/src/services/kv/api.ts` — add resize-export endpoints
- `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` — branch on `canvasMode === 'resize'`
- `web/src/components/studio/kv-generator/KvCanvasBottomNav.tsx` — hide tools cluster in resize mode

---

## Task 1: Types

**Files:**
- Create: `web/src/types/kv/resize.ts`

- [ ] **Step 1: Write the types**

```typescript
// web/src/types/kv/resize.ts
export type PlatformGroup = "social-media" | "print";

export type PlatformId =
  | "instagram-post"
  | "instagram-story"
  | "instagram-landscape"
  | "facebook-post"
  | "facebook-cover"
  | "tiktok-video"
  | "youtube-thumbnail"
  | "linkedin-post"
  | "twitter-post"
  | "a4-portrait"
  | "a4-landscape"
  | "square-poster";

export type Platform = {
  id: PlatformId;
  label: string;
  group: PlatformGroup;
  width: number;
  height: number;
  note?: string;
};

export type CropWindow = { x: number; y: number; w: number; h: number };

export type KvResizeExportStatus = "pending" | "generating" | "done" | "failed";

export type KvResizeExport = {
  id: string;
  studioFileId: string;
  parentGenerationId: string;
  platformId: PlatformId;
  platformLabel: string;
  platformGroup: PlatformGroup;
  width: number;
  height: number;
  imageUrl: string | null;
  status: KvResizeExportStatus;
  cropWindow: CropWindow | null;
  errorMessage: string | null;
  createdAt: string;
  updatedAt: string;
};

export const PLATFORMS: readonly Platform[] = [
  { id: "instagram-post", label: "Instagram Post", group: "social-media", width: 1080, height: 1080 },
  { id: "instagram-story", label: "Instagram Story / Reel", group: "social-media", width: 1080, height: 1920 },
  { id: "instagram-landscape", label: "Instagram Landscape", group: "social-media", width: 1080, height: 566 },
  { id: "facebook-post", label: "Facebook Post", group: "social-media", width: 1200, height: 630 },
  { id: "facebook-cover", label: "Facebook Cover", group: "social-media", width: 820, height: 360 },
  { id: "tiktok-video", label: "TikTok Video", group: "social-media", width: 1080, height: 1920 },
  { id: "youtube-thumbnail", label: "YouTube Thumbnail", group: "social-media", width: 1280, height: 720 },
  { id: "linkedin-post", label: "LinkedIn Post", group: "social-media", width: 1200, height: 627 },
  { id: "twitter-post", label: "X / Twitter Post", group: "social-media", width: 1200, height: 675 },
  { id: "a4-portrait", label: "A4 Portrait", group: "print", width: 1240, height: 1754, note: "Preview quality" },
  { id: "a4-landscape", label: "A4 Landscape", group: "print", width: 1754, height: 1240, note: "Preview quality" },
  { id: "square-poster", label: "Square Poster", group: "print", width: 1200, height: 1200 },
];
```

- [ ] **Step 2: Commit**

```bash
git add web/src/types/kv/resize.ts
git commit -m "feat(web): add KV resize types and platform registry"
```

---

## Task 2: Platform helpers

**Files:**
- Create: `web/src/lib/studio/kv/resizePlatforms.ts`

- [ ] **Step 1: Write helpers**

```typescript
// web/src/lib/studio/kv/resizePlatforms.ts
import type { Platform, PlatformGroup, PlatformId } from "@/types/kv/resize";
import { PLATFORMS } from "@/types/kv/resize";

export function platformsByGroup(): Record<PlatformGroup, Platform[]> {
  return {
    "social-media": PLATFORMS.filter((p) => p.group === "social-media"),
    print: PLATFORMS.filter((p) => p.group === "print"),
  };
}

export function platformById(id: PlatformId): Platform | undefined {
  return PLATFORMS.find((p) => p.id === id);
}

export const GROUP_LABEL: Record<PlatformGroup, string> = {
  "social-media": "Social Media",
  print: "Print",
};
```

- [ ] **Step 2: Commit**

```bash
git add web/src/lib/studio/kv/resizePlatforms.ts
git commit -m "feat(web): add platform grouping helpers"
```

---

## Task 3: Crop math — write failing tests

**Files:**
- Create: `web/src/lib/studio/kv/cropMath.test.ts`

- [ ] **Step 1: Write the failing tests**

```typescript
// web/src/lib/studio/kv/cropMath.test.ts
import { describe, expect, it } from "vitest";
import { centerCropWindow, fitInsideTarget } from "./cropMath";

describe("centerCropWindow", () => {
  it("crops the source horizontally when source is wider than target", () => {
    // 1920×1080 source, 1080×1080 target → height-fit, crop horizontally
    const cw = centerCropWindow(1920, 1080, 1080, 1080);
    expect(cw).toEqual({ x: 420, y: 0, w: 1080, h: 1080 });
  });

  it("crops vertically when source is taller than target ratio", () => {
    // 1080×1920 source, 1080×566 target
    const cw = centerCropWindow(1080, 1920, 1080, 566);
    expect(cw.x).toBe(0);
    expect(cw.w).toBe(1080);
    expect(cw.h).toBe(Math.round(1080 / (1080 / 566)));
  });

  it("returns full source when source fits inside target on both axes", () => {
    const cw = centerCropWindow(800, 600, 1080, 1080);
    expect(cw).toEqual({ x: 0, y: 0, w: 800, h: 600 });
  });
});

describe("fitInsideTarget", () => {
  it("centers source on transparent canvas when source fits inside target", () => {
    const fit = fitInsideTarget(800, 600, 1080, 1080);
    expect(fit.paste).toEqual({ x: 140, y: 240, w: 800, h: 600 });
    expect(fit.pad).toEqual({ top: 240, right: 140, bottom: 240, left: 140 });
  });

  it("scales source down to fit when source is larger on either axis", () => {
    // 2000×1500 source, 1080×1080 target — source doesn't fit on width.
    const fit = fitInsideTarget(2000, 1500, 1080, 1080);
    expect(fit.paste.w).toBeLessThanOrEqual(1080);
    expect(fit.paste.h).toBeLessThanOrEqual(1080);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd web && bun test src/lib/studio/kv/cropMath.test.ts
```

Expected: FAIL — module does not exist.

---

## Task 4: Crop math — implement

**Files:**
- Create: `web/src/lib/studio/kv/cropMath.ts`

- [ ] **Step 1: Implement**

```typescript
// web/src/lib/studio/kv/cropMath.ts
import type { CropWindow } from "@/types/kv/resize";

export function centerCropWindow(
  srcW: number,
  srcH: number,
  targetW: number,
  targetH: number,
): CropWindow {
  if (srcW <= targetW && srcH <= targetH) {
    return { x: 0, y: 0, w: srcW, h: srcH };
  }
  const srcAspect = srcW / srcH;
  const targetAspect = targetW / targetH;

  if (srcAspect >= targetAspect) {
    const newH = srcH;
    const newW = Math.round(srcH * targetAspect);
    return { x: Math.floor((srcW - newW) / 2), y: 0, w: newW, h: newH };
  }
  const newW = srcW;
  const newH = Math.round(srcW / targetAspect);
  return { x: 0, y: Math.floor((srcH - newH) / 2), w: newW, h: newH };
}

type Fit = {
  paste: { x: number; y: number; w: number; h: number };
  pad: { top: number; right: number; bottom: number; left: number };
};

export function fitInsideTarget(
  srcW: number,
  srcH: number,
  targetW: number,
  targetH: number,
): Fit {
  let pasteW = srcW;
  let pasteH = srcH;

  if (srcW > targetW || srcH > targetH) {
    const scale = Math.min(targetW / srcW, targetH / srcH);
    pasteW = Math.floor(srcW * scale);
    pasteH = Math.floor(srcH * scale);
  }

  const x = Math.floor((targetW - pasteW) / 2);
  const y = Math.floor((targetH - pasteH) / 2);

  return {
    paste: { x, y, w: pasteW, h: pasteH },
    pad: {
      top: y,
      right: targetW - pasteW - x,
      bottom: targetH - pasteH - y,
      left: x,
    },
  };
}
```

- [ ] **Step 2: Run tests**

```bash
cd web && bun test src/lib/studio/kv/cropMath.test.ts
```

Expected: 5 tests pass.

- [ ] **Step 3: Commit**

```bash
git add web/src/lib/studio/kv/cropMath.ts web/src/lib/studio/kv/cropMath.test.ts
git commit -m "feat(web): add cropMath helpers for resize"
```

---

## Task 5: API client

**Files:**
- Modify: `web/src/services/kv/api.ts`

- [ ] **Step 1: Add resize-export endpoints**

Append to `web/src/services/kv/api.ts` (adjust import paths to match existing patterns in that file):

```typescript
import type {
  CropWindow,
  KvResizeExport,
  PlatformId,
} from "@/types/kv/resize";

// ... existing imports

type WireExport = {
  id: string;
  studio_file_id: string;
  parent_generation_id: string;
  platform_id: PlatformId;
  platform_label: string;
  platform_group: "social-media" | "print";
  width: number;
  height: number;
  image_url: string | null;
  status: "pending" | "generating" | "done" | "failed";
  crop_window: CropWindow | null;
  error_message: string | null;
  created_at: string;
  updated_at: string;
};

function toExport(w: WireExport): KvResizeExport {
  return {
    id: w.id,
    studioFileId: w.studio_file_id,
    parentGenerationId: w.parent_generation_id,
    platformId: w.platform_id,
    platformLabel: w.platform_label,
    platformGroup: w.platform_group,
    width: w.width,
    height: w.height,
    imageUrl: w.image_url,
    status: w.status,
    cropWindow: w.crop_window,
    errorMessage: w.error_message,
    createdAt: w.created_at,
    updatedAt: w.updated_at,
  };
}

export async function listResizeExports(fileId: string): Promise<KvResizeExport[]> {
  const resp = await fetch(`/api/studio/files/${fileId}/resize-exports`, {
    credentials: "include",
  });
  if (!resp.ok) throw new Error(`listResizeExports failed: ${resp.status}`);
  const json = (await resp.json()) as { data: WireExport[] };
  return json.data.map(toExport);
}

export async function createResizeExports(
  fileId: string,
  body: {
    parentGenerationId: string;
    platformIds: PlatformId[];
    cropWindows?: Partial<Record<PlatformId, CropWindow>>;
  },
): Promise<KvResizeExport[]> {
  const resp = await fetch(`/api/studio/files/${fileId}/resize-exports`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      parent_generation_id: body.parentGenerationId,
      platform_ids: body.platformIds,
      crop_windows: body.cropWindows,
    }),
  });
  if (resp.status === 409) throw new Error("STALE_PARENT");
  if (!resp.ok) throw new Error(`createResizeExports failed: ${resp.status}`);
  const json = (await resp.json()) as { data: WireExport[] };
  return json.data.map(toExport);
}

export async function regenerateResizeExport(
  fileId: string,
  exportId: string,
  cropWindow?: CropWindow,
): Promise<KvResizeExport> {
  const resp = await fetch(
    `/api/studio/files/${fileId}/resize-exports/${exportId}/regenerate`,
    {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ crop_window: cropWindow ?? null }),
    },
  );
  if (!resp.ok) throw new Error(`regenerate failed: ${resp.status}`);
  const json = (await resp.json()) as { data: WireExport };
  return toExport(json.data);
}

export async function deleteResizeExport(
  fileId: string,
  exportId: string,
): Promise<void> {
  const resp = await fetch(
    `/api/studio/files/${fileId}/resize-exports/${exportId}`,
    { method: "DELETE", credentials: "include" },
  );
  if (!resp.ok) throw new Error(`delete failed: ${resp.status}`);
}
```

- [ ] **Step 2: Commit**

```bash
git add web/src/services/kv/api.ts
git commit -m "feat(web): add resize-export API client methods"
```

---

## Task 6: SSE stream client

**Files:**
- Create: `web/src/services/kv/resize-stream.ts`
- Create: `web/src/services/kv/resize-stream.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// web/src/services/kv/resize-stream.test.ts
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { connectResizeStream } from "./resize-stream";

class FakeEventSource {
  static instances: FakeEventSource[] = [];
  url: string;
  listeners: Record<string, ((evt: MessageEvent) => void)[]> = {};
  closed = false;
  constructor(url: string) {
    this.url = url;
    FakeEventSource.instances.push(this);
  }
  addEventListener(event: string, cb: (evt: MessageEvent) => void) {
    (this.listeners[event] ||= []).push(cb);
  }
  emit(event: string, data: unknown) {
    const evt = { data: JSON.stringify(data) } as MessageEvent;
    (this.listeners[event] || []).forEach((cb) => cb(evt));
  }
  close() {
    this.closed = true;
  }
}

describe("connectResizeStream", () => {
  beforeEach(() => {
    FakeEventSource.instances = [];
    (globalThis as any).EventSource = FakeEventSource;
  });
  afterEach(() => {
    delete (globalThis as any).EventSource;
  });

  it("forwards export.updated events to onUpdate", () => {
    const onUpdate = vi.fn();
    connectResizeStream("file-1", onUpdate);

    const es = FakeEventSource.instances[0];
    es.emit("export.updated", {
      id: "x1",
      studio_file_id: "file-1",
      parent_generation_id: "g1",
      platform_id: "tiktok-video",
      platform_label: "TikTok Video",
      platform_group: "social-media",
      width: 1080,
      height: 1920,
      image_url: null,
      status: "generating",
      crop_window: null,
      error_message: null,
      created_at: "2026-04-28T00:00:00Z",
      updated_at: "2026-04-28T00:00:01Z",
    });

    expect(onUpdate).toHaveBeenCalledOnce();
    expect(onUpdate.mock.calls[0][0].platformId).toBe("tiktok-video");
    expect(onUpdate.mock.calls[0][0].status).toBe("generating");
  });

  it("close() shuts down the EventSource", () => {
    const handle = connectResizeStream("file-1", vi.fn());
    handle.close();
    expect(FakeEventSource.instances[0].closed).toBe(true);
  });
});
```

- [ ] **Step 2: Implement**

```typescript
// web/src/services/kv/resize-stream.ts
import type { KvResizeExport } from "@/types/kv/resize";

export type ResizeStreamHandle = { close: () => void };

export function connectResizeStream(
  fileId: string,
  onUpdate: (row: KvResizeExport) => void,
): ResizeStreamHandle {
  const es = new EventSource(
    `/api/studio/files/${fileId}/resize-exports/stream`,
    { withCredentials: true },
  );

  es.addEventListener("export.updated", (evt) => {
    const wire = JSON.parse((evt as MessageEvent).data);
    onUpdate({
      id: wire.id,
      studioFileId: wire.studio_file_id,
      parentGenerationId: wire.parent_generation_id,
      platformId: wire.platform_id,
      platformLabel: wire.platform_label,
      platformGroup: wire.platform_group,
      width: wire.width,
      height: wire.height,
      imageUrl: wire.image_url,
      status: wire.status,
      cropWindow: wire.crop_window,
      errorMessage: wire.error_message,
      createdAt: wire.created_at,
      updatedAt: wire.updated_at,
    });
  });

  return {
    close: () => es.close(),
  };
}
```

- [ ] **Step 3: Run tests + commit**

```bash
cd web && bun test src/services/kv/resize-stream.test.ts
```

Expected: 2 tests pass.

```bash
git add web/src/services/kv/resize-stream.ts web/src/services/kv/resize-stream.test.ts
git commit -m "feat(web): add SSE client for resize export updates"
```

---

## Task 7: Zustand store

**Files:**
- Create: `web/src/store/kv/useKvResizeStore.ts`

- [ ] **Step 1: Implement the store**

```typescript
// web/src/store/kv/useKvResizeStore.ts
import { create } from "zustand";
import type { KvResizeExport, PlatformId } from "@/types/kv/resize";

type State = {
  selectedPlatformIds: Set<PlatformId>;
  exportsByPlatformId: Map<PlatformId, KvResizeExport>;
  togglePlatform: (id: PlatformId) => void;
  clearSelection: () => void;
  setExports: (rows: KvResizeExport[]) => void;
  applyServerEvent: (row: KvResizeExport) => void;
  resetForNewSource: () => void;
};

export const useKvResizeStore = create<State>((set) => ({
  selectedPlatformIds: new Set(),
  exportsByPlatformId: new Map(),

  togglePlatform: (id) =>
    set((s) => {
      const next = new Set(s.selectedPlatformIds);
      next.has(id) ? next.delete(id) : next.add(id);
      return { selectedPlatformIds: next };
    }),

  clearSelection: () => set({ selectedPlatformIds: new Set() }),

  setExports: (rows) =>
    set(() => {
      const map = new Map<PlatformId, KvResizeExport>();
      rows.forEach((r) => map.set(r.platformId, r));
      return { exportsByPlatformId: map };
    }),

  applyServerEvent: (row) =>
    set((s) => {
      const next = new Map(s.exportsByPlatformId);
      next.set(row.platformId, row);
      return { exportsByPlatformId: next };
    }),

  resetForNewSource: () =>
    set({
      selectedPlatformIds: new Set(),
      exportsByPlatformId: new Map(),
    }),
}));
```

- [ ] **Step 2: Commit**

```bash
git add web/src/store/kv/useKvResizeStore.ts
git commit -m "feat(web): add useKvResizeStore"
```

---

## Task 8: useResizeExports hook

**Files:**
- Create: `web/src/lib/studio/kv/useResizeExports.ts`

- [ ] **Step 1: Implement**

```typescript
// web/src/lib/studio/kv/useResizeExports.ts
import { useEffect } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import {
  createResizeExports,
  deleteResizeExport,
  listResizeExports,
  regenerateResizeExport,
} from "@/services/kv/api";
import { connectResizeStream } from "@/services/kv/resize-stream";
import { useKvResizeStore } from "@/store/kv/useKvResizeStore";
import type { CropWindow, KvResizeExport, PlatformId } from "@/types/kv/resize";

const QUERY_KEY = (fileId: string) => ["kv-resize-exports", fileId];

export function useResizeExports(fileId: string, parentGenerationId: string | null) {
  const qc = useQueryClient();
  const setExports = useKvResizeStore((s) => s.setExports);
  const applyServerEvent = useKvResizeStore((s) => s.applyServerEvent);

  const query = useQuery({
    queryKey: QUERY_KEY(fileId),
    queryFn: () => listResizeExports(fileId),
    enabled: Boolean(fileId),
  });

  useEffect(() => {
    if (query.data) setExports(query.data);
  }, [query.data, setExports]);

  // SSE subscription — opened only when we have at least one in-flight row.
  useEffect(() => {
    const inFlight = (query.data ?? []).some(
      (r) => r.status === "pending" || r.status === "generating",
    );
    if (!inFlight) return;

    const handle = connectResizeStream(fileId, (row) => {
      applyServerEvent(row);
      qc.setQueryData<KvResizeExport[]>(QUERY_KEY(fileId), (prev) => {
        if (!prev) return [row];
        const idx = prev.findIndex((p) => p.id === row.id);
        if (idx === -1) return [...prev, row];
        const copy = [...prev];
        copy[idx] = row;
        return copy;
      });
    });
    return () => handle.close();
  }, [fileId, query.data, applyServerEvent, qc]);

  const create = useMutation({
    mutationFn: (vars: {
      platformIds: PlatformId[];
      cropWindows?: Partial<Record<PlatformId, CropWindow>>;
    }) => {
      if (!parentGenerationId) throw new Error("No parent generation");
      return createResizeExports(fileId, {
        parentGenerationId,
        platformIds: vars.platformIds,
        cropWindows: vars.cropWindows,
      });
    },
    onSuccess: (rows) => {
      qc.setQueryData<KvResizeExport[]>(QUERY_KEY(fileId), (prev) => {
        const map = new Map((prev ?? []).map((r) => [r.id, r]));
        rows.forEach((r) => map.set(r.id, r));
        return Array.from(map.values());
      });
    },
  });

  const regenerate = useMutation({
    mutationFn: (vars: { exportId: string; cropWindow?: CropWindow }) =>
      regenerateResizeExport(fileId, vars.exportId, vars.cropWindow),
    onSuccess: (row) => {
      qc.setQueryData<KvResizeExport[]>(QUERY_KEY(fileId), (prev) =>
        (prev ?? []).map((r) => (r.id === row.id ? row : r)),
      );
    },
  });

  const remove = useMutation({
    mutationFn: (exportId: string) => deleteResizeExport(fileId, exportId),
    onSuccess: (_v, exportId) => {
      qc.setQueryData<KvResizeExport[]>(QUERY_KEY(fileId), (prev) =>
        (prev ?? []).filter((r) => r.id !== exportId),
      );
    },
  });

  return { query, create, regenerate, remove };
}
```

- [ ] **Step 2: Commit**

```bash
git add web/src/lib/studio/kv/useResizeExports.ts
git commit -m "feat(web): add useResizeExports hook with SSE wiring"
```

---

## Task 9: Empty state component

**Files:**
- Create: `web/src/components/studio/kv-generator/KvResizeEmptyState.tsx`

- [ ] **Step 1: Implement**

```tsx
// web/src/components/studio/kv-generator/KvResizeEmptyState.tsx
"use client";

export function KvResizeEmptyState() {
  return (
    <div className="flex h-full w-full flex-col items-center justify-center px-8 text-center">
      <p className="font-geist text-textSmMedium font-medium leading-[1.4] tracking-[-0.14px] text-text-inverse-subtlest">
        Generate a KV first to enable Resize
      </p>
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add web/src/components/studio/kv-generator/KvResizeEmptyState.tsx
git commit -m "feat(web): add KvResizeEmptyState"
```

---

## Task 10: Resize panel — write failing test

**Files:**
- Create: `web/src/components/studio/kv-generator/KvResizePanel.test.tsx`

- [ ] **Step 1: Write the failing test**

```tsx
import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { KvResizePanel } from "./KvResizePanel";

describe("KvResizePanel", () => {
  it("renders both groups with platforms", () => {
    render(
      <KvResizePanel
        disabled={false}
        selectedIds={new Set()}
        onToggle={() => {}}
        onResize={() => {}}
      />,
    );
    expect(screen.getByText("Social Media")).toBeInTheDocument();
    expect(screen.getByText("Instagram Post")).toBeInTheDocument();
  });

  it("disables CTA when no selection", () => {
    render(
      <KvResizePanel
        disabled={false}
        selectedIds={new Set()}
        onToggle={() => {}}
        onResize={() => {}}
      />,
    );
    const cta = screen.getByRole("button", { name: /Resize · 0 selected/i });
    expect(cta).toBeDisabled();
  });

  it("enables CTA and calls onResize when clicked", () => {
    const onResize = vi.fn();
    render(
      <KvResizePanel
        disabled={false}
        selectedIds={new Set(["instagram-post", "tiktok-video"])}
        onToggle={() => {}}
        onResize={onResize}
      />,
    );
    const cta = screen.getByRole("button", { name: /Resize · 2 selected/i });
    expect(cta).not.toBeDisabled();
    fireEvent.click(cta);
    expect(onResize).toHaveBeenCalledOnce();
  });

  it("toggles a platform on checkbox click", () => {
    const onToggle = vi.fn();
    render(
      <KvResizePanel
        disabled={false}
        selectedIds={new Set()}
        onToggle={onToggle}
        onResize={() => {}}
      />,
    );
    fireEvent.click(screen.getByLabelText("Instagram Post"));
    expect(onToggle).toHaveBeenCalledWith("instagram-post");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizePanel.test.tsx
```

Expected: FAIL — component does not exist.

---

## Task 11: Resize panel — implement

**Files:**
- Create: `web/src/components/studio/kv-generator/KvResizePanel.tsx`

- [ ] **Step 1: Implement**

```tsx
// web/src/components/studio/kv-generator/KvResizePanel.tsx
"use client";

import { useState } from "react";
import { CaretDown, CaretRight } from "@phosphor-icons/react";

import { Checkbox } from "@/components/frndos/Checkbox";
import { Button } from "@/components/frndos/Button";
import { GROUP_LABEL, platformsByGroup } from "@/lib/studio/kv/resizePlatforms";
import type { Platform, PlatformGroup, PlatformId } from "@/types/kv/resize";

type Props = {
  disabled: boolean;
  selectedIds: Set<PlatformId>;
  onToggle: (id: PlatformId) => void;
  onResize: () => void;
};

export function KvResizePanel({ disabled, selectedIds, onToggle, onResize }: Props) {
  const groups = platformsByGroup();
  const [openGroups, setOpenGroups] = useState<Record<PlatformGroup, boolean>>({
    "social-media": true,
    print: false,
  });

  const count = selectedIds.size;

  return (
    <aside className="flex h-full w-[232px] flex-col border-r border-[rgba(255,255,255,0.05)] bg-[rgba(255,255,255,0.02)] backdrop-blur-[12px]">
      <div className="px-4 py-4">
        <p className="font-geist text-textSmMedium font-medium tracking-[-0.14px] text-text-inverse">
          Platform
        </p>
      </div>

      <div className="flex-1 overflow-y-auto px-2">
        {(["social-media", "print"] as PlatformGroup[]).map((group) => (
          <Group
            key={group}
            group={group}
            platforms={groups[group]}
            open={openGroups[group]}
            onToggleOpen={() =>
              setOpenGroups((g) => ({ ...g, [group]: !g[group] }))
            }
            selectedIds={selectedIds}
            onTogglePlatform={onToggle}
          />
        ))}
      </div>

      <div className="border-t border-[rgba(255,255,255,0.05)] p-4">
        <Button
          onClick={onResize}
          disabled={disabled || count === 0}
          className="w-full"
        >
          Resize · {count} selected
        </Button>
      </div>
    </aside>
  );
}

function Group({
  group,
  platforms,
  open,
  onToggleOpen,
  selectedIds,
  onTogglePlatform,
}: {
  group: PlatformGroup;
  platforms: Platform[];
  open: boolean;
  onToggleOpen: () => void;
  selectedIds: Set<PlatformId>;
  onTogglePlatform: (id: PlatformId) => void;
}) {
  return (
    <div className="mb-2">
      <button
        type="button"
        onClick={onToggleOpen}
        className="flex w-full items-center justify-between rounded-md px-2 py-2 hover:bg-[rgba(255,255,255,0.04)]"
      >
        <span className="font-geist text-textSmMedium font-medium tracking-[-0.14px] text-text-inverse">
          {GROUP_LABEL[group]}
        </span>
        {open ? (
          <CaretDown size={16} className="text-text-inverse-subtlest" />
        ) : (
          <CaretRight size={16} className="text-text-inverse-subtlest" />
        )}
      </button>
      {open && (
        <ul className="mt-1 flex flex-col">
          {platforms.map((p) => (
            <li key={p.id}>
              <label
                aria-label={p.label}
                className="flex cursor-pointer items-start gap-3 rounded-md px-2 py-2 hover:bg-[rgba(255,255,255,0.04)]"
              >
                <Checkbox
                  checked={selectedIds.has(p.id)}
                  onChange={() => onTogglePlatform(p.id)}
                />
                <div className="flex flex-col">
                  <span className="font-geist text-[14px] leading-[1.4] text-text-inverse">
                    {p.label}
                  </span>
                  <span className="font-geist text-textXs leading-[1.4] text-text-inverse-subtlest">
                    {p.width} × {p.height} px
                    {p.note ? ` · ${p.note}` : ""}
                  </span>
                </div>
              </label>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
```

- [ ] **Step 2: Run tests**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizePanel.test.tsx
```

Expected: 4 tests pass.

- [ ] **Step 3: Commit**

```bash
git add web/src/components/studio/kv-generator/KvResizePanel.tsx \
        web/src/components/studio/kv-generator/KvResizePanel.test.tsx
git commit -m "feat(web): add KvResizePanel with platform groups and CTA"
```

---

## Task 12: Original row + Result row + Crop modal

**Files:**
- Create: `web/src/components/studio/kv-generator/KvResizeOriginalRow.tsx`
- Create: `web/src/components/studio/kv-generator/KvResizeResultRow.tsx`
- Create: `web/src/components/studio/kv-generator/KvResizeResultRow.test.tsx`
- Create: `web/src/components/studio/kv-generator/KvResizeCropModal.tsx`
- Create: `web/src/components/studio/kv-generator/KvResizeCropModal.test.tsx`

- [ ] **Step 1: Original row**

```tsx
// web/src/components/studio/kv-generator/KvResizeOriginalRow.tsx
"use client";

import { DownloadSimple } from "@phosphor-icons/react";

type Props = {
  imageUrl: string;
  width: number;
  height: number;
  onDownload: () => void;
};

export function KvResizeOriginalRow({ imageUrl, width, height, onDownload }: Props) {
  return (
    <div className="mx-auto flex w-full max-w-[800px] flex-col gap-2 px-6 py-6">
      <div className="flex items-center justify-between">
        <p className="font-geist text-textSm leading-[1.4] text-text-inverse">
          <span className="text-text-inverse">Original</span>
          <span className="text-text-inverse-subtlest"> · {width} × {height} px</span>
        </p>
        <button
          type="button"
          onClick={onDownload}
          aria-label="Download original"
          className="flex h-6 w-6 items-center justify-center rounded-md hover:bg-[rgba(255,255,255,0.05)]"
        >
          <DownloadSimple size={16} className="text-text-inverse-subtlest" />
        </button>
      </div>
      <img
        src={imageUrl}
        alt="Original generation"
        className="w-full rounded-md"
        style={{ aspectRatio: `${width} / ${height}` }}
      />
    </div>
  );
}
```

- [ ] **Step 2: Result row test**

```tsx
// web/src/components/studio/kv-generator/KvResizeResultRow.test.tsx
import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { KvResizeResultRow } from "./KvResizeResultRow";

const baseRow = {
  id: "x1",
  studioFileId: "f1",
  parentGenerationId: "g1",
  platformId: "tiktok-video" as const,
  platformLabel: "TikTok Video",
  platformGroup: "social-media" as const,
  width: 1080,
  height: 1920,
  imageUrl: null,
  status: "pending" as const,
  cropWindow: null,
  errorMessage: null,
  createdAt: "2026-04-28T00:00:00Z",
  updatedAt: "2026-04-28T00:00:00Z",
};

describe("KvResizeResultRow", () => {
  it("renders skeleton in pending state", () => {
    render(
      <KvResizeResultRow
        row={baseRow}
        onDownload={() => {}}
        onAdjustCrop={() => {}}
      />,
    );
    expect(screen.getByText(/TikTok Video/)).toBeInTheDocument();
    expect(screen.getByLabelText("Generating skeleton")).toBeInTheDocument();
  });

  it("renders image and action buttons in done state", () => {
    const onDownload = vi.fn();
    render(
      <KvResizeResultRow
        row={{ ...baseRow, status: "done", imageUrl: "https://x/y.png" }}
        onDownload={onDownload}
        onAdjustCrop={() => {}}
      />,
    );
    expect(screen.getByRole("img")).toHaveAttribute("src", "https://x/y.png");
    fireEvent.click(screen.getByLabelText("Download"));
    expect(onDownload).toHaveBeenCalledOnce();
  });

  it("renders Retry in failed state", () => {
    const onAdjustCrop = vi.fn();
    render(
      <KvResizeResultRow
        row={{ ...baseRow, status: "failed", errorMessage: "boom" }}
        onDownload={() => {}}
        onAdjustCrop={onAdjustCrop}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /Retry/i }));
    expect(onAdjustCrop).toHaveBeenCalledOnce();
  });
});
```

- [ ] **Step 3: Result row implementation**

```tsx
// web/src/components/studio/kv-generator/KvResizeResultRow.tsx
"use client";

import { ArrowsClockwise, DownloadSimple, Crop } from "@phosphor-icons/react";

import type { KvResizeExport } from "@/types/kv/resize";

type Props = {
  row: KvResizeExport;
  onDownload: () => void;
  onAdjustCrop: () => void;
};

export function KvResizeResultRow({ row, onDownload, onAdjustCrop }: Props) {
  return (
    <div className="mx-auto flex w-full max-w-[800px] flex-col gap-2 px-6 py-4">
      <div className="flex items-center justify-between">
        <p className="font-geist text-textSm leading-[1.4]">
          <span className="text-text-inverse">{row.platformLabel}</span>
          <span className="text-text-inverse-subtlest"> · {row.width} × {row.height} px</span>
        </p>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={onDownload}
            disabled={row.status !== "done"}
            aria-label="Download"
            className="flex h-6 w-6 items-center justify-center rounded-md hover:bg-[rgba(255,255,255,0.05)] disabled:opacity-30"
          >
            <DownloadSimple size={16} className="text-text-inverse-subtlest" />
          </button>
          <button
            type="button"
            onClick={onAdjustCrop}
            aria-label="Adjust crop and regenerate"
            className="flex h-6 w-6 items-center justify-center rounded-md hover:bg-[rgba(255,255,255,0.05)]"
          >
            <ArrowsClockwise size={16} className="text-text-inverse-subtlest" />
          </button>
        </div>
      </div>

      {row.status === "pending" || row.status === "generating" ? (
        <div
          aria-label="Generating skeleton"
          className="w-full animate-pulse rounded-md bg-[rgba(255,255,255,0.05)]"
          style={{ aspectRatio: `${row.width} / ${row.height}` }}
        />
      ) : row.status === "done" && row.imageUrl ? (
        <img
          src={row.imageUrl}
          alt={row.platformLabel}
          className="w-full rounded-md"
          style={{ aspectRatio: `${row.width} / ${row.height}` }}
        />
      ) : (
        <div
          className="flex w-full flex-col items-center justify-center gap-2 rounded-md border border-red-500/30 bg-red-500/5 p-6"
          style={{ aspectRatio: `${row.width} / ${row.height}` }}
        >
          <p className="font-geist text-textSm text-text-inverse-subtlest">
            {row.errorMessage ?? "Generation failed"}
          </p>
          <button
            type="button"
            onClick={onAdjustCrop}
            className="rounded-md border border-[rgba(255,255,255,0.1)] px-3 py-1 font-geist text-textSm text-text-inverse hover:bg-[rgba(255,255,255,0.05)]"
          >
            Retry
          </button>
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 4: Run tests + commit (interim)**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizeResultRow.test.tsx
```

Expected: 3 tests pass.

```bash
git add web/src/components/studio/kv-generator/KvResizeOriginalRow.tsx \
        web/src/components/studio/kv-generator/KvResizeResultRow.tsx \
        web/src/components/studio/kv-generator/KvResizeResultRow.test.tsx
git commit -m "feat(web): add KvResizeOriginalRow and KvResizeResultRow"
```

- [ ] **Step 5: Crop modal test**

```tsx
// web/src/components/studio/kv-generator/KvResizeCropModal.test.tsx
import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { KvResizeCropModal } from "./KvResizeCropModal";

describe("KvResizeCropModal", () => {
  it("renders source image and confirm button", () => {
    render(
      <KvResizeCropModal
        sourceUrl="https://example.com/src.png"
        sourceWidth={1920}
        sourceHeight={1080}
        targetWidth={1080}
        targetHeight={1080}
        initialCrop={null}
        onCancel={() => {}}
        onConfirm={() => {}}
      />,
    );
    expect(screen.getByRole("img", { name: /source/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Regenerate/i })).toBeInTheDocument();
  });

  it("calls onConfirm with the crop window", () => {
    const onConfirm = vi.fn();
    render(
      <KvResizeCropModal
        sourceUrl="https://example.com/src.png"
        sourceWidth={1920}
        sourceHeight={1080}
        targetWidth={1080}
        targetHeight={1080}
        initialCrop={null}
        onCancel={() => {}}
        onConfirm={onConfirm}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /Regenerate/i }));
    expect(onConfirm).toHaveBeenCalledOnce();
    expect(onConfirm.mock.calls[0][0]).toMatchObject({
      x: expect.any(Number),
      y: expect.any(Number),
      w: expect.any(Number),
      h: expect.any(Number),
    });
  });
});
```

- [ ] **Step 6: Crop modal implementation**

```tsx
// web/src/components/studio/kv-generator/KvResizeCropModal.tsx
"use client";

import { useEffect, useRef, useState } from "react";

import { BaseModal } from "@/components/frndos/BaseModal";
import { Button } from "@/components/frndos/Button";
import { centerCropWindow } from "@/lib/studio/kv/cropMath";
import type { CropWindow } from "@/types/kv/resize";

type Props = {
  sourceUrl: string;
  sourceWidth: number;
  sourceHeight: number;
  targetWidth: number;
  targetHeight: number;
  initialCrop: CropWindow | null;
  onCancel: () => void;
  onConfirm: (crop: CropWindow) => void;
};

/**
 * Crop adjustment modal — draggable rectangle locked to the target's aspect
 * ratio. v1: drag-only, no resize. The rectangle is the largest area
 * that fits the target ratio inside the source.
 */
export function KvResizeCropModal({
  sourceUrl,
  sourceWidth,
  sourceHeight,
  targetWidth,
  targetHeight,
  initialCrop,
  onCancel,
  onConfirm,
}: Props) {
  const [crop, setCrop] = useState<CropWindow>(
    initialCrop ?? centerCropWindow(sourceWidth, sourceHeight, targetWidth, targetHeight),
  );

  const containerRef = useRef<HTMLDivElement>(null);
  const dragState = useRef<{ startX: number; startY: number; cropX: number; cropY: number } | null>(null);

  // Keep crop bounds inside source on prop changes
  useEffect(() => {
    setCrop((c) => clampCrop(c, sourceWidth, sourceHeight));
  }, [sourceWidth, sourceHeight]);

  function onPointerDown(e: React.PointerEvent) {
    dragState.current = {
      startX: e.clientX,
      startY: e.clientY,
      cropX: crop.x,
      cropY: crop.y,
    };
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
  }

  function onPointerMove(e: React.PointerEvent) {
    if (!dragState.current || !containerRef.current) return;
    const rect = containerRef.current.getBoundingClientRect();
    const scale = sourceWidth / rect.width;
    const dx = (e.clientX - dragState.current.startX) * scale;
    const dy = (e.clientY - dragState.current.startY) * scale;

    setCrop(
      clampCrop(
        {
          x: Math.round(dragState.current.cropX + dx),
          y: Math.round(dragState.current.cropY + dy),
          w: crop.w,
          h: crop.h,
        },
        sourceWidth,
        sourceHeight,
      ),
    );
  }

  function onPointerUp() {
    dragState.current = null;
  }

  return (
    <BaseModal open onClose={onCancel} title="Adjust crop">
      <div className="flex flex-col gap-4">
        <div
          ref={containerRef}
          className="relative w-full overflow-hidden rounded-md bg-black"
          style={{ aspectRatio: `${sourceWidth} / ${sourceHeight}` }}
        >
          <img
            src={sourceUrl}
            alt="Source"
            className="absolute inset-0 h-full w-full object-cover"
          />
          <div
            onPointerDown={onPointerDown}
            onPointerMove={onPointerMove}
            onPointerUp={onPointerUp}
            className="absolute cursor-move border-2 border-white shadow-[0_0_0_9999px_rgba(0,0,0,0.5)]"
            style={{
              left: `${(crop.x / sourceWidth) * 100}%`,
              top: `${(crop.y / sourceHeight) * 100}%`,
              width: `${(crop.w / sourceWidth) * 100}%`,
              height: `${(crop.h / sourceHeight) * 100}%`,
            }}
          />
        </div>

        <div className="flex justify-end gap-2">
          <Button variant="ghost" onClick={onCancel}>
            Cancel
          </Button>
          <Button onClick={() => onConfirm(crop)}>Regenerate</Button>
        </div>
      </div>
    </BaseModal>
  );
}

function clampCrop(c: CropWindow, srcW: number, srcH: number): CropWindow {
  const x = Math.max(0, Math.min(c.x, srcW - c.w));
  const y = Math.max(0, Math.min(c.y, srcH - c.h));
  return { x, y, w: c.w, h: c.h };
}
```

- [ ] **Step 7: Run tests + commit**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizeCropModal.test.tsx
```

Expected: 2 tests pass.

```bash
git add web/src/components/studio/kv-generator/KvResizeCropModal.tsx \
        web/src/components/studio/kv-generator/KvResizeCropModal.test.tsx
git commit -m "feat(web): add KvResizeCropModal"
```

---

## Task 13: Resize canvas (stacked rows wrapper)

**Files:**
- Create: `web/src/components/studio/kv-generator/KvResizeCanvas.tsx`

- [ ] **Step 1: Implement**

```tsx
// web/src/components/studio/kv-generator/KvResizeCanvas.tsx
"use client";

import { useState } from "react";

import { useResizeExports } from "@/lib/studio/kv/useResizeExports";
import { useKvResizeStore } from "@/store/kv/useKvResizeStore";
import type { CropWindow, KvResizeExport, PlatformId } from "@/types/kv/resize";
import type { KvGeneration } from "@/types/kv/generation";

import { KvResizeCropModal } from "./KvResizeCropModal";
import { KvResizeOriginalRow } from "./KvResizeOriginalRow";
import { KvResizeResultRow } from "./KvResizeResultRow";

type Props = {
  fileId: string;
  source: KvGeneration; // latest generation
};

export function KvResizeCanvas({ fileId, source }: Props) {
  const exportsByPlatformId = useKvResizeStore((s) => s.exportsByPlatformId);
  const { regenerate } = useResizeExports(fileId, source.id);

  const [cropTarget, setCropTarget] = useState<KvResizeExport | null>(null);

  const exports = Array.from(exportsByPlatformId.values()).sort(
    (a, b) => a.createdAt.localeCompare(b.createdAt),
  );

  return (
    <div className="flex h-full w-full flex-col overflow-y-auto">
      <KvResizeOriginalRow
        imageUrl={source.imageUrl}
        width={source.width}
        height={source.height}
        onDownload={() => downloadUrl(source.imageUrl, "original.png")}
      />

      {exports.map((row) => (
        <KvResizeResultRow
          key={row.id}
          row={row}
          onDownload={() =>
            row.imageUrl &&
            downloadUrl(row.imageUrl, `${row.platformId}.png`)
          }
          onAdjustCrop={() => setCropTarget(row)}
        />
      ))}

      {cropTarget && (
        <KvResizeCropModal
          sourceUrl={source.imageUrl}
          sourceWidth={source.width}
          sourceHeight={source.height}
          targetWidth={cropTarget.width}
          targetHeight={cropTarget.height}
          initialCrop={cropTarget.cropWindow}
          onCancel={() => setCropTarget(null)}
          onConfirm={(crop) => {
            regenerate.mutate({ exportId: cropTarget.id, cropWindow: crop });
            setCropTarget(null);
          }}
        />
      )}
    </div>
  );
}

function downloadUrl(url: string, filename: string) {
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
}
```

NOTE: This component imports `KvGeneration` from `@/types/kv/generation`. If that type doesn't expose `width`/`height` directly, derive them from `metadata.aspect_ratio` or extend the type. Check the existing type definition first.

- [ ] **Step 2: Commit**

```bash
git add web/src/components/studio/kv-generator/KvResizeCanvas.tsx
git commit -m "feat(web): add KvResizeCanvas wrapper"
```

---

## Task 14: Wire into KvGeneratorLayout

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx`
- Modify: `web/src/components/studio/kv-generator/KvCanvasBottomNav.tsx`

- [ ] **Step 1: Modify KvGeneratorLayout to render Resize when canvasMode === 'resize'**

Find the `canvasMode` switch in `KvGeneratorLayout.tsx`. Locate where it currently renders `KvLayersPanel` + `KvCanvas` for non-craft modes. Add a branch:

```tsx
{canvasMode === "resize" && latestGeneration ? (
  <>
    <KvResizePanel
      disabled={resizeMutation.isPending}
      selectedIds={selectedPlatformIds}
      onToggle={togglePlatform}
      onResize={() =>
        createResize.mutate({
          platformIds: Array.from(selectedPlatformIds),
        })
      }
    />
    <KvResizeCanvas fileId={fileId} source={latestGeneration} />
  </>
) : canvasMode === "resize" && !latestGeneration ? (
  <KvResizeEmptyState />
) : (
  // ...existing layers panel + canvas
)}
```

Wire the `useResizeExports` hook above the JSX:

```tsx
import { useResizeExports } from "@/lib/studio/kv/useResizeExports";
import { useKvResizeStore } from "@/store/kv/useKvResizeStore";
import { KvResizePanel } from "./KvResizePanel";
import { KvResizeCanvas } from "./KvResizeCanvas";
import { KvResizeEmptyState } from "./KvResizeEmptyState";

// inside the component:
const selectedPlatformIds = useKvResizeStore((s) => s.selectedPlatformIds);
const togglePlatform = useKvResizeStore((s) => s.togglePlatform);
const resetResize = useKvResizeStore((s) => s.resetForNewSource);
const { create: createResize } = useResizeExports(
  fileId,
  latestGeneration?.id ?? null,
);

// Reset selected platforms when the source generation id changes:
useEffect(() => {
  resetResize();
}, [latestGeneration?.id, resetResize]);
```

- [ ] **Step 2: Hide tools cluster in KvCanvasBottomNav when canvasMode === 'resize'**

In `KvCanvasBottomNav.tsx`, find the existing condition that hides tools for `canvasMode === "craft"` and add `|| canvasMode === "resize"` to the same condition. Match the existing pattern.

- [ ] **Step 3: Run the existing test suites to ensure nothing regressed**

```bash
cd web && bun test src/components/studio/kv-generator/
```

Expected: all existing tests still pass.

- [ ] **Step 4: Commit**

```bash
git add web/src/components/studio/kv-generator/KvGeneratorLayout.tsx \
        web/src/components/studio/kv-generator/KvCanvasBottomNav.tsx
git commit -m "feat(web): wire resize panel and canvas into KvGeneratorLayout"
```

---

## Task 15: End-to-end smoke test in dev

- [ ] **Step 1: Start the dev environment**

```bash
./run-all.sh
```

- [ ] **Step 2: Manual smoke test**

1. Open a KV file with at least one Sketch generation.
2. Click `Resize` in TopNav. Verify the layers panel becomes the platform picker, the canvas swaps to a single Original row.
3. Check 3 platforms (one each from 1:1, 9:16, and 16:9). Click `Resize · 3 selected`.
4. Verify three skeletons appear with correct labels and dimensions.
5. Wait for completion (≤30s expected). Verify each skeleton swaps to a rendered image.
6. Click Adjust crop on one row. Drag the crop rectangle. Click Regenerate. Verify that single row regenerates.
7. Switch to Sketch — canvas returns to normal. Switch back to Resize — exports are still there.
8. Generate a new Sketch version. Switch back to Resize — exports reset (empty state).

- [ ] **Step 3: Verify SSE behavior**

In DevTools Network tab, confirm an `EventSource` connection to `/api/studio/files/{file}/resize-exports/stream` opens when generation is in flight, and closes once all rows reach `done`/`failed`.

---

## Self-review

- ✅ Spec § Layout — Resize state → Tasks 11 (panel), 13 (canvas), 12 (rows)
- ✅ Spec § User flow steps 1–10 → Tasks 11–14 + 15 (smoke test)
- ✅ Spec § Edge cases (empty state, idempotency, retry, soft delete) → Tasks 9, 12, 14
- ✅ Spec § Web files touched → matches File Structure exactly
- ✅ Spec § Acceptance criteria 1–15 → covered by Tasks 10–15 (component tests + smoke test)
- ✅ No placeholders; every step has full code
- ✅ Type names consistent: `Platform`, `PlatformId`, `KvResizeExport`, `CropWindow` used the same way across hooks, components, and store
- ✅ Hook signature consistent: `useResizeExports(fileId, parentGenerationId)` referenced same way in canvas + layout
