# KV Brand Logo — Strict Server-Side Bake — Design

> **Status:** design (awaiting review)
> **Date:** 2026-06-04
> **Author:** daffa
> **Services:** api, ai-service, web
> **Supersedes:** the "B3" logo path (logo URL → image prompt → gpt-image img-to-img). See
> `docs/superpowers/plans/2026-05-26-kv-generator-b3-server-side-logo-url-detection.md`,
> `…-brand-logo-embedding-layer2.md`. Layer-1 brand-asset feeding (palette/fonts/dos-donts) stays.

## Problem

When a user asks the KV generator to add the brand logo, the current pipeline routes the logo
through the image-generation model (gpt-image-2). Two failure modes result:

1. **Detection is fragile (B3 lapis 1).** The logo is only fetched if the LLM happens to echo the
   exact S3 URL into the final image prompt (`if logo_url not in prompt: return None` in
   `brand_logo_fetcher.py`). S3 logo filenames contain spaces/commas (e.g.
   `logos/1778068911_ChatGPT Image May 6, 2026, 06_56_16 PM.png`), so URL-encoding mismatches break
   the substring match. When it misses, generation falls back to text-to-image and the model
   **invents a wordmark from the brand name** — this is why frndGlow rendered the text "frndGlow"
   instead of its droplet logo even though a valid PNG logo exists in the DB.
2. **Generative models cannot guarantee an untouched logo (B3 lapis 2).** Even on the happy path,
   `/v1/images/edits` regenerates the whole canvas using the logo as a *reference* — it does not
   composite. gpt-image-2 can redraw, recolor, restyle, or add elements to the logo. The
   "embed pixel-for-pixel" instruction in the prompt is a plea a diffusion model cannot honor.

**Goal:** the brand logo must appear in the output **exactly as supplied in the brand guideline**,
never altered by a generative model — i.e. a strict, deterministic paste.

## Decisions (locked during brainstorming)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Relationship to existing B3 logo path | **Replace entirely.** Logo never enters a gpt-image prompt again. |
| 2 | Treatment of the logo pixels | **Baked into the generated raster** (single flat image), NOT an interactive canvas overlay layer. |
| 3 | How "place logo + where" is decided | **LLM structured output** from the image-mode agent. |
| 4 | Logo background handling | **Composite as-is** (assume transparent PNG); zero modification of the logo. |
| 5 | Persistence across regenerations | **Sticky.** A small `{anchor, scale}` spec is persisted and auto re-baked on every subsequent generation until removed. |
| 6 | Where compositing + state live | **ai-service composites (download → stamp → re-upload); api supplies the logo bytes, supplies the persisted spec, and persists the resolved spec by intercepting the ai-service stream. Web needs no changes.** |

### Baked-in vs. existing overlay (explicit, to avoid confusion)

