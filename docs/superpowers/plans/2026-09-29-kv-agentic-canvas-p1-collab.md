# KV Agentic Canvas P1 — collab (frnd-hocuspocus) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give api two internal collab routes for KV files — `GET /internal/kv-files/{id}/document` (read the live Y.Doc, contract C1.1) and `POST /internal/kv-files/{id}/ops` (apply a batch of layer ops atomically inside the live Y.Doc, contract C1.2) — and, after every successful ops write, materialise the file's full overlay list to api's new `POST /internal/kv-files/{id}/overlays` (collab side of contract C2).

**Architecture:** Same pattern as the deck writers (`appendSlides.ts`, `removeSlides.ts`): `hocuspocus.openDirectConnection("kv_file:{id}", {internal: true})`, then `connection.transact(fn)` with every write wrapped in one `doc.transact(…, SERVER_WRITE_ORIGIN)`, then `connection.disconnect()` in `finally`. That works for a doc no browser has open (it is loaded through `KvPersistence.onLoadDocument`) and delivers the write to open browsers as a normal remote update. Overlay maps are read and written exactly like web's `yjsSerializer.ts` (rect is a nested `Y.Map`; payload is a `Y.Map` whose **values are plain JSON**; the board binding key in the doc is camelCase `boardGenerationId`). All validation runs on a pure copy before the first write. The route handlers live in their own module (`kvHttp.ts`) with injected persistence/materialisation so they are testable against a real Hocuspocus instance and a real WebSocket client.

**Tech Stack:** Node ≥20, TypeScript 5.7 (ESM, `.js` import suffixes), `@hocuspocus/server` 2.15.3, `yjs` 13.6, `zod` 3.23, `pg` 8, `pino`, `vitest` 4.1 (tests use `@hocuspocus/provider` 2.15 + `ws` for a live client).

**Spec:** `docs/superpowers/specs/2026-09-29-kv-agentic-canvas-design.md` (§7.1 is this plan). **Binding contracts:** `docs/superpowers/plans/2026-09-29-kv-agentic-canvas-p1-contracts.md` (C0, C1, C2). Both paths are relative to the frndos-agentic workspace root; this plan's code lives in the `collab/` repo (frnd-hocuspocus).

## Global Constraints

