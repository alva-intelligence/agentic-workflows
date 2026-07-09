# Superadmin Tiered Video Pricing — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a superadmin register a *tiered* custom video model (resolution×video_in / mode×audio / resolution / fixed) — not just flat — by teaching the `model_settings` write path to build a tiered `pricing` JSON the resolver already understands.

**Architecture:** The web form sends **structured tiers**; the API builds the stored `pricing` JSON (keys via a shared `videoRateKey`, `fallback_per_second = max(rate)`). A provider→allowed-shapes config both drives validation and is exposed to the web form. The pricing **resolver is unchanged** — it already reads `priced_on`/`rates`/`fallback_per_second` from the merged registry (custom models supply pricing via the `model_settings.pricing` JSON).

**Tech Stack:** Laravel 13, PHP 8.5, Pest.

## Global Constraints

- Branch `feature/daffa/vc-video-dynamic-pricing` (already checked out in `api/`).
- **Unit tests only, by direct file path** (`./vendor/bin/pest tests/Unit/...Test.php`, NOT `--filter` — pre-existing Feature-suite collection error). Feature suite is blocked (`lesson_api_feature_suite_blocked_softdeletes`); do NOT add Feature tests. Confirm phpunit.xml/tests/Pest.php DB isolation before running (`lesson_test_db_isolation`).
- **Do NOT change the resolver** (`PricingHelper::resolveVideoUnitRate` / `calculateVideoCost` logic). Only extract a shared key helper.
- Rate-key format is **single-source**: keys are `implode('|', normalizeDim per priced_on dim)` — `resolution`→literal, `video_in`→`video_in`|`default`, `mode`→literal, `audio`→`audio`|`default`. Examples: `1080p|video_in`, `pro|default`, `4k`.
- `fallback_per_second = max(rate)` (conservative; matches the hardcoded tables).
- Provider→shape mapping: bytedance→[flat, resolution_video_in]; kuaishou→[flat, mode_audio]; google/openai→[flat, resolution]; tencent→[flat, fixed]. `flat` always allowed.
- Free video models stay `{type: per_second, price_per_second: 0.0}` (unchanged).
- Design spec: `docs/superpowers/specs/2026-07-09-superadmin-tiered-video-pricing-design.md`.
- Paths under `api/`; run from `/Users/alva.e202511001/Desktop/work/frndos-agentic/api`.

---

### Task 1: Extract `PricingHelper::videoRateKey` (single-source key format)

**Files:**
- Modify: `app/Helpers/PricingHelper.php` (add `videoRateKey`; refactor `resolveVideoUnitRate` lines 134-137 to use it)
- Test: `tests/Unit/Helpers/VideoRateKeyTest.php` (create)

**Interfaces:**
- Produces: `PricingHelper::videoRateKey(array $pricedOn, array $dims): string` — the `|`-joined `normalizeDim` tokens in `priced_on` order.

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Helpers/VideoRateKeyTest.php`:

```php
<?php

use App\Helpers\PricingHelper;

it('builds resolution x video_in keys', function () {
    expect(PricingHelper::videoRateKey(['resolution', 'video_in'], ['resolution' => '1080p', 'video_in' => true]))->toBe('1080p|video_in');
    expect(PricingHelper::videoRateKey(['resolution', 'video_in'], ['resolution' => '720p', 'video_in' => false]))->toBe('720p|default');
});

it('builds mode x audio keys', function () {
    expect(PricingHelper::videoRateKey(['mode', 'audio'], ['mode' => 'pro', 'audio' => true]))->toBe('pro|audio');
    expect(PricingHelper::videoRateKey(['mode', 'audio'], ['mode' => 'standard', 'audio' => false]))->toBe('standard|default');
});

