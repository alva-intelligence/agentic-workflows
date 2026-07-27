# KV PSD Import Fidelity — API Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the KV canvas persist a per-overlay blend mode, and stop silently truncating imported PSDs at 100 overlays.

**Architecture:** Two validation changes to the studio overlay requests. `payload.blendMode` is whitelisted via a new shared trait (mirroring how typography rules are shared), and the overlay array cap rises from 100 to 300. No database migration — `overlays` is a JSON column cast to `array` on `StudioFile`.

**Tech Stack:** Laravel 13, PHP 8.5, Pest.

**Spec:** `docs/superpowers/specs/2026-07-27-kv-psd-import-fidelity-design.md`

## Global Constraints

- **`validated()` strips any payload sub-key without a rule.** Every new payload key MUST be whitelisted on **both** `UpdateStudioFileOverlaysRequest` and `StoreBrandOverlayPresetRequest`, or it silently vanishes on save. This has bitten this codebase before (see `tests/Unit/Requests/OverlayLayerFlagsValidationTest.php`).
- **The API stores the CSS/canvas blend value, not the Photoshop one.** The web client maps `'soft light'` → `'soft-light'` before saving. The API never sees Photoshop's vocabulary.
- **Allowed blend values (17, exact):** `normal`, `multiply`, `screen`, `overlay`, `darken`, `lighten`, `color-dodge`, `color-burn`, `hard-light`, `soft-light`, `difference`, `exclusion`, `hue`, `saturation`, `color`, `luminosity`, `lighter`.
- **Tests are Pest Unit tests** under `tests/Unit/Requests/`. Do NOT add Feature tests — the api Feature suite currently fails on a fresh migrate for unrelated reasons (workspaces backfill + SoftDeletes), so a Feature test here would be unrunnable.
- **Branch:** `feature/daffa/vc-kv-psd-import-fidelity` (already created from `develop`).

---

### Task 1: Whitelist `payload.blendMode` on both overlay requests

**Files:**
- Create: `app/Http/Requests/Studio/Concerns/HasBlendModePayloadRules.php`
- Modify: `app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php`
- Modify: `app/Http/Requests/Studio/StoreBrandOverlayPresetRequest.php`
- Test: `tests/Unit/Requests/OverlayBlendModeValidationTest.php`

**Interfaces:**
- Consumes: nothing.
- Produces: `blendModePayloadRules(): array` — returns `['overlays.*.payload.blendMode' => [...]]`, spread into both requests' `rules()`.

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Requests/OverlayBlendModeValidationTest.php`:

```php
<?php

use App\Http\Requests\Studio\StoreBrandOverlayPresetRequest;
use App\Http\Requests\Studio\UpdateStudioFileOverlaysRequest;
use Illuminate\Support\Facades\Validator;
use Tests\TestCase;

uses(TestCase::class);

/**
 * Regression: FormRequest::validated() strips any payload sub-key without a
 * rule. blendMode carries a PSD layer's compositing mode onto the canvas —
 * without a whitelist entry an imported Multiply scrim silently reverts to
 * an opaque rectangle on the next reload.
 */
function blendOverlayData(string $type, ?string $blendMode): array
{
    $payload = ['type' => $type];
    if ($type === 'text') {
        $payload['content'] = 'Hello';
        $payload['color'] = '#112233';
    }
    if ($type === 'image') {
        $payload['asset_url'] = 'https://example.com/a.png';
        $payload['mime_type'] = 'image/png';
    }
    if ($blendMode !== null) {
        $payload['blendMode'] = $blendMode;
    }

    return [
        'overlays' => [[
            'type' => $type,
            'x' => 0.1, 'y' => 0.1, 'width' => 0.6, 'height' => 0.1, 'rotation' => 0,
            'payload' => $payload,
        ]],
    ];
}

test('UpdateStudioFileOverlaysRequest preserves blendMode through validated()', function () {
    $v = Validator::make(
        blendOverlayData('image', 'multiply'),
        (new UpdateStudioFileOverlaysRequest)->rules(),
    );
    expect($v->fails())->toBeFalse();
    expect($v->validated()['overlays'][0]['payload']['blendMode'])->toBe('multiply');
});

test('blendMode is accepted on text overlays too (PSD text layers carry blend modes)', function () {
    $v = Validator::make(
        blendOverlayData('text', 'soft-light'),
        (new UpdateStudioFileOverlaysRequest)->rules(),
    );
    expect($v->fails())->toBeFalse();
    expect($v->validated()['overlays'][0]['payload']['blendMode'])->toBe('soft-light');
});

