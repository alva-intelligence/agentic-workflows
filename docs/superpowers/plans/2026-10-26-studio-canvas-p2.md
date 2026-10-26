# Studio Canvas P2 — Composition, real Image runs, focus and region edit

Status: planned, not implemented. Worker: daffa. Branch in api/web/ai-service/collab: `feature/daffa/vc-studio-canvas`.

Main PRD: `frnd/docs/prd/studio-canvas.md`, FR-11, FR-16..17, FR-20..23, FR-27, AC-10..11. Prerequisite: verified P1 checkpoint. This plan does not turn on production access, push branches, or create PRs.

## Checkpoint

- web `2f98daafd`: real P1 runs, version edits/status, credits, failures and analytics.
- api `6d1f3a7c5`: private S3 brief upload fix.
- ai-service `c1c055d3`: reconciled P1 records. Collab P1 already committed.
- P1 evidence remains in the manifest and tracks; no new P2 behavior is claimed.

## Decisions

1. Reuse the existing KV inference path, not a new image generator. API image execution calls `POST /ai/kv-generator/complete`, reads `generation_ready` through `KvGeneratePayloadBuilder::readyPayload`, and settles the existing Studio run. HTTP 200 or `done` without a usable image is failure. No new AI endpoint is needed.
2. Use an image-specific queue job/transport with a 240-second HTTP budget and a job budget greater than that, following `RenderKvVariantJob` (420 seconds). Keep P1's 30-second HTTP/60-second callback dispatch for text/brief. One attempt; never automatically replay a paid request. Configure image deadline and queue visibility to exceed the chosen job budget; retain watchdog settlement.
3. Studio owns the one up-front, server-quoted fixed charge and exact failure/cancel refund. Quote includes operation, model/provider, dimensions and region count as relevant; opening focus or moving layers is free. Existing image registry/pricing supplies supported models and estimates; never use prototype prices. Persist the accepted quote on the run. A Studio-owned adapter saves `KvGeneration` through the existing Eloquent model and per-file version lock without calling KV metering. Keep `KvGenerationService::persistCompletion` and ordinary KV callers unchanged. Retain actual usage for attribution without a second charge.
4. Capture an immutable image execution snapshot before enqueue, including resolved inputs, model/provider, prefetched context, selected base, layers, motion and operation. Job and completion use that capture, never re-resolve image inputs from live Yjs. Preserve P1 text/brief semantics.
5. Reuse existing `nodes[node_id].params.domain` intent storage and `StudioDoc::domain()`. Do not introduce parallel root maps or a second document-read endpoint. Server version/facts stay in `nodeVersions`/`runFacts`.
6. `studio_compositions` is the latest server materialization, not immutable history. Each successful `studio_node_versions.output` stores its own Composition snapshot; the captured input snapshot stays in `studio_runs.meta`. This uses existing JSON columns rather than adding a redundant snapshot table. No public request can directly set server base/status/output.
7. Use `StudioOverlay` as the persisted overlay contract and reuse Craft Fabric primitives. Replace the prototype-only layer representation on real Image paths; migrate existing saved real-file intent, preserving IDs, stacking, text, geometry, visibility and style. Do not run two independently writable layer models.
8. Master region edit supports multiple boxes in one render: the existing `BoundingBox[]`, union mask and per-box prompt composer already support it. Minimum AC-11 proof uses one area; also exercise two independently prompted areas. Do not reduce to single-area or charge one full render per box.

Simpler alternative rejected: pointing P1 `aiPath()` at `/complete` would time out, wait for a callback that never arrives, and risk double billing through KV persistence.

## Shared contracts to implement first

Frozen in `docs/superpowers/plans/2026-10-26-studio-canvas-p2-contracts.md`
(I0–I7): node type/price keys, image intent, hash keys, version output,
new routes, overlay persistence, transport and trust boundary. The summaries
below stay for context; the contract file wins on any conflict.

### Image operation and output