- Repo: `/Users/alva.e202511001/Desktop/work/frndos-agentic/collab` (frnd-hocuspocus). All paths below are relative to it. Default branch `main`; work branch `feature/daffa/vc-kv-agentic-canvas`.
- P1 only: op kinds `set_layer`, `add_layer`, `remove_layer`. No board ops (`add_board`, `rekey_board_tip`, `hide_board`, `unhide_board` are P2 — they must be refused as `invalid_body`, not ignored).
- Routes (C1): `GET /internal/kv-files/{fileId}/document`, `POST /internal/kv-files/{fileId}/ops`. Auth header `X-Internal-Token`, constant-time compare, 401 `{ "error": "unauthorized" }`. Body cap 2 MB. Doc name `kv_file:{studioFileId}`.
- Ops: 1..200 per call (`too_many_ops`, `max: 200`); validate all, then ONE `doc.transact(fn, SERVER_WRITE_ORIGIN)`; any failure → nothing written.
- Payload merge: shallow by top-level key; a key set to `null` is deleted; unnamed keys untouched.
- `expected`: only keys present are compared; rect by field, payload by top-level key, deep equality.
- Error codes (C1.2): 409 `layer_changed {layer_id, expected, current}`, 404 `layer_not_found {layer_id}`, 409 `layer_exists {layer_id}`, 422 `invalid_body {issues}`, 422 `too_many_ops {max: 200}`, 401 `unauthorized`.
- 200 body: `{ applied: [{kind, layer_id}], before: { layers: { <id>: Layer JSON | null } }, materialized: boolean }`.
- Materialisation (C2): `POST {API_BASE_URL}/internal/kv-files/{fileId}/overlays` body `{ overlays: [Layer JSON…], source: "agent_write" }`, header `X-Internal-Token`; 4xx → no retry; 5xx/transport → retry (3 attempts, 250 ms × 2^n backoff, as `materializeKvSnapshot`); a failure never rolls back the write → `materialized: false`.
- Layer JSON (C0), wire shape: `{ id, type, rect: {x, y, width, height, rotation}, z, payload, board_generation_id }`. Never rename a field.
- Doc shape must match web exactly (`web/src/lib/kv/yjsSerializer.ts` `overlayToOverlayMap` / `kvOverlaysFromDoc`): payload values are plain JSON set with `payload.set(k, v)` — never `toYValue`; payload edits mutate the existing payload `Y.Map` per key (web's binding observes that map and edits `content` the same way).
- Commits: `feat(hocuspocus): …` / `docs(hocuspocus): …`, ending with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Do not push; the repo owner reviews frnd-hocuspocus changes before deploy (spec §14.2).
- Test commands: `npx vitest run <file>` and `npm test`, `npm run typecheck`, `npm run build`. If a shell hook (rtk) condenses vitest output so the counts are not visible, prefix the command with `rtk proxy`.
- Baseline before any change: `npm test` → `Test Files 12 passed (12)`, `Tests 140 passed (140)`.

## Review Focus

1. **A KV file whose collab doc has no overlays while `studio_files.overlays` has layers** (never opened since collab began; `KvPersistence` seeds boards only). Expected: the read reports the persisted layers and the first write hydrates them into the doc, so materialising never replaces a full REST list with only the agent's layer. Pinned in Task 3 (`reports the persisted overlays when the doc has none`) and Task 4 (`hydrates from the persisted overlays before validating and writing`).
2. **A browser has created a layer it has not saved yet (`tmp_…` id) when the agent writes.** Expected: the materialised list leaves that layer out (the browser's own autosave mints its id), instead of a 422 for the whole list or a second id for the same layer. Pinned in Task 5 (`leaves out a browser's unsaved tmp_ layer`).
3. **The doc holds a seed-race duplicate of one overlay id** (web tolerates it by reading the first copy). Expected: `set_layer` edits the copy readers see (the first); `remove_layer` removes every copy so the second does not resurface. Pinned in Task 1 (`dedupes a seed-race duplicate keeping the FIRST copy`) and Task 4 (`removes EVERY copy of a seed-race duplicate`).
4. **A person edits another key of the same layer's payload while the agent's write is in flight.** Expected: both edits survive the merge (per-key write on the existing payload map, never a replacement map). Pinned in Task 4 (`a browser's concurrent edit to ANOTHER payload key survives the merge`).
5. **api sends a P2 op kind or a misspelt field** (`rekey_board_tip`, `set.text`, empty `set`). Expected: 422 `invalid_body` with zod issues and nothing written, never a silent no-op. Pinned in Task 6 (`422 invalid_body with zod issues`).

## Contract deviations

None of these renames or removes a contract field. Items 1–4 and 7 are behaviour the contracts leave unsaid, resolved as below; items 5, 6 and 8 add behaviour that the api plan needs to know about.

1. **C0 names the Y.Doc board-binding key `board_generation_id`; the doc key is `boardGenerationId`.** Web writes camelCase in the doc (`yjsSerializer.ts:155`) and snake_case only on the `StudioOverlay` boundary. Resolution: collab reads/writes `boardGenerationId` in the doc and emits `board_generation_id` in Layer JSON on the wire. The wire contract is unchanged.
2. **`before.layers[id]` when one batch touches an id more than once.** C1.2 says "Layer JSON before the op". Resolution: the state **before the batch** (the first touch wins), which is what an undo must restore. `add_layer` → `null`.
3. **`expected` for a payload key that is absent.** Resolution: an expected value of `null` matches an absent key or a `null` value, so api can assert "not set yet" when it sets a new key (e.g. `hidden`). `current` in a 409 reports an absent payload key as `null`.
4. **Duplicate overlay ids in the doc.** Resolution: reads dedupe keeping the first copy (as web's `kvOverlaysFromDoc`); `set_layer` edits the first copy; `remove_layer` deletes every copy.
5. **An empty doc overlay list is hydrated from `studio_files.overlays` (new, additive).** Without it, the first agent write into a never-opened file would materialise `[agent layer]` over the file's real layers (data loss). Resolution: when the doc's overlay list is empty, `GET …/document` returns the persisted list, and `POST …/ops` pushes the persisted list into the doc inside the same write transaction before applying the ops. This is web's own recovery rule (`KvGeneratorLayout.tsx`: "doc has no overlays and REST has some → add them"). Collab reads the column directly (`SELECT overlays FROM studio_files WHERE id = $1`), as it already reads `metadata->'kv_canvas'`.
6. **The materialisation POST gets a per-attempt timeout (3 s).** C1.2 says "bounded by the existing snapshot timeout/retry rules", but the existing KV snapshot POST has no timeout, and this call runs while api waits on the ops response. Worst case is about 9.75 s (3 × 3 s plus 0.25 s and 0.5 s backoff). **api plan: the `KvCollabWriter` timeout for `POST …/ops` must be at least 15 s.**
7. **Status codes the table does not list.** An unparsable or oversized body (over 2 MB) → 400 `{error: "invalid_json"}`. An unexpected failure → 500 `{error: "ops_failed"}` / `{error: "read_failed"}`, which api maps to `collab_unavailable`. `GET …/document` returns `{document}` with no `ok` key, as C1.1 specifies (unlike the deck read).
8. **Unsaved browser layers (`tmp_…` ids) are left out of the C2 list.** Web strips `tmp_` ids before its own save and rekeys after the echo (`useDebouncedOverlaySave.ts`). Sending one would 422 the whole list (`overlays.*.id` is `size:26`) or mint a second id. The browser's autosave owns those layers.

Notes for the api plan. These are not deviations, but collab behaviour depends on them:
- Collab does **not** validate payload keys or rect ranges against `UpdateStudioFileOverlaysRequest`. This matches the deck routes' "api validates, collab stores" posture. api must validate the **post-op** layer (normaliser rules) before calling `ops`. Otherwise a value that C2 then 422s (for example `width: 0`) lands in the live doc, and every browser autosave would 422 too.
- P1 ops do not touch boards, so collab does not POST the board snapshot after an ops write. That arrives with P2's board ops.
- Collab accepts `run_id` and only logs it. The ledger is api's.

## File structure

| File | Status | Responsibility |
|---|---|---|
| `src/kvOverlays.ts` | create | Pure overlay mirror of web: `KvLayer` types, overlay `Y.Map` ↔ Layer JSON, stored-row → Layer JSON, dedupe, CAS compare, pure `set` merge |
| `src/__fixtures__/kv-doc.ts` | create | Test fixtures: verbatim copy of web's `overlayToOverlayMap`, sample layers, a real in-memory-persisted Hocuspocus |
| `src/kvPersistedOverlays.ts` | create | Read `studio_files.overlays` as `KvLayer[]` (injected into the routes) |
| `src/readKvDocument.ts` | create | C1.1 read: live doc → contract JSON, persisted-overlay fallback |
| `src/applyKvOps.ts` | create | C1.2: validate-all (`planKvOps`) then one transact; hydration; pre-images; calls materialiser |
| `src/snapshot.ts` | modify (append) | C2 client: `materializeKvOverlays` (POST, retry, timeout, `tmp_` filter) |
| `src/http.ts` | create | `readJsonBody`, `json`, `internalTokenOk` moved out of `index.ts` (which boots on import) |
| `src/kvHttp.ts` | create | zod body, the two route handlers, error mapping |
| `src/routes.ts` | modify | `read_kv_document` / `apply_kv_ops` in the single matcher |
| `src/index.ts` | modify | import helpers from `http.ts`, wire the two routes with real deps |
| `README.md` | modify | document the KV internal routes |

---

### Task 1: KV overlay mirror (`kvOverlays.ts`) + test fixtures

**Files:**
- Create: `src/kvOverlays.ts`
- Create: `src/__fixtures__/kv-doc.ts`
- Test: `src/kvOverlays.test.ts`

**Interfaces:**
- Consumes: `isPlainObject` from `src/serialize.ts` (existing).
- Produces (later tasks rely on these exact names):
  - `interface KvLayerRect { x; y; width; height; rotation: number }`
  - `interface KvLayer { id: string; type: string; rect: KvLayerRect; z: number; payload: Record<string, unknown>; board_generation_id: string | null }`
  - `interface KvLayerExpectation { rect?: Partial<KvLayerRect>; z?: number; payload?: Record<string, unknown> }`
  - `overlayMapToLayer(map: Y.Map<unknown>): KvLayer`
  - `readKvLayers(doc: Y.Doc): KvLayer[]` (doc order, dedupe keep-first)
  - `layerToOverlayMap(layer: KvLayer): Y.Map<unknown>`
  - `storedOverlayToLayer(row: unknown): KvLayer | null`
  - `overlayIndexesOf(doc: Y.Doc, id: string): number[]`
  - `jsonEqual(a: unknown, b: unknown): boolean`
  - `currentFor(layer: KvLayer, expected: KvLayerExpectation): KvLayerExpectation`
  - `matchesExpected(layer: KvLayer, expected: KvLayerExpectation): boolean`
  - `applySetToLayer(layer: KvLayer, set: { rect?: Partial<KvLayerRect>; z?: number; payload?: Record<string, unknown> }): KvLayer`
  - Fixtures: `WebOverlay`, `webOverlayMap`, `HEADLINE`, `LOGO`, `webKvDoc(overlays?)`, `memoryHocuspocus()`, `persist(store, fileId, doc)`, `stored(store, fileId)`, `overlayMap(doc, id)`, `overlayIds(doc)`.

- [ ] **Step 1: Cut the branch and record the baseline**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/collab
git checkout main && git pull origin main
git checkout -b feature/daffa/vc-kv-agentic-canvas
npm ci
npm test
```
Expected: `Test Files 12 passed (12)` / `Tests 140 passed (140)`.

- [ ] **Step 2: Create the test fixtures**

`src/__fixtures__/kv-doc.ts`. `webOverlayMap` is a verbatim copy of web's `overlayToOverlayMap` (`web/src/lib/kv/yjsSerializer.ts:149-168`). Tests build docs with it and never with collab's own writer, so a drift between the two repos fails a test instead of round-tripping. `memoryHocuspocus` is a real `Hocuspocus` whose load/store hooks keep encoded state in a `Map`. `openDirectConnection` on a name nobody has open loads from that map, the same way `KvPersistence` loads a file no browser has open.

```ts
import { Hocuspocus } from '@hocuspocus/server';
import * as Y from 'yjs';

/**
 * Test fixtures for the KV layer routes.
 *
 * `webOverlayMap` is a VERBATIM copy of web's `overlayToOverlayMap`
 * (web/src/lib/kv/yjsSerializer.ts) over web's flat `StudioOverlay` shape.
 * Docs in these tests are built with it — never with collab's own
 * `layerToOverlayMap` — so a reader/writer drift between the two repos fails
 * a test instead of round-tripping through the same bug.
 */
export interface WebOverlay {
  id: string;
  type: string;
  x: number;
  y: number;
  width: number;
  height: number;
  rotation: number;
  z: number;
  payload: Record<string, unknown>;
  board_generation_id: string | null;
}

export function webOverlayMap(overlay: WebOverlay): Y.Map<unknown> {
  const map = new Y.Map<unknown>();
  map.set('id', overlay.id);
  map.set('type', overlay.type);
  map.set('boardGenerationId', overlay.board_generation_id ?? null);
  const rect = new Y.Map<unknown>();
  rect.set('x', overlay.x);
  rect.set('y', overlay.y);
  rect.set('width', overlay.width);
  rect.set('height', overlay.height);
  rect.set('rotation', overlay.rotation);
  map.set('rect', rect);
  map.set('z', overlay.z);
  const payload = new Y.Map<unknown>();
  Object.entries(overlay.payload).forEach(([k, v]) => payload.set(k, v));
  map.set('payload', payload);
  return map;
}

export const HEADLINE: WebOverlay = {
  id: '01HZHEADLINE0000000000000A',
  type: 'text',
  x: 0.1,
  y: 0.05,
  width: 0.6,
  height: 0.12,
  rotation: 0,
  z: 0,
  payload: {
    type: 'text',
    content: 'Promo Ramadan',
    color: '#FFFFFF',
    fontFamily: 'Inter',
    runs: [{ start: 0, end: 5, fontWeight: 700 }],
  },
  board_generation_id: 'gen_board_a',
};

export const LOGO: WebOverlay = {
  id: '01HZLOGO00000000000000000B',
  type: 'image',
  x: 0.8,
  y: 0.85,
  width: 0.15,
  height: 0.1,
  rotation: 0,
  z: 1,
  payload: { type: 'image', asset_url: 'https://cdn.example.com/logo.png', mime_type: 'image/png' },
  board_generation_id: 'gen_board_a',
};

/** A KV doc the way web builds it: one board, the given overlays. */
export function webKvDoc(overlays: WebOverlay[] = [HEADLINE, LOGO]): Y.Doc {
  const doc = new Y.Doc();
  doc.transact(() => {
    const meta = doc.getMap<unknown>('meta');
    meta.set('schemaVersion', 2);
    meta.set('masterGenerationId', 'gen_board_a');
    const board = new Y.Map<unknown>();
    board.set('x', 0);
    board.set('y', 0);
    board.set('name', 'Concept A');
    const chain = new Y.Array<string>();
    chain.push(['gen_board_v1', 'gen_board_a']);
    board.set('versionIds', chain);
    board.set('productionStatus', null);
    board.set('assigneeId', null);
    doc.getMap<Y.Map<unknown>>('boards').set('gen_board_a', board);
    doc.getArray<Y.Map<unknown>>('overlays').push(overlays.map(webOverlayMap));
    doc.getArray<string>('removed');
  });
  return doc;
}

/**
 * A REAL Hocuspocus instance whose persistence is an in-memory map of
 * encoded doc states — the same load/store hooks KvPersistence implements,
 * minus Postgres. `openDirectConnection` on a name nobody has open loads it
 * from `store`, exactly like a KV file no browser has open.
 */
export function memoryHocuspocus(): { hocuspocus: Hocuspocus; store: Map<string, Uint8Array> } {
  const store = new Map<string, Uint8Array>();
  const hocuspocus = new Hocuspocus({
    quiet: true,
    extensions: [
      {
        async onLoadDocument({ documentName, document }) {
          const saved = store.get(documentName);
          if (saved) Y.applyUpdate(document, saved);
          return document;
        },
        async onStoreDocument({ documentName, document }) {
          store.set(documentName, Y.encodeStateAsUpdate(document));
        },
      },
    ],
  });
  return { hocuspocus, store };
}

/** Persist `doc` as the stored state of `kv_file:{fileId}`. */
export function persist(store: Map<string, Uint8Array>, fileId: string, doc: Y.Doc): void {
  store.set(`kv_file:${fileId}`, Y.encodeStateAsUpdate(doc));
}

/** The stored state of `kv_file:{fileId}` as a fresh doc. */
export function stored(store: Map<string, Uint8Array>, fileId: string): Y.Doc {
  const doc = new Y.Doc();
  const saved = store.get(`kv_file:${fileId}`);
  if (saved) Y.applyUpdate(doc, saved);
  return doc;
}

/** The overlay Y.Map with `id` (first copy), or undefined. */
export function overlayMap(doc: Y.Doc, id: string): Y.Map<unknown> | undefined {
  const arr = doc.getArray<Y.Map<unknown>>('overlays');
  for (let i = 0; i < arr.length; i += 1) if (arr.get(i).get('id') === id) return arr.get(i);
  return undefined;
}

export function overlayIds(doc: Y.Doc): string[] {
  return doc.getArray<Y.Map<unknown>>('overlays').toArray().map((m) => m.get('id') as string);
}
```

- [ ] **Step 3: Write the failing test**

`src/kvOverlays.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import * as Y from 'yjs';

process.env.API_BASE_URL = 'http://api.test.local';
process.env.X_INTERNAL_TOKEN = 'test-internal-token-longer-than-20-chars';
process.env.DATABASE_URL = 'postgres://x@localhost/x';

const { HEADLINE, LOGO, webKvDoc, webOverlayMap } = await import('./__fixtures__/kv-doc.js');
const {
  applySetToLayer,
  currentFor,
  layerToOverlayMap,
  matchesExpected,
  readKvLayers,
  storedOverlayToLayer,
} = await import('./kvOverlays.js');

const HEADLINE_LAYER = {
  id: HEADLINE.id,
  type: 'text',
  rect: { x: 0.1, y: 0.05, width: 0.6, height: 0.12, rotation: 0 },
  z: 0,
  payload: HEADLINE.payload,
  board_generation_id: 'gen_board_a',
};

describe('readKvLayers', () => {
  it('reads a web-built doc into Layer JSON (nested rect, snake_case board id)', () => {
    const layers = readKvLayers(webKvDoc());
    expect(layers.map((l) => l.id)).toEqual([HEADLINE.id, LOGO.id]);
    expect(layers[0]).toEqual(HEADLINE_LAYER);
  });

  it('dedupes a seed-race duplicate keeping the FIRST copy (web kvOverlaysFromDoc)', () => {
    const doc = webKvDoc([HEADLINE, { ...HEADLINE, payload: { ...HEADLINE.payload, content: 'stale copy' } }]);
    const layers = readKvLayers(doc);
    expect(layers).toHaveLength(1);
    expect(layers[0]!.payload.content).toBe('Promo Ramadan');
  });

  it('reads an empty doc as no layers', () => {
    expect(readKvLayers(new Y.Doc())).toEqual([]);
  });
});

describe('layerToOverlayMap', () => {
  it('builds exactly the Y.Map web builds: same keys, rect a Y.Map, payload values PLAIN JSON', () => {
    const doc = new Y.Doc();
    const arr = doc.getArray<Y.Map<unknown>>('overlays');
    arr.push([webOverlayMap(HEADLINE), layerToOverlayMap(HEADLINE_LAYER)]);
    const web = arr.get(0);
    const ours = arr.get(1);

    expect([...ours.keys()].sort()).toEqual([...web.keys()].sort());
    expect(ours.toJSON()).toEqual(web.toJSON());
    expect(ours.get('rect')).toBeInstanceOf(Y.Map);
    const payload = ours.get('payload') as Y.Map<unknown>;
    expect(payload).toBeInstanceOf(Y.Map);
    // web's binding reads `payload.get("runs")` as a plain array.
    expect(Array.isArray(payload.get('runs'))).toBe(true);
    expect(payload.get('runs')).not.toBeInstanceOf(Y.Array);
  });
});

describe('storedOverlayToLayer', () => {
  it('maps an api-stored row (flat rect + timestamps) to Layer JSON, dropping api-owned keys', () => {
    expect(
      storedOverlayToLayer({
        id: HEADLINE.id,
        type: 'text',
        x: 0.1,
        y: 0.05,
        width: 0.6,
        height: 0.12,
        rotation: 0,
        z: 0,
        board_generation_id: 'gen_board_a',
        payload: HEADLINE.payload,
        created_at: '2026-09-01T00:00:00+00:00',
        updated_at: '2026-09-02T00:00:00+00:00',
      }),
    ).toEqual(HEADLINE_LAYER);
  });

  it('refuses a row with no id', () => {
    expect(storedOverlayToLayer({ type: 'text', payload: {} })).toBeNull();
  });
});

describe('matchesExpected / currentFor', () => {
  it('compares only the keys named, rect by field and payload by top-level key', () => {
    expect(matchesExpected(HEADLINE_LAYER, { rect: { y: 0.05 }, payload: { content: 'Promo Ramadan' } })).toBe(true);
    expect(matchesExpected(HEADLINE_LAYER, { rect: { y: 0.06 } })).toBe(false);
    expect(matchesExpected(HEADLINE_LAYER, { payload: { content: 'Other' } })).toBe(false);
    expect(matchesExpected(HEADLINE_LAYER, { z: 0 })).toBe(true);
    expect(matchesExpected(HEADLINE_LAYER, { z: 4 })).toBe(false);
  });

  it('deep-compares a nested payload value, key order agnostic', () => {
    expect(matchesExpected(HEADLINE_LAYER, { payload: { runs: [{ fontWeight: 700, end: 5, start: 0 }] } })).toBe(true);
    expect(matchesExpected(HEADLINE_LAYER, { payload: { runs: [{ start: 0, end: 5, fontWeight: 400 }] } })).toBe(false);
  });

  it('an expected null payload value matches an absent key (and nothing else)', () => {
    expect(matchesExpected(HEADLINE_LAYER, { payload: { hidden: null } })).toBe(true);
    expect(matchesExpected({ ...HEADLINE_LAYER, payload: { hidden: true } }, { payload: { hidden: null } })).toBe(false);
  });

  it('reports current values for exactly the expected keys (absent payload key → null)', () => {
    expect(currentFor(HEADLINE_LAYER, { rect: { y: 0 }, payload: { content: 'x', hidden: false } })).toEqual({
      rect: { y: 0.05 },
      payload: { content: 'Promo Ramadan', hidden: null },
    });
  });
});

describe('applySetToLayer', () => {
  it('merges rect fields and payload keys; null deletes a payload key; others untouched', () => {
    const next = applySetToLayer(HEADLINE_LAYER, {
      rect: { y: 0.2 },
      payload: { content: 'Ramadan Sale', fontFamily: null },
    });
    expect(next.rect).toEqual({ x: 0.1, y: 0.2, width: 0.6, height: 0.12, rotation: 0 });
    expect(next.payload).toEqual({
      type: 'text',
      content: 'Ramadan Sale',
      color: '#FFFFFF',
      runs: [{ start: 0, end: 5, fontWeight: 700 }],
    });
    expect(HEADLINE_LAYER.payload.fontFamily).toBe('Inter'); // input not mutated
  });
});
```

- [ ] **Step 4: Run it and see it fail**

Run: `npx vitest run src/kvOverlays.test.ts`
Expected: FAIL. The suite cannot load `./kvOverlays.js` (`Failed to load url ./kvOverlays.js` / cannot find module).

- [ ] **Step 5: Implement `src/kvOverlays.ts`**

```ts
import * as Y from 'yjs';

import { isPlainObject } from './serialize.js';

/**
 * KV overlay ("layer") mirror of web's overlay Y.Doc shape.
 *
 * Web writes each overlay as (web/src/lib/kv/yjsSerializer.ts
 * `overlayToOverlayMap`):
 *
 *   Y.Map {
 *     id: string,
 *     type: "text" | "image" | "shape",
 *     boardGenerationId: string | null,      // camelCase IN THE DOC
 *     rect: Y.Map { x, y, width, height, rotation },
 *     z: number,
 *     payload: Y.Map                          // values are PLAIN JSON
 *   }
 *
 * `payload` values are set with `payload.set(k, v)` — an array (e.g. text
 * `runs`) or an object stays a plain JSON value, it is NOT lifted into a
 * nested Y type. Web's binding reads `payload.get("runs")` as a plain array
 * and edits text with `payload.set("content", …)` in place, so this module
 * must do exactly the same. Using `toYValue` here would hand the browser a
 * Y.Array where it expects an array and corrupt live docs.
 *
 * On the wire (api ↔ collab, contract C0) a layer is `KvLayer`: flat snake
 * case `board_generation_id`, nested `rect`.
 */

export interface KvLayerRect {
  x: number;
  y: number;
  width: number;
  height: number;
  rotation: number;
}

export interface KvLayer {
  id: string;
  type: string;
  rect: KvLayerRect;
  z: number;
  payload: Record<string, unknown>;
  board_generation_id: string | null;
}

/** What a caller may assert about a layer before a write (contract C1.2). */
export interface KvLayerExpectation {
  rect?: Partial<KvLayerRect>;
  z?: number;
  payload?: Record<string, unknown>;
}

const RECT_KEYS = ['x', 'y', 'width', 'height', 'rotation'] as const;

/** One overlay Y.Map → `KvLayer`. Defaults mirror web's `kvOverlaysFromDoc`. */
export function overlayMapToLayer(map: Y.Map<unknown>): KvLayer {
  const rect = map.get('rect') as Y.Map<unknown> | undefined;
  const payload = map.get('payload') as Y.Map<unknown> | undefined;
  return {
    id: map.get('id') as string,
    type: map.get('type') as string,
    rect: {
      x: (rect?.get('x') as number | undefined) ?? 0,
      y: (rect?.get('y') as number | undefined) ?? 0,
      width: (rect?.get('width') as number | undefined) ?? 0,
      height: (rect?.get('height') as number | undefined) ?? 0,
      rotation: (rect?.get('rotation') as number | undefined) ?? 0,
    },
    z: (map.get('z') as number | undefined) ?? 0,
    payload: payload instanceof Y.Map ? (payload.toJSON() as Record<string, unknown>) : {},
    board_generation_id: (map.get('boardGenerationId') as string | null | undefined) ?? null,
  };
}

/**
 * Every overlay in doc order, deduped by id keeping the FIRST occurrence —
 * exactly web's `kvOverlaysFromDoc`, so collab and the browser agree on which
 * copy of a seed-race duplicate is "the" layer.
 */
export function readKvLayers(doc: Y.Doc): KvLayer[] {
  const overlays = doc.getArray<Y.Map<unknown>>('overlays');
  const out: KvLayer[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < overlays.length; i += 1) {
    const map = overlays.get(i);
    if (!(map instanceof Y.Map)) continue;
    const id = map.get('id');
    if (typeof id !== 'string' || seen.has(id)) continue;
    seen.add(id);
    out.push(overlayMapToLayer(map));
  }
  return out;
}

/** `KvLayer` → overlay Y.Map, mirroring web's `overlayToOverlayMap` key for key. */
export function layerToOverlayMap(layer: KvLayer): Y.Map<unknown> {
  const map = new Y.Map<unknown>();
  map.set('id', layer.id);
  map.set('type', layer.type);
  map.set('boardGenerationId', layer.board_generation_id ?? null);
  const rect = new Y.Map<unknown>();
  for (const k of RECT_KEYS) rect.set(k, layer.rect[k]);
  map.set('rect', rect);
  map.set('z', layer.z);
  const payload = new Y.Map<unknown>();
  // Plain values — see the module docblock. Never toYValue.
  for (const [k, v] of Object.entries(layer.payload)) payload.set(k, v);
  map.set('payload', payload);
  return map;
}

/**
 * A row of the `studio_files.overlays` column (api's stored shape: flat
 * x/y/width/height/rotation, snake_case board id, plus api-owned timestamps)
 * → `KvLayer`. Returns null for a row that is not a usable overlay.
 */
export function storedOverlayToLayer(row: unknown): KvLayer | null {
  if (!isPlainObject(row)) return null;
  if (typeof row.id !== 'string' || row.id === '' || typeof row.type !== 'string') return null;
  const num = (v: unknown): number => (typeof v === 'number' ? v : Number(v ?? 0) || 0);
  return {
    id: row.id,
    type: row.type,
    rect: {
      x: num(row.x),
      y: num(row.y),
      width: num(row.width),
      height: num(row.height),
      rotation: num(row.rotation),
    },
    z: num(row.z),
    payload: isPlainObject(row.payload) ? { ...row.payload } : {},
    board_generation_id: typeof row.board_generation_id === 'string' ? row.board_generation_id : null,
  };
}

/** Every index holding an overlay with `id` (a seed race can leave two). */
export function overlayIndexesOf(doc: Y.Doc, id: string): number[] {
  const overlays = doc.getArray<Y.Map<unknown>>('overlays');
  const out: number[] = [];
  for (let i = 0; i < overlays.length; i += 1) {
    const map = overlays.get(i);
    if (map instanceof Y.Map && map.get('id') === id) out.push(i);
  }
  return out;
}

/** Structural JSON equality, key-order agnostic. */
export function jsonEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    return a.every((v, i) => jsonEqual(v, b[i]));
  }
  if (isPlainObject(a) && isPlainObject(b)) {
    const ka = Object.keys(a);
    const kb = Object.keys(b);
    if (ka.length !== kb.length) return false;
    return ka.every((k) => Object.prototype.hasOwnProperty.call(b, k) && jsonEqual(a[k], b[k]));
  }
  return false;
}

/**
 * The layer's CURRENT values for exactly the keys `expected` names — the
 * `current` half of a 409 `layer_changed`. An absent payload key reads as
 * null so the two sides stay JSON-comparable.
 */
export function currentFor(layer: KvLayer, expected: KvLayerExpectation): KvLayerExpectation {
  const out: KvLayerExpectation = {};
  if (expected.rect) {
    const rect: Partial<KvLayerRect> = {};
    for (const k of RECT_KEYS) if (k in expected.rect) rect[k] = layer.rect[k];
    out.rect = rect;
  }
  if (expected.z !== undefined) out.z = layer.z;
  if (expected.payload) {
    const payload: Record<string, unknown> = {};
    for (const k of Object.keys(expected.payload)) payload[k] = layer.payload[k] ?? null;
    out.payload = payload;
  }
  return out;
}

/**
 * Compare-and-set check. Only keys present in `expected` are compared; an
 * expected payload value of `null` matches an absent key (so a caller can
 * assert "not set yet").
 */
export function matchesExpected(layer: KvLayer, expected: KvLayerExpectation): boolean {
  const current = currentFor(layer, expected);
  const want: KvLayerExpectation = {
    ...(expected.rect ? { rect: expected.rect } : {}),
    ...(expected.z !== undefined ? { z: expected.z } : {}),
    ...(expected.payload
      ? {
          payload: Object.fromEntries(
            Object.entries(expected.payload).map(([k, v]) => [k, v ?? null]),
          ),
        }
      : {}),
  };
  return jsonEqual(JSON.parse(JSON.stringify(current)), JSON.parse(JSON.stringify(want)));
}

/** The layer after a `set` (pure — for validating later ops in the batch). */
export function applySetToLayer(
  layer: KvLayer,
  set: { rect?: Partial<KvLayerRect>; z?: number; payload?: Record<string, unknown> },
): KvLayer {
  const payload = { ...layer.payload };
  for (const [k, v] of Object.entries(set.payload ?? {})) {
    if (v === null) delete payload[k];
    else payload[k] = v;
  }
  return {
    ...layer,
    rect: { ...layer.rect, ...(set.rect ?? {}) },
    z: set.z ?? layer.z,
    payload,
  };
}
```

- [ ] **Step 6: Run it and see it pass**

Run: `npx vitest run src/kvOverlays.test.ts`
Expected: `Tests 11 passed (11)`.
Then run `npm run typecheck`. Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add src/kvOverlays.ts src/kvOverlays.test.ts src/__fixtures__/kv-doc.ts
git commit -m "feat(hocuspocus): mirror web's KV overlay doc shape as Layer JSON

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Read persisted overlays (`kvPersistedOverlays.ts`)

**Files:**
- Create: `src/kvPersistedOverlays.ts`
- Test: `src/kvPersistedOverlays.test.ts`

**Interfaces:**
- Consumes: `pool` from `src/db.ts`; `KvLayer`, `storedOverlayToLayer` from Task 1.
- Produces: `type LoadPersistedOverlays = (fileId: string) => Promise<KvLayer[]>` and `const loadPersistedOverlays: LoadPersistedOverlays` (the production implementation; tests inject fakes of the type).

- [ ] **Step 1: Write the failing test**

`src/kvPersistedOverlays.test.ts`. It mocks `./db.js`, so no Postgres is touched. The stored row shape is what `StudioFileController::updateOverlays` writes (`api/app/Http/Controllers/Api/Studio/StudioFileController.php`): flat `x/y/width/height/rotation`, `board_generation_id`, `payload`, `created_at`, `updated_at`. The column is `json`, nullable (`api/database/migrations/2026_04_25_172545_add_overlays_to_studio_files_table.php`), and node-pg parses `json` (type 114) into objects.

```ts
import { beforeEach, describe, expect, it, vi } from 'vitest';

process.env.API_BASE_URL = 'http://api.test.local';
process.env.X_INTERNAL_TOKEN = 'test-internal-token-longer-than-20-chars';
process.env.DATABASE_URL = 'postgres://x@localhost/x';

const { query } = vi.hoisted(() => ({ query: vi.fn() }));
vi.mock('./db.js', () => ({ pool: { query } }));

const { loadPersistedOverlays } = await import('./kvPersistedOverlays.js');

const ROW = {
  id: '01HZLOGO00000000000000000B',
  type: 'image',
  x: 0.8,
  y: 0.85,
  width: 0.15,
  height: 0.1,
  rotation: 0,
  z: 1,
  board_generation_id: null,
  payload: { type: 'image', asset_url: 'https://cdn.example.com/logo.png', mime_type: 'image/png' },
  created_at: '2026-09-01T00:00:00+00:00',
  updated_at: '2026-09-01T00:00:00+00:00',
};

describe('loadPersistedOverlays', () => {
  beforeEach(() => query.mockReset());

  it('reads studio_files.overlays for the file and maps each row to Layer JSON', async () => {
    query.mockResolvedValueOnce({ rows: [{ overlays: [ROW] }] });

    const layers = await loadPersistedOverlays('01HZFILE');

    expect(query).toHaveBeenCalledWith('SELECT overlays FROM studio_files WHERE id = $1', ['01HZFILE']);
    expect(layers).toEqual([
      {
        id: ROW.id,
        type: 'image',
        rect: { x: 0.8, y: 0.85, width: 0.15, height: 0.1, rotation: 0 },
        z: 1,
        payload: ROW.payload,
        board_generation_id: null,
      },
    ]);
  });

  it('NULL column, missing row → no layers', async () => {
    query.mockResolvedValueOnce({ rows: [{ overlays: null }] });
    expect(await loadPersistedOverlays('F')).toEqual([]);
    query.mockResolvedValueOnce({ rows: [] });
    expect(await loadPersistedOverlays('F')).toEqual([]);
  });

  it('parses a string column value rather than dropping every layer', async () => {
    query.mockResolvedValueOnce({ rows: [{ overlays: JSON.stringify([ROW]) }] });
    expect((await loadPersistedOverlays('F')).map((l) => l.id)).toEqual([ROW.id]);
  });
});
```

- [ ] **Step 2: Run it and see it fail**

Run: `npx vitest run src/kvPersistedOverlays.test.ts`
Expected: FAIL (cannot load `./kvPersistedOverlays.js`).

- [ ] **Step 3: Implement `src/kvPersistedOverlays.ts`**

```ts
import { pool } from './db.js';
import { type KvLayer, storedOverlayToLayer } from './kvOverlays.js';

/** Reads a file's persisted overlay list. Injected so tests never touch Postgres. */
export type LoadPersistedOverlays = (fileId: string) => Promise<KvLayer[]>;

/**
 * `studio_files.overlays` (api-owned `json` column, NULL = no overlays) as
 * `KvLayer`s, in stored order.
 *
 * WHY. The server-side seed (`KvPersistence.onLoadDocument` → `seedKvDoc`)
 * seeds BOARDS only. Overlays reach a KV Y.Doc only when a browser seeds or
 * recovers them from REST (web `KvGeneratorLayout`: "if the doc has no
 * overlays and REST has some, add them"). A file nobody has opened since the
 * collab log began therefore has an EMPTY `overlays` array in its doc while
 * REST holds real layers. Writing into that doc and then materialising the
 * doc's (one-layer) list over REST would silently delete every other layer.
 * The ops path applies web's own rule instead: an empty doc list is hydrated
 * from this column first.
 */
export const loadPersistedOverlays: LoadPersistedOverlays = async (fileId) => {
  const result = await pool.query<{ overlays: unknown }>(
    'SELECT overlays FROM studio_files WHERE id = $1',
    [fileId],
  );
  const raw = result.rows[0]?.overlays;
  // `json` (not jsonb) comes back parsed from node-pg too; a string would be a
  // driver/config change — parse it rather than drop every layer.
  const rows = typeof raw === 'string' ? (JSON.parse(raw) as unknown) : raw;
  if (!Array.isArray(rows)) return [];
  return rows.map(storedOverlayToLayer).filter((l): l is KvLayer => l !== null);
};
```

- [ ] **Step 4: Run it and see it pass**

Run: `npx vitest run src/kvPersistedOverlays.test.ts`
Expected: `Tests 3 passed (3)`. `npm run typecheck` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/kvPersistedOverlays.ts src/kvPersistedOverlays.test.ts
git commit -m "feat(hocuspocus): read a KV file's persisted overlays as Layer JSON

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Read the live KV document (`readKvDocument.ts`, C1.1 core)

**Files:**
- Create: `src/readKvDocument.ts`
- Test: `src/readKvDocument.test.ts`

**Interfaces:**
- Consumes: `KvLayer`, `readKvLayers` (Task 1); `LoadPersistedOverlays` (Task 2); `KV_CANVAS_SCHEMA_VERSION`, `KV_DOC_PREFIX` from `src/kvSerialize.ts` (existing).
- Produces:
  - `interface KvDocumentJson { meta: { schemaVersion: number; masterGenerationId: string | null }; boards: Record<string, { x: number; y: number; name: string | null; versionIds: string[] }>; overlays: KvLayer[]; removed: string[] }`
  - `kvDocumentName(fileId: string): string` → `"kv_file:" + fileId`
  - `docToKvDocumentJson(doc: Y.Doc, overlays: KvLayer[]): KvDocumentJson`
  - `readLiveKvDocument(args: { hocuspocus: Hocuspocus; fileId: string; loadPersistedOverlays: LoadPersistedOverlays }): Promise<KvDocumentJson>`

- [ ] **Step 1: Write the failing test**

`src/readKvDocument.test.ts`. It uses the real Hocuspocus from the fixture with the file closed: its state is only in the store.

```ts
import { describe, expect, it, vi } from 'vitest';
import * as Y from 'yjs';

process.env.API_BASE_URL = 'http://api.test.local';
process.env.X_INTERNAL_TOKEN = 'test-internal-token-longer-than-20-chars';
process.env.DATABASE_URL = 'postgres://x@localhost/x';

const { HEADLINE, LOGO, memoryHocuspocus, persist, stored, webKvDoc } = await import('./__fixtures__/kv-doc.js');
const { readLiveKvDocument } = await import('./readKvDocument.js');

const FILE = '01HZFILE000000000000000002';

describe('readLiveKvDocument', () => {
  it('returns meta, boards (camelCase versionIds), overlays as Layer JSON and removed, from a closed file', async () => {
    const { hocuspocus, store } = memoryHocuspocus();
    const doc = webKvDoc();
    doc.getArray<string>('removed').push(['gen_old', 'gen_old']);
    persist(store, FILE, doc);
    const before = store.get(`kv_file:${FILE}`);

    const out = await readLiveKvDocument({ hocuspocus, fileId: FILE, loadPersistedOverlays: vi.fn(async () => []) });

    expect(out.meta).toEqual({ schemaVersion: 2, masterGenerationId: 'gen_board_a' });
    expect(out.boards).toEqual({
      gen_board_a: { x: 0, y: 0, name: 'Concept A', versionIds: ['gen_board_v1', 'gen_board_a'] },
    });
    expect(out.overlays.map((l) => l.id)).toEqual([HEADLINE.id, LOGO.id]);
    expect(out.overlays[0]).toEqual({
      id: HEADLINE.id,
      type: 'text',
      rect: { x: 0.1, y: 0.05, width: 0.6, height: 0.12, rotation: 0 },
      z: 0,
      payload: HEADLINE.payload,
      board_generation_id: 'gen_board_a',
    });
    expect(out.removed).toEqual(['gen_old']);
    // A read writes nothing back.
    expect(Y.encodeStateAsUpdate(stored(store, FILE))).toEqual(before);
  });

  it('reports the persisted overlays when the doc has none (what the ops path will hydrate)', async () => {
    const { hocuspocus, store } = memoryHocuspocus();
    persist(store, FILE, webKvDoc([]));
    const persisted = [
      { id: LOGO.id, type: 'image', rect: { x: 0.8, y: 0.85, width: 0.15, height: 0.1, rotation: 0 }, z: 1, payload: LOGO.payload, board_generation_id: null },
    ];
    const load = vi.fn(async () => persisted);

    const out = await readLiveKvDocument({ hocuspocus, fileId: FILE, loadPersistedOverlays: load });

    expect(load).toHaveBeenCalledWith(FILE);
    expect(out.overlays).toEqual(persisted);
  });

  it('never consults persistence when the doc has layers', async () => {
    const { hocuspocus, store } = memoryHocuspocus();
    persist(store, FILE, webKvDoc());
    const load = vi.fn(async () => []);
    await readLiveKvDocument({ hocuspocus, fileId: FILE, loadPersistedOverlays: load });
    expect(load).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run it and see it fail**

Run: `npx vitest run src/readKvDocument.test.ts`
Expected: FAIL (cannot load `./readKvDocument.js`).

- [ ] **Step 3: Implement `src/readKvDocument.ts`**

```ts
import type { Hocuspocus } from '@hocuspocus/server';
import * as Y from 'yjs';

import { type KvLayer, readKvLayers } from './kvOverlays.js';
import type { LoadPersistedOverlays } from './kvPersistedOverlays.js';
import { KV_CANVAS_SCHEMA_VERSION, KV_DOC_PREFIX } from './kvSerialize.js';

/** Contract C1.1 `document`. Boards keep the doc's camelCase `versionIds`. */
export interface KvDocumentJson {
  meta: { schemaVersion: number; masterGenerationId: string | null };
  boards: Record<string, { x: number; y: number; name: string | null; versionIds: string[] }>;
  overlays: KvLayer[];
  removed: string[];
}

export function kvDocumentName(fileId: string): string {
  return `${KV_DOC_PREFIX}${fileId}`;
}

/** The live doc as contract JSON, overlays from `overlays` (already resolved). */
export function docToKvDocumentJson(doc: Y.Doc, overlays: KvLayer[]): KvDocumentJson {
  const meta = doc.getMap<unknown>('meta');
  const boards: KvDocumentJson['boards'] = {};
  doc.getMap<Y.Map<unknown>>('boards').forEach((board, id) => {
    const chain = board.get('versionIds');
    boards[id] = {
      x: (board.get('x') as number | undefined) ?? 0,
      y: (board.get('y') as number | undefined) ?? 0,
      name: (board.get('name') as string | null | undefined) ?? null,
      versionIds: chain instanceof Y.Array ? (chain.toArray() as string[]) : [],
    };
  });
  return {
    meta: {
      schemaVersion: (meta.get('schemaVersion') as number | undefined) ?? KV_CANVAS_SCHEMA_VERSION,
      masterGenerationId: (meta.get('masterGenerationId') as string | null | undefined) ?? null,
    },
    boards,
    overlays,
    removed: [...new Set(doc.getArray<string>('removed').toArray())],
  };
}

/**
 * Read a KV file's LIVE document (contract C1.1). No transaction: a read must
 * not run the store hooks. When the doc's overlay list is empty the persisted
 * list is reported instead — the same list `applyKvOps` hydrates the doc from
 * before its first write, so what api reads is what the ops are checked
 * against (see `kvPersistedOverlays.ts`).
 */
export async function readLiveKvDocument(args: {
  hocuspocus: Hocuspocus;
  fileId: string;
  loadPersistedOverlays: LoadPersistedOverlays;
}): Promise<KvDocumentJson> {
  const { hocuspocus, fileId, loadPersistedOverlays } = args;
  const connection = await hocuspocus.openDirectConnection(kvDocumentName(fileId), { internal: true });
  try {
    const doc = connection.document as unknown as Y.Doc;
    let overlays = readKvLayers(doc);
    if (overlays.length === 0) overlays = await loadPersistedOverlays(fileId);
    return docToKvDocumentJson(doc, overlays);
  } finally {
    await connection.disconnect();
  }
}
```

- [ ] **Step 4: Run it and see it pass**

Run: `npx vitest run src/readKvDocument.test.ts`
Expected: `Tests 3 passed (3)`. `npm run typecheck` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/readKvDocument.ts src/readKvDocument.test.ts
git commit -m "feat(hocuspocus): read a KV file's live document as contract JSON

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Apply layer op batches (`applyKvOps.ts`, C1.2 core)

**Files:**
- Create: `src/applyKvOps.ts`
- Test: `src/applyKvOps.test.ts`

**Interfaces:**
- Consumes: from Task 1 `applySetToLayer`, `currentFor`, `KvLayer`, `KvLayerExpectation`, `KvLayerRect`, `layerToOverlayMap`, `matchesExpected`, `overlayIndexesOf`, `readKvLayers`; `LoadPersistedOverlays` (Task 2); `kvDocumentName` (Task 3); `SERVER_WRITE_ORIGIN` from `src/serialize.ts`; `logger`.
- Produces:
  - `const MAX_KV_OPS = 200`
  - `interface KvLayerSet { rect?: Partial<KvLayerRect>; z?: number; payload?: Record<string, unknown> }`
  - `type KvOp = { kind: 'set_layer'; layer_id; set: KvLayerSet; expected? } | { kind: 'add_layer'; layer: KvLayer } | { kind: 'remove_layer'; layer_id; expected? }`
  - `interface ApplyKvOpsResult { applied: Array<{ kind; layer_id: string }>; before: { layers: Record<string, KvLayer | null> }; materialized: boolean }`
  - `type MaterializeOverlays = (fileId: string, layers: KvLayer[]) => Promise<boolean>` (Task 5's `materializeKvOverlays` satisfies it)
  - Errors: `KvLayerChanged(layerId, expected, current)`, `KvLayerNotFound(layerId)`, `KvLayerExists(layerId)`, `KvTooManyOps(max)`, each exposing those as readonly fields
  - `planKvOps(start: KvLayer[], ops: KvOp[]): { applied; before }` (pure validation)
  - `applyKvOps(args: { hocuspocus; fileId; ops: KvOp[]; runId?: string | null; loadPersistedOverlays; materialize }): Promise<ApplyKvOpsResult>`

Facts these tests rest on, read from `@hocuspocus/server` 2.15.3 `dist/hocuspocus-server.esm.js` (`class DirectConnection`):
- `transact(fn, origin)` calls `fn(document)` synchronously, then awaits `storeDocumentHooks(…, immediately = true)`. A throw inside `fn` rejects before the store hooks run, so validation that throws before the first write leaves nothing written.
- It does **not** open a `Y.transact`. Hence the `doc.transact(…, SERVER_WRITE_ORIGIN)` wrapper, which is what makes a batch one Yjs update (test `a whole batch reaches peers as ONE Yjs update`).
- `disconnect()` also awaits the store hooks. The in-memory `store` in the fixture therefore holds the written state as soon as `applyKvOps` resolves, and the tests read it with `stored(store, FILE)`.

- [ ] **Step 1: Write the failing test**

`src/applyKvOps.test.ts`. Each op has at least one test that fails if the op is a no-op; this was checked by mutation (making `writeOp` return immediately fails 12 of these tests). The atomicity test puts the refusal **last** in the batch, so an implementation that wrote as it validated would be caught.

```ts
import { describe, expect, it, vi } from 'vitest';
import * as Y from 'yjs';

process.env.API_BASE_URL = 'http://api.test.local';
process.env.X_INTERNAL_TOKEN = 'test-internal-token-longer-than-20-chars';
process.env.DATABASE_URL = 'postgres://x@localhost/x';

const { HEADLINE, LOGO, memoryHocuspocus, overlayIds, overlayMap, persist, stored, webKvDoc } = await import(
  './__fixtures__/kv-doc.js'
);
const { applyKvOps, KvLayerChanged, KvLayerExists, KvLayerNotFound, KvTooManyOps } = await import('./applyKvOps.js');
const { readKvLayers } = await import('./kvOverlays.js');

const FILE = '01HZFILE000000000000000001';

type Op = Parameters<typeof applyKvOps>[0]['ops'][number];

/** A file no browser has open: its state exists only in the store. */
function closedFile(doc: Y.Doc = webKvDoc()) {
  const { hocuspocus, store } = memoryHocuspocus();
  persist(store, FILE, doc);
  const materialize = vi.fn(async () => true);
  const loadPersistedOverlays = vi.fn(async () => []);
  const run = (ops: Op[]) =>
    applyKvOps({ hocuspocus, fileId: FILE, ops, loadPersistedOverlays, materialize });
  return { hocuspocus, store, materialize, loadPersistedOverlays, run };
}

const NEW_LAYER = {
  id: '01HZNEWLAYER00000000000000',
  type: 'text',
  rect: { x: 0.1, y: 0.8, width: 0.5, height: 0.08, rotation: 0 },
  z: 2,
  payload: { type: 'text', content: 'Shop now', color: '#000000', runs: [{ start: 0, end: 4, fontWeight: 600 }] },
  board_generation_id: 'gen_board_a',
};

describe('applyKvOps — set_layer', () => {
  it('writes rect fields, z and payload keys into a closed file and persists them', async () => {
    const { store, run } = closedFile();

    const result = await run([
      { kind: 'set_layer', layer_id: HEADLINE.id, set: { rect: { y: 0.3 }, z: 5, payload: { content: 'Ramadan Sale' } } },
    ]);

    const doc = stored(store, FILE);
    const headline = readKvLayers(doc).find((l) => l.id === HEADLINE.id)!;
    expect(headline.rect).toEqual({ x: 0.1, y: 0.3, width: 0.6, height: 0.12, rotation: 0 });
    expect(headline.z).toBe(5);
    expect(headline.payload.content).toBe('Ramadan Sale');
    expect(result.applied).toEqual([{ kind: 'set_layer', layer_id: HEADLINE.id }]);
    expect(result.materialized).toBe(true);
  });

  it('payload merge is shallow: unnamed keys kept, a null key deleted', async () => {
    const { store, run } = closedFile();

    await run([{ kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { color: '#FF0000', fontFamily: null } } }]);

    expect(readKvLayers(stored(store, FILE))[0]!.payload).toEqual({
      type: 'text',
      content: 'Promo Ramadan',
      color: '#FF0000',
      runs: [{ start: 0, end: 5, fontWeight: 700 }],
    });
  });

  it('edits the EXISTING payload Y.Map per key (the map web observes), never a replacement', async () => {
    const { hocuspocus, run } = closedFile();
    // Hold the doc open like a browser would, and keep the payload map.
    const holder = await hocuspocus.openDirectConnection(`kv_file:${FILE}`, {});
    const doc = holder.document as unknown as Y.Doc;
    const payloadBefore = overlayMap(doc, HEADLINE.id)!.get('payload');

    await run([{ kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { content: 'Ramadan Sale' } } }]);

    const payloadAfter = overlayMap(doc, HEADLINE.id)!.get('payload') as Y.Map<unknown>;
    expect(payloadAfter).toBe(payloadBefore);
    expect(payloadAfter.get('content')).toBe('Ramadan Sale');
    await holder.disconnect();
  });

  it("a browser's concurrent edit to ANOTHER payload key survives the merge", async () => {
    const { hocuspocus, run } = closedFile();
    const holder = await hocuspocus.openDirectConnection(`kv_file:${FILE}`, {});
    const server = holder.document as unknown as Y.Doc;
    // A browser in sync with the server, then offline for one edit.
    const browser = new Y.Doc();
    Y.applyUpdate(browser, Y.encodeStateAsUpdate(server));
    (overlayMap(browser, HEADLINE.id)!.get('payload') as Y.Map<unknown>).set('color', '#00FF00');

    await run([{ kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { content: 'Both' } } }]);

    // Exchange both sides' updates, as the provider would on reconnect.
    Y.applyUpdate(server, Y.encodeStateAsUpdate(browser, Y.encodeStateVector(server)));
    Y.applyUpdate(browser, Y.encodeStateAsUpdate(server, Y.encodeStateVector(browser)));
    for (const doc of [server, browser]) {
      expect(readKvLayers(doc)[0]!.payload).toMatchObject({ content: 'Both', color: '#00FF00' });
    }
    await holder.disconnect();
  });

  it('returns the layer as it was BEFORE the batch', async () => {
    const { run } = closedFile();
    const result = await run([
      { kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { content: 'A' } } },
      { kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { content: 'B' } } },
    ]);
    expect(result.before.layers[HEADLINE.id]!.payload.content).toBe('Promo Ramadan');
    expect(result.applied).toHaveLength(2);
  });

  it('409 layer_changed with expected + current when the CAS misses; nothing written', async () => {
    const { store, run, materialize } = closedFile();
    const before = Y.encodeStateAsUpdate(stored(store, FILE));

    const err = await run([
      { kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { content: 'X' } }, expected: { payload: { content: 'Old headline' }, rect: { y: 0.05 } } },
    ]).catch((e: unknown) => e);

    expect(err).toBeInstanceOf(KvLayerChanged);
    expect((err as InstanceType<typeof KvLayerChanged>).layerId).toBe(HEADLINE.id);
    expect((err as InstanceType<typeof KvLayerChanged>).expected).toEqual({ payload: { content: 'Old headline' }, rect: { y: 0.05 } });
    expect((err as InstanceType<typeof KvLayerChanged>).current).toEqual({ rect: { y: 0.05 }, payload: { content: 'Promo Ramadan' } });
    expect(Y.encodeStateAsUpdate(stored(store, FILE))).toEqual(before);
    expect(materialize).not.toHaveBeenCalled();
  });

  it('a matching CAS writes', async () => {
    const { store, run } = closedFile();
    await run([
      { kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { content: 'X' } }, expected: { payload: { content: 'Promo Ramadan' } } },
    ]);
    expect(readKvLayers(stored(store, FILE))[0]!.payload.content).toBe('X');
  });

  it('404 layer_not_found for an unknown id', async () => {
    const { run } = closedFile();
    await expect(run([{ kind: 'set_layer', layer_id: 'ghost', set: { z: 1 } }])).rejects.toBeInstanceOf(KvLayerNotFound);
  });
});

describe('applyKvOps — add_layer', () => {
  it('appends a web-shaped overlay with plain payload values', async () => {
    const { store, run } = closedFile();

    const result = await run([{ kind: 'add_layer', layer: NEW_LAYER }]);

    const doc = stored(store, FILE);
    expect(overlayIds(doc)).toEqual([HEADLINE.id, LOGO.id, NEW_LAYER.id]);
    const map = overlayMap(doc, NEW_LAYER.id)!;
    expect(map.get('boardGenerationId')).toBe('gen_board_a');
    expect(map.get('rect')).toBeInstanceOf(Y.Map);
    const runs = (map.get('payload') as Y.Map<unknown>).get('runs');
    expect(Array.isArray(runs)).toBe(true);
    expect(readKvLayers(doc)[2]).toEqual(NEW_LAYER);
    expect(result.before.layers).toEqual({ [NEW_LAYER.id]: null });
  });

  it('409 layer_exists when the id is already a layer; nothing written', async () => {
    const { store, run } = closedFile();
    await expect(run([{ kind: 'add_layer', layer: { ...NEW_LAYER, id: LOGO.id } }])).rejects.toBeInstanceOf(KvLayerExists);
    expect(overlayIds(stored(store, FILE))).toEqual([HEADLINE.id, LOGO.id]);
  });

  it('a later op in the batch sees an earlier add', async () => {
    const { store, run } = closedFile();
    await run([
      { kind: 'add_layer', layer: NEW_LAYER },
      { kind: 'set_layer', layer_id: NEW_LAYER.id, set: { payload: { content: 'Buy' } } },
    ]);
    expect(readKvLayers(stored(store, FILE))[2]!.payload.content).toBe('Buy');
  });
});

describe('applyKvOps — remove_layer', () => {
  it('removes the layer and returns its pre-image', async () => {
    const { store, run } = closedFile();
    const result = await run([{ kind: 'remove_layer', layer_id: LOGO.id }]);
    expect(overlayIds(stored(store, FILE))).toEqual([HEADLINE.id]);
    expect(result.before.layers[LOGO.id]!.payload.asset_url).toBe('https://cdn.example.com/logo.png');
  });

  it('removes EVERY copy of a seed-race duplicate (else the second copy resurfaces)', async () => {
    const { store, run } = closedFile(webKvDoc([HEADLINE, LOGO, HEADLINE]));
    await run([{ kind: 'remove_layer', layer_id: HEADLINE.id }]);
    expect(overlayIds(stored(store, FILE))).toEqual([LOGO.id]);
  });

  it('honours expected (CAS) like set_layer', async () => {
    const { run } = closedFile();
    await expect(
      run([{ kind: 'remove_layer', layer_id: LOGO.id, expected: { rect: { x: 0.5 } } }]),
    ).rejects.toBeInstanceOf(KvLayerChanged);
  });
});

describe('applyKvOps — atomicity and one update', () => {
  it('a failing op anywhere in the batch leaves the doc unchanged (earlier valid ops NOT written)', async () => {
    const { store, run, materialize } = closedFile();
    const before = Y.encodeStateAsUpdate(stored(store, FILE));

    await expect(
      run([
        { kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { content: 'Should not land' } } },
        { kind: 'add_layer', layer: NEW_LAYER },
        { kind: 'remove_layer', layer_id: 'ghost' },
      ]),
    ).rejects.toBeInstanceOf(KvLayerNotFound);

    expect(Y.encodeStateAsUpdate(stored(store, FILE))).toEqual(before);
    expect(materialize).not.toHaveBeenCalled();
  });

  it('a whole batch reaches peers as ONE Yjs update', async () => {
    const { hocuspocus, run } = closedFile();
    const holder = await hocuspocus.openDirectConnection(`kv_file:${FILE}`, {});
    const doc = holder.document as unknown as Y.Doc;
    const updates: Uint8Array[] = [];
    doc.on('update', (u: Uint8Array) => updates.push(u));

    await run([
      { kind: 'set_layer', layer_id: HEADLINE.id, set: { rect: { y: 0.4 } } },
      { kind: 'add_layer', layer: NEW_LAYER },
      { kind: 'remove_layer', layer_id: LOGO.id },
    ]);

    expect(updates).toHaveLength(1);
    await holder.disconnect();
  });

  it('refuses more than 200 ops before opening the doc', async () => {
    const { run, loadPersistedOverlays } = closedFile();
    const ops = Array.from({ length: 201 }, () => ({ kind: 'set_layer' as const, layer_id: HEADLINE.id, set: { z: 1 } }));
    await expect(run(ops)).rejects.toBeInstanceOf(KvTooManyOps);
    expect(loadPersistedOverlays).not.toHaveBeenCalled();
  });
});

describe('applyKvOps — materialisation', () => {
  it('materialises the FULL post-write overlay list', async () => {
    const { run, materialize } = closedFile();
    await run([{ kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { content: 'New' } } }]);
    expect(materialize).toHaveBeenCalledTimes(1);
    const [fileId, layers] = materialize.mock.calls[0] as unknown as [string, Array<{ id: string; payload: Record<string, unknown> }>];
    expect(fileId).toBe(FILE);
    expect(layers.map((l) => l.id)).toEqual([HEADLINE.id, LOGO.id]);
    expect(layers[0]!.payload.content).toBe('New');
  });

  it('a failed materialisation reports materialized:false and KEEPS the write', async () => {
    const { store, run, materialize } = closedFile();
    materialize.mockResolvedValueOnce(false);
    const result = await run([{ kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { content: 'Kept' } } }]);
    expect(result.materialized).toBe(false);
    expect(readKvLayers(stored(store, FILE))[0]!.payload.content).toBe('Kept');
  });

  it('a throwing materialiser is also materialized:false, not a failed write', async () => {
    const { store, run, materialize } = closedFile();
    materialize.mockRejectedValueOnce(new Error('boom'));
    const result = await run([{ kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { content: 'Kept' } } }]);
    expect(result.materialized).toBe(false);
    expect(readKvLayers(stored(store, FILE))[0]!.payload.content).toBe('Kept');
  });
});

describe('applyKvOps — empty doc overlay list (never-opened file)', () => {
  it('hydrates from the persisted overlays before validating and writing, so no REST layer is lost', async () => {
    const { store, run, loadPersistedOverlays, materialize } = closedFile(webKvDoc([]));
    loadPersistedOverlays.mockResolvedValueOnce([
      {
        id: HEADLINE.id,
        type: 'text',
        rect: { x: 0.1, y: 0.05, width: 0.6, height: 0.12, rotation: 0 },
        z: 0,
        payload: { ...HEADLINE.payload },
        board_generation_id: 'gen_board_a',
      },
      {
        id: LOGO.id,
        type: 'image',
        rect: { x: 0.8, y: 0.85, width: 0.15, height: 0.1, rotation: 0 },
        z: 1,
        payload: { ...LOGO.payload },
        board_generation_id: 'gen_board_a',
      },
    ] as never);

    const result = await run([{ kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { content: 'Hydrated' } } }]);

    expect(loadPersistedOverlays).toHaveBeenCalledWith(FILE);
    const doc = stored(store, FILE);
    expect(overlayIds(doc)).toEqual([HEADLINE.id, LOGO.id]);
    expect(readKvLayers(doc)[0]!.payload.content).toBe('Hydrated');
    expect(result.before.layers[HEADLINE.id]!.payload.content).toBe('Promo Ramadan');
    const [, layers] = materialize.mock.calls[0] as unknown as [string, unknown[]];
    expect(layers).toHaveLength(2);
  });

  it('does not read persisted overlays when the doc already has layers', async () => {
    const { run, loadPersistedOverlays } = closedFile();
    await run([{ kind: 'set_layer', layer_id: HEADLINE.id, set: { z: 3 } }]);
    expect(loadPersistedOverlays).not.toHaveBeenCalled();
  });

  it('a refused batch on an empty doc does not hydrate either', async () => {
    const { store, run, loadPersistedOverlays } = closedFile(webKvDoc([]));
    loadPersistedOverlays.mockResolvedValueOnce([]);
    await expect(run([{ kind: 'set_layer', layer_id: HEADLINE.id, set: { z: 3 } }])).rejects.toBeInstanceOf(KvLayerNotFound);
    expect(overlayIds(stored(store, FILE))).toEqual([]);
  });
});
```

- [ ] **Step 2: Run it and see it fail**

Run: `npx vitest run src/applyKvOps.test.ts`
Expected: FAIL (cannot load `./applyKvOps.js`).

- [ ] **Step 3: Implement `src/applyKvOps.ts`**

```ts
import type { Hocuspocus } from '@hocuspocus/server';
import * as Y from 'yjs';

import {
  applySetToLayer,
  currentFor,
  type KvLayer,
  type KvLayerExpectation,
  type KvLayerRect,
  layerToOverlayMap,
  matchesExpected,
  overlayIndexesOf,
  readKvLayers,
} from './kvOverlays.js';
import type { LoadPersistedOverlays } from './kvPersistedOverlays.js';
import { logger } from './logger.js';
import { kvDocumentName } from './readKvDocument.js';
import { SERVER_WRITE_ORIGIN } from './serialize.js';

/** Contract C1.2 op cap. */
export const MAX_KV_OPS = 200;

export interface KvLayerSet {
  rect?: Partial<KvLayerRect>;
  z?: number;
  /** Top-level payload keys to replace; `null` deletes the key. */
  payload?: Record<string, unknown>;
}

export type KvOp =
  | { kind: 'set_layer'; layer_id: string; set: KvLayerSet; expected?: KvLayerExpectation }
  | { kind: 'add_layer'; layer: KvLayer }
  | { kind: 'remove_layer'; layer_id: string; expected?: KvLayerExpectation };

export interface ApplyKvOpsResult {
  applied: Array<{ kind: KvOp['kind']; layer_id: string }>;
  before: { layers: Record<string, KvLayer | null> };
  materialized: boolean;
}

/** Posts the file's full overlay list to api; true only on a 2xx. */
export type MaterializeOverlays = (fileId: string, layers: KvLayer[]) => Promise<boolean>;

export class KvLayerChanged extends Error {
  constructor(
    public readonly layerId: string,
    public readonly expected: KvLayerExpectation,
    public readonly current: KvLayerExpectation,
  ) {
    super(`layer ${layerId} changed since it was read`);
  }
}

export class KvLayerNotFound extends Error {
  constructor(public readonly layerId: string) {
    super(`no layer ${layerId} in this file`);
  }
}

export class KvLayerExists extends Error {
  constructor(public readonly layerId: string) {
    super(`layer ${layerId} already exists`);
  }
}

export class KvTooManyOps extends Error {
  constructor(public readonly max: number) {
    super(`at most ${max} ops per call`);
  }
}

/**
 * Validate a batch against the layers as they will be when each op runs.
 * Pure: throws the first refusal, returns the pre-images. Later ops see
 * earlier ones (add then set the same id is valid; set after remove is 404).
 */
export function planKvOps(
  start: KvLayer[],
  ops: KvOp[],
): { applied: ApplyKvOpsResult['applied']; before: Record<string, KvLayer | null> } {
  if (ops.length > MAX_KV_OPS) throw new KvTooManyOps(MAX_KV_OPS);
  const working = new Map(start.map((l) => [l.id, l] as const));
  const before: Record<string, KvLayer | null> = {};
  const applied: ApplyKvOpsResult['applied'] = [];
  const touch = (id: string): void => {
    // The state BEFORE THE BATCH — what an undo restores — so the first
    // touch of an id wins.
    if (!(id in before)) before[id] = working.get(id) ?? null;
  };

  for (const op of ops) {
    if (op.kind === 'add_layer') {
      if (working.has(op.layer.id)) throw new KvLayerExists(op.layer.id);
      touch(op.layer.id);
      working.set(op.layer.id, op.layer);
      applied.push({ kind: op.kind, layer_id: op.layer.id });
      continue;
    }
    const current = working.get(op.layer_id);
    if (!current) throw new KvLayerNotFound(op.layer_id);
    if (op.expected && !matchesExpected(current, op.expected)) {
      throw new KvLayerChanged(op.layer_id, op.expected, currentFor(current, op.expected));
    }
    touch(op.layer_id);
    if (op.kind === 'set_layer') working.set(op.layer_id, applySetToLayer(current, op.set));
    else working.delete(op.layer_id);
    applied.push({ kind: op.kind, layer_id: op.layer_id });
  }
  return { applied, before };
}

/** Apply one validated op to the doc. Called only inside the write transaction. */
function writeOp(doc: Y.Doc, op: KvOp): void {
  const overlays = doc.getArray<Y.Map<unknown>>('overlays');
  if (op.kind === 'add_layer') {
    overlays.push([layerToOverlayMap(op.layer)]);
    return;
  }
  const indexes = overlayIndexesOf(doc, op.layer_id);
  if (op.kind === 'remove_layer') {
    // Every copy: web reads the first of a seed-race duplicate, so deleting
    // only that one would make the second reappear as the layer.
    for (let j = indexes.length - 1; j >= 0; j -= 1) overlays.delete(indexes[j]!, 1);
    return;
  }
  // set_layer — the first copy, the one every reader (web + readKvLayers) sees.
  const map = overlays.get(indexes[0]!);
  const { rect, z, payload } = op.set;
  if (rect) {
    let rectMap = map.get('rect') as Y.Map<unknown> | undefined;
    if (!(rectMap instanceof Y.Map)) {
      rectMap = new Y.Map<unknown>();
      map.set('rect', rectMap);
    }
    // Property-level, like web's docUpdateOverlay: a concurrent drag of one
    // field and this write of another both survive.
    for (const [k, v] of Object.entries(rect)) if (v !== undefined) rectMap.set(k, v);
  }
  if (z !== undefined) map.set('z', z);
  if (payload) {
    let payloadMap = map.get('payload') as Y.Map<unknown> | undefined;
    if (!(payloadMap instanceof Y.Map)) {
      payloadMap = new Y.Map<unknown>();
      map.set('payload', payloadMap);
    }
    // Per key on the EXISTING map (never a replacement map): web's binding
    // observes this map and edits `content` the same way. Plain values only.
    for (const [k, v] of Object.entries(payload)) {
      if (v === null) payloadMap.delete(k);
      else payloadMap.set(k, v);
    }
  }
}

/**
 * Apply a batch of layer ops to a KV file's live Y.Doc (contract C1.2).
 *
 * Works whether or not a browser has the file open: `openDirectConnection`
 * loads a closed doc through `KvPersistence.onLoadDocument`, and joins an
 * open one so connected browsers receive the change as a normal remote
 * update.
 *
 * Every op is validated before anything is written; any refusal throws and
 * the doc is untouched. All writes (including hydrating an empty overlay list
 * from `studio_files.overlays`, see kvPersistedOverlays.ts) are ONE
 * `doc.transact(…, SERVER_WRITE_ORIGIN)` — one update for peers and the log.
 *
 * After the write the full overlay list is materialised to api. A failure
 * there does not undo the write (it is already in the log and in every open
 * browser, whose autosave re-materialises it); it is reported as
 * `materialized: false`.
 */
export async function applyKvOps(args: {
  hocuspocus: Hocuspocus;
  fileId: string;
  ops: KvOp[];
  /** api's agent run id — logged only; the ledger lives in api. */
  runId?: string | null;
  loadPersistedOverlays: LoadPersistedOverlays;
  materialize: MaterializeOverlays;
}): Promise<ApplyKvOpsResult> {
  const { hocuspocus, fileId, ops, loadPersistedOverlays, materialize } = args;
  const runId = args.runId ?? null;
  if (ops.length > MAX_KV_OPS) throw new KvTooManyOps(MAX_KV_OPS);

  const connection = await hocuspocus.openDirectConnection(kvDocumentName(fileId), { internal: true });
  try {
    const doc = connection.document as unknown as Y.Doc;
    // Async read OUTSIDE the transaction (its callback is synchronous); the
    // emptiness is re-checked inside, where nothing can interleave.
    const persisted = readKvLayers(doc).length === 0 ? await loadPersistedOverlays(fileId) : [];

    // Cast so the checker does not narrow to `null` across the callback.
    let result = null as Omit<ApplyKvOpsResult, 'materialized'> | null;
    await connection.transact((d) => {
      const live = readKvLayers(d);
      const hydrate = live.length === 0 ? persisted : [];
      const plan = planKvOps(live.length === 0 ? persisted : live, ops); // throws → nothing written
      d.transact(() => {
        if (hydrate.length > 0) {
          d.getArray<Y.Map<unknown>>('overlays').push(hydrate.map(layerToOverlayMap));
        }
        for (const op of ops) writeOp(d, op);
      }, SERVER_WRITE_ORIGIN);
      result = { applied: plan.applied, before: { layers: plan.before } };
      if (hydrate.length > 0) {
        logger.info({ fileId, hydrated: hydrate.length }, 'hydrated empty kv overlay list from studio_files.overlays');
      }
    });
    // `transact` runs its callback synchronously; unreachable unless that
    // contract changes upstream — say so rather than report a fake success.
    if (result === null) throw new Error('transact did not run');
    const done = result;

    let materialized = false;
    try {
      materialized = await materialize(fileId, readKvLayers(doc));
    } catch (err) {
      logger.error({ err, fileId }, 'kv overlay materialisation threw — write kept');
    }
    logger.info(
      { fileId, runId, ops: ops.length, materialized },
      'applied kv layer ops via direct connection',
    );
    return { ...done, materialized };
  } finally {
    // Always: a leaked direct connection keeps the doc loaded forever.
    await connection.disconnect();
  }
}
```

- [ ] **Step 4: Run it and see it pass**

Run: `npx vitest run src/applyKvOps.test.ts`
Expected: `Tests 23 passed (23)`. `npm run typecheck` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/applyKvOps.ts src/applyKvOps.test.ts
git commit -m "feat(hocuspocus): apply KV layer op batches atomically in the live Y.Doc

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Materialise overlays to api (`materializeKvOverlays`, C2 collab side)

**Files:**
- Modify: `src/snapshot.ts` (add one import; append the new function after `materializeKvSnapshot`, end of file)
- Modify: `src/snapshot.test.ts` (line 10 import; append one `describe` block at the end of the file)

**Interfaces:**
- Consumes: `KvLayer` (Task 1, type-only import); existing `config`, `logger`, `MAX_ATTEMPTS = 3`, `BASE_BACKOFF_MS = 250` in `snapshot.ts`.
- Produces: `materializeKvOverlays(fileId: string, layers: KvLayer[]): Promise<boolean>` (satisfies Task 4's `MaterializeOverlays`), `TMP_OVERLAY_ID_PREFIX = 'tmp_'`, `KV_OVERLAYS_POST_TIMEOUT_MS = 3_000`.

- [ ] **Step 1: Write the failing test**

In `src/snapshot.test.ts`, change line 10 from

```ts
const { materializeSnapshotOnLastDisconnect, materializeKvSnapshot } = await import('./snapshot.js');
```
to
```ts
const { materializeSnapshotOnLastDisconnect, materializeKvSnapshot, materializeKvOverlays } = await import('./snapshot.js');
```

and append at the end of the file:

```ts
describe('materializeKvOverlays', () => {
  afterEach(() => {
    globalThis.fetch = originalFetch;
    vi.restoreAllMocks();
  });

  const LAYERS = [
    {
      id: '01HZHEADLINE0000000000000A',
      type: 'text',
      rect: { x: 0.1, y: 0.05, width: 0.6, height: 0.12, rotation: 0 },
      z: 0,
      payload: { type: 'text', content: 'Promo', color: '#FFFFFF' },
      board_generation_id: 'gen_board_a',
    },
  ];

  it('POSTs {overlays, source:agent_write} with the internal token and returns true on 2xx', async () => {
    const spy = vi.fn(async () => new Response('{"count":1}', { status: 200 }));
    globalThis.fetch = spy as unknown as typeof fetch;

    const ok = await materializeKvOverlays('01HZ8W5N00000000000000FILE', LAYERS);

    expect(ok).toBe(true);
    expect(spy).toHaveBeenCalledTimes(1);
    const [url, init] = spy.mock.calls[0] as unknown as [string, RequestInit];
    expect(String(url)).toBe('http://api.test.local/internal/kv-files/01HZ8W5N00000000000000FILE/overlays');
    expect(init.method).toBe('POST');
    expect((init.headers as Record<string, string>)['X-Internal-Token']).toBe('test-internal-token-longer-than-20-chars');
    expect(JSON.parse(init.body as string)).toEqual({ overlays: LAYERS, source: 'agent_write' });
    expect(init.signal).toBeInstanceOf(AbortSignal);
  });

  it('POSTs an EMPTY list (removing the last layer is real, not a mis-read)', async () => {
    const spy = vi.fn(async () => new Response('{"count":0}', { status: 200 }));
    globalThis.fetch = spy as unknown as typeof fetch;

    expect(await materializeKvOverlays('F1', [])).toBe(true);
    const [, init] = spy.mock.calls[0] as unknown as [string, RequestInit];
    expect(JSON.parse(init.body as string)).toEqual({ overlays: [], source: 'agent_write' });
  });

  it('a 4xx is false after ONE attempt (validation will not change on retry)', async () => {
    const spy = vi.fn(async () => new Response('unprocessable', { status: 422 }));
    globalThis.fetch = spy as unknown as typeof fetch;

    expect(await materializeKvOverlays('F1', LAYERS)).toBe(false);
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it('retries 5xx up to 3 attempts, then false', async () => {
    const spy = vi.fn(async () => new Response('boom', { status: 503 }));
    globalThis.fetch = spy as unknown as typeof fetch;

    expect(await materializeKvOverlays('F1', LAYERS)).toBe(false);
    expect(spy).toHaveBeenCalledTimes(3);
  });

  it('a transport error is retried and a later 2xx is true', async () => {
    const spy = vi
      .fn()
      .mockRejectedValueOnce(new TypeError('fetch failed'))
      .mockResolvedValueOnce(new Response('{"count":1}', { status: 200 }));
    globalThis.fetch = spy as unknown as typeof fetch;

    expect(await materializeKvOverlays('F1', LAYERS)).toBe(true);
    expect(spy).toHaveBeenCalledTimes(2);
  });

  it("leaves out a browser's unsaved tmp_ layer (the browser's own save mints its id)", async () => {
    const spy = vi.fn(async () => new Response('{"count":1}', { status: 200 }));
    globalThis.fetch = spy as unknown as typeof fetch;

    await materializeKvOverlays('F1', [...LAYERS, { ...LAYERS[0]!, id: 'tmp_k3j9x0aa' }]);

    const [, init] = spy.mock.calls[0] as unknown as [string, RequestInit];
    const sent = JSON.parse(init.body as string) as { overlays: Array<{ id: string }> };
    expect(sent.overlays.map((o) => o.id)).toEqual(['01HZHEADLINE0000000000000A']);
  });
});
```

The 5xx test takes about 750 ms of real backoff, the same as the existing `retries transient 5xx` test.

- [ ] **Step 2: Run it and see it fail**

Run: `npx vitest run src/snapshot.test.ts`
Expected: the 6 new tests FAIL with `TypeError: materializeKvOverlays is not a function`; the 13 existing tests pass.

- [ ] **Step 3: Implement**

In `src/snapshot.ts`, add after `import { config } from './config.js';`:

```ts
import type { KvLayer } from './kvOverlays.js';
```

Append at the end of the file (after the closing `}` of `materializeKvSnapshot`):

```ts
/** web's prefix for a browser-created layer not yet saved (useDebouncedOverlaySave). */
export const TMP_OVERLAY_ID_PREFIX = 'tmp_';

/** Per-attempt cap on the overlay POST. The ops route awaits this call, so an
 *  unbounded hang here would hang api's tool call too. */
export const KV_OVERLAYS_POST_TIMEOUT_MS = 3_000;

/**
 * Materialise a KV file's full overlay list into `studio_files.overlays` via
 * `POST /internal/kv-files/{fileId}/overlays { overlays, source: 'agent_write' }`
 * (contract C2). Called by the ops route right after a server write, so
 * export / resize paths that read REST see agent edits even when no browser
 * is open to autosave them.
 *
 * Same retry rules as `materializeKvSnapshot`: 4xx aborts (a contract break
 * must stay loud, and api's validation 422 will not change on retry), 5xx and
 * transport errors retry up to MAX_ATTEMPTS with the same backoff. Unlike the
 * snapshot, each attempt is time-boxed (the caller is waiting) and the result
 * is returned so the route can report `materialized`.
 *
 * No empty-list guard: removing the last layer is a legitimate empty list,
 * and refusing it would leave the removed layer in REST, where web's
 * overlay recovery would put it back. The ops path hydrates an empty doc
 * from REST before writing, so an empty list here is a real one.
 */
export async function materializeKvOverlays(fileId: string, layers: KvLayer[]): Promise<boolean> {
  // A `tmp_` id is a layer a browser created and has not saved yet: its own
  // autosave strips the id, api mints a ULID, and the browser rekeys the doc.
  // Sending it here would either 422 the whole list (api wants a 26-char id)
  // or mint a SECOND id for the same layer. The browser's save owns it.
  const persistable = layers.filter((l) => !l.id.startsWith(TMP_OVERLAY_ID_PREFIX));
  const url = `${config.API_BASE_URL}/internal/kv-files/${encodeURIComponent(fileId)}/overlays`;
  const body = JSON.stringify({ overlays: persistable, source: 'agent_write' });

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          'X-Internal-Token': config.X_INTERNAL_TOKEN,
        },
        body,
        signal: AbortSignal.timeout(KV_OVERLAYS_POST_TIMEOUT_MS),
      });

      if (res.ok) {
        logger.info(
          { fileId, attempt, count: persistable.length, skippedUnsaved: layers.length - persistable.length },
          'materialized kv overlays to api',
        );
        return true;
      }

      if (res.status >= 400 && res.status < 500) {
        logger.error(
          { fileId, attempt, status: res.status },
          'api kv overlays POST returned 4xx — contract break, aborting (no retry)',
        );
        return false;
      }

      logger.warn({ fileId, attempt, status: res.status }, 'api kv overlays POST 5xx — will retry');
    } catch (err) {
      logger.warn({ err, fileId, attempt }, 'api kv overlays POST transport error — will retry');
    }

    if (attempt < MAX_ATTEMPTS) {
      await new Promise((r) => setTimeout(r, BASE_BACKOFF_MS * 2 ** (attempt - 1)));
    }
  }

  logger.error({ fileId }, 'api kv overlays POST gave up — the doc keeps the write');
  return false;
}
```

- [ ] **Step 4: Run it and see it pass**

Run: `npx vitest run src/snapshot.test.ts`
Expected: `Tests 19 passed (19)`. `npm run typecheck` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/snapshot.ts src/snapshot.test.ts
git commit -m "feat(hocuspocus): materialise a KV file's overlays to api after a server write

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The two routes: matcher, handlers, zod body, error mapping, wiring

**Files:**
- Create: `src/http.ts` (helpers moved out of `index.ts`)
- Create: `src/kvHttp.ts`
- Modify: `src/routes.ts` (two regexes, two union members, two match branches)
- Modify: `src/index.ts` (imports, remove the moved helpers, `kvRouteDeps`, two `case`s, docblock lines)
- Test: `src/kvHttp.test.ts` (create), `src/routes.test.ts` (append one `it`)

**Interfaces:**
- Consumes: `applyKvOps`, `KvOp`, `KvLayerChanged`, `KvLayerExists`, `KvLayerNotFound`, `KvTooManyOps`, `MAX_KV_OPS`, `MaterializeOverlays` (Task 4); `readLiveKvDocument` (Task 3); `LoadPersistedOverlays`, `loadPersistedOverlays` (Task 2); `materializeKvOverlays` (Task 5).
- Produces:
  - `src/http.ts`: `readJsonBody(req, maxBytes = 2_000_000): Promise<unknown>`, `json(res, status, body): void`, `internalTokenOk(req): boolean` (bodies byte-for-byte those currently in `index.ts:221-237` and `index.ts:305-313`)
  - `src/kvHttp.ts`: `interface KvRouteDeps { hocuspocus; loadPersistedOverlays; materialize }`, `kvOpsBody` (zod), `handleReadKvDocument(req, res, deps, fileId)`, `handleApplyKvOps(req, res, deps, fileId)`
  - `src/routes.ts`: `KV_DOCUMENT`, `KV_OPS`, route kinds `{ kind: 'read_kv_document'; fileId }`, `{ kind: 'apply_kv_ops'; fileId }`

Why the handlers are not in `index.ts`: `index.ts` calls `http.listen` and registers signal handlers on import, so no test imports it (the existing deck handlers are untested at the HTTP layer for that reason). `kvHttp.test.ts` stands up the same wiring: the same matcher and handlers, a real `Hocuspocus`, the same `ws` upgrade → `hocuspocus.handleConnection` path, and a real `HocuspocusProvider` client. Node 20 has no global `WebSocket`, so the client passes `ws` as `WebSocketPolyfill` on an explicit `HocuspocusProviderWebsocket`. Passing it on `HocuspocusProvider` alone throws `WebSocket is not defined`.

- [ ] **Step 1: Write the failing tests**

Append inside the top-level `describe('matchInternalRoute', …)` in `src/routes.test.ts` (before its final `});`):

```ts
  it('routes the KV file routes by method, never colliding with the deck document route', () => {
    expect(matchInternalRoute('GET', '/internal/kv-files/01HZFILE/document')).toEqual({
      kind: 'read_kv_document',
      fileId: '01HZFILE',
    });
    expect(matchInternalRoute('POST', '/internal/kv-files/01HZFILE/ops')).toEqual({
      kind: 'apply_kv_ops',
      fileId: '01HZFILE',
    });
    // Wrong method → no route (404), not a different handler.
    expect(matchInternalRoute('PUT', '/internal/kv-files/01HZFILE/document')).toBeNull();
    expect(matchInternalRoute('GET', '/internal/kv-files/01HZFILE/ops')).toBeNull();
    // The deck route is untouched by the kv-files prefix.
    expect(matchInternalRoute('GET', '/internal/decks/01HZFILE/document')).toEqual({
      kind: 'read_document',
      deckId: '01HZFILE',
    });
    // A malformed escape is still "no route", never a throw.
    expect(matchInternalRoute('POST', '/internal/kv-files/%zz/ops')).toBeNull();
    expect(matchInternalRoute('GET', '/internal/kv-files/%zz/document')).toBeNull();
  });
```

Create `src/kvHttp.test.ts`:

```ts
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';

import { HocuspocusProvider, HocuspocusProviderWebsocket } from '@hocuspocus/provider';
import { afterEach, describe, expect, it, vi } from 'vitest';
import WebSocket, { WebSocketServer } from 'ws';
import * as Y from 'yjs';

process.env.API_BASE_URL = 'http://api.test.local';
process.env.X_INTERNAL_TOKEN = 'test-internal-token-longer-than-20-chars';
process.env.DATABASE_URL = 'postgres://x@localhost/x';

const TOKEN = 'test-internal-token-longer-than-20-chars';

const { HEADLINE, LOGO, memoryHocuspocus, persist, stored, webKvDoc } = await import('./__fixtures__/kv-doc.js');
const { handleApplyKvOps, handleReadKvDocument } = await import('./kvHttp.js');
const { readKvLayers } = await import('./kvOverlays.js');
const { matchInternalRoute } = await import('./routes.js');

const FILE = '01HZFILE000000000000000003';

/**
 * The production wiring in miniature: the same route matcher and handlers
 * index.ts uses, a real Hocuspocus behind them, and the same WS upgrade path
 * browsers connect through. Persistence and materialisation are faked.
 */
async function boot() {
  const { hocuspocus, store } = memoryHocuspocus();
  persist(store, FILE, webKvDoc());
  const materialize = vi.fn(async () => true);
  const loadPersistedOverlays = vi.fn(async () => []);
  const deps = { hocuspocus, materialize, loadPersistedOverlays };

  const server: Server = createServer((req, res) => {
    const route = matchInternalRoute(req.method, req.url);
    if (route?.kind === 'read_kv_document') return void handleReadKvDocument(req, res, deps, route.fileId);
    if (route?.kind === 'apply_kv_ops') return void handleApplyKvOps(req, res, deps, route.fileId);
    res.writeHead(404).end();
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on('upgrade', (request, socket, head) => {
    wss.handleUpgrade(request, socket, head, (ws) => hocuspocus.handleConnection(ws, request));
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;

  const post = (body: unknown, token = TOKEN) =>
    fetch(`http://127.0.0.1:${port}/internal/kv-files/${FILE}/ops`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Internal-Token': token },
      body: JSON.stringify(body),
    });
  const get = (token = TOKEN) =>
    fetch(`http://127.0.0.1:${port}/internal/kv-files/${FILE}/document`, { headers: { 'X-Internal-Token': token } });

  const providers: HocuspocusProvider[] = [];
  const sockets: HocuspocusProviderWebsocket[] = [];
  const openBrowser = async (): Promise<Y.Doc> => {
    const doc = new Y.Doc();
    // Node 20 has no global WebSocket: the socket takes the `ws` polyfill.
    const websocketProvider = new HocuspocusProviderWebsocket({
      url: `ws://127.0.0.1:${port}`,
      WebSocketPolyfill: WebSocket as never,
    });
    const provider = new HocuspocusProvider({
      websocketProvider,
      name: `kv_file:${FILE}`,
      token: 'browser',
      document: doc,
    });
    sockets.push(websocketProvider);
    providers.push(provider);
    await new Promise<void>((resolve, reject) => {
      provider.on('synced', () => resolve());
      setTimeout(() => reject(new Error('sync timeout')), 5000);
    });
    return doc;
  };

  const close = async () => {
    providers.forEach((p) => p.destroy());
    sockets.forEach((s) => s.destroy());
    wss.close();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  };
  cleanups.push(close);
  return { store, materialize, loadPersistedOverlays, post, get, openBrowser };
}

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  while (cleanups.length) await cleanups.pop()!();
});

describe('POST /internal/kv-files/{id}/ops', () => {
  it('200 with applied, before and materialized', async () => {
    const { post } = await boot();
    const res = await post({
      run_id: '01HZRUN0000000000000000001',
      ops: [{ kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { content: 'Ramadan Sale' } } }],
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { applied: unknown; before: { layers: Record<string, { payload: { content: string } }> }; materialized: boolean };
    expect(body.applied).toEqual([{ kind: 'set_layer', layer_id: HEADLINE.id }]);
    expect(body.before.layers[HEADLINE.id]!.payload.content).toBe('Promo Ramadan');
    expect(body.materialized).toBe(true);
  });

  it('an OPEN browser receives the write live, on the payload map it already holds', async () => {
    const { post, openBrowser } = await boot();
    const browser = await openBrowser();
    const payloadMap = browser
      .getArray<Y.Map<unknown>>('overlays')
      .get(0)
      .get('payload') as Y.Map<unknown>;
    const seen: string[] = [];
    payloadMap.observe(() => seen.push(payloadMap.get('content') as string));

    const res = await post({ ops: [{ kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { content: 'Live' } } }] });
    expect(res.status).toBe(200);

    await vi.waitFor(() => expect(seen).toEqual(['Live']));
    expect(readKvLayers(browser)[0]!.payload.content).toBe('Live');
  });

  it('writes a file NO browser has open (loaded from persistence) and stores it', async () => {
    const { post, store } = await boot();
    const res = await post({ ops: [{ kind: 'remove_layer', layer_id: LOGO.id }] });
    expect(res.status).toBe(200);
    expect(readKvLayers(stored(store, FILE)).map((l) => l.id)).toEqual([HEADLINE.id]);
  });

  it('materialization failure → 200 materialized:false, write kept', async () => {
    const { post, store, materialize } = await boot();
    materialize.mockResolvedValueOnce(false);
    const res = await post({ ops: [{ kind: 'set_layer', layer_id: HEADLINE.id, set: { z: 7 } }] });
    expect(res.status).toBe(200);
    expect(((await res.json()) as { materialized: boolean }).materialized).toBe(false);
    expect(readKvLayers(stored(store, FILE))[0]!.z).toBe(7);
  });

  it('401 unauthorized on a wrong token, nothing written', async () => {
    const { post, store } = await boot();
    const before = Y.encodeStateAsUpdate(stored(store, FILE));
    const res = await post({ ops: [{ kind: 'remove_layer', layer_id: LOGO.id }] }, 'wrong-token-but-long-enough-xx');
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: 'unauthorized' });
    expect(Y.encodeStateAsUpdate(stored(store, FILE))).toEqual(before);
  });

  it('409 layer_changed carries layer_id, expected and current', async () => {
    const { post } = await boot();
    const res = await post({
      ops: [{ kind: 'set_layer', layer_id: HEADLINE.id, set: { payload: { content: 'X' } }, expected: { payload: { content: 'Stale' } } }],
    });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({
      error: 'layer_changed',
      layer_id: HEADLINE.id,
      expected: { payload: { content: 'Stale' } },
      current: { payload: { content: 'Promo Ramadan' } },
    });
  });

  it('404 layer_not_found', async () => {
    const { post } = await boot();
    const res = await post({ ops: [{ kind: 'remove_layer', layer_id: 'ghost' }] });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'layer_not_found', layer_id: 'ghost' });
  });

  it('409 layer_exists', async () => {
    const { post } = await boot();
    const res = await post({
      ops: [{ kind: 'add_layer', layer: { id: LOGO.id, type: 'text', rect: { x: 0, y: 0, width: 0.1, height: 0.1, rotation: 0 }, z: 3, payload: { type: 'text' }, board_generation_id: null } }],
    });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: 'layer_exists', layer_id: LOGO.id });
  });

  it('422 too_many_ops above 200', async () => {
    const { post } = await boot();
    const ops = Array.from({ length: 201 }, () => ({ kind: 'set_layer', layer_id: HEADLINE.id, set: { z: 1 } }));
    const res = await post({ ops });
    expect(res.status).toBe(422);
    expect(await res.json()).toEqual({ error: 'too_many_ops', max: 200 });
  });

  it('422 invalid_body with zod issues (unknown key, empty set, empty ops)', async () => {
    const { post } = await boot();
    for (const body of [
      { ops: [{ kind: 'set_layer', layer_id: HEADLINE.id, set: { text: 'x' } }] },
      { ops: [{ kind: 'set_layer', layer_id: HEADLINE.id, set: {} }] },
      { ops: [] },
      { ops: [{ kind: 'rekey_board_tip', from: 'a', to: 'b' }] },
    ]) {
      const res = await post(body);
      expect(res.status).toBe(422);
      const json = (await res.json()) as { error: string; issues: unknown[] };
      expect(json.error).toBe('invalid_body');
      expect(json.issues.length).toBeGreaterThan(0);
    }
  });
});

