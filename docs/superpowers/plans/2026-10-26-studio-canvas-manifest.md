# Studio Canvas — Progress Manifest (2026-10-26)

Snapshot of what is built and what is planned for `studio-canvas` (worker daffa).
Source of truth for scope: `frnd/docs/prd/studio-canvas.md`. This file maps the
recorded specs/plans to the commits that implement them.

All four repos are on `feature/daffa/vc-studio-canvas`, rebased 2026-10-26 onto
`origin/develop` (api, web), `origin/development` (ai-service), `origin/main`
(collab). **Nothing is pushed; no PRs.**

| Repo | Commits on branch | Base |
|---|---|---|
| api | 11 | `origin/develop` |
| web | 66 (incl. Rafly's prototype merge) | `origin/develop` |
| ai-service | 3 | `origin/development` |
| collab (`frnd-hocuspocus`) | 2 | `origin/main` |

## Recorded documents

| Kind | Path |
|---|---|
| Main PRD | `frnd/docs/prd/studio-canvas.md` (phases P0–P5, OQ-1..OQ-8) |
| Service PRDs | `api/`, `web/`, `ai-service/` `docs/prd/studio-canvas.md` |
| Tracks | `api/`, `web/`, `ai-service/` `docs/tracks/studio-canvas.track.md` (collab has none) |
| Run engine spec | `docs/superpowers/specs/2026-10-21-studio-run-engine-p1-design.md` |
| P0 plans | `docs/superpowers/plans/2026-10-21-studio-canvas-p0-{api,collab,web-core,web-surface}.md` |
| Stage A plan | `docs/superpowers/plans/2026-10-21-studio-canvas-stage-a-prototype-bridge.md` |
| P1 run engine plans | `docs/superpowers/plans/2026-10-21-studio-run-engine-p1-{contracts,api,ai-service,collab,web}.md` |
| Decisions | `.workflow-state.json` → `features["studio-canvas"].brainstorming` |

P2 plan: `docs/superpowers/plans/2026-10-26-studio-canvas-p2.md` (recorded,
not implemented). P3..P5 have no executable plans yet.

## Status per plan

### P0 — core, persistence, file CRUD

| Plan | Tasks | Status | Commits |
|---|---|---|---|
| p0-api | 1 tool row + permission, 2 hide tool while flag off, 3 tables + models, 4 file create/read, 5 collab verify endpoint | Done | api `c2ea3776a`, `960cda8d5` |
| p0-collab | 1 `studio:` prefix + verifier, 2 `StudioPersistence` (`studio_yjs_updates`), 3 end-to-end smoke | 1–2 done; 3 (manual smoke) not recorded | collab `195c7e6` |
| p0-web-core | 1 values/ports, 2 records on Y.Doc, 3 node-type registry, 4 editor + undo, 5 migrations, 6 templates, 7 tool registry + barrel, 8 lint boundaries | Done | web `292adbc40`..`3a073defa` |
| p0-web-surface | 1 flag/routes/file API, 2 Hocuspocus sync, 3 File + Text plugins, 4 canvas surface, 5 shell/toolbar/keys, 6 PostHog, 7 manual check | 1–6 done; surface later replaced by Stage A; 7 not recorded | web `6c4c582b4`..`09a615ed9` |

### Stage A — Rafly's prototype UI on the real doc

| Plan | Tasks | Status | Commits |
|---|---|---|---|
| stage-a-prototype-bridge | 1 prototype port types, 2 NODE_SPECS as core types, 3 projection + diff, 4 binding, 5 real route renders prototype, 6 remove P0 surface, 7 tokens | Done (+ review fixes) | web merge `75976e764`, `458006684`..`8bd6e300a` |

Result: `/studio/canvas/[file_id]` (and the brand twin) shows the prototype UI;
nodes, wires, sections, stickies persist through collab. P1 now replaces the
Text generator and brief runs with the real API; other nodes remain free
simulations. Share / Download / Duplicate / Rename remain prototype-only.

### P1 — run engine (Text generator + brief reading)

| Plan | Tasks | Status | Commits |
|---|---|---|---|
| contracts (C0–C6) | binding contracts + input-hash vectors | Recorded | root `8a4b9d8`, `09193a2` |
| p1-api | 1 schema/enums/prices, 2 charger + exact refunds, 3 collab client/doc/resolver/hasher, 4 runner registry (text, brief), 5 intent API (start/quote/show/cancel/upload), 6 job + callback + settler, 7 watchdog, 8 PRD + track | **Done** | api `e856ab4dc`..`6c6bbdcc6` |
| p1-ai-service | 1 shared document reader, 2 text generator endpoint, 3 brief reading endpoint | **Done** | ai `9da8e34f`, `1db1e7a0`, `6b778996` |
| p1-collab | 1 document read + run-facts write routes | **Done** | collab `bde3d6b` |
| p1-web | 1 run facts + delete guard, 2 hashes/inputs/errors, 3 API client, 4 projection, 5 real actions, 6 failed UI + balance, 7 analytics/docs | **Implemented; local smoke verified** | Tasks 1–3: `cc33bd77b`, `059594370`, `06c7754bc`; Tasks 4–7: `2f98daafd` |

Fixed on 2026-10-26 (api): the callback read ai-service's `""` as `null`
(`ConvertEmptyStringsToNull`) and failed tagline/caption/plain-text and
empty-field brief outputs; plus the watchdog `studio:fail-stale-runs`.

### P2 — implemented + browser-verified; P3..P5 — not planned yet

| Plan | Tasks | Status | Commits |
|---|---|---|---|
| `2026-10-26-studio-canvas-p2.md` (contracts I0–I7) | api TASK-11..14, web TASK-19..23, ai TASK-7 | **Done; local smoke verified** | api `83df940ce`..`b303847da`; ai `d1a61d65`; collab `6e2834b`; web `a3ee23e12`..`6c4789d05` |

P2 delivered: Composition/variant routes + zero-cost Save version, immutable
pre-queue capture, one `image_render` runner (sketch/craft/region_edit) over the
existing `/ai/kv-generator/complete`, Studio-owned settlement with one charge and
one refund, real Image node, Fabric focus editor on an extracted surface, and
master multi-area region edit.

Browser proof on `01m5ve0k6p8a4btxkr1s8b330y`: real image run (1536×1024,
10 cr, one charge, one `kv_generations` mode `sketch`, one immutable version),
focus mode with Fabric, Text + Shape overlays persisting across reload, and a
two-area region edit producing v2 `operation=region_edit` with overlays kept.

Four defects were found by that smoke and fixed with tests: focus crashed on a
malformed persisted overlay (`3bc01718d`), Text/Shape never placed a layer
(`232a79a7f`), a non-ULID prototype id blocked every paid run with an opaque
error (`04f52a992`), and the migration left such ids in place (`6c4789d05`).

Not verified live: size tabs / sparse override writes (loaded composition had no
variants), image-overlay placement, two-tab overlay sync, in-flight cancel.

| Phase | Scope (main PRD §5) | api service PRD tasks |
|---|---|---|
| P3 | Section fan-out, Refine, "KV from a brief" end-to-end | TASK-15 |
| P4 | Size set, per-property overrides, Out of date, push-to-all, download all | TASK-16..17 |
| P5 | Motion, PSD entry, share for approval, download | TASK-18..20 |

## What can be tested today

- Through the UI: real single-node Text generator and PDF/DOCX, typed, or Lark
  brief requests; server run state, version navigation/edits, input staleness,
  Keep, cancel, safe failure/Retry UI, and real effective credits. Non-P1 nodes
  remain simulations. Live Lark extraction was not exercised in this session.
- Browser proof on `01m5ve0k6p8a4btxkr1s8b330y`: three real taglines with a
  2-credit debit, peer output/edit sync, v1/v2 selection and reload persistence,
  Keep, DOCX extraction at 0 credits, cancellation preserving the previous
  version, and network failure without stuck running.
- Upload smoke exposed the default local disk's missing temporary URLs. Fixed
  upload storage to private S3, matching existing attachment handling; real
  DOCX extraction then succeeded. Backend regression: 3 passed/10 assertions.
- Core/API/bridge: 185 checks passed; prototype/UI: 382 passed. Typecheck has
  unrelated repo errors; no diagnostics in the touched Studio paths.

## Open items

- P2 implementation follows the recorded plan; P3–P5 planning remains pending.
- P1 checkpoints saved locally: web `2f98daafd`, api `6d1f3a7c5`,
  ai-service `c1c055d3`. Nothing pushed; no PRs.
- Spec §12 "calls not yet confirmed by Daffa" (charge up front, edits per
  version, mock runs free, deleted-mid-run keeps version + refund, `failed`
  state, brief reading free, shown version flows downstream, per-input hashes).
- Main PRD open questions OQ-1..OQ-7 (OQ-1: feature spec artifact not shared
  with agents; OQ-7 overlaps the multi-node failure policy).
- Before the flag goes on: `BrandRoleFeatureGate` entry (web lockstep),
  brand-less file permission decision.
- Older P0-only smoke checklists were not separately re-executed; P1 browser
  proof now covers actual two-tab run output and edit synchronization.
- Web and ai-service tracks reconciled on 2026-10-26; collab has no track.

## P2 planning evidence

- Existing KV `/complete` provides image generation and master region edit,
  but returns events, not a Studio callback. Keep its inference pipeline;
  add an API image transport with its own bounded job budget.
- Studio is the single charge/refund owner. Ordinary KV persistence meters
  separately, so reusing it unmodified would double-charge.
- In-memory collab smoke: nested `nodes[].params.domain` retains artboard and
  motion intent; current `nodeVersionFact` rejects `output.kind=image`.
  No new root artboards map or document-read endpoint is needed.
- Capture immutable inputs before queueing and store history with each Studio
  version; mutable Composition cache columns alone are insufficient.
- P2 implementation, provider calls and browser proof have not started.