- Real runnable node remains UI/core type `image`; operation is `sketch`, `craft`, or `region_edit`. Refine creation/fan-out belongs to P3, but a manually added Image must generate from explicit prompt in P2. A source-linked craft operation resolves the shown successful source version server-side.
- Image intent includes validated operation/settings and, for region edit, normalized boxes `{id,x,y,width,height,prompt}`. Reuse `KvBoundingBoxRules`, require positive dimensions and a rectangle wholly inside the base. Resolve base generation from the shown successful same-file Studio version, never a browser-supplied URL or arbitrary KV ID.
- Version output discriminator: `kind: "image"`; fields: `composition_id`, `generation_id`, `image_url`, `source_image_url` (nullable), `thumbnail_url` (nullable), `width`, `height`, `operation`, and `composition_snapshot`.
- `composition_snapshot`: `{base_image_version_id,width,height,layers,motion}`. `base_image_version_id` is the persisted KV generation ULID. `layers` are validated `StudioOverlay[]`; `motion` is the existing intent timeline or null, preserved without implementing P5 playback. Version ID is the enclosing Studio node version ID, not a second invented snapshot ID.
- Obtain natural dimensions from the saved asset using existing bounded image-inspection infrastructure; KV events do not supply authoritative dimensions. Validate nonempty usable output, trusted asset location and file identity before persistence. Preserve source/logo semantics from KV; do not bake live overlays into the base image.
- Extend API output normalization/fact writer, collab `nodeVersionFact`, web `NodeVersionFact` parser, input resolution/hash and projection together. Add image handling without changing valid P1 text/brief outputs. Hash the actual frozen operation/settings/source inputs; layer-only edits do not create spurious paid base-image staleness.

### Composition API

- `GET v1/studio/canvas/files/{file}/compositions/{comp}`: authorized latest server materialization plus identifiers; the UI gets immutable history from Studio node versions. Enforce composition belongs to file and caller can read that file.
- Create the unique `(studio_file_id,node_id)` composition on the first accepted Image run, not through client-written server fields. On successful settlement update its current base/cache atomically with the accepted Studio version. Failure must not destroy the last successful composition.
- Replace the service PRD's unrestricted public `PUT` base/status proposal with server-owned settlement. Layers/motion are intent through Yjs, not REST writes. Version selection stays client intent and cannot rewrite the newest server base.
- Snapshot validation rejects malformed/foreign image and overlay asset references before charging. A deleted node, cancelled run, duplicate delivery or failed generation cannot publish a new base/version. Use existing terminal claim and per-node concurrency guarantees; save KV generation, Studio version and composition update under the accepted transaction so a lost cancellation race does not leave a published orphan or second charge.

### KV request normalization

- `mode=image` plus `canvas_mode=sketch|craft` for ordinary generation; `mode=edit,canvas_mode=craft` for master region edit. Explicit aspect ratio suppresses interactive question cards. Resolve supported model/provider from the server registry. Existing edit path pins OpenAI `gpt-image-2`; quote and UI must reflect the actual executor, not another selected model.
- Base ref is `{id,image_url,mode}`; use the stored source image URL where KV does, and pass `mode=sketch` for a first Craft polish so de-styling remains intact.
- Supply frozen prefetched brand/project context. Studio files need not have KV chat threads: use the Studio file ID as non-chat execution correlation `thread_id`, without creating hidden files/threads or chat messages. Validate this path against `run_stream` before wiring the runner. Normalize optional brand/project context with empty context blocks and the executor's accepted empty brand identifier, not invented brand records; prove brandless execution locally.
- Do not call `ChatService::streamKvGenerator`, which owns KV chat/browser streaming. Reuse payload/context/parser/model primitives; `KvGeneratePayloadBuilder::build` hardcodes Craft/thread assumptions and is not a drop-in for all Studio operations.
- No change to existing KV tables/schema or visible editor behavior. New Studio images may create normal `kv_generations` rows through the isolated persistence adapter. KV editor layers/metadata are never the Studio focus source of truth.
- Fixed-price Studio billing does not require a shared AI metering rewrite. Existing master edit drops usage and the shared tool has a token-accounting defect: record these as existing limitations, do not silently repair unrelated KV billing in P2.

## Implementation order

### Task 1 — Freeze contracts and reconcile service PRDs

Files: API/web/AI `docs/prd/studio-canvas.md`, P1 contracts addendum or shared P2 contract section here, respective tracks.