describe('GET /internal/kv-files/{id}/document', () => {
  it('200 {document} with Layer JSON overlays', async () => {
    const { get } = await boot();
    const res = await get();
    expect(res.status).toBe(200);
    const body = (await res.json()) as { document: { overlays: Array<{ id: string }>; boards: Record<string, unknown> } };
    expect(body.document.overlays.map((o) => o.id)).toEqual([HEADLINE.id, LOGO.id]);
    expect(Object.keys(body.document.boards)).toEqual(['gen_board_a']);
  });

  it('401 on a wrong token', async () => {
    const { get } = await boot();
    const res = await get('nope');
    expect(res.status).toBe(401);
  });
});
```

- [ ] **Step 2: Run them and see them fail**

Run: `npx vitest run src/routes.test.ts src/kvHttp.test.ts`
Expected: `routes.test.ts` has 1 failure (`matchInternalRoute` returns `null` for `/internal/kv-files/…`). `kvHttp.test.ts` FAILS to load `./kvHttp.js`.

- [ ] **Step 3: Create `src/http.ts`**

```ts
import { timingSafeEqual } from 'node:crypto';
import type { IncomingMessage, ServerResponse } from 'node:http';

import { config } from './config.js';

/**
 * HTTP helpers shared by every internal route. Moved out of `index.ts`
 * (which boots the server on import) so route handlers in their own modules
 * can be exercised by tests.
 */

