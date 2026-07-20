# KV Generator Brand Asset Feeding (Layer 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Feed the KV Generator's LLM the brand's existing visual assets (logo URL, color palette, fonts, visual dos/donts) so it can auto-use them — e.g. resolve "tambahkan logo Telkomsel" against the stored brand logo instead of web-searching or asking the user to upload.

**Architecture:** Extend the `PrefetchedBrand` Pydantic schema with visual-asset fields, mirror them in the Laravel `ChatService` payload (sourcing from existing `brands` columns that are already populated by the Brand Knowledge UI), and update the KV-generator system prompt so the LLM knows to **prefer brand-provided assets over web search/upload** unless the user explicitly overrides. Zero schema migrations — every field already lives in the `brands` table.

**Tech Stack:**
- AI Service — Python 3.12, FastAPI, Pydantic v2, pytest, Agno agents
- API — Laravel 13, PHP 8.5, Pest 3, PostgreSQL
- Communication — JSON over HTTPS (ai-service `KvStreamRequest` payload)

**Branch:** `feature/daffa/vc-studio-projects-kv-generator` (extends the in-flight feature)

**Scope boundary (explicit):**
- ✅ Logo (single primary URL) — `brands.logo`
- ✅ Color palettes — `brands.color_palettes` (jsonb array)
- ✅ Fonts — `brands.fonts` (jsonb array)
- ✅ Visual dos/donts — `brands.visual_dos` / `brands.visual_donts` (jsonb arrays)
- ✅ System-prompt instruction to prefer brand assets over web/upload
- ❌ Logo variants (dark/light/mono) — requires new `brand_assets` table (Layer 2, separate PRD)
- ❌ Mascots, products, packaging, photography refs — Layer 2
- ❌ Web/UI changes — none. The toggle that gates brand knowledge already exists.

---

## File Structure

### AI Service
- `ai-service/app/agents/kv_generator/request_schema.py` — extend `PrefetchedBrand`
- `ai-service/app/agents/kv_generator/context_builder.py` — extend `_format_brand_block`
- `ai-service/app/agents/kv_generator/prompts/base.py` — append asset-priority directive
- `ai-service/app/agents/kv_generator/prompts/image_mode.py` — append image-mode logo handling
- `ai-service/tests/agents/kv_generator/test_schemas.py` — schema acceptance test
- `ai-service/tests/agents/kv_generator/test_context_builder.py` — prompt rendering tests

### API
- `api/app/Services/ChatService.php` — extend `buildBrandIdentity()`, add `buildBrandVisuals()`, extend prefetched assembly
- `api/app/Data/DemoBrand/DemoBrandData.php` — extend `toBrandContext()` with visual fields
- `api/app/Data/DemoBrand/DemoBrandProvider.php` — add `logo_url` / `color_palettes` / etc. to fixtures
- `api/tests/Feature/Chat/BrandAssetFeedingTest.php` — new feature test (asserts payload shape)

---

## Task 1: Extend `PrefetchedBrand` schema (ai-service)

**Files:**
- Modify: `ai-service/app/agents/kv_generator/request_schema.py:24-28`
- Test: `ai-service/tests/agents/kv_generator/test_schemas.py`

**Rationale:** The schema is the contract between API and AI service. Lock the shape first so both sides agree on field names/types.

- [ ] **Step 1: Write the failing schema test**

Append to `ai-service/tests/agents/kv_generator/test_schemas.py`:

```python
from app.agents.kv_generator.request_schema import PrefetchedBrand


def test_prefetched_brand_accepts_visual_asset_fields():
    """The brand payload must accept logo URL, palettes, fonts, and visual
    rules so the LLM can use them as-is instead of web-searching."""
    brand = PrefetchedBrand(
        brand_name="Telkomsel",
        dna="...",
        identity="...",
        tonality="...",
        logo_url="https://s3.example.com/brands/telkomsel/logo.png",
        color_palettes=[
            {"type": "primary", "hex_code": "#E60012"},
            {"type": "secondary", "hex_code": "#FFFFFF"},
        ],
        fonts=[{"name": "Telkomsel Batik Sans", "weight": "Regular"}],
        visual_dos=["Use clear sky backgrounds", "Lead with red"],
        visual_donts=["Don't use stretched logos", "Avoid green tones"],
    )
    assert brand.logo_url == "https://s3.example.com/brands/telkomsel/logo.png"
    assert brand.color_palettes[0]["hex_code"] == "#E60012"
    assert brand.fonts[0]["name"] == "Telkomsel Batik Sans"
    assert "stretched logos" in brand.visual_donts[0]


def test_prefetched_brand_visual_fields_are_optional():
    """Older API builds and demo fixtures without visual data must still
    deserialize — Layer 1 must be backwards compatible."""
    brand = PrefetchedBrand(brand_name="LegacyBrand")
    assert brand.logo_url is None
    assert brand.color_palettes == []
    assert brand.fonts == []
    assert brand.visual_dos == []
    assert brand.visual_donts == []
```