- [ ] Record exact image output, immutable JSON capture, operation/hash keys, quote and server-owned Composition API above before implementation.
- [ ] Reconcile API TASK-11..14 and web TASK-19..23 with this plan. Preserve existing-variant read/edit, sparse override persistence and minimum scoped TASK-12 actions in P2; P4 retains size creation/render/layout/staleness orchestration. Never mark a whole task complete for metadata or master support alone.
- [ ] Correct AI TASK-7 transport docs: `/complete` returns events, not Studio callbacks; actual size edit path is `/ai/kv-resize-region-edit/edit`. Keep size/upscale adapters as later-phase work, not a claimed P2 feature.
- [ ] Keep production flag/permission gates and unresolved product questions visible. No workflow phase transition: remain `implementation`.
- [ ] Reconcile main/web PRD renderer text with the recorded React Flow graph decision; Fabric remains image/focus/compositor. Disable unsupported prototype settings/actions in real files rather than silently ignoring them.

Acceptance: API/collab/web share one image shape; no public base/status setter or contradictory billing owner remains in the affected PRD sections.

### Task 2 — API capture, Composition materialization and settlement

Existing seams: `Services/Studio/Runs/{StudioRunService,StudioDoc,StudioRunSettler,StudioRunFacts,StudioRunFactWriter,StudioRunnerRegistry}.php`, `Models/Studio/{StudioComposition,StudioRun,StudioNodeVersion}.php`, current run routes/controllers and pricing helpers. New image runner/job and snapshot helper live beside existing Studio implementations; introduce only what this path uses.

- [ ] Add validated image resolve/quote logic using nested domain, source shown version and server model registry. Freeze request and composition intent in run metadata in the same accepted start/charge flow.
- [ ] Widen `studio_compositions.node_id` from 26 to 64 characters, matching run/version IDs. Reuse overlay validation with Composition binding and file-owned assets, not merely trusted bucket URLs.
- [ ] Add authorized Composition read endpoint and unique create/materialization path. Empty/invalid input never charges.
- [ ] Add cancel-safe success transaction for image persistence/version/cache. Non-image settlement remains unchanged. Old immutable snapshots remain byte-equivalent after later edits/runs.
- [ ] Implement scoped existing-variant read/metadata actions and sparse `${layerId}.${prop}` leaf persistence. Public actions never set generated status/output; push clears selected override intent in Yjs. Preserve variant identity, dimensions, source revision and motion overrides in immutable snapshots. P4 still owns size render/batch orchestration.
- [ ] Add explicit zero-cost `POST .../compositions/{comp}/versions` Save version: capture validated live layers/motion/variant intent against a DB-backed base into an immutable Studio node version, without provider execution or debit. Dirty focus Done invokes this action; no-op Done adds no duplicate. Freeze its exact fact/response contract in Task 1.
- [ ] Extend existing P1 contract tests only where image behavior changes. Retain one small deterministic regression covering capture-before-dispatch plus later live edits and cancellation preventing publication. Use scratch `frnd_studio_test`; never run destructive test migrations on development DB.

Acceptance: queued image runs do not consult live payload again; snapshot/history and current live intent can differ safely; no new version appears after cancel/failure.

### Task 3 — Collab image facts and web contract consumers

Files: `collab/src/studioRunFacts.ts`, its existing tests, web `lib/studio/core/runFacts.ts`, `lib/studio/runs/*`, `lib/studio/bridge/{bindStudioRuns,bindNodeStudio}.ts`, `services/studioCanvasRuns.ts` as required.

- [ ] Accept/validate image node version output through the existing fact write. Preserve append-once behavior and missing-node handling. Existing document JSON already carries nested intent; leave its read shape unchanged unless an actual missing field is demonstrated.
- [ ] Resolve source version/artifact identity from authorized DB rows, not client-writable Yjs output JSON. Enforce server-only image facts at the collab trust boundary or isolate accepted client intent from authoritative state. Prevent delayed queued/running retries from regressing terminal/new-run facts while preserving append-once version delivery.
- [ ] Add image runtime projection without writing image URLs, generation IDs, version history, billing or server base back into client intent. Preserve reload isolation established in P1.
- [ ] Real image quotes are per node/settings/source, not cached solely by node type. Quote failure disables paid execution with an actionable error; never silently use a prototype estimate for a real image charge.
- [ ] Bind image Run/cancel/version navigation/Keep/Retry and balance refresh. Restore original action overrides on unbind, matching existing bridge lifecycle. Region edit uses this same server run lifecycle, never local timers.
- [ ] Use nested Y.Map leaf writes for image layers/properties and sparse override keys, preserving existing serialized `params.domain` shape. Whole-domain JSON replacement loses unrelated concurrent edits. Migrate saved intent and preserve local-origin undo once per gesture, not a second persistence model.