/** Read a JSON body, bounded. */
export async function readJsonBody(req: IncomingMessage, maxBytes = 2_000_000): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    // A deck caps at a few dozen slides; anything near this is a bug or an
    // attack, and buffering it would be the damage either way.
    if (size > maxBytes) throw new Error('body too large');
    chunks.push(chunk as Buffer);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

export const json = (res: ServerResponse, status: number, body: unknown): void => {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
};

/** Shared by every internal route. */
export function internalTokenOk(req: IncomingMessage): boolean {
  const token = req.headers['x-internal-token'];
  // Constant-time compare: this secret also authenticates our own calls TO
  // api, so a timing oracle here would leak more than one route.
  const supplied = Buffer.from(typeof token === 'string' ? token : '');
  const expected = Buffer.from(config.X_INTERNAL_TOKEN);
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}
```

- [ ] **Step 4: Create `src/kvHttp.ts`**

```ts
import type { IncomingMessage, ServerResponse } from 'node:http';

import type { Hocuspocus } from '@hocuspocus/server';
import { z } from 'zod';

import {
  applyKvOps,
  type KvOp,
  KvLayerChanged,
  KvLayerExists,
  KvLayerNotFound,
  KvTooManyOps,
  MAX_KV_OPS,
  type MaterializeOverlays,
} from './applyKvOps.js';
import { internalTokenOk, json, readJsonBody } from './http.js';
import type { LoadPersistedOverlays } from './kvPersistedOverlays.js';
import { logger } from './logger.js';
import { readLiveKvDocument } from './readKvDocument.js';