- [ ] **Step 2: Run schema test to verify it fails**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_schemas.py::test_prefetched_brand_accepts_visual_asset_fields -v`
Expected: FAIL — `ValidationError: Extra inputs are not permitted` for `logo_url` / `color_palettes` / `fonts` / `visual_dos` / `visual_donts`.

- [ ] **Step 3: Extend the `PrefetchedBrand` model**

Replace the existing class in `ai-service/app/agents/kv_generator/request_schema.py:24-28`:

```python
class PrefetchedBrand(BaseModel):
    brand_name: Optional[str] = None
    dna: Optional[str] = None
    identity: Optional[str] = None
    tonality: Optional[str] = None
    # Visual identity assets surfaced from the brand knowledge `brands`
    # table (Layer 1 — single logo + palette + fonts + visual rules).
    # The LLM uses these as the source of truth for "use the brand logo /
    # brand colors / brand fonts" so it does not fall back to web search
    # or ask the user to upload assets that are already on file.
    logo_url: Optional[str] = None
    color_palettes: List[Dict[str, Any]] = Field(default_factory=list)
    fonts: List[Dict[str, Any]] = Field(default_factory=list)
    visual_dos: List[str] = Field(default_factory=list)
    visual_donts: List[str] = Field(default_factory=list)
```

(`List`, `Dict`, `Any`, `Field` are already imported at the top of the file.)

- [ ] **Step 4: Run schema tests to verify both pass**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_schemas.py -v`
Expected: PASS for both new tests; all pre-existing tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/kv_generator/request_schema.py \
        ai-service/tests/agents/kv_generator/test_schemas.py
git commit -m "feat(ai): extend PrefetchedBrand with visual asset fields"
```

---

## Task 2: Render visual assets in the brand prompt block (ai-service)

**Files:**
- Modify: `ai-service/app/agents/kv_generator/context_builder.py:42-55, 91-101`
- Test: `ai-service/tests/agents/kv_generator/test_context_builder.py`

**Rationale:** Schema accepts the fields, but they're dropped on the floor unless the prompt builder formats them. Build a structured block the LLM can scan quickly.

- [ ] **Step 1: Write failing prompt-rendering tests**

Append to `ai-service/tests/agents/kv_generator/test_context_builder.py`:

```python
@pytest.mark.asyncio
async def test_system_prompt_includes_brand_visual_assets():
    """When the API pre-resolves logo / palette / fonts / visual rules,
    they must appear in the rendered brand block so the LLM can act on
    them without web search."""
    api = AsyncMock()
    ctx = LaunchContext(studio_file_id="f1", use_brand_knowledge=True, brand_id="b1")

    from app.agents.kv_generator.request_schema import Prefetched, PrefetchedBrand
    prefetched = Prefetched(brand=PrefetchedBrand(
        brand_name="Telkomsel",
        dna="Mission: connect everyone",
        identity="Description: telco",
        tonality="Confident, warm",
        logo_url="https://s3.example.com/brands/telkomsel/logo.png",
        color_palettes=[
            {"type": "primary", "hex_code": "#E60012"},
            {"type": "secondary", "hex_code": "#FFFFFF"},
        ],
        fonts=[{"name": "Telkomsel Batik Sans", "weight": "Regular"}],
        visual_dos=["Lead with red", "Clear sky backgrounds"],
        visual_donts=["No stretched logos", "Avoid green tones"],
    ))

    prompt = await build_system_prompt(
        mode="image", launch_context=ctx, api_client=api, prefetched=prefetched,
    )

    # The block must surface every asset on its own labelled line so the
    # LLM does not have to parse free-form prose.
    assert "Logo URL: https://s3.example.com/brands/telkomsel/logo.png" in prompt
    assert "#E60012" in prompt
    assert "primary" in prompt
    assert "Telkomsel Batik Sans" in prompt
    assert "Lead with red" in prompt
    assert "No stretched logos" in prompt
    api.get_brand_knowledge.assert_not_called()


