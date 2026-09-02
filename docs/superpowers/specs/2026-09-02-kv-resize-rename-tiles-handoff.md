# Handoff — KV Resize: rename a tile

> **Written:** 2026-09-02, at the end of the duplicate-custom-tile session.
> **For:** a fresh session picking up the rename feature.
> **Read this whole file before doing anything.**

## Where the current work stands

The **duplicate-custom-tile** feature is complete and merge-ready on branch
`feature/daffa/vc-kv-resize-duplicate-tile`, which exists in **two separate
repos** under this workspace:

- `api/` — 6 commits, `98db0917..0486c71b`
- `web/` — 10 commits, `1ff91419e..a0a076976`

Both are **local only, unpushed**, and **Daffa has not yet chosen** whether to
merge locally, push a PR, or leave them. Do not decide that for him. Rename
should be its **own branch cut after** that decision, not stacked onto a
merge-ready branch.

Spec: `docs/superpowers/specs/2026-09-02-kv-resize-duplicate-tile-design.md`
Plan: `docs/superpowers/plans/2026-09-02-kv-resize-duplicate-tile.md`

**Nothing in that feature has ever been clicked in a browser.** The runtime
checklist is at the end of the plan; it is still owed.

## The feature being brainstormed

Let a user rename a resize tile, so "100 × 200 (2)" can become something
meaningful like "Hero variant". The duplicate-tile spec deferred this
deliberately, with the reasoning: naming is only useful *after* the result is
visible, so the right shape is **rename-after-the-fact**, not a name field on
the create form.

## Verified facts — do not re-derive, and do not trust the old spec here

The duplicate-tile spec claims the label "is synthesised at exactly one site per
side". **That claim is wrong** and was corrected by inspection at the end of the
session. There are **two** label paths in web:

**Path 1 — server-sent, and it has a genuine choke point.**
`api/app/Http/Resources/KvResizeExportResource.php:22`:

```php
'platform_label' => $platform['label'] ?? CustomResizeSize::labelFor($platformId) ?? $this->platform_id,
```

Insert `$this->name ??` at the front of that expression and **six** web
consumers get rename for free, untouched:

- `web/src/components/studio/kv-generator/KvResizeResultRow.tsx:265` — the canvas tile's own label
- `web/src/components/studio/kv-generator/KvResizeCanvas.tsx:2439` — `tileLabel`
- `web/src/components/studio/kv-generator/resizeBoardLayout.ts:138`
- `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx:3092` and `:3180`
- `web/src/components/studio/kv-generator/KvChat.tsx:2541` — the regenerate chip

**Path 2 — client-derived, and it does NOT see the row.**
`platformById(id)` in `web/src/lib/studio/kv/resizePlatforms.ts` takes only an
id, so it cannot know a name. Its consumers are the panel rows (`PlatformRow`
in `KvResizePanel.tsx`) and `web/src/app/share/[token]/KvShareClient.tsx`.
The panel already has the export (`ex`) in scope, so preferring
`ex.platformLabel` there is a one-line change.

**The share page is the scope multiplier.** Its payload carries only
`platform_id` and derives the label client-side, so a renamed tile will NOT
show its name on a public link unless the name is added to the share payload.
Decide explicitly whether that is in scope.

## Other verified facts

- `kv_resize_exports` has **no** `name` column. Its `$fillable` is in
  `api/app/Models/KvResizeExport.php`. There IS a jsonb `metadata` column, but
  do **not** put the name there: `metadata` is deliberately NOT copied when a
  tile is duplicated, and it holds render-lifecycle caches and markers. A name
  would inherit the wrong rule. Use a real nullable column.
- A `PATCH files/{file}/resize-exports/{export}/overlays` route already exists
  (`api/routes/api.php:4133`), so there is precedent for a PATCH here. **Do not
  extend that route.** `excludeUnvalidatedArrayKeys` is on in this project, and
  a `payload.*` validation rule has previously stripped an entire overlay
  payload. Give rename its own small route.
- Rough estimate from the same inspection: **~1 day** without the share page,
  **~1.5 days** with it. Most of the time is the edit affordance, not the
  plumbing.

## Two design decisions that need Daffa, not an assumption

1. **Duplicating a named tile.** He has "Hero variant" and duplicates it. Is the
   copy "Hero variant", "Hero variant (copy)", or does it fall back to the
   derived `100 × 200 (2)`?
2. **Duplicate names.** Once a tile can be named, the ordinal `(2)` disappears
   from its label — so two tiles could both be "Hero" and be ambiguous again,
   which is exactly the problem the duplicate feature just solved. Reject
   duplicate names, or keep appending the ordinal after the name?

Ask these with the ask tool. Do not pick for him.

## Environment traps that will cost you an hour each

- **api Feature tests need a scratch Postgres.** `phpunit.xml` pins
  `DB_CONNECTION=sqlite`/`:memory:`, but the migrations use `DROP SEQUENCE`,
  which SQLite rejects. A shell env var overrides the pin:

  ```
  DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test TELESCOPE_ENABLED=false ./vendor/bin/pest <paths>
  ```

  The database `frnd_dup_tile_test` exists and is migrated. **Never** point it
  at `DB_DATABASE=frnd` — that is the live dev database and `RefreshDatabase`
  would wipe it. Pass test paths, never `--filter`.
- **`bun run build` is broken** and it is not your change: it dies loading
  Next's compiled server runtime (`Expected CommonJS module to have a function
  wrapper`), which Bun's own message calls a Bun bug. Build with
  `node ./node_modules/next/dist/bin/next build`, which succeeds.
- **`web/src/app/share/[token]/KvShareClient.test.tsx` must run alone.**
  Combined with other suites it dies on `@tremor/react`'s bundled
  `@headlessui/react` patching `HTMLElement.prototype.focus` at import time.
  Symptom: the run reports fewer tests than the files hold.
- **`bun test` on a directory has consumed tens of gigabytes** here. Always pass
  specific file paths. Test files import from `"vitest"`; that is correct, do
  not "fix" it.
- **There is no type gate** (`ignoreBuildErrors`) and `tsc` has an ~810-error
  baseline. Diff error sets by `file:line` against a baseline rather than
  reading totals. Known pre-existing, unrelated: `KvShareClient.tsx:228` and
  `:230` (`TS2339`, `image_url` on `PublicKvItem`), and
  `KvGeneratorLayout.tsx:6681` (`TS2322`). Also one pre-existing failing test in
  `KvResizeResultRow.test.tsx`, which queries
  `/reset overlays to project default/i` while the real aria-label is
  `"Not following master — reset to follow"` — a stale expectation from an older
  rename, not yours.
- **PostHog events are part of a web feature here.** A mutation's funnel moments
  must come in success AND failure. Use a typed `track*` wrapper calling
  `safeCapture` in `src/lib/analytics/`, never a raw inline `posthog.capture`,
  and never hand-pass `user_id`/`workspace_id`/`brand_id` — super properties
  attach those automatically.

## Still owed to Daffa from the last session, not code

- A taxonomy row in the Lark wiki for `kv_generator.resize_tile_duplicated` and
  `kv_generator.resize_tile_duplicate_failed` (use those exact strings).
- PostHog event descriptions, tags and `verified` after the first production fire.
- Consider a `source: "canvas" | "panel"` property on those events. He chose two
  entry points over a one-entry-point recommendation; that property is the data
  that would confirm or refute the choice. Deliberately not implemented.

## How to start

Invoke `superpowers:brainstorming` **before** anything else — before reading
code, before clarifying questions. This is a new feature, so it is that skill's
territory, and it will route to writing-plans afterwards.
