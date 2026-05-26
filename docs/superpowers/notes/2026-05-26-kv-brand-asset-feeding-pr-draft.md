# KV Brand Asset Feeding — Layer 1 + B3 — PR Description Draft

This branch bundles two passes that together solve the reported bug "tambahkan logo Telkomsel → AI falls back to web-search instead of using the brand's stored logo." Layer 1 makes the LLM **aware** of the brand's visual assets. B3 makes the IMAGE-GENERATION MODEL actually **embed** the real brand logo into the output.

## Why

Reported issue: prompts like "tambahkan logo Telkomsel" produced KVs with a generic / web-searched / hand-drawn logo. Root cause was two-fold:

1. The ai-service received only `brand_name`, `dna`, `identity`, `tonality` — no visual-asset fields. → **Solved by Layer 1.**
2. Even when the LLM included the logo URL in the image prompt, `gpt-image-2` tokenizes URLs as text strings — it can't actually fetch URLs and embed images from prompts. → **Solved by B3.**

## What this branch does

### Layer 1 — feed visual context to the LLM (additive only, zero migration)

- **ai-service**: extends `PrefetchedBrand` schema with 5 new fields (`logo_url`, `color_palettes`, `fonts`, `visual_dos`, `visual_donts`); renders them as a labelled block in the KV system prompt; adds a "brand asset priority" directive in `base.py` and an unconditional Logo URL inclusion directive in `image_mode.py`.
- **api**: adds `buildBrandVisuals()` helper to `ChatService`, resolves the brand logo URL via `Storage::disk('s3')->url()` (bypasses the JSON-only accessor), merges the visuals into the prefetched payload, and updates the demo brand fixtures with matching visual data.

### B3 — actually embed the real logo via img-to-img (server-side fetch in ai-service)

- **ai-service**: adds `brand_logo_fetcher.py` with `maybe_fetch_brand_logo_as_attachment()`. After the image-mode LLM finalises the image prompt, it scans the prompt for the brand's logo URL string. If found, it fetches the bytes server-side via `httpx`, MIME-validates via magic-byte sniffing, base64-encodes, and appends the resulting `Attachment` to `request.attachments`. The existing `should_iterate` check then routes the call through `/v1/images/edits` (img-to-img mode) so gpt-image-2 actually sees the brand logo bytes — not just a URL string in the text prompt.
- **api**: zero changes (Layer 1 already supplies `logo_url` via the `PrefetchedBrand` schema). The earlier api-side keyword-heuristic Layer 2 (`BrandLogoIntentDetector` + `BrandLogoAttachmentBuilder`) was reverted because the final user turn before image-mode is typically a content-free confirmation like "yes, generate it" — keyword scan there missed the logo intent expressed several turns earlier. The LLM's full-context decision (URL in the produced prompt) is a strictly stronger signal.

## Architecture: why B3 over api-side keyword detection

The api-side keyword approach (now reverted) only saw `$userQuery` from the latest turn. Real Studio KV flow:

```
Turn 1 (chat):  "buat KV ramadan dengan logo Telkomsel"  ← logo intent HERE
Turn 2 (chat):  refinement
Turn 3 (chat):  "yes, generate it"                       ← API sees only this
                                                          → "yes, generate it" has no "logo" keyword
                                                          → no attachment, falls back to text-to-image
```

B3 sits ON the ai-service side, AFTER the LLM has produced the final image prompt. The image-mode LLM has full chat history context and is instructed (Layer 1 directive) to include the brand logo URL when relevant. If it does, the URL is in the final prompt — that's the signal B3 uses to fetch and attach. Self-correcting: if the user said "tanpa logo" anywhere, the LLM won't include the URL → no fetch → text-to-image path.

## Scope NOT in this branch

- Logo variants (dark / light / mono / horizontal) — needs a `brand_assets` table (Layer 3 / separate PRD)
- Mascots, products, patterns, photography references, packaging
- Web upload UI for brand assets
- Caching of fetched logo bytes (1 S3 GET per image-mode generation is fine for now)

## Two PRs to open

1. **ai-service** → `development`: 10 commits, ~700 insertions across 7 files
2. **api** → `develop`: 13 commits, ~370 insertions / 620 deletions (net positive; the deletions are the reverted Layer-2 keyword path) across ~7 files

## Test plan

- [x] ai-service: `pytest tests/agents/kv_generator/test_context_builder.py tests/agents/kv_generator/test_schemas.py tests/agents/kv_generator/test_brand_logo_fetcher.py tests/agents/kv_generator/test_service_image_mode_logo_embedding.py` — **29/29 pass**
  - `test_schemas` — 8 tests (5 from Layer 1 + 3 from KvStreamRequest validation)
  - `test_context_builder` — 10 tests (5 pre-existing + 5 from Layer 1 brand block rendering)
  - `test_brand_logo_fetcher` — 9 tests (happy path + 8 failure modes)
  - `test_service_image_mode_logo_embedding` — 2 integration tests (img-to-img path + text-to-image fallback)