@pytest.mark.asyncio
async def test_brand_block_omits_empty_visual_sections():
    """Missing data must not produce empty bullet lines — keeps the
    prompt compact and stops the LLM hallucinating placeholder values."""
    api = AsyncMock()
    ctx = LaunchContext(studio_file_id="f1", use_brand_knowledge=True, brand_id="b1")

    from app.agents.kv_generator.request_schema import Prefetched, PrefetchedBrand
    prefetched = Prefetched(brand=PrefetchedBrand(
        brand_name="MinimalBrand",
        dna="dna-text",
        identity="identity-text",
        tonality="tonality-text",
        # No logo_url, no palettes, no fonts, no visual rules.
    ))

    prompt = await build_system_prompt(
        mode="chat", launch_context=ctx, api_client=api, prefetched=prefetched,
    )

    assert "Logo URL:" not in prompt
    assert "Color palette:" not in prompt
    assert "Fonts:" not in prompt
    assert "Visual dos:" not in prompt
    assert "Visual donts:" not in prompt
```

- [ ] **Step 2: Run prompt tests to verify they fail**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_context_builder.py::test_system_prompt_includes_brand_visual_assets -v`
Expected: FAIL — `Logo URL: https://...` is not in the rendered prompt.

- [ ] **Step 3: Pass visual fields through `brand_dict` and extend `_format_brand_block`**

In `ai-service/app/agents/kv_generator/context_builder.py`, replace the prefetched-brand mapping block at lines 42-55:

```python
    # Brand knowledge context
    brand_dict: Optional[dict] = None
    if prefetched and prefetched.brand:
        if prefetched.brand.brand_name:
            brand_dict = {
                "brand_name": prefetched.brand.brand_name,
                "dna": prefetched.brand.dna or "",
                "identity": prefetched.brand.identity or "",
                "tonality": prefetched.brand.tonality or "",
                "logo_url": prefetched.brand.logo_url or "",
                "color_palettes": prefetched.brand.color_palettes,
                "fonts": prefetched.brand.fonts,
                "visual_dos": prefetched.brand.visual_dos,
                "visual_donts": prefetched.brand.visual_donts,
            }
    elif launch_context.use_brand_knowledge and launch_context.brand_id:
        brand_dict = await api_client.get_brand_knowledge(launch_context.brand_id)

    if brand_dict:
        sections.append(_format_brand_block(brand_dict))
```

Then replace `_format_brand_block` at lines 91-101 with:

```python
def _format_brand_block(brand: dict) -> str:
    """Render the brand context block. Visual asset lines are only emitted
    when populated — empty sections would dilute the LLM's attention and
    encourage placeholder hallucination."""
    name = brand.get("brand_name", "")
    dna = brand.get("dna", "")
    identity = brand.get("identity", "")
    tonality = brand.get("tonality", "")

    lines: list[str] = [
        f"Brand: {name}",
        f"- DNA: {dna}",
        f"- Identity: {identity}",
        f"- Tonality: {tonality}",
    ]

    logo_url = brand.get("logo_url") or ""
    if logo_url:
        lines.append(f"- Logo URL: {logo_url}")

    palettes = brand.get("color_palettes") or []
    if palettes:
        palette_str = ", ".join(
            f"{p.get('type', 'color')} {p.get('hex_code', '')}".strip()
            for p in palettes
            if p.get("hex_code")
        )
        if palette_str:
            lines.append(f"- Color palette: {palette_str}")

    fonts = brand.get("fonts") or []
    if fonts:
        font_str = ", ".join(
            f"{f.get('name', '')} {f.get('weight', '')}".strip()
            for f in fonts
            if f.get("name")
        )
        if font_str:
            lines.append(f"- Fonts: {font_str}")

    dos = brand.get("visual_dos") or []
    if dos:
        lines.append("- Visual dos: " + "; ".join(d for d in dos if d))

    donts = brand.get("visual_donts") or []
    if donts:
        lines.append("- Visual donts: " + "; ".join(d for d in donts if d))

    return "\n".join(lines)
```

- [ ] **Step 4: Run prompt tests to verify they pass**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_context_builder.py -v`
Expected: all tests PASS (new ones + pre-existing 5).

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/kv_generator/context_builder.py \
        ai-service/tests/agents/kv_generator/test_context_builder.py
git commit -m "feat(ai): render brand visual assets in KV system prompt"
```

---

## Task 3: Add asset-priority directive to the system prompt (ai-service)

**Files:**
- Modify: `ai-service/app/agents/kv_generator/prompts/base.py`
- Modify: `ai-service/app/agents/kv_generator/prompts/image_mode.py`
- Test: `ai-service/tests/agents/kv_generator/test_context_builder.py`

**Rationale:** Without an explicit directive, the LLM may still fall back to web search or upload requests even when the logo URL is in the prompt. Tell it directly: prefer brand-provided assets unless the user overrides.