export interface KvRouteDeps {
  hocuspocus: Hocuspocus;
  loadPersistedOverlays: LoadPersistedOverlays;
  materialize: MaterializeOverlays;
}

const finite = z.number().finite();

const rectPatch = z
  .object({ x: finite.optional(), y: finite.optional(), width: finite.optional(), height: finite.optional(), rotation: finite.optional() })
  .strict();

const payloadPatch = z.record(z.string().min(1), z.unknown());

const expectation = z
  .object({ rect: rectPatch.optional(), z: z.number().int().optional(), payload: payloadPatch.optional() })
  .strict();

/** Contract C0 Layer JSON. Shallow on payload: api owns what a payload is. */
const layerJson = z
  .object({
    id: z.string().min(1),
    type: z.string().min(1),
    rect: z.object({ x: finite, y: finite, width: finite, height: finite, rotation: finite }).strict(),
    z: z.number().int(),
    payload: payloadPatch,
    board_generation_id: z.string().min(1).nullish().transform((v) => v ?? null),
  })
  .strict();

/**
 * Contract C1.2 body. `.strict()` everywhere so a misspelt key is a 422, not
 * a silent no-op. The 200-op cap is checked BEFORE this schema so it can be
 * reported as its own `too_many_ops` code.
 */
export const kvOpsBody = z
  .object({
    run_id: z.string().min(1).nullish(),
    ops: z
      .array(
        z.discriminatedUnion('kind', [
          z
            .object({
              kind: z.literal('set_layer'),
              layer_id: z.string().min(1),
              set: z
                .object({ rect: rectPatch.optional(), z: z.number().int().optional(), payload: payloadPatch.optional() })
                .strict()
                .refine((s) => s.rect !== undefined || s.z !== undefined || s.payload !== undefined, {
                  message: 'set needs at least one of rect, z, payload',
                }),
              expected: expectation.optional(),
            })
            .strict(),
          z.object({ kind: z.literal('add_layer'), layer: layerJson }).strict(),
          z
            .object({ kind: z.literal('remove_layer'), layer_id: z.string().min(1), expected: expectation.optional() })
            .strict(),
        ]),
      )
      .min(1),
  })
  .strict();