- [ ] api Feature tests (`BrandAssetFeedingTest`) — **cannot execute due to pre-existing migration infra bug**. Several migrations contain PostgreSQL-only raw SQL (`DROP SEQUENCE IF EXISTS`, `ALTER TABLE ... DROP CONSTRAINT`) without driver guards; Pest's `RefreshDatabase` against SQLite in-memory fails. Tracked as a separate cleanup task. The Layer-1 test file is structurally correct and will run once the migration sweep ships.
- [ ] **Manual smoke**: log in, switch to a workspace with a brand that has a logo (e.g. FCN workspace's Telkomsel in the staging dump), enable Brand Knowledge, run a multi-turn KV conversation that establishes logo intent and confirms generation. Verify:
  - ai-service log shows `POST .../v1/images/edits` (NOT `/v1/images/generations`) — confirms img-to-img routing took effect.
  - Generated KV embeds the **actual Telkomsel logo** (real red Telkomsel mark), not a hand-drawn "TELKOMSEL" text approximation.
  - `kv_generations.prompt_snapshot` contains the brand logo URL string (Layer 1 directive still working).

## Pre-flight before running any Feature test

Always confirm `bootstrap/cache/config.php` does NOT exist before running pest. If it does, run `php artisan config:clear` first. The cached config bakes `DB_CONNECTION=pgsql` from `.env` and silently defeats phpunit.xml's `DB_CONNECTION=sqlite` override → `RefreshDatabase` then wipes the dev Postgres DB. This bit us during smoke testing.

## Commits

### ai-service (`development` ← `feature/daffa/vc-kv-brand-asset-feeding`)

```
0bcf4c7 test(ai): integration test for B3 logo URL → img-to-img routing
67fb3a0 refactor(ai): tighten B3 canvas-mode guard to sketch-only allowlist
7199857 feat(ai): inject brand logo as img-to-img reference when URL in final prompt
9461230 refactor(ai): align brand-logo fetcher logs + split empty/oversized branches
027f4d5 feat(ai): add server-side brand-logo fetcher for B3 img-to-img routing
1b08ea4 refactor(ai): unconditional logo-URL directive + image-mode test
f02e006 feat(ai): instruct KV agent to prefer brand-provided assets
01a082e refactor(ai): simplify brand block guards + partial-payload test
35d9da5 feat(ai): render brand visual assets in KV system prompt
feef997 feat(ai): extend PrefetchedBrand with visual asset fields
```

Files changed: 7
- `app/agents/kv_generator/request_schema.py` — 5 new fields on `PrefetchedBrand`
- `app/agents/kv_generator/context_builder.py` — brand visual block rendering
- `app/agents/kv_generator/prompts/base.py` — brand asset priority directive
- `app/agents/kv_generator/prompts/image_mode.py` — unconditional logo-URL directive
- `app/agents/kv_generator/brand_logo_fetcher.py` — **new** (B3 helper, ~140 LOC)
- `app/agents/kv_generator/service.py` — B3 wire-in (16 LOC inside `_run_image_mode`)
- `tests/agents/kv_generator/test_context_builder.py` — new (~170 LOC)
- `tests/agents/kv_generator/test_schemas.py` — new (~35 LOC)
- `tests/agents/kv_generator/test_brand_logo_fetcher.py` — **new** (~165 LOC)
- `tests/agents/kv_generator/test_service_image_mode_logo_embedding.py` — **new** (~245 LOC)

### api (`develop` ← `feature/daffa/vc-kv-brand-asset-feeding`)

```
26860d7f revert(api): drop Layer 2 keyword-based logo embedding (B3 supersedes)  ← revert
92dbce10 test(api): cover brand-logo attachment injection in KV stream payload
88149b05 refactor(api): use imports for brand logo services in ChatService
1344c000 feat(api): inject brand logo as img-to-img reference when user requests it
072ec713 feat(api): add BrandLogoAttachmentBuilder for KV img-to-img references
92af90e7 refactor(api): broaden BrandLogoIntentDetector negation phrasings
ff2b8092 feat(api): add BrandLogoIntentDetector for KV brand-logo embedding
2e6fec86 docs(api): align demo brand docblocks with widened brand context shape
cf3a79d7 feat(api): include visual assets in demo brand fixtures
14c227a5 test(api): clearer assertions + Storage fake for brand asset test
a5b73f91 test(api): cover brand visual assets in KV stream payload
a9ac3ed7 fix(api): resolve brand logo URL explicitly for KV payload
a955ec73 feat(api): include brand visual assets in KV prefetched payload
```

The first commit (chronologically last) is the revert of the api-side keyword L2. Squash-on-merge will collapse this into a clean net diff: the Layer-1 work + the demo fixture updates + the brand-logo accessor fix. The intermediate L2 commits won't appear in the develop history.

Files changed (final state after revert):
- `app/Services/ChatService.php` — `buildBrandVisuals()` helper + payload merge
- `app/Data/DemoBrand/DemoBrandProvider.php` — demo fixture visual fields
- `app/Data/DemoBrand/DemoBrandData.php` — docblock alignment
- `tests/Feature/Chat/BrandAssetFeedingTest.php` — Layer-1 integration test (cannot execute due to pre-existing infra bug; see Test plan above)