Acceptance: both tabs consume one image version/fact; reload does not turn projected output into saved intent; malformed output fails safely without pretending success.

### Task 4 — Existing KV completion transport

Files: new Studio image runner/job/adapter beside `RunStudioNodeJob`; reuse `KvGeneratePayloadBuilder::readyPayload`, `KvBrandContextBuilder`, model registry, `KvGenerationService` persistence internals with an explicit Studio-only no-charge entry point.

- [ ] Add the bounded `/complete` call and event normalization from frozen capture. Keep generation/editor/context semantics; no extra model integration.
- [ ] Resolve base/file/asset identity and dimensions; assign operation mode explicitly because master edit events can omit it. Reject no-image/question-card/malformed/cross-file results.
- [ ] Persist once and settle through Studio's accepted terminal transition, not the ordinary KV metered completion path. Record provider attribution/usage when available without inventing missing numbers.
- [ ] Test idempotent start, provider failure, cancel before dispatch, cancel in flight, lost worker/watchdog and replayed success against existing invariants. Do not promise provider cancellation: cancellation rejects late publication and refunds once.

Acceptance: one user Run creates one accepted charge, one KV image row and one Studio version; a failed/cancelled run creates no published version and refunds once. A direct existing KV run still uses its original billing path.

### Task 5 — Real Image preview and Fabric focus editor

Existing UI: `components/node-studio/{nodes/ImageNode.tsx,nodes/MasterCard.tsx,artboard/FocusMode.tsx,artboard/LayersPanel.tsx,artboard/FocusToolbar.tsx,shell/LayerProps.tsx}`, `lib/node-studio/artboardModel.ts`, store actions. Reuse Craft `KvFabricCanvas.tsx`/`fabric/*` lifecycle, overlay builders, reconciliation, transforms, text editing and selection. React Flow remains graph renderer.

- [ ] Replace mock swatches/fixture media with the shown server version's actual image and natural dimensions. Do not seed `masterKvArtboard` or manufacture overlays in real files.
- [ ] Extract the controlled single-board Fabric surface from existing lifecycle/reconcile/tools. `KvFabricCanvas` creates a private KV doc and its hooks attach KV Yjs even with callback overlays: move KV persistence attachment outside the shared surface. Never pass Studio Y.Doc as KvYDoc or create a hidden mirror. Reuse `KvSurface`, builders and geometry; no copied renderer or nonexistent KvTileOverlayEditor import.
- [ ] Persist overlays as StudioOverlay intent; migrate the prototype representation once on real files with stable IDs. Use existing editor/undo transactions; peer updates must not echo as local writes. Reuse base/overlay geometry helpers instead of manual viewport-to-pixel conversions.
- [ ] Reuse `buildBoardStaticCanvas`, thumbnail helpers and shared imageLoader for authoritative base-plus-overlay previews; never silently hide overlays behind a base-only fallback. Dispose async surfaces on target/version changes. Disable duplicate prototype delete/nudge/undo handling while Fabric owns focus.
- [ ] Connect layers panel, inspector and text/shape/image tools to Fabric selection/commits. Add/reorder/hide/lock/edit/move/resize operations, keyboard undo/redo and focus exit must work with read-only guards. Image overlays must use persistent existing upload infrastructure, not blob URLs that disappear on reload.
- [ ] Maintain focus and error accessibility, existing frndOS v2 components/tokens, loading and empty states. No whole prototype refactor outside this surface. Record actual focus-enter analytics; do not claim PostHog delivery without live proof.
- [ ] Require Studio file/tool/brand write authorization for image/reference/overlay uploads; the generic overlay asset route's workspace-only check is insufficient. Key region drafts by composition, shown base and optional variant to prevent stale-target submissions.

Acceptance: generate an image, open Edit, add text/shape/image, edit and reorder, undo/redo, see peer edits, reload, and reopen with the same base/layers. No KV overlay REST write occurs. A viewer cannot mutate or trigger paid runs.

