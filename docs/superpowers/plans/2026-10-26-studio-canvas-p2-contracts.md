# Studio Canvas P2 — Cross-service contracts

Frozen 2026-10-26. Consumed by the api, web and collab tracks of
`docs/superpowers/plans/2026-10-26-studio-canvas-p2.md`. A track that needs a
change edits THIS file first, then every consumer. Extends the P1 contracts in
`2026-10-21-studio-run-engine-p1-contracts.md`; P1 text/brief behaviour is
unchanged.

Everything below is a **new P2 decision**, not an existing endpoint or field.

## I0. Runnable node type

| UI node (`DocNode.type`) | Core record type | Runner | Price key (default) |
|---|---|---|---|
| `image` | `image` | `image_render` | `studio_image_generate` (10) |
| `image` with `operation = "region_edit"` | `image` | `image_render` | `studio_image_region_edit` (10) |

One runner serves the node type; the operation selects price, request and
validation. `StudioRunnerRegistry` is keyed by node type, so a second runner
for `image` would overwrite the first. Prices are `CreditPrice` keys with the
defaults above; a superadmin row overrides them, and `0` stays a real price.
Other prototype node types keep their free mock runs.

## I1. Image intent (client-written, in the doc)

Lives where the prototype already stores it: `nodes[nodeId].params.domain`.
No new root map, no new client run API — `POST .../runs` still takes only
`node_id` + `Idempotency-Key`, and the server resolves intent from the doc.

```ts
// params.domain.images[nodeId] — existing ImageSettings plus P2 fields
type ImageIntent = {
  operation: "sketch" | "craft" | "region_edit";   // default "sketch"
  prompt: string;                                   // required unless region_edit
  model: "auto" | "gpt-image-2" | "nano-banana-pro" | "seedream-4" | "flux-2-pro";
  ratio: "4:5" | "1:1" | "9:16" | "16:9";
  creativity: "raw" | "low" | "medium" | "high";
  brandIq: boolean;
  /** Only when operation === "region_edit"; see I2. */
  regions?: ImageRegion[];
  /** Only when operation !== "sketch": the node whose shown version is the base. */
  sourceNodeId?: string | null;
};

type ImageRegion = {
  id: string;        // client ULID, ≤64 chars
  x: number; y: number; width: number; height: number;  // normalised to the BASE image
  prompt: string;    // ≤2000 chars, required and non-empty
};
```

Rules:

- `x`,`y` in `[0,1]`; `width`,`height` in `(0,1]`; `x+width ≤ 1`, `y+height ≤ 1`.
  Zero-area boxes are rejected at the api boundary (ai-service rejects them
  too, after the charge would have happened). Reuse `KvBoundingBoxRules` and
  tighten `width`/`height` to `>0`. Max boxes = `KvObjectDetectService::MAX_OBJECTS`.
- `region_edit` requires ≥1 region and a base; `sketch`/`craft` require a
  non-empty prompt. `craft` requires a base.
- `variants` is ignored in P2 (one image per run). Unsupported settings are
  disabled in the UI, never silently dropped server-side.
- The base is resolved **server-side** from the shown succeeded version of
  `sourceNodeId ?? nodeId` in the same file, through the DB — never from a
  browser-supplied URL, KV id, or doc output JSON.
- Layers/motion intent stays in `params.domain.artboards[nodeId]` /
  `params.domain.motion[nodeId]` as `StudioOverlay[]` (see I5).

## I2. Input hashes (contract C3 extension)

New hash keys for the `image` runner, hashed exactly as P1 hashes
(canonical JSON, sha256 hex):

| Key | Content |
|---|---|
| `operation` | the operation string |
| `settings` | prompt, model, ratio, creativity, brandIq |
| `regions` | the ordered region list (region_edit only) |
| `source` | the resolved base `studio_node_versions.id`, or `""` |