it('builds single-dimension resolution keys', function () {
    expect(PricingHelper::videoRateKey(['resolution'], ['resolution' => '4k']))->toBe('4k');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./vendor/bin/pest tests/Unit/Helpers/VideoRateKeyTest.php`
Expected: FAIL — `Call to undefined method ...videoRateKey()`.

- [ ] **Step 3: Add `videoRateKey` and refactor the resolver to use it**

In `app/Helpers/PricingHelper.php`, add this method immediately after `normalizeDim` (after line 103):

```php
    /**
     * Build the rates-map key for a video tier: the normalizeDim tokens for
     * each priced_on dimension, joined by '|', in priced_on order. Single
     * source of the key format for BOTH the resolver and the custom-model
     * pricing writer, so written keys always match looked-up keys.
     *
     * @param  array<int,string>  $pricedOn
     * @param  array<string,mixed>  $dims
     */
    public static function videoRateKey(array $pricedOn, array $dims): string
    {
        return implode('|', array_map(
            fn ($dim) => self::normalizeDim($dim, $dims),
            $pricedOn
        ));
    }
```

Then in `resolveVideoUnitRate`, replace the inline key build (lines 134-137):

```php
        $key = implode('|', array_map(
            fn ($dim) => self::normalizeDim($dim, $dims),
            $pricedOn
        ));
```

with:

```php
        $key = self::videoRateKey($pricedOn, $dims);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./vendor/bin/pest tests/Unit/Helpers/VideoRateKeyTest.php tests/Unit/Services/Studio/KvMotionMeteringPricingTest.php`
Expected: PASS — new file green AND the existing pricing test still green (resolver refactor is behavior-preserving).

- [ ] **Step 5: Commit**

```bash
git add app/Helpers/PricingHelper.php tests/Unit/Helpers/VideoRateKeyTest.php
git commit -m "refactor(api): extract PricingHelper::videoRateKey (shared by resolver + writer)"
```

---

### Task 2: Video pricing-shape config (provider → shapes, shape → structure)

**Files:**
- Modify: `app/Helpers/LLMHelper.php` (add two constants + an accessor)
- Test: `tests/Unit/Helpers/VideoPricingShapesTest.php` (create)

**Interfaces:**
- Produces:
  - `LLMHelper::VIDEO_PRICING_SHAPES` — shape key → `{priced_on, values, type?}`.
  - `LLMHelper::VIDEO_PROVIDER_SHAPES` — provider → allowed shape keys.
  - `LLMHelper::videoPricingShapesForProvider(string $provider): array` — the shape defs allowed for a provider (empty for unknown provider).

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Helpers/VideoPricingShapesTest.php`:

```php
<?php

use App\Helpers\LLMHelper;

it('maps bytedance to flat + resolution_video_in', function () {
    $shapes = LLMHelper::videoPricingShapesForProvider('bytedance');
    expect(array_keys($shapes))->toBe(['flat', 'resolution_video_in']);
    expect($shapes['resolution_video_in']['priced_on'])->toBe(['resolution', 'video_in']);
});

it('maps kuaishou to flat + mode_audio', function () {
    $shapes = LLMHelper::videoPricingShapesForProvider('kuaishou');
    expect(array_keys($shapes))->toBe(['flat', 'mode_audio']);
    expect($shapes['mode_audio']['priced_on'])->toBe(['mode', 'audio']);
});

it('maps tencent to flat + fixed', function () {
    $shapes = LLMHelper::videoPricingShapesForProvider('tencent');
    expect(array_keys($shapes))->toBe(['flat', 'fixed']);
    expect($shapes['fixed']['type'])->toBe('fixed');
});

it('returns empty for an unknown provider', function () {
    expect(LLMHelper::videoPricingShapesForProvider('nope'))->toBe([]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./vendor/bin/pest tests/Unit/Helpers/VideoPricingShapesTest.php`
Expected: FAIL — `Call to undefined method ...videoPricingShapesForProvider()`.

- [ ] **Step 3: Add the constants + accessor**

In `app/Helpers/LLMHelper.php`, add near the other video helpers (e.g. just before `getVideoPricing`):

```php
    /**
     * Video pricing-shape presets for the superadmin custom-model form. Each
     * shape maps to the resolver's pricing structure. `values` lists the
     * dimension value vocab the form offers (admin selects which apply).
     */
    public const array VIDEO_PRICING_SHAPES = [
        'flat' => ['priced_on' => [], 'values' => []],
        'fixed' => ['type' => 'fixed', 'priced_on' => [], 'values' => []],
        'resolution' => ['priced_on' => ['resolution'], 'values' => ['resolution' => ['480p', '720p', '1080p', '4k']]],
        'resolution_video_in' => ['priced_on' => ['resolution', 'video_in'], 'values' => ['resolution' => ['480p', '720p', '1080p', '4k']]],
        'mode_audio' => ['priced_on' => ['mode', 'audio'], 'values' => ['mode' => ['standard', 'pro', '4k']]],
    ];

    /**
     * Which pricing shapes each video provider may use — constrained to what
     * ai-service actually reports for that provider's generate_video branch.
     * `flat` is always allowed.
     */
    public const array VIDEO_PROVIDER_SHAPES = [
        'bytedance' => ['flat', 'resolution_video_in'],
        'kuaishou' => ['flat', 'mode_audio'],
        'google' => ['flat', 'resolution'],
        'openai' => ['flat', 'resolution'],
        'tencent' => ['flat', 'fixed'],
    ];

    /**
     * The shape defs (keyed by shape) a given provider may use.
     *
     * @return array<string,array<string,mixed>>
     */
    public static function videoPricingShapesForProvider(string $provider): array
    {
        $allowed = self::VIDEO_PROVIDER_SHAPES[$provider] ?? [];

        $out = [];
        foreach ($allowed as $shapeKey) {
            $out[$shapeKey] = self::VIDEO_PRICING_SHAPES[$shapeKey];
        }

        return $out;
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./vendor/bin/pest tests/Unit/Helpers/VideoPricingShapesTest.php`
Expected: PASS (4 passed).

- [ ] **Step 5: Commit**

```bash
git add app/Helpers/LLMHelper.php tests/Unit/Helpers/VideoPricingShapesTest.php
git commit -m "feat(api): video pricing-shape presets + provider->shapes config"
```

---

### Task 3: `PricingHelper::buildVideoPricing` — structured tiers → stored pricing JSON

**Files:**
- Modify: `app/Helpers/PricingHelper.php` (add `buildVideoPricing`)
- Test: `tests/Unit/Helpers/BuildVideoPricingTest.php` (create)

**Interfaces:**
- Consumes: `videoRateKey` (Task 1).
- Produces: `PricingHelper::buildVideoPricing(array $pricing): array` — turns a validated form pricing payload into the stored `pricing` JSON:
  - `{type: fixed, fixed_price}` → returns as-is (cast float).
  - flat (`type: per_second`, no `priced_on`) → `{type: per_second, price_per_second}`.
  - tiered (`type: per_second`, `priced_on`, `tiers: [{dims, rate}]`) → `{type: per_second, priced_on, rates: {<videoRateKey>: rate}, fallback_per_second: max(rate)}`.

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Helpers/BuildVideoPricingTest.php`:

```php
<?php

use App\Helpers\PricingHelper;

it('builds a flat shape', function () {
    $out = PricingHelper::buildVideoPricing(['type' => 'per_second', 'price_per_second' => 0.3]);
    expect($out)->toBe(['type' => 'per_second', 'price_per_second' => 0.3]);
});

it('builds a fixed shape', function () {
    $out = PricingHelper::buildVideoPricing(['type' => 'fixed', 'fixed_price' => 1.8]);
    expect($out)->toBe(['type' => 'fixed', 'fixed_price' => 1.8]);
});

it('builds a resolution x video_in tiered shape with keyed rates + max fallback', function () {
    $out = PricingHelper::buildVideoPricing([
        'type' => 'per_second',
        'priced_on' => ['resolution', 'video_in'],
        'tiers' => [
            ['dims' => ['resolution' => '1080p', 'video_in' => true], 'rate' => 0.6],
            ['dims' => ['resolution' => '1080p', 'video_in' => false], 'rate' => 0.5],
            ['dims' => ['resolution' => '720p', 'video_in' => true], 'rate' => 0.25],
            ['dims' => ['resolution' => '720p', 'video_in' => false], 'rate' => 0.2],
        ],
    ]);
    expect($out['type'])->toBe('per_second');
    expect($out['priced_on'])->toBe(['resolution', 'video_in']);
    expect($out['rates'])->toBe([
        '1080p|video_in' => 0.6, '1080p|default' => 0.5, '720p|video_in' => 0.25, '720p|default' => 0.2,
    ]);
    expect($out['fallback_per_second'])->toBe(0.6);
});

it('round-trips: a built tiered pricing resolves back to the entered rate', function () {
    // The rates keys must be exactly what videoRateKey produces at resolve time.
    $dims = ['resolution' => '1080p', 'video_in' => true];
    $out = PricingHelper::buildVideoPricing([
        'type' => 'per_second',
        'priced_on' => ['resolution', 'video_in'],
        'tiers' => [['dims' => $dims, 'rate' => 0.6]],
    ]);
    $key = PricingHelper::videoRateKey($out['priced_on'], $dims);
    expect($out['rates'][$key])->toBe(0.6);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./vendor/bin/pest tests/Unit/Helpers/BuildVideoPricingTest.php`
Expected: FAIL — `Call to undefined method ...buildVideoPricing()`.

- [ ] **Step 3: Add `buildVideoPricing`**

In `app/Helpers/PricingHelper.php`, add (near `videoRateKey`):

```php
    /**
     * Build the stored video `pricing` JSON from a validated custom-model
     * pricing payload. Flat / fixed / tiered — tiered rate keys are built via
     * videoRateKey so they match the resolver, and fallback_per_second is the
     * highest entered rate (conservative).
     *
     * @param  array<string,mixed>  $pricing
     * @return array<string,mixed>
     */
    public static function buildVideoPricing(array $pricing): array
    {
        if (($pricing['type'] ?? '') === 'fixed') {
            return ['type' => 'fixed', 'fixed_price' => (float) ($pricing['fixed_price'] ?? 0.0)];
        }

        $pricedOn = $pricing['priced_on'] ?? [];
        if (empty($pricedOn)) {
            return ['type' => 'per_second', 'price_per_second' => (float) ($pricing['price_per_second'] ?? 0.0)];
        }

        $rates = [];
        foreach (($pricing['tiers'] ?? []) as $tier) {
            $key = self::videoRateKey($pricedOn, $tier['dims'] ?? []);
            $rates[$key] = (float) ($tier['rate'] ?? 0.0);
        }

        return [
            'type' => 'per_second',
            'priced_on' => array_values($pricedOn),
            'rates' => $rates,
            'fallback_per_second' => $rates === [] ? 0.0 : max($rates),
        ];
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./vendor/bin/pest tests/Unit/Helpers/BuildVideoPricingTest.php`
Expected: PASS (4 passed).

- [ ] **Step 5: Commit**

```bash
git add app/Helpers/PricingHelper.php tests/Unit/Helpers/BuildVideoPricingTest.php
git commit -m "feat(api): PricingHelper::buildVideoPricing (structured tiers -> stored pricing JSON)"
```

---

### Task 4: Wire the controller — validation, build, edit, and expose the shapes config

**Files:**
- Modify: `app/Http/Controllers/Api/Admin/AdminModelSettingController.php` (`metadataRules` video block + provider guard; `buildCustomPricing` video branch delegates to `buildVideoPricing`; expose shapes in the metadata/options response)
- Modify: `app/Actions/UpdateCustomModelAction.php` (video branch delegates to `buildVideoPricing`)

**Interfaces:**
- Consumes: `PricingHelper::buildVideoPricing` (Task 3), `LLMHelper::videoPricingShapesForProvider` + `LLMHelper::VIDEO_PROVIDER_SHAPES` (Task 2).

**Note on testing:** `metadataRules` is request validation and `buildCustomPricing`/`UpdateCustomModelAction` are controller/action methods — the blocked Feature suite can't exercise them here. Their *core* (the built pricing JSON) is fully proven by Task 3's pure `buildVideoPricing` tests. These edits are the mechanical wiring (delegate + validation rules + config passthrough); verify by reading the diff + `php -l`, and a runtime e2e (POST a tiered model, inspect its `model_settings.pricing`).

- [ ] **Step 1: Extend `metadataRules` video validation + provider guard**

In `app/Http/Controllers/Api/Admin/AdminModelSettingController.php`, replace the video block in `metadataRules` (lines 601-604):

```php
                'video' => [
                    'pricing.type' => 'required|in:per_second',
                    'pricing.price_per_second' => 'required|numeric|min:0',
                ],
```

with (accept fixed + flat + tiered; per-provider shape guard):

```php
                'video' => (function () use ($provider) {
                    $shapes = LLMHelper::videoPricingShapesForProvider($provider ?? '');
                    $allowedPricedOn = collect($shapes)->pluck('priced_on')->filter()->all();

                    return [
                        'pricing.type' => 'required|in:per_second,fixed',
                        // fixed
                        'pricing.fixed_price' => 'required_if:pricing.type,fixed|numeric|min:0',
                        // flat (per_second, no priced_on)
                        'pricing.price_per_second' => 'exclude_if:pricing.type,fixed|required_without:pricing.priced_on|numeric|min:0',
                        // tiered (per_second + priced_on + tiers)
                        'pricing.priced_on' => ['sometimes', 'array', Rule::in($allowedPricedOn)],
                        'pricing.tiers' => 'required_with:pricing.priced_on|array|min:1',
                        'pricing.tiers.*.rate' => 'required_with:pricing.priced_on|numeric|min:0',
                        'pricing.tiers.*.dims' => 'required_with:pricing.priced_on|array',
                    ];
                })(),
```

(`Rule::in($allowedPricedOn)` rejects a `priced_on` the provider doesn't support — the provider guard. `Rule` is already imported in this controller.)

- [ ] **Step 2: Delegate `buildCustomPricing`'s video branch to `buildVideoPricing`**

In the same file, in `buildCustomPricing`, replace the non-free video branch (lines 692-695):

```php
            'video' => [
                'type' => 'per_second',
                'price_per_second' => (float) $validated['pricing']['price_per_second'],
            ],
```

with:

```php
            'video' => PricingHelper::buildVideoPricing($validated['pricing']),
```

(Leave the free-model video default `['type' => 'per_second', 'price_per_second' => 0.0]` at line 680 unchanged. Ensure `use App\Helpers\PricingHelper;` is present at the top of the file — add it if missing.)

- [ ] **Step 3: Same delegation in `UpdateCustomModelAction`**

In `app/Actions/UpdateCustomModelAction.php`, find its video pricing build (mirrors `buildCustomPricing`) and replace it with `PricingHelper::buildVideoPricing($validated['pricing'])` (add the `use App\Helpers\PricingHelper;` import if missing). Keep the free-model zero shape unchanged.

- [ ] **Step 4: Expose the shapes config to the web form**

Find the endpoint/response that feeds the superadmin Add-model form its options (search the controller for where it returns provider lists / form metadata — e.g. an `options()` / `meta()` method or the index payload). Add the per-provider video pricing shapes so the form can render the right presets:

```php
'video_pricing_shapes' => LLMHelper::VIDEO_PROVIDER_SHAPES,
'video_pricing_shape_defs' => LLMHelper::VIDEO_PRICING_SHAPES,
```

(If no such options endpoint exists, add a minimal `GET v1/admin/model-settings/pricing-shapes` returning these two — behind the existing superadmin middleware group.)

- [ ] **Step 5: Syntax check + builder regression**

Run:
```bash
php -l app/Http/Controllers/Api/Admin/AdminModelSettingController.php
php -l app/Actions/UpdateCustomModelAction.php
./vendor/bin/pest tests/Unit/Helpers/BuildVideoPricingTest.php tests/Unit/Helpers/VideoRateKeyTest.php tests/Unit/Helpers/VideoPricingShapesTest.php tests/Unit/Services/Studio/KvMotionMeteringPricingTest.php
```
Expected: no syntax errors; all listed unit suites PASS.

- [ ] **Step 6: Commit**

```bash
git add app/Http/Controllers/Api/Admin/AdminModelSettingController.php app/Actions/UpdateCustomModelAction.php
git commit -m "feat(api): superadmin can create tiered video models (validation + build + shapes config)"
```

## Self-Review Notes

- **Spec coverage:** shared key helper (Task 1); preset + provider config (Task 2); structured-tiers→pricing builder with keyed rates + max fallback (Task 3); validation + provider guard + delegate + config exposure (Task 4). Resolver unchanged; free-model unchanged. ✓
- **Type consistency:** `videoRateKey(pricedOn, dims)` (Task 1) is used by `resolveVideoUnitRate` AND `buildVideoPricing` (Task 3), and the round-trip test proves written keys == resolved keys. `videoPricingShapesForProvider` (Task 2) drives both the validation guard and the exposed config (Task 4). ✓
- **Testability honesty:** Tasks 1-3 fully pure-unit-tested (incl. the key round-trip). Task 4's validation/controller wiring isn't unit-testable (Feature suite blocked) — its output (the pricing JSON) is proven by Task 3; called out, not hidden. Runtime e2e recommended (POST a tiered model, inspect `model_settings.pricing`).
- **No placeholders:** every step has concrete code + exact commands. Task 4 Step 4 requires locating the existing options endpoint — the fallback (a minimal dedicated endpoint) is specified so there's no ambiguity.

## Web follow-up (separate plan)

The web form (superadmin Models Settings → Add/edit model) needs: a provider-driven **Pricing shape** dropdown, a **tiered rate editor** (dimension-value checkboxes → rate matrix, read-only max fallback), and the **structured `tiers`** payload. That's a separate plan on a **web branch** (web isn't on the pricing branch) — write it after exploring the existing Add-model form component.