- [ ] **Step 1: Write failing directive test**

Append to `ai-service/tests/agents/kv_generator/test_context_builder.py`:

```python
@pytest.mark.asyncio
async def test_base_prompt_includes_brand_asset_priority_directive():
    """The base prompt must instruct the model to prefer brand-provided
    assets over web search / asking for upload — this is the whole
    point of feeding the brand's logo URL in the first place."""
    api = AsyncMock()
    ctx = LaunchContext(studio_file_id="f1", use_brand_knowledge=False, brand_id="b1")

    prompt = await build_system_prompt(
        mode="chat", launch_context=ctx, api_client=api,
    )

    # Wording is flexible but the directive must be unambiguous.
    assert "brand-provided" in prompt.lower() or "brand context" in prompt.lower()
    assert "web search" in prompt.lower()
    assert "upload" in prompt.lower()
```

- [ ] **Step 2: Run directive test to verify it fails**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_context_builder.py::test_base_prompt_includes_brand_asset_priority_directive -v`
Expected: FAIL — none of the keywords are in `BASE_PROMPT`.

- [ ] **Step 3: Update `BASE_PROMPT`**

Replace `ai-service/app/agents/kv_generator/prompts/base.py` entirely:

```python
BASE_PROMPT = (
    "You are a KV (key visual) generator. You help the user create brand-safe "
    "campaign visuals. Respect the brief and brand guidance when generating. "
    "Keep responses concise and focused on the visual outcome.\n\n"
    "Brand asset priority: when the user references a brand element that is "
    "already provided in the brand context (logo URL, color palette, fonts, "
    "visual dos/donts), use the brand-provided asset directly. Do NOT "
    "fall back to a web search and do NOT ask the user to upload it. "
    "Only override this when the user explicitly says so — e.g. 'use the "
    "logo from this file I uploaded', 'use the black variant from <URL>', "
    "or 'find a different logo online'."
)
```

- [ ] **Step 4: Strengthen image-mode guidance for logo handling**

Replace `ai-service/app/agents/kv_generator/prompts/image_mode.py` entirely:

```python
GUIDANCE = (
    "In image mode your response is used as the prompt for an image-generation "
    "model (gpt-image-1). Your reply MUST be a single paragraph that describes "
    "the image to create, synthesising everything relevant from the chat "
    "history (brand, campaign concept, subjects, style, mood, palette, "
    "composition, aspect ratio). Do NOT ask questions, do NOT address the "
    "user, do NOT include meta commentary or headings — just the image prompt "
    "itself. If the user's latest message is just a confirmation like 'yes' "
    "or 'go ahead', build the prompt from the prior turns instead of from "
    "that short message. Keep it concrete, visual, and under 300 words. "
    "When the user asks to include the brand logo and a Logo URL is present "
    "in the brand context, reference the brand logo explicitly in the prompt "
    "(e.g. 'with the brand logo from <Logo URL> placed in the bottom-right') "
    "instead of describing a generic logo or fetching one from the web."
)
```

- [ ] **Step 5: Run all KV-generator AI-service tests**

Run: `cd ai-service && pytest tests/agents/kv_generator/ -v`
Expected: all tests PASS (directive, prompt rendering, schemas, plus the pre-existing suite).

- [ ] **Step 6: Commit**

```bash
git add ai-service/app/agents/kv_generator/prompts/base.py \
        ai-service/app/agents/kv_generator/prompts/image_mode.py \
        ai-service/tests/agents/kv_generator/test_context_builder.py