Layer and motion edits are deliberately **not** hashed: moving a logo does not
make the base image out of date.

## I3. Version output (contract C1 extension)

```ts
type ImageOutput = {
  kind: "image";
  composition_id: string;        // studio_compositions.id (ULID)
  variant_id: string | null;     // P2 master runs are always null
  artifact: { source: "kv_generation"; id: string };  // discriminated, extensible in P4
  image_url: string;
  source_image_url: string | null;   // logo-free base, when KV supplies one
  thumbnail_url: string | null;
  width: number;                 // natural pixels, probed from the saved asset
  height: number;
  operation: "sketch" | "craft" | "region_edit" | "save";
  composition_snapshot: CompositionSnapshot;
};

type CompositionSnapshot = {
  base_image_version_id: string;      // the artifact id above
  width: number; height: number;
  layers: StudioOverlay[];            // validated, ids preserved
  motion: unknown | null;             // existing timeline intent, carried verbatim
  variants: VariantSnapshot[];        // [] when the composition has no sizes
};

type VariantSnapshot = {
  id: string; width: number; height: number;
  platform_id: string | null;
  layout_strategy: "keep_layers" | "ai_regenerate";
  overrides: Record<string, unknown>;        // sparse `${layerId}.${prop}`
  motion_overrides: Record<string, unknown>; // sparse `${trackId}.${prop}`
};
```

- `operation: "save"` is the zero-cost version (I4) — same shape, no provider
  call, no charge, `artifact` pointing at the unchanged current base.
- The version id is `studio_node_versions.id`. There is no second snapshot id
  and no snapshot table: `studio_node_versions.output` IS the immutable history.
- `studio_compositions.*_snapshot` and `studio_composition_variants.*_snapshot`
  remain **mutable current heads** (a cache for reads), never history.
- `price` on the version fact is the accepted Studio quote (0 for `save`).

Consumers to extend together: api output normalisation, collab
`nodeVersionFact`, web `NodeVersionFact` parser + projection. Valid P1
`text_list` / `brief` outputs keep validating unchanged.

## I4. New api routes

All inside the existing `feature.flag:show-studio-canvas,off` group, under
`v1/studio/`, authorised through `StudioCanvasFileService::canAccess`.

| Method | Path | Purpose |
|---|---|---|
| GET | `canvas/files/{id}/compositions/{comp}` | current head + identifiers |
| POST | `canvas/files/{id}/compositions/{comp}/versions` | zero-cost Save version |
| GET | `canvas/files/{id}/compositions/{comp}/variants` | list existing variants |
| POST | `canvas/files/{id}/compositions/{comp}/variants` | create size **metadata** only |
| POST | `canvas/files/{id}/compositions/{comp}/variants/push` | clear selected override keys |

- `GET compositions/{comp}` → `{data:{id,node_id,base_image_version_id,width,height,status,updated_at}}`.
  `comp` must belong to `{id}`; otherwise 404 through the existing exception.
- `POST .../versions` body: `{}`. The server reads the current live doc intent,
  validates it (I1/I5), and appends an immutable version with `operation:"save"`
  against the current base. No provider call, no charge, no refund path.
  When nothing changed since the newest version, it returns `200` with that
  version and appends nothing. Returns `201` with the new version otherwise.
- `POST .../variants` body `{width,height,platform_id?,layout_strategy?}`;
  creates metadata only. It never renders, never charges and never sets
  `image_url` or `status` from the client.
- `POST .../variants/push` body `{keys:string[]}` (`${layerId}.${prop}`);
  clears those override keys from the named variants' **intent**. It is an
  authorised operation, not a server overwrite of output.
- There is **no public setter** for base, status or output. Those are written
  only by run settlement. P4 owns size rendering, layout strategy execution,
  staleness propagation and bulk download.

## I5. Overlay persistence