/** `GET /internal/kv-files/{fileId}/document` (contract C1.1). */
export async function handleReadKvDocument(
  req: IncomingMessage,
  res: ServerResponse,
  deps: KvRouteDeps,
  fileId: string,
): Promise<void> {
  if (!internalTokenOk(req)) {
    logger.warn({ fileId }, 'read-kv-document rejected: bad internal token');
    json(res, 401, { error: 'unauthorized' });
    return;
  }
  try {
    const document = await readLiveKvDocument({
      hocuspocus: deps.hocuspocus,
      fileId,
      loadPersistedOverlays: deps.loadPersistedOverlays,
    });
    json(res, 200, { document });
  } catch (err) {
    logger.error({ err, fileId }, 'read-kv-document failed');
    json(res, 500, { error: 'read_failed' });
  }
}

/** `POST /internal/kv-files/{fileId}/ops` (contract C1.2). */
export async function handleApplyKvOps(
  req: IncomingMessage,
  res: ServerResponse,
  deps: KvRouteDeps,
  fileId: string,
): Promise<void> {
  if (!internalTokenOk(req)) {
    logger.warn({ fileId }, 'kv-ops rejected: bad internal token');
    json(res, 401, { error: 'unauthorized' });
    return;
  }

  let body: unknown;
  try {
    body = await readJsonBody(req);
  } catch {
    json(res, 400, { error: 'invalid_json' });
    return;
  }

  const rawOps = (body as { ops?: unknown } | null)?.ops;
  if (Array.isArray(rawOps) && rawOps.length > MAX_KV_OPS) {
    json(res, 422, { error: 'too_many_ops', max: MAX_KV_OPS });
    return;
  }

  const parsed = kvOpsBody.safeParse(body);
  if (!parsed.success) {
    json(res, 422, { error: 'invalid_body', issues: parsed.error.issues });
    return;
  }

  try {
    const result = await applyKvOps({
      hocuspocus: deps.hocuspocus,
      fileId,
      ops: parsed.data.ops as KvOp[],
      runId: parsed.data.run_id ?? null,
      loadPersistedOverlays: deps.loadPersistedOverlays,
      materialize: deps.materialize,
    });
    json(res, 200, result);
  } catch (err) {
    if (err instanceof KvLayerChanged) {
      logger.info({ fileId, layerId: err.layerId }, 'kv-ops refused: layer changed');
      json(res, 409, { error: 'layer_changed', layer_id: err.layerId, expected: err.expected, current: err.current });
      return;
    }
    if (err instanceof KvLayerNotFound) {
      logger.info({ fileId, layerId: err.layerId }, 'kv-ops refused: no such layer');
      json(res, 404, { error: 'layer_not_found', layer_id: err.layerId });
      return;
    }
    if (err instanceof KvLayerExists) {
      json(res, 409, { error: 'layer_exists', layer_id: err.layerId });
      return;
    }
    if (err instanceof KvTooManyOps) {
      json(res, 422, { error: 'too_many_ops', max: err.max });
      return;
    }
    // Loud 5xx: api maps it to `collab_unavailable`, never to a success.
    logger.error({ err, fileId }, 'kv-ops failed');
    json(res, 500, { error: 'ops_failed' });
  }
}
```

- [ ] **Step 5: Add the routes to `src/routes.ts`**

Insert directly above `export type InternalRoute =`:

```ts
/** `GET /internal/kv-files/{fileId}/document` — the live KV doc (C1.1). */
export const KV_DOCUMENT = /^\/internal\/kv-files\/([^/]+)\/document$/;