git commit -m "feat(ai): instruct KV agent to prefer brand-provided assets"
```

---

## Task 4: Add `buildBrandVisuals()` helper in `ChatService` (api)

**Files:**
- Modify: `api/app/Services/ChatService.php:2461-2470` (extend identity helpers area)
- Test: `api/tests/Feature/Chat/BrandAssetFeedingTest.php` (new file in Task 5)

**Rationale:** Keep payload assembly DRY. A small private helper that pulls raw arrays off the Brand model (no formatting — formatting is the ai-service's job) makes the prefetched-brand assembly readable.

- [ ] **Step 1: Read the existing helper block one more time to anchor on style**

Read: `api/app/Services/ChatService.php` lines 2450-2497 — confirm `buildBrandDna`, `buildBrandIdentity`, `joinBrandLines` are still in that shape.

- [ ] **Step 2: Add the `buildBrandVisuals` helper**

Insert this method into `ChatService` immediately after `buildBrandIdentity()` (before `joinBrandLines`) at approximately line 2471:

```php
    /**
     * Return the raw visual-asset arrays for the prefetched brand payload.
     * No formatting — ai-service's `_format_brand_block` is responsible
     * for rendering these into the LLM prompt. Empty arrays for missing
     * data so the JSON shape is stable and the Pydantic defaults apply.
     *
     * @return array{
     *     logo_url: string|null,
     *     color_palettes: array<int, array<string, mixed>>,
     *     fonts: array<int, array<string, mixed>>,
     *     visual_dos: array<int, string>,
     *     visual_donts: array<int, string>,
     * }
     */
    private static function buildBrandVisuals(Brand $brand): array
    {
        return [
            'logo_url' => $brand->logo ?: null,
            'color_palettes' => self::asListOfMaps($brand->color_palettes),
            'fonts' => self::asListOfMaps($brand->fonts),
            'visual_dos' => self::asListOfStrings($brand->visual_dos),
            'visual_donts' => self::asListOfStrings($brand->visual_donts),
        ];
    }

    /**
     * Coerce an Eloquent-cast jsonb column to a plain list of associative
     * arrays. Drops scalars / nulls so the ai-service Pydantic List[Dict]
     * field never sees a malformed entry.
     *
     * @param  mixed  $value
     * @return array<int, array<string, mixed>>
     */
    private static function asListOfMaps($value): array
    {
        if (! is_array($value)) {
            return [];
        }

        return array_values(array_filter(
            $value,
            fn ($item) => is_array($item) && ! empty($item),
        ));
    }

    /**
     * Coerce an Eloquent-cast jsonb column to a plain list of strings.
     * Drops empty values to keep the prompt compact.
     *
     * @param  mixed  $value
     * @return array<int, string>
     */
    private static function asListOfStrings($value): array
    {
        if (! is_array($value)) {
            return [];
        }

        return array_values(array_filter(
            array_map(fn ($v) => is_scalar($v) ? trim((string) $v) : '', $value),
            fn ($v) => $v !== '',
        ));
    }
```

- [ ] **Step 3: Wire `buildBrandVisuals` into the prefetched payload**

In `api/app/Services/ChatService.php` lines 486-491, extend the `$prefetched['brand']` assignment so it spreads the visuals on top of the existing keys:

```php
                        $prefetched['brand'] = array_merge(
                            [
                                'brand_name' => $brand->name,
                                'dna' => self::buildBrandDna($brand),
                                'identity' => self::buildBrandIdentity($brand),
                                'tonality' => $tonalityString,
                            ],
                            self::buildBrandVisuals($brand),
                        );
```

(The merge order matters: we keep the textual fields first so a future refactor that puts `logo_url` into `buildBrandIdentity` can't silently shadow it.)

- [ ] **Step 4: Run any existing ChatService unit tests that touch the brand prefetch path (sanity)**

Run: `cd api && ./vendor/bin/pest --filter=Chat`
Expected: PASS for whatever currently exists — we haven't broken anything yet. (Brand-asset coverage comes in Task 5.)

- [ ] **Step 5: Commit**

```bash
git add api/app/Services/ChatService.php
git commit -m "feat(api): include brand visual assets in KV prefetched payload"
```

---

## Task 5: Feature test — prefetched payload carries visual assets (api)

**Files:**
- Create: `api/tests/Feature/Chat/BrandAssetFeedingTest.php`

**Rationale:** The PHP side is a JSON-builder — the cheapest correctness check is "given a brand with these fields, what shape is the payload?". A feature test that intercepts the outgoing HTTP request to ai-service nails this without spinning up Python.

- [ ] **Step 1: Inspect the existing chat test to find the http-mock pattern**

Read: `api/tests/Feature/Chat/ChatThreadTest.php` — scan for any `Http::fake(...)` or `expectsHttp(...)` calls so the new test follows the same mocking style. Note the auth/setup helpers and the route name used for streaming.

- [ ] **Step 2: Write the failing feature test**

Create `api/tests/Feature/Chat/BrandAssetFeedingTest.php`:

```php
<?php

use App\Models\Brand;
use App\Models\User;
use App\Models\Workspace;
use Illuminate\Support\Facades\Http;

beforeEach(function () {
    // Capture every outgoing HTTP call so we can assert on the
    // ai-service payload without actually hitting the network.
    Http::preventStrayRequests();
    Http::fake();
});