- Canonical shape is `StudioOverlay` (`web/src/types/studio.ts`), validated by
  `StudioOverlayNormalizer` with Composition binding: `{id,type,x,y,width,height,
  rotation,z,payload{…}}`, payload discriminated `text|image|shape`.
- Overlay id is a 26-character ULID. The shared validator is used by KV too, so
  the api rule stays strict and the **client mints ids**: the one-time migration
  keeps an id only when it already satisfies the rule, otherwise it replaces it
  with a fresh ULID in the same pass (idempotent — a migrated board is never
  re-minted) and rewrites every `${layerId}.${prop}` / `${trackId}.${prop}`
  override key whose prefix was renamed. Client and migration share ONE id
  predicate (`lib/node-studio/overlayRules.ts`) so they cannot drift.
- The prototype `Layer {frame,content,style,kind}` form is migrated once on real
  files, preserving order, text, geometry, visibility and style. Both forms must
  never be writable at the same time.
- A layer that cannot satisfy the api's structural rules must be named in the UI
  before any charge — the quote payload reports only `inputs_missing`, not which
  layer, so the client mirrors the rules rather than showing a generic error.
- Variant overrides are sparse leaf keys `${layerId}.${prop}` — not the
  prototype's per-layer property groups.
- Writes go to **nested `Y.Map` leaves** inside `params.domain`, preserving the
  serialised JSON shape. Replacing the whole `domain` value loses a peer's
  concurrent edit on another layer.
- Image overlays must reference persisted assets uploaded through a
  Studio-authorised route (file/tool/brand write check). Blob URLs are rejected.

## I6. Execution transport

- api → ai-service: `POST /ai/kv-generator/complete`, request built from the
  **frozen snapshot**, never re-resolved from the live doc.
  - generate: `mode:"image"`, `canvas_mode:"sketch"|"craft"`, explicit
    `aspect_ratio`, resolved `image_model`/`image_model_provider`.
  - region edit: `mode:"edit"`, `canvas_mode:"craft"`, `bounding_boxes`,
    `base_generation`. The executor pins `gpt-image-2`; quote and UI must show
    the actual executor.
  - `base_generation: {id,image_url,mode}` using the stored source image URL.
  - `thread_id` = the Studio file id (execution correlation only). No KV chat
    thread, file or message is created. Validate against `run_stream` before
    wiring.
  - Brand/project context is frozen `prefetched` at capture time.
- Success is `generation_ready` parsed by
  `KvGeneratePayloadBuilder::readyPayload`. HTTP 200, `done`, or a question card
  without a usable image is a **failure**, refunded like any other.
- Budgets: HTTP 240 s, job timeout 420 s, `tries = 1`, run deadline > job
  budget. P1 text/brief keeps 30 s/60 s.
- Persistence: a Studio-owned adapter writes a normal `kv_generations` row via
  the existing model under the per-file version lock. It does **not** call
  `KvGenerationService::persistCompletion` or KV metering.
  `mode` is set explicitly (`craft` for craft/region edit, `sketch` for sketch),
  because the master edit event omits it.
- Billing: one Studio fixed charge at accepted Run, one exact refund on
  failure/cancel/timeout, via the existing `StudioRunCharger`. Reported model
  and token usage are stored for attribution only.
- Everything — `kv_generations` row, `studio_node_versions` row, composition
  head update — happens inside the settler's existing terminal claim
  transaction. A cancelled, duplicate or late callback publishes nothing.

## I7. Trust boundary

- The doc is client-writable. api resolves base/source/version identity from
  authorised DB rows, never from `runFacts` / `nodeVersions` JSON.
- Every composition, variant, artifact and upload reference is scoped to the
  file first, then the composition, then the variant. Cross-file, cross-brand
  and cross-workspace references are rejected before charging.
- A stale `queued`/`running` fact replay must not overwrite a newer terminal
  fact; version append stays idempotent by version id.
- Viewers (`connection.readOnly`) cannot run, save a version, upload or mutate.