/** `POST /internal/kv-files/{fileId}/ops` — layer op batch (C1.2). */
export const KV_OPS = /^\/internal\/kv-files\/([^/]+)\/ops$/;
```

Replace the last union member

```ts
  | { kind: 'replace_document'; deckId: string };
```
with
```ts
  | { kind: 'replace_document'; deckId: string }
  | { kind: 'read_kv_document'; fileId: string }
  | { kind: 'apply_kv_ops'; fileId: string };
```

In `match()`, between the closing `}` of the `if (document) { … }` block and `return null;`, insert:

```ts

  const kvDocument = method === 'GET' ? KV_DOCUMENT.exec(url) : null;
  if (kvDocument) return { kind: 'read_kv_document', fileId: dec(kvDocument[1]!) };

  const kvOps = method === 'POST' ? KV_OPS.exec(url) : null;
  if (kvOps) return { kind: 'apply_kv_ops', fileId: dec(kvOps[1]!) };
```

- [ ] **Step 6: Wire `src/index.ts`**

1. Delete line 1: `import { timingSafeEqual } from 'node:crypto';`
2. Replace `import { matchInternalRoute } from './routes.js';` with:
   ```ts
   import { internalTokenOk, json, readJsonBody } from './http.js';
   import { handleApplyKvOps, handleReadKvDocument, type KvRouteDeps } from './kvHttp.js';
   import { loadPersistedOverlays } from './kvPersistedOverlays.js';
   import { matchInternalRoute } from './routes.js';
   ```
3. Replace `import { materializeKvSnapshot, materializeSnapshotOnLastDisconnect } from './snapshot.js';` with:
   ```ts
   import { materializeKvOverlays, materializeKvSnapshot, materializeSnapshotOnLastDisconnect } from './snapshot.js';
   ```
4. Delete the local `readJsonBody` function (from `/** Read a JSON body, bounded. */` through its closing `}`) and the local `const json = …;`. Put this in their place:
   ```ts
   /** The KV routes' collaborators — injected so `kvHttp.test.ts` can fake them. */
   const kvRouteDeps: KvRouteDeps = {
     hocuspocus,
     loadPersistedOverlays,
     materialize: materializeKvOverlays,
   };
   ```
5. Delete the local `/** Shared by both internal routes. */ function internalTokenOk(…) { … }` (now imported from `http.ts`).
6. In the server's `switch (route?.kind)`, after the `case 'replace_document':` block (before `default:`), add:
   ```ts
       case 'read_kv_document':
         void handleReadKvDocument(req, res, kvRouteDeps, route.fileId);
         return;
       case 'apply_kv_ops':
         void handleApplyKvOps(req, res, kvRouteDeps, route.fileId);
         return;
   ```
7. In the `Node HTTP server that handles:` docblock, after the `PUT  /internal/decks/{id}/document` line, add:
   ```ts
    *   - `GET  /internal/kv-files/{id}/document` → the live KV doc (layers).
    *   - `POST /internal/kv-files/{id}/ops`      → apply a KV layer op batch.
   ```

`config`, `IncomingMessage` and `ServerResponse` stay imported in `index.ts`: they are still used by `http.listen` and the deck handlers.

- [ ] **Step 7: Run the tests, typecheck and build**

Run: `npx vitest run src/routes.test.ts src/kvHttp.test.ts`
Expected: `routes.test.ts` → `Tests 8 passed (8)`; `kvHttp.test.ts` → `Tests 12 passed (12)`.

Run: `npm test`
Expected: `Test Files 17 passed (17)`, `Tests 199 passed (199)` (140 baseline + 11 + 3 + 3 + 23 + 6 + 1 + 12).

Run: `npm run typecheck && npm run build`
Expected: both exit 0; `dist/` contains `applyKvOps.js`, `http.js`, `kvHttp.js`, `kvOverlays.js`, `kvPersistedOverlays.js`, `readKvDocument.js`.

- [ ] **Step 8: Smoke-check the wired server by hand (optional; needs local api Postgres)**

With a local `.env` (README "Run locally"), run `npm run dev`, then:

```bash
curl -s -H "X-Internal-Token: $X_INTERNAL_TOKEN" http://localhost:1234/internal/kv-files/<a real studio_files.id>/document | head -c 400
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:1234/internal/kv-files/x/ops -d '{}'
```
Expected: the first prints `{"document":{"meta":…,"boards":…,"overlays":[…],"removed":[…]}}`; the second prints `401`.

- [ ] **Step 9: Commit**

```bash
git add src/http.ts src/kvHttp.ts src/kvHttp.test.ts src/routes.ts src/routes.test.ts src/index.ts
git commit -m "feat(hocuspocus): internal KV document read + layer ops routes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Document the KV internal routes in the README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the KV routes section**