it('feeds brand visual assets into the ai-service KV stream payload', function () {
    $user = User::factory()->create();
    $workspace = Workspace::factory()->create();
    $user->workspaces()->attach($workspace);

    $brand = Brand::factory()->create([
        'workspace_id' => $workspace->id,
        'user_id' => $user->id,
        'name' => 'Telkomsel',
        'logo' => 'brands/telkomsel/logo.png',
        'color_palettes' => [
            ['type' => 'primary', 'hex_code' => '#E60012'],
            ['type' => 'secondary', 'hex_code' => '#FFFFFF'],
        ],
        'fonts' => [
            ['name' => 'Telkomsel Batik Sans', 'weight' => 'Regular'],
        ],
        'visual_dos' => ['Lead with red', 'Clear sky backgrounds'],
        'visual_donts' => ['No stretched logos', 'Avoid green tones'],
    ]);

    // Drive the chat stream the same way the existing ChatThreadTest does
    // — see that file for the exact helper / route pattern. The key
    // assertion is the ai-service request body.
    actingAs($user)
        ->postJson(route('chat.stream'), [
            // Fill in the same minimal body the existing ChatThreadTest
            // uses for a KV stream call with brand knowledge enabled,
            // setting:
            //   launch_context.use_brand_knowledge = true
            //   launch_context.brand_id = $brand->id
        ])
        ->assertOk();

    Http::assertSent(function ($request) use ($brand) {
        if (! str_contains($request->url(), '/kv/stream')) {
            return false;
        }
        $body = $request->data();
        $prefetchedBrand = $body['prefetched']['brand'] ?? null;

        return $prefetchedBrand !== null
            && $prefetchedBrand['brand_name'] === 'Telkomsel'
            && str_ends_with($prefetchedBrand['logo_url'] ?? '', 'logo.png')
            && $prefetchedBrand['color_palettes'][0]['hex_code'] === '#E60012'
            && $prefetchedBrand['fonts'][0]['name'] === 'Telkomsel Batik Sans'
            && in_array('Lead with red', $prefetchedBrand['visual_dos'])
            && in_array('No stretched logos', $prefetchedBrand['visual_donts']);
    });
});

it('emits empty arrays for visual fields when the brand has no visuals', function () {
    $user = User::factory()->create();
    $workspace = Workspace::factory()->create();
    $user->workspaces()->attach($workspace);

    $brand = Brand::factory()->create([
        'workspace_id' => $workspace->id,
        'user_id' => $user->id,
        'name' => 'BareBrand',
        'logo' => null,
        'color_palettes' => null,
        'fonts' => null,
        'visual_dos' => null,
        'visual_donts' => null,
    ]);

    actingAs($user)
        ->postJson(route('chat.stream'), [
            // Same minimal body as above, using $brand->id.
        ])
        ->assertOk();

    Http::assertSent(function ($request) {
        if (! str_contains($request->url(), '/kv/stream')) {
            return false;
        }
        $body = $request->data();
        $brand = $body['prefetched']['brand'] ?? null;

        // logo_url must be null (not empty string) so Pydantic's
        // Optional[str] default applies cleanly.
        return $brand !== null
            && $brand['logo_url'] === null
            && $brand['color_palettes'] === []
            && $brand['fonts'] === []
            && $brand['visual_dos'] === []
            && $brand['visual_donts'] === [];
    });
});
```

> **Note for the engineer:** The two `postJson(...)` bodies have placeholder comments. Open `api/tests/Feature/Chat/ChatThreadTest.php`, find the request body used for a KV stream call with `use_brand_knowledge = true`, and copy the exact shape into both `postJson` bodies, substituting `'brand_id' => $brand->id`. Do **not** invent fields — the route's `FormRequest` will reject anything unrecognized.

- [ ] **Step 3: Run the test to confirm both pass**

Run: `cd api && ./vendor/bin/pest tests/Feature/Chat/BrandAssetFeedingTest.php -v`
Expected: both tests PASS. If the URL match fails, print `$body` once via `dump()` and adjust the `str_contains` URL fragment to match the actual ai-service host configured in `config/services.php`.

- [ ] **Step 4: Commit**

```bash
git add api/tests/Feature/Chat/BrandAssetFeedingTest.php
git commit -m "test(api): cover brand visual assets in KV stream payload"
```

---

## Task 6: Extend `DemoBrandData` with visual assets (api)

**Files:**
- Modify: `api/app/Data/DemoBrand/DemoBrandData.php`
- Modify: `api/app/Data/DemoBrand/DemoBrandProvider.php`

**Rationale:** Demo brands bypass the real `brands` table and feed the prefetched payload directly via `DemoBrandProvider::brandContext()`. Without updating them, demo flows produce a payload that's missing the new fields and the ai-service will fall back to its defaults — defeating the point for sales demos.

- [ ] **Step 1: Read the existing demo data file to anchor on structure**

Read: `api/app/Data/DemoBrand/DemoBrandData.php` and `api/app/Data/DemoBrand/DemoBrandProvider.php:10-77` — note the two existing fixtures (`frndbank`, `frndskincare`).

- [ ] **Step 2: Extend `DemoBrandData` with the new fields**

Replace `api/app/Data/DemoBrand/DemoBrandData.php`:

```php
<?php