### Task 6 — Master region edit and end-to-end proof

Existing UI: `components/node-studio/region/{RegionLayer,RegionOverlay}.tsx`, `lib/node-studio/regionEdit.ts`, store region actions. Existing executor: KV `mode=edit`, `BoundingBox[]`, shared mask/prompt helpers.

- [ ] Convert actual Fabric/base-image coordinates into normalized boxes, retain individual prompts and validate bounds. Enable one or multiple areas using the already-supported master endpoint.
- [ ] Store the region-edit operation/boxes as intent, quote from the actual pinned executor, and invoke the real Image run override. Keep the previous base visible during processing; show server-owned errors/cancel/retry.
- [ ] On success replace only the base reference. The immutable output captures the run-start layers/motion; meanwhile live layer/motion changes made by peers during the render remain live and are not overwritten by completion. Historic version view reads its own snapshot; returning to current editing uses live intent. Clear submitted region drafts only after accepted success, not on error/cancel.
- [ ] Complete the browser scenarios below and update PRDs/tracks/manifest with exact exercised results. Do not mark P2 verified on unit tests alone.

Acceptance: AC-10 and AC-11 hold in the actual Studio route, including existing-variant tabs and sparse leaf edits that reload/peer-sync without freezing unrelated properties. P3 fan-out/Refine creation, P4 size render/layout/staleness orchestration and P5 motion/PSD/share/download remain pending; no simulated paid success is shown as a real image run.

## Runtime verification

### Evidence already exercised during planning (not P2 feature proof)

A throwaway `bun -e` probe imported collab `docToStudioDocumentJson` and `nodeVersionFact` with in-memory Y.Doc:

- Document JSON keys are `nodes,wires,runFacts,nodeVersions`.
- Nested `nodes[].params.domain.artboards/motion` survives serialization; no new root map is necessary.
- An otherwise valid version with `output.kind=image` is rejected by the current schema. Task 3 must change that behavior.

No provider request, new UI, P2 implementation or P2 regression suite was executed during planning.

### Required implementation smoke, in dependency order

1. Check existing API/web/AI/collab services and queue before smoke. Use a disposable Studio file and authorized account, never fabricated production IDs or exposed credentials. Quote first; it must not spend. Use the displayed accepted price for paid runs.
2. Generate one actual Image from prompt. Observe queued/running/success and retrievable image pixels in both tabs; verify balance delta equals accepted quote, one run/version/generation, and same-key replay does not spend again.
3. Edit prompt/layers after start but before dispatch/return. Inspect captured metadata and immutable version: execution uses the capture; current live intent remains edited. The next version cannot mutate the first snapshot.
4. Open Fabric focus: text, shape and persistent image overlay, selection/inspector edits, layer order/visibility/lock, undo/redo, peer tab and reload. Observe no KV editor-intent API writes.
5. Draw one region and run; then two separated boxes with different prompts in one run. Observe new real base/version, preserved overlay/motion IDs/values, historic base still selectable and current live edits intact.
6. Cancel before dispatch and in flight; simulate provider failure/transport refusal. Observe no stuck running, no published late result and exactly one refund. Reject foreign source generation, invalid rectangle, read-only user and invalid image output without spend.
7. Exercise existing KV generation/edit once through its normal route to verify no changed imagery/overlay ownership/billing behavior. Re-run P1 text/brief smoke only for consumers affected by P2 changes.
8. After all edits, run the focused existing contract/regression checks once, touched-path lint/type checks, then browser visual proof. Record exact commands/results and unrelated pre-existing errors; do not re-pin incidental wording tests.
9. Exercise zero-cost Save version after overlay edits: the new snapshot contains edits, prior snapshot is unchanged, no provider/debit occurs. Two-tab edits to different layers/properties both survive. Old fact replay cannot regress a newer run, and forged Yjs output cannot become a trusted image source.

## Open product gates outside this plan

Feature-spec access, auto-overlay derivation on Refine, production flag/brandless permission policy, multi-node failure policy, P4 size orchestration and P5 export/share remain in the main PRD. Optional brand *execution normalization* must work in P2 without deciding broader permission policy. Do not infer approvals, mark implementation complete, or enable production access from this planning record.