test('StoreBrandOverlayPresetRequest preserves blendMode (presets snapshot layers)', function () {
    $data = [
        'name' => 'My preset',
        'overlays' => blendOverlayData('image', 'screen')['overlays'],
    ];
    $v = Validator::make($data, (new StoreBrandOverlayPresetRequest)->rules());
    expect($v->fails())->toBeFalse();
    expect($v->validated()['overlays'][0]['payload']['blendMode'])->toBe('screen');
});

test('an unknown blend mode is rejected rather than stored', function () {
    $v = Validator::make(
        blendOverlayData('image', 'vivid-light'),
        (new UpdateStudioFileOverlaysRequest)->rules(),
    );
    expect($v->fails())->toBeTrue();
    expect($v->errors()->has('overlays.0.payload.blendMode'))->toBeTrue();
});

test('blendMode is optional — omitting it stays valid', function () {
    $v = Validator::make(
        blendOverlayData('image', null),
        (new UpdateStudioFileOverlaysRequest)->rules(),
    );
    expect($v->fails())->toBeFalse();
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd api && ./vendor/bin/pest tests/Unit/Requests/OverlayBlendModeValidationTest.php
```

Expected: FAIL. The first three tests fail on the missing key — `validated()` returns a payload with no `blendMode`, so the `toBe(...)` assertion errors with "Undefined array key". The `vivid-light` test also fails, because with no rule the value is simply stripped rather than rejected.

- [ ] **Step 3: Create the shared trait**

Create `app/Http/Requests/Studio/Concerns/HasBlendModePayloadRules.php`:

```php
<?php

namespace App\Http\Requests\Studio\Concerns;

use Illuminate\Validation\Rule;

trait HasBlendModePayloadRules
{
    /**
     * Validation rule for an overlay's blend mode. Shared by the file-overlays
     * PATCH and the brand-overlay-preset store requests so the two stay in sync.
     *
     * MUST be whitelisted — validated() strips any payload sub-key without a
     * rule, which would silently drop an imported PSD layer's compositing mode
     * (a Multiply scrim reverting to an opaque rectangle on reload).
     *
     * The stored value is the CSS/canvas globalCompositeOperation name, NOT
     * Photoshop's. The web client maps PSD's vocabulary ('soft light') to the
     * canvas one ('soft-light') at import, and falls back to 'normal' for the
     * Photoshop modes canvas has no equivalent for (vivid light, pin light,
     * hard mix, divide, dissolve, ...). Applies to text, image and shape
     * payloads; group payloads never carry one.
     *
     * @return array<string, mixed>
     */
    protected function blendModePayloadRules(): array
    {
        return [
            'overlays.*.payload.blendMode' => [
                'sometimes', 'nullable',
                Rule::in([
                    'normal', 'multiply', 'screen', 'overlay', 'darken', 'lighten',
                    'color-dodge', 'color-burn', 'hard-light', 'soft-light',
                    'difference', 'exclusion', 'hue', 'saturation', 'color',
                    'luminosity', 'lighter',
                ]),
            ],
        ];
    }
}
```

- [ ] **Step 4: Wire the trait into `UpdateStudioFileOverlaysRequest`**

In `app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php`, add the import and `use` alongside the existing traits:

```php
use App\Http\Requests\Studio\Concerns\HasBlendModePayloadRules;
use App\Http\Requests\Studio\Concerns\HasShapeOverlayPayloadRules;
use App\Http\Requests\Studio\Concerns\HasTextOverlayPayloadRules;
```

```php
class UpdateStudioFileOverlaysRequest extends FormRequest
{
    use HasBlendModePayloadRules;
    use HasShapeOverlayPayloadRules;
    use HasTextOverlayPayloadRules;
```

Then spread the rules inside `rules()`, immediately after the `textOverlayPayloadRules()` spread:

```php
            ...$this->textOverlayPayloadRules(),
            ...$this->blendModePayloadRules(),
```

- [ ] **Step 5: Wire the trait into `StoreBrandOverlayPresetRequest`**

Apply exactly the same three edits to `app/Http/Requests/Studio/StoreBrandOverlayPresetRequest.php`: add the `use App\Http\Requests\Studio\Concerns\HasBlendModePayloadRules;` import, add `use HasBlendModePayloadRules;` to the class body next to the other two traits, and spread `...$this->blendModePayloadRules(),` after the `textOverlayPayloadRules()` spread in `rules()`.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd api && ./vendor/bin/pest tests/Unit/Requests/OverlayBlendModeValidationTest.php
```

Expected: PASS, 5 tests.

- [ ] **Step 7: Run the neighbouring overlay validation tests for regressions**

```bash
cd api && ./vendor/bin/pest tests/Unit/Requests
```

Expected: PASS. `OverlayLayerFlagsValidationTest` in particular must stay green — it asserts the same `validated()` whitelist behaviour for `name`/`hidden`/`locked`.

- [ ] **Step 8: Commit**

```bash
cd api && git add app/Http/Requests/Studio/Concerns/HasBlendModePayloadRules.php app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php app/Http/Requests/Studio/StoreBrandOverlayPresetRequest.php tests/Unit/Requests/OverlayBlendModeValidationTest.php
git commit -m "feat(api): whitelist overlay blendMode payload field"
```

---

### Task 2: Raise the overlay cap from 100 to 300

**Files:**
- Modify: `app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php:27`
- Modify: `app/Http/Requests/Studio/StoreBrandOverlayPresetRequest.php:26`
- Test: `tests/Unit/Requests/OverlayCapValidationTest.php`

**Interfaces:**
- Consumes: nothing.
- Produces: a 300-overlay ceiling that the web client mirrors in its own `MAX_OVERLAYS_PER_FILE` constant.

Real agency PSDs routinely exceed 100 layers. Today the web client reads the remaining room and slices the excess off the **top** of the stack, so the layers carrying the composition survive but everything above them silently disappears.

Both requests move together deliberately: a preset snapshots overlays from a file, so a preset cap below the file cap would make some files' layer sets un-presetable.

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Requests/OverlayCapValidationTest.php`:

```php
<?php

use App\Http\Requests\Studio\StoreBrandOverlayPresetRequest;
use App\Http\Requests\Studio\UpdateStudioFileOverlaysRequest;
use Illuminate\Support\Facades\Validator;
use Tests\TestCase;

uses(TestCase::class);

/**
 * The cap is a hard ceiling the web client mirrors: a save above it is
 * rejected wholesale, which would poison every autosave after an import.
 * Real agency PSDs regularly carry more than 100 layers.
 */
function capOverlays(int $count): array
{
    return array_map(fn () => [
        'type' => 'text',
        'x' => 0.1, 'y' => 0.1, 'width' => 0.6, 'height' => 0.1, 'rotation' => 0,
        'payload' => ['type' => 'text', 'content' => 'Hi', 'color' => '#112233'],
    ], range(1, $count));
}

test('UpdateStudioFileOverlaysRequest accepts 300 overlays', function () {
    $v = Validator::make(
        ['overlays' => capOverlays(300)],
        (new UpdateStudioFileOverlaysRequest)->rules(),
    );
    expect($v->fails())->toBeFalse();
});

test('UpdateStudioFileOverlaysRequest still rejects past 300', function () {
    $v = Validator::make(
        ['overlays' => capOverlays(301)],
        (new UpdateStudioFileOverlaysRequest)->rules(),
    );
    expect($v->fails())->toBeTrue();
    expect($v->errors()->has('overlays'))->toBeTrue();
});

test('StoreBrandOverlayPresetRequest matches the file cap', function () {
    $v = Validator::make(
        ['name' => 'Big preset', 'overlays' => capOverlays(300)],
        (new StoreBrandOverlayPresetRequest)->rules(),
    );
    expect($v->fails())->toBeFalse();
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd api && ./vendor/bin/pest tests/Unit/Requests/OverlayCapValidationTest.php
```

Expected: FAIL on the two 300-overlay tests — `overlays` exceeds `max:100`.

- [ ] **Step 3: Raise both caps**

In `app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php`, change the `overlays` rule and update its comment:

```php
            // Ceiling mirrored by the web client's MAX_OVERLAYS_PER_FILE — a
            // save above it is rejected wholesale and would poison every
            // autosave after a PSD import. Raised 100 → 300 for real agency
            // PSDs; keep the two in sync.
            'overlays' => ['present', 'array', 'max:300'],
```

In `app/Http/Requests/Studio/StoreBrandOverlayPresetRequest.php`:

```php
            'overlays' => ['required', 'array', 'min:1', 'max:300'],
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd api && ./vendor/bin/pest tests/Unit/Requests/OverlayCapValidationTest.php
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Run the full request suite**

```bash
cd api && ./vendor/bin/pest tests/Unit/Requests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd api && git add app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php app/Http/Requests/Studio/StoreBrandOverlayPresetRequest.php tests/Unit/Requests/OverlayCapValidationTest.php
git commit -m "feat(api): raise studio overlay cap from 100 to 300"
```

---

## Done criteria

- `payload.blendMode` survives `validated()` on both requests, for text, image and shape payloads.
- An unknown blend value is rejected with a field error rather than silently dropped.
- Both requests accept 300 overlays and reject 301.
- `./vendor/bin/pest tests/Unit/Requests` is green.

## Not in this plan

- `type: "group"` and `parent_id` validation, and the `color`-rule and cycle-check traps that come with them — those are **phase 2**, planned separately once phase 1 lands.