In `README.md`, directly after the deck routes table (the row that ends with `` | read / replace the live document | ``) and before the `- **Fail-open by design:**` bullet, insert:

```markdown
- **Server-side KV layer writes (api → this service, `X-Internal-Token`, body ≤ 2 MB):** api's KV agent tools edit layers (overlays) in the live `kv_file:{id}` Y.Doc — never `studio_files.overlays` directly, which any open tab's full-replace autosave would erase. Overlays are read/written exactly like web's `yjsSerializer.ts` (rect `Y.Map`, payload `Y.Map` of plain JSON values, doc key `boardGenerationId`). If the doc has no overlays yet (a file nobody has opened since collab began — the server seed covers boards only), the read reports `studio_files.overlays` and the first write hydrates the doc from it, so a write never materialises a partial list.

  | Route | Does |
  |---|---|
  | `GET /internal/kv-files/{id}/document` | the live doc as JSON: `{document: {meta, boards, overlays: [Layer JSON], removed}}` |
  | `POST /internal/kv-files/{id}/ops` | `{run_id?, ops: [1..200]}` with `set_layer {layer_id, set:{rect?, z?, payload?}, expected?}` (payload merged per top-level key, `null` deletes), `add_layer {layer}`, `remove_layer {layer_id, expected?}`. All ops validated first, then one transaction — any refusal writes nothing: 409 `layer_changed` (CAS miss, with `expected` + `current`), 404 `layer_not_found`, 409 `layer_exists`, 422 `invalid_body` / `too_many_ops`. 200 `{applied, before: {layers}, materialized}` — then POSTs the full overlay list to api `POST /internal/kv-files/{id}/overlays` (3 attempts, 3 s each; a failure keeps the write and reports `materialized: false`; unsaved browser `tmp_…` layers are left out) |
```

Also update the one-line description under `## How it works` → `- **Snapshots:**` bullet by appending: ` KV overlays are additionally materialised to \`studio_files.overlays\` right after every server-side layer write.`

- [ ] **Step 2: Check the rendering**

Run: `grep -n "kv-files" README.md`
Expected: the two new route rows plus the existing snapshot row and the appended overlay note.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(hocuspocus): document the internal KV document and layer ops routes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Self-review (done while writing)

- **Spec coverage (§7.1, §13 collab, contracts C1/C2):** GET document → Task 3 + 6. POST ops with `set_layer` / `add_layer` / `remove_layer` → Task 4 + 6. Validate-all then one transact → Task 4 (`planKvOps`, atomicity test). `expected` CAS → 409 → Task 1 + 4 + 6. Pre-images → Task 4. Materialise overlays after a write → Task 5 + 4. Doc not currently open → Task 3/4 (`closedFile`, `stored`) + Task 6. Open client receives the update → Task 6 (live provider). 401 → Task 6. `too_many_ops` → Task 4 + 6. Board ops and the board snapshot are P2 (recorded in Contract deviations, notes).
- **Placeholders:** none. Every code step embeds the full file or the exact insertion. Every step whose outcome is checked says what the run or command should show.
- **Type consistency:** `KvLayer` / `KvLayerExpectation` / `KvLayerRect` are defined in Task 1 and used unchanged. `LoadPersistedOverlays` comes from Task 2 and is used in Tasks 3, 4 and 6. `MaterializeOverlays` from Task 4 is satisfied by `materializeKvOverlays` from Task 5. `kvDocumentName` from Task 3 is used in Task 4. Route kinds `read_kv_document` / `apply_kv_ops` are used in both `routes.ts` and `index.ts`.
- **Review Focus:** every line has a named test in its owning task.
- **Prototype check:** the code in this plan was run in a scratch copy of the repo at `main` (7b99d33): `npm test` 199/199 passing (5 consecutive runs), `npm run typecheck` and `npm run build` clean. Mutations were confirmed to fail the named tests: a no-op `writeOp`; no hydration; removing only the first duplicate; a replacement payload map; `null` stored instead of deleted.