The persisted state is **metadata only** (`{anchor, scale}` — zero pixels). It is NOT an overlay
layer. The logo pixels are fused into the generated raster by ai-service before S3 upload. The user
cannot drag/resize the baked logo on the canvas; repositioning is done via chat ("pindah logo ke
kiri atas") which triggers a re-stamp. This is distinct from the app's existing canvas-overlay
treatment (movable layers flattened at export).

## Architecture overview

```
  web: NO CHANGES (the logo is baked into the returned generation image; the
       stamp spec is server-internal). The browser renders generation_done as today.

┌──────────────────────────── api (Laravel) ─────────────────────────────┐
│ ChatService::streamKvGenerator                                          │
│  outbound (build KvStreamRequest):                                      │
│   - if image-producing + brand-knowledge + brand has logo: read logo    │
│     bytes via Storage::disk('s3')->get(getRawOriginal('logo')) →        │
│     base64 → request.brand_logo {data_base64, mime_type}               │
│   - include persisted studio_files.brand_logo_stamp in request          │
│  inbound (consume ai-service NDJSON stream, same loop as generation_     │
│   ready): on `logo_stamp_state` event → write studio_files.brand_logo_  │
│   stamp (the resolved {anchor,scale} or null). No browser relay needed. │
└───────────────────────────────────┬─────────────────────────────────────┘
                                     │  KvStreamRequest / NDJSON events
                                     ▼
          ┌──────────────────── ai-service ───────────────────────┐
          │ kv_generator/service.py (image / craft / edit / resize)│
          │  1. refine image_prompt as today (logo NOT mentioned)  │
          │  2. classify_logo_directive(chat_history, prompt,      │
          │     logo_available) → {action, anchor, scale}          │
          │     (dedicated small-model JSON call)                   │
          │  3. resolve_stamp(directive, request.brand_logo_stamp) │
          │     → ResolvedStamp | None                             │
          │  4. generate scene (logo NOT involved)                 │
          │  5. if ResolvedStamp and request.brand_logo present:   │
          │     download generated image → stamp_logo() PIL        │
          │     composite/flatten → re-upload via upload_file_to_s3│
          │     → replace render image_url/thumbnail_url           │
          │  6. emit GenerationReadyEvent (as today) +             │
          │     LogoStampStateEvent(stamp=ResolvedStamp|null)      │
          └─────────────────────────────────────────────────────────┘
```

## Components

### 1. api — supply logo bytes + persisted spec

**`app/Services/ChatService.php` (KV stream assembly)**
- Drop the Layer-1 `logo_url` from the prefetched brand block that feeds the *prompt* (the agent no
  longer needs the URL). Keep a boolean signal that a logo exists (see context_builder below) — done
  by sending the logo bytes (their presence is the signal).
- When the request is **image-producing** (`mode` ∈ {image, edit} or a resize/craft generation),
  brand-knowledge is ON, and the brand has a logo: read the raw object via
  `Storage::disk('s3')->get($brand->getRawOriginal('logo'))`, base64-encode, and attach as a
  dedicated request field `brand_logo: {data_base64, mime_type}`. MIME sniffed from bytes; reject
  anything outside `image/png|jpeg|webp|gif` (send `null` if rejected).
- Include `brand_logo_stamp` (the persisted `{anchor, scale}` or `null`) from the studio file in the
  request.
- Do **not** persist `brand_logo` bytes anywhere — it is request-scoped only.

**Studio file model + migration**
- New nullable jsonb column `brand_logo_stamp` on `studio_files`:
  `{ "anchor": "<9-grid>", "scale": "small|medium|large" }` or `null`. Add to the model `$fillable`
  + `$casts` (`'brand_logo_stamp' => 'array'`), mirroring the existing `overlays` column.

**Inbound stream interception (persist the resolved spec)**
- In the `switch ($parsedData['event'])` loop (`ChatService.php:631`), add a
  `case 'logo_stamp_state':` that loads the studio file and writes
  `brand_logo_stamp` = the event's `stamp` (the `{anchor, scale}` map, or `null` on remove). This
  mirrors how `generation_ready` (`ChatService.php:774`) does a mid-stream DB write. No browser relay
  and no new PATCH endpoint — the stamp is server-internal (the logo is already baked into the image
  the browser receives).

### 2. ai-service — structured directive, resolver, compositor

**`app/agents/kv_generator/request_schema.py`**
- Add to the request model:
  - `brand_logo: Optional[BrandLogoAsset]` where `BrandLogoAsset = {data_base64: str, mime_type: Literal[...]}`.
  - `brand_logo_stamp: Optional[BrandLogoStamp]` where
    `BrandLogoStamp = {anchor: Anchor, scale: Scale}`.
  - `Anchor = Literal["top-left","top-center","top-right","mid-left","center","mid-right","bottom-left","bottom-center","bottom-right"]`
  - `Scale = Literal["small","medium","large"]`
- Stop rendering `logo_url` in the prompt. The field may stay in `PrefetchedBrand` for backward
  compatibility but is unused by this feature (the agent no longer needs the URL).

**`app/agents/kv_generator/prompts/image_mode.py`**
- Remove all logo-URL / "embed pixel-for-pixel" / sub-brand-logo instructions. The refined
  `image_prompt` MUST NOT mention the logo at all (the logo is composited separately).

**Logo-intent classifier (dedicated LLM call, not the main refiner)**
- Rather than re-plumb the streaming refiner (`_llm_stream`) to emit a Pydantic model, add a focused
  classifier call — same pattern as the existing `_stream_post_generation_summary` gpt-4o-mini call.
- `classify_logo_directive(chat_history, user_prompt, logo_available: bool) -> LogoDirective`
  returns structured JSON:
  ```
  LogoDirective { action: "place" | "remove" | "none", anchor: Anchor | null, scale: Scale | null }
  ```
- Instruction: "If the user asks to add/move the brand logo → `action=place` with the requested
  corner/scale (default `bottom-right`/`medium`). Remove/hapus logo → `action=remove`. Otherwise
  `action=none`." Runs only when `logo_available` (api sent `brand_logo`). Defensive default on any
  error / missing key: `action=none`.

**`app/agents/kv_generator/context_builder.py`**
- `_format_brand_block`: drop the `- Logo URL: …` line. The main refiner stays logo-agnostic; logo
  awareness lives only in the classifier (which receives `logo_available` directly).

**`app/agents/kv_generator/logo_stamp.py` (new)**
- `resolve_stamp(directive, persisted) -> Optional[BrandLogoStamp]`
  - `action=place` → `{anchor, scale}` from directive (apply defaults for nulls). Becomes new spec.
  - `action=remove` → `None` (clears persisted).
  - `action=none` → return `persisted` (sticky).
- `stamp_logo(scene_png: bytes, logo: bytes, stamp: BrandLogoStamp) -> bytes`
  - PIL: open scene (RGBA), open logo (preserve alpha), resize logo so its width =
    `scale_pct(scale) × scene_width` (small 8% / medium 12% / large 18%), preserving aspect ratio,
    **never upscaling beyond the logo's native resolution** (cap to native to avoid blur).
  - Position at `anchor` with a fixed edge margin = 4% of the scene's shorter side. `center`/`mid-*`
    use geometric centering on the relevant axis.
  - `alpha_composite` the logo, flatten back to the scene's output format, return bytes.
  - Pure function, no I/O — unit-testable.

**`app/agents/kv_generator/service.py`**
- Image-mode flow: refine `image_prompt` as today; run `classify_logo_directive(...)` to get the
  directive; generate the scene logo-free (logo no longer appended to `attachments`).
- Because the image tools (`edit_image_fn`, `_render_image`) return an already-uploaded `image_url`
  (not raw bytes), the stamp step is **download → composite → re-upload**: after `render` is obtained,
  `stamp = resolve_stamp(directive, request.brand_logo_stamp)`; if `stamp and request.brand_logo`:
  `_download_image(render["image_url"])` → `stamp_logo(...)` → write to a temp file → `upload_file_to_s3(...)`
  (mirror the `generate_image.py:412` call: `file_permission="public"`) → replace
  `render["image_url"]` and `render["thumbnail_url"]` with the new URL.
- Apply this stamp step in `_run_image_mode` (sketch + craft) and `_run_edit_mode`; resize reuses the
  same helper. For regenerations with no fresh `place`/`remove` directive, the resolver returns the
  persisted `brand_logo_stamp` (`action=none` semantics) → the logo survives iteration and stays
  pristine even after a generative edit.
- Emit `LogoStampStateEvent(stamp=<resolved {anchor,scale} or null>)` right after
  `GenerationReadyEvent` so api persists it.
- Delete `brand_logo_fetcher.py` and its wiring (`service.py:263-286`), the `logo_url` line in
  `image_mode.py`/`craft_mode.py`, and their tests.

### 3. web — no changes

The logo is baked into the generation image the browser already receives via `kv_generation_done`;
the stamp spec is persisted server-side by api. The canvas renders the returned image unchanged.
No new SSE event handling, no studio-file PATCH, no type changes are required for v1.

## Data flow (happy path)

1. User: "tambahkan brand logo di kanan bawah, tanpa teks."
2. api: image-producing + brand-knowledge ON + brand has logo → reads S3 logo bytes → base64 →
   `request.brand_logo`; `request.brand_logo_stamp = null` (first time).
3. ai-service: refines `image_prompt` (no logo mention); classifier →
   `{action:"place", anchor:"bottom-right", scale:"medium"}`.
4. `resolve_stamp` → `{bottom-right, medium}`.
5. Scene generated (logo-free) and uploaded by the image tool. ai-service downloads it, `stamp_logo`
   composites the real logo bottom-right, re-uploads, swaps the URL in `render`.
6. `GenerationReadyEvent` (api writes the kv_generations row) + `LogoStampStateEvent {bottom-right,
   medium}` → api writes `studio_files.brand_logo_stamp`.
7. Next turn "buat background lebih biru": api sends `brand_logo` + persisted
   `{bottom-right, medium}`; classifier returns `action:none`; resolver returns the persisted spec;
   logo re-baked automatically at the same spot.
8. "hapus logo": classifier returns `action:remove`; resolver returns `null`; no composite;
   `LogoStampStateEvent {stamp:null}` → api clears `studio_files.brand_logo_stamp`.

## Edge cases

- **No logo / fetch fails / bad MIME:** api sends `brand_logo = null`. ai-service skips compositing
  even if a stamp is active; the agent surfaces a short note ("logo brand belum tersedia"). No crash.
- **Aspect ratio change (resize):** anchors are relative, so position recomputes correctly for the
  new canvas; scale is a % of the new width.
- **Edit in the logo's corner:** the logo is re-stamped on top after the edit, so the brand lockup
  stays exact (desired for a strict lockup).
- **Logo larger than scale target:** downscale to target. Smaller than target: cap at native (no
  upscale → no blur).
- **Logo with an opaque background (not transparent):** out of scope for v1 — composited as-is per
  decision #4. Mitigation: recommend brands upload transparent PNGs. Auto knockout/rembg is a
  documented future enhancement.

## Testing

**ai-service (pytest)**
- `resolve_stamp`: place (with/without defaults), remove, none-with-persisted, none-without-persisted.
- `stamp_logo`: correct anchor pixel region for each of the 9 anchors; width matches scale %; aspect
  ratio preserved; no upscale beyond native; alpha respected; output decodes as a valid image.
- service integration: image-mode with `action=place` → output bytes contain the logo at the anchor;
  sticky (turn 2 with `action=none` + persisted spec → still stamped); `action=remove` → not stamped;
  `brand_logo=null` → not stamped, no error; `logo_stamp_state` event emitted with the resolved spec.

**api (Pest)**
- KV stream request carries `brand_logo` (base64 + mime) when image-producing + brand has logo;
  carries `null` when brand has no logo or mode is chat.
- KV stream request carries the persisted `brand_logo_stamp` from the studio file.
- Inbound `logo_stamp_state` event handling persists `{anchor, scale}` to
  `studio_files.brand_logo_stamp`, and clears it to `null` on remove.
- Migration: column exists, nullable, jsonb.

**web**
- No changes → no new tests.

## Out of scope (v1)

- Auto background removal / white knockout (decision #4 — as-is only).
- User drag/resize of the baked logo (that is the existing overlay treatment; not this feature).
- Multiple logos / logo variants (dark/light/mono).
- Logo placement in pure chat mode (no image produced).

## Migration / rollout notes

- This branch already contains B3 code. Removing it (fetcher + img-to-img-for-logo + prompt logo
  instructions + Layer-1 `logo_url` prompt rendering) is part of this work, gated behind the same PR.
- Layer-1 non-logo brand feeding (palette, fonts, visual dos/donts) is untouched.
- DB-safety: any Pest run must verify `api/bootstrap/cache/config.php` is absent first (known
  dev-DB-wipe foot-gun — see `lesson_test_db_isolation`).