namespace App\Data\DemoBrand;

use Spatie\LaravelData\Data;

class DemoBrandData extends Data
{
    /**
     * @param  array<string, string>  $tonality
     * @param  array<string, mixed>  $knowledge
     * @param  array<int, string>  $integrations
     * @param  array<int, array{type: string, hex_code: string}>  $color_palettes
     * @param  array<int, array{name: string, weight: string}>  $fonts
     * @param  array<int, string>  $visual_dos
     * @param  array<int, string>  $visual_donts
     */
    public function __construct(
        public readonly string $slug,
        public readonly string $name,
        public readonly string $industry,
        public readonly string $description,
        public readonly string $dna,
        public readonly string $identity,
        public readonly array $tonality,
        public readonly array $knowledge,
        public readonly array $integrations,
        public readonly ?string $logo_url = null,
        public readonly array $color_palettes = [],
        public readonly array $fonts = [],
        public readonly array $visual_dos = [],
        public readonly array $visual_donts = [],
    ) {}

    /**
     * Brand context shaped identically to what ChatService produces from a
     * real Brand model. tonality is JSON-encoded because ai-service's
     * PrefetchedBrand.tonality schema expects Optional[str].
     *
     * @return array{
     *     brand_name: string,
     *     dna: string,
     *     identity: string,
     *     tonality: string,
     *     logo_url: string|null,
     *     color_palettes: array<int, array<string, mixed>>,
     *     fonts: array<int, array<string, mixed>>,
     *     visual_dos: array<int, string>,
     *     visual_donts: array<int, string>,
     * }
     */
    public function toBrandContext(): array
    {
        return [
            'brand_name' => $this->name,
            'dna' => $this->dna,
            'identity' => $this->identity,
            'tonality' => json_encode($this->tonality, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
            'logo_url' => $this->logo_url,
            'color_palettes' => $this->color_palettes,
            'fonts' => $this->fonts,
            'visual_dos' => $this->visual_dos,
            'visual_donts' => $this->visual_donts,
        ];
    }
}
```

- [ ] **Step 3: Add visual fields to the two demo fixtures**

In `api/app/Data/DemoBrand/DemoBrandProvider.php`, extend each fixture (`frndbank`, `frndskincare`). Add these keys to the `frndbank` fixture (after `'integrations' => [...]`):

```php
            'logo_url' => 'https://placehold.co/512x512/0F4C81/FFFFFF?text=frndBank',
            'color_palettes' => [
                ['type' => 'primary', 'hex_code' => '#0F4C81'],
                ['type' => 'secondary', 'hex_code' => '#13B47B'],
                ['type' => 'accent', 'hex_code' => '#F4F6F8'],
            ],
            'fonts' => [
                ['name' => 'Inter', 'weight' => 'SemiBold'],
                ['name' => 'Inter', 'weight' => 'Regular'],
            ],
            'visual_dos' => [
                'Use clean, professional photography',
                'Lead with blues and greens',
                'Surface data and numbers prominently',
            ],
            'visual_donts' => [
                'Avoid stock-image cliches (handshakes, fanned cash)',
                'No aggressive red/orange palettes',
                'Do not crowd compositions',
            ],
```

And add to the `frndskincare` fixture in the same position:

```php
            'logo_url' => 'https://placehold.co/512x512/E8C9C0/3B2A2A?text=frndSkin',
            'color_palettes' => [
                ['type' => 'primary', 'hex_code' => '#E8C9C0'],
                ['type' => 'secondary', 'hex_code' => '#3B2A2A'],
                ['type' => 'accent', 'hex_code' => '#FFF7F2'],
            ],
            'fonts' => [
                ['name' => 'Söhne', 'weight' => 'Buch'],
                ['name' => 'Söhne', 'weight' => 'Kräftig'],
            ],
            'visual_dos' => [
                'Soft pastels with airy white space',
                'Ingredient close-ups and texture shots',
                'UGC-style framing with natural light',
            ],
            'visual_donts' => [
                'Avoid harsh studio lighting',
                'No clinical or pharma-feeling visuals',
                'Do not over-retouch skin in references',
            ],
```

- [ ] **Step 4: Verify Spatie Data still hydrates the fixtures**

Run: `cd api && php artisan tinker --execute="dd(\App\Data\DemoBrand\DemoBrandProvider::brandContext('frndbank'));"`
Expected: array with keys `brand_name`, `dna`, `identity`, `tonality`, `logo_url`, `color_palettes`, `fonts`, `visual_dos`, `visual_donts`, all populated.

If hydration fails, the most likely cause is the constructor argument order — Spatie Data hydrates positionally from the fixture array. Reorder constructor params to match the fixture key order, or convert the fixture to use the same key order as the constructor.

- [ ] **Step 5: Commit**

```bash
git add api/app/Data/DemoBrand/DemoBrandData.php \
        api/app/Data/DemoBrand/DemoBrandProvider.php
git commit -m "feat(api): include visual assets in demo brand fixtures"
```

---

## Task 7: End-to-end smoke check

**Files:** none modified — verification only.

**Rationale:** Schema, payload, and prompt are wired separately. One manual round-trip catches the boring integration bugs (typo'd field name, wrong S3 URL accessor, mis-cast jsonb) that the unit tests can't.

- [ ] **Step 1: Run the full ai-service KV-generator test suite**

Run: `cd ai-service && pytest tests/agents/kv_generator/ -v`
Expected: 100% PASS, no skips.

- [ ] **Step 2: Run the full api chat test suite**

Run: `cd api && ./vendor/bin/pest tests/Feature/Chat/ -v`
Expected: 100% PASS, including the new `BrandAssetFeedingTest`.

- [ ] **Step 3: Start both services and drive a manual KV request**

Run in two terminals:
- Terminal A: `cd api && php artisan optimize:clear && php artisan optimize && php artisan serve --port=9191`
- Terminal B: `cd ai-service && source .venv/bin/activate && fastapi dev`

Then in a third terminal, tail the ai-service log to see the rendered system prompt:

```bash
tail -f ai-service/logs/*.log 2>/dev/null || echo "no log file — uvicorn output goes to terminal B"
```

In the frontend (or curl directly), trigger a KV stream with:
- A brand that has `logo`, `color_palettes`, `fonts`, `visual_dos`, `visual_donts` populated
- Brand-knowledge toggle ON
- Prompt: `"tambahkan logo brand di pojok kanan bawah dengan suasana sunset"`

Confirm in the ai-service logs that the rendered system prompt contains:
- `Logo URL: <the real S3 URL>`
- `Color palette: primary #...`
- `Fonts: ...`
- `Visual dos: ...`
- `Visual donts: ...`
- `Brand asset priority:` directive

And confirm the generated image references the brand logo URL (or at minimum the brand colors) instead of a generic logo.

- [ ] **Step 4: If smoke check passes — commit any incidental fixes and update the workflow tracker**

Update the track file `web/docs/tracks/studio-projects-kv-generator.track.md` (or the corresponding api / ai-service track file) with a new session log entry:

```
### 2026-05-26 — daffa (frndos-implement)
- Layer 1 brand asset feeding shipped: PrefetchedBrand schema, _format_brand_block,
  ChatService payload, demo fixtures, and system-prompt directive.
- Verified end-to-end via Telkomsel brand + manual KV stream.
- Layer 2 (logo variants, mascots, products, packaging) deferred to its own PRD.
```

Commit any housekeeping:

```bash
git add web/docs/tracks/*.track.md api/docs/tracks/*.track.md ai-service/docs/tracks/*.track.md 2>/dev/null
git commit -m "docs(tracks): log layer-1 brand asset feeding completion" --allow-empty
```

---

## Self-review checklist

- ✅ **Spec coverage:** Logo, palettes, fonts, visual dos/donts, prompt directive — all mapped to tasks 1–5; demo fixtures (task 6); smoke (task 7).
- ✅ **No placeholders:** All code shown verbatim. The two `postJson` bodies in Task 5 explicitly point the engineer at `ChatThreadTest.php` for the exact stream body shape and warn against inventing fields — that's the only "read existing test" reference and it's load-bearing because the FormRequest schema lives outside this plan's scope.
- ✅ **Type consistency:** `logo_url: Optional[str]` (Python) ↔ `'logo_url' => string|null` (PHP). `color_palettes: List[Dict[str, Any]]` ↔ `array<int, array<string, mixed>>`. Method names match across tasks: `buildBrandVisuals`, `asListOfMaps`, `asListOfStrings`, `_format_brand_block`.
- ✅ **TDD:** Every code task starts with a failing test (tasks 1, 2, 3, 5).
- ✅ **Frequent commits:** One commit per task.
- ✅ **DRY:** `asListOfMaps` / `asListOfStrings` factored out so the helper handles future jsonb fields cleanly.
- ✅ **YAGNI:** Logo variants, mascots, etc. explicitly punted to a separate PRD in the scope boundary.
