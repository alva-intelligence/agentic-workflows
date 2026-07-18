# KV Canvas Shape Overlays — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept a new overlay `type: "shape"` (parametric vector shapes with solid/gradient fill + stroke) in the studio-file overlays PATCH and in brand overlay presets, with validation that whitelists every shape payload field.

**Architecture:** Shapes ride the existing `StudioOverlay` envelope — no new columns, no controller changes (both controllers pass `payload` through whole after `validated()`). Work is confined to two FormRequests. Because `validated()` strips any payload sub-key without a rule, the core of this plan is a complete, whitelisted rule set for the shape payload, extracted into a shared trait mirroring `HasTextOverlayPayloadRules`.

**Tech Stack:** Laravel 13, PHP 8.5, Pest 4 (Unit tests only — the Feature suite fails on fresh migrate).

## Global Constraints

- Work in worktree: `/Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/kv-canvas-shapes` (branch `feature/daffa/vc-kv-canvas-shapes`, based on `origin/develop`).
- Colors: 6-digit hex only, regex `/^#[0-9A-Fa-f]{6}$/` (matches existing overlay color rules).
- `type` and `payload.type` are BOTH discriminated — add `'shape'` to both `Rule::in([...])`.
- Tests are **Pest Unit** (`uses(TestCase::class);`, no DB), matching `tests/Unit/Requests/OverlayGradientValidationTest.php`. Do NOT add Feature tests.
- After any PHP change: `vendor/bin/pint --dirty --format agent`.
- Shape payload fields to whitelist: `kind`, `color`, `gradient.{type,from,to,angle}`, `stroke.{color,width}`, `corner_radius`, `sides`. Any field without a rule is silently dropped on save.
- Shape kinds enum: `rectangle | ellipse | triangle | polygon | line`.

---

### Task 1: Shared shape-payload validation trait

**Files:**
- Create: `app/Http/Requests/Studio/Concerns/HasShapeOverlayPayloadRules.php`
- Test: `tests/Unit/Requests/ShapeOverlayValidationTest.php`

**Interfaces:**
- Produces: `trait HasShapeOverlayPayloadRules` with `protected function shapeOverlayPayloadRules(): array` returning a `[dot.path => rules]` map for the shape payload, consumed by both request classes in Tasks 2–3.

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Requests/ShapeOverlayValidationTest.php`. This tests the trait *through* `UpdateStudioFileOverlaysRequest` once Task 2 wires it in; for Task 1 we assert the trait method's rule map directly via an anonymous class so the trait is testable in isolation.

```php
<?php

use App\Http\Requests\Studio\Concerns\HasShapeOverlayPayloadRules;
use Illuminate\Support\Facades\Validator;
use Tests\TestCase;

uses(TestCase::class);

function shapeRules(): array
{
    $host = new class
    {
        use HasShapeOverlayPayloadRules;

        public function rules(): array
        {
            return [
                'overlays' => ['present', 'array'],
                'overlays.*.payload' => ['required', 'array'],
                'overlays.*.payload.type' => ['required'],
                ...$this->shapeOverlayPayloadRules(),
            ];
        }
    };

    return $host->rules();
}

function shapeBase(array $payload): array
{
    return [
        'overlays' => [[
            'payload' => array_merge(['type' => 'shape', 'kind' => 'rectangle', 'color' => '#ff0000'], $payload),
        ]],
    ];
}

function shapeValidate(array $data): Illuminate\Contracts\Validation\Validator
{
    return Validator::make($data, shapeRules());
}

test('accepts a solid rectangle shape and preserves its keys', function () {
    $v = shapeValidate(shapeBase(['corner_radius' => 0.2]));
    expect($v->fails())->toBeFalse();
    $payload = $v->validated()['overlays'][0]['payload'];
    expect($payload)->toHaveKeys(['kind', 'color', 'corner_radius']);
});

test('accepts a gradient + stroke shape and preserves nested keys', function () {
    $v = shapeValidate(shapeBase([
        'gradient' => ['type' => 'linear', 'from' => '#ff0000', 'to' => '#0000ff', 'angle' => 90],
        'stroke' => ['color' => '#000000', 'width' => 0.01],
    ]));
    expect($v->fails())->toBeFalse();
    $payload = $v->validated()['overlays'][0]['payload'];
    expect($payload['gradient'])->toHaveKeys(['type', 'from', 'to', 'angle'])
        ->and($payload['stroke'])->toHaveKeys(['color', 'width']);
});

test('accepts a polygon with sides and a line', function () {
    expect(shapeValidate(shapeBase(['kind' => 'polygon', 'sides' => 6]))->fails())->toBeFalse();
    expect(shapeValidate(shapeBase(['kind' => 'line', 'stroke' => ['color' => '#000000', 'width' => 0.01]]))->fails())->toBeFalse();
});

test('rejects bad kind, bad hex, out-of-range sides/corner_radius/angle', function () {
    expect(shapeValidate(shapeBase(['kind' => 'hexagram']))->fails())->toBeTrue();
    expect(shapeValidate(shapeBase(['color' => 'red']))->fails())->toBeTrue();
    expect(shapeValidate(shapeBase(['kind' => 'polygon', 'sides' => 2]))->fails())->toBeTrue();
    expect(shapeValidate(shapeBase(['kind' => 'polygon', 'sides' => 99]))->fails())->toBeTrue();
    expect(shapeValidate(shapeBase(['corner_radius' => 2]))->fails())->toBeTrue();
    expect(shapeValidate(shapeBase(['gradient' => ['from' => '#ff0000', 'to' => '#0000ff', 'angle' => 400]]))->fails())->toBeTrue();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --compact --filter=ShapeOverlayValidation`
Expected: FAIL — `Trait "App\Http\Requests\Studio\Concerns\HasShapeOverlayPayloadRules" not found`.

- [ ] **Step 3: Create the trait**

Create `app/Http/Requests/Studio/Concerns/HasShapeOverlayPayloadRules.php`. Model it on `HasTextOverlayPayloadRules` (same dir). Every field is conditioned on `overlays.*.payload.type,shape` so it only applies to shape overlays. `sides` range 3–12 matches the web stepper; `corner_radius` and gradient `angle`/stroke `width` are numeric-bounded.

```php
<?php

namespace App\Http\Requests\Studio\Concerns;

use Illuminate\Validation\Rule;

/**
 * Validation rules for the "shape" overlay payload (rectangle/ellipse/triangle/
 * polygon/line with solid or 2-color gradient fill + optional stroke).
 *
 * WARNING: FormRequest::validated() strips any payload sub-key that has no rule
 * here, so every shape field MUST be whitelisted or it is silently dropped on
 * save. Mirrors HasTextOverlayPayloadRules.
 */
trait HasShapeOverlayPayloadRules
{
    protected function shapeOverlayPayloadRules(): array
    {
        $hex = 'regex:/^#[0-9A-Fa-f]{6}$/';

        return [
            'overlays.*.payload.kind' => [
                'required_if:overlays.*.payload.type,shape',
                Rule::in(['rectangle', 'ellipse', 'triangle', 'polygon', 'line']),
            ],
            'overlays.*.payload.color' => ['required_if:overlays.*.payload.type,shape', $hex],

            // Optional 2-color gradient (mirrors the text overlay gradient shape).
            'overlays.*.payload.gradient' => ['sometimes', 'nullable', 'array'],
            'overlays.*.payload.gradient.type' => ['sometimes', Rule::in(['linear', 'radial'])],
            'overlays.*.payload.gradient.from' => ['required_with:overlays.*.payload.gradient', $hex],
            'overlays.*.payload.gradient.to' => ['required_with:overlays.*.payload.gradient', $hex],
            'overlays.*.payload.gradient.angle' => ['required_with:overlays.*.payload.gradient', 'numeric', 'between:0,360'],

            // Optional stroke (border). Absent = no stroke.
            'overlays.*.payload.stroke' => ['sometimes', 'nullable', 'array'],
            'overlays.*.payload.stroke.color' => ['required_with:overlays.*.payload.stroke', $hex],
            'overlays.*.payload.stroke.width' => ['required_with:overlays.*.payload.stroke', 'numeric', 'between:0,1'],

            // Kind-specific, optional.
            'overlays.*.payload.corner_radius' => ['sometimes', 'nullable', 'numeric', 'between:0,1'],
            'overlays.*.payload.sides' => ['sometimes', 'nullable', 'integer', 'between:3,12'],
        ];
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan test --compact --filter=ShapeOverlayValidation`
Expected: PASS (all 4 tests).

- [ ] **Step 5: Format + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/kv-canvas-shapes
vendor/bin/pint --dirty --format agent
git add app/Http/Requests/Studio/Concerns/HasShapeOverlayPayloadRules.php tests/Unit/Requests/ShapeOverlayValidationTest.php
git commit -m "feat(api): add shape overlay payload validation trait"
```

---

### Task 2: Wire shape rules into the file-overlays PATCH request

**Files:**
- Modify: `app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php`
- Test: `tests/Unit/Requests/ShapeOverlayValidationTest.php` (add end-to-end-through-the-real-request cases)

**Interfaces:**
- Consumes: `HasShapeOverlayPayloadRules::shapeOverlayPayloadRules()` from Task 1.

- [ ] **Step 1: Add failing test through the real request**

Append to `tests/Unit/Requests/ShapeOverlayValidationTest.php`:

```php
use App\Http\Requests\Studio\UpdateStudioFileOverlaysRequest;

function fileOverlayShapeBase(array $payload): array
{
    return [
        'overlays' => [[
            'type' => 'shape',
            'x' => 0.1, 'y' => 0.1, 'width' => 0.3, 'height' => 0.3, 'rotation' => 0,
            'payload' => array_merge(['type' => 'shape', 'kind' => 'ellipse', 'color' => '#00ff00'], $payload),
        ]],
    ];
}

test('UpdateStudioFileOverlaysRequest accepts a shape overlay and preserves payload', function () {
    $data = fileOverlayShapeBase(['gradient' => ['type' => 'radial', 'from' => '#ff0000', 'to' => '#0000ff', 'angle' => 0]]);
    $v = Validator::make($data, (new UpdateStudioFileOverlaysRequest)->rules());
    expect($v->fails())->toBeFalse();
    expect($v->validated()['overlays'][0]['payload'])->toHaveKeys(['kind', 'color', 'gradient']);
});

test('UpdateStudioFileOverlaysRequest rejects an unknown shape kind', function () {
    $v = Validator::make(fileOverlayShapeBase(['kind' => 'blob']), (new UpdateStudioFileOverlaysRequest)->rules());
    expect($v->fails())->toBeTrue();
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `php artisan test --compact --filter=ShapeOverlayValidation`
Expected: FAIL — the new `type: "shape"` is rejected by `Rule::in(['text','image'])` and shape payload keys are stripped.

- [ ] **Step 3: Edit the request**

In `app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php`:

1. Add the trait import + `use` inside the class:
```php
use App\Http\Requests\Studio\Concerns\HasShapeOverlayPayloadRules;
// ...
class UpdateStudioFileOverlaysRequest extends FormRequest
{
    use HasShapeOverlayPayloadRules;
```
(If it already `use`s `HasTextOverlayPayloadRules`, add this on the next line.)

2. In `rules()`, change the top-level type rule to include `shape`:
```php
'overlays.*.type' => ['required', Rule::in(['text', 'image', 'shape'])],
```

3. Change the payload discriminant to include `shape`:
```php
'overlays.*.payload.type' => ['required', Rule::in(['text', 'image', 'shape'])],
```

4. Spread the shape rules alongside the existing text/image payload rules (after the `...$this->textOverlayPayloadRules(),` spread, before the image block):
```php
            ...$this->textOverlayPayloadRules(),
            ...$this->shapeOverlayPayloadRules(),
```

The `withValidator()` hook needs no change — shapes carry no `asset_url`, so the image host-check branch (gated on `payload.type === 'image'`) skips them, and the `board_generation_id` check is type-agnostic.

- [ ] **Step 4: Run to verify it passes**

Run: `php artisan test --compact --filter=ShapeOverlayValidation`
Expected: PASS (all Task 1 + Task 2 tests).

- [ ] **Step 5: Confirm existing overlay tests still pass**

Run: `php artisan test --compact --filter=OverlayGradientValidation`
Expected: PASS (text/image validation unaffected).

- [ ] **Step 6: Format + commit**

```bash
vendor/bin/pint --dirty --format agent
git add app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php tests/Unit/Requests/ShapeOverlayValidationTest.php
git commit -m "feat(api): accept shape overlays in studio-file overlays PATCH"
```

---

### Task 3: Wire shape rules into the brand-overlay-preset request

**Files:**
- Modify: `app/Http/Requests/Studio/StoreBrandOverlayPresetRequest.php`
- Test: `tests/Unit/Requests/ShapePresetValidationTest.php`

**Interfaces:**
- Consumes: `HasShapeOverlayPayloadRules::shapeOverlayPayloadRules()` from Task 1.

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Requests/ShapePresetValidationTest.php`:

```php
<?php

use App\Http\Requests\Studio\StoreBrandOverlayPresetRequest;
use Illuminate\Support\Facades\Validator;
use Tests\TestCase;

uses(TestCase::class);

test('StoreBrandOverlayPresetRequest accepts a preset containing a shape', function () {
    $data = [
        'name' => 'Brand shapes',
        'overlays' => [[
            'type' => 'shape',
            'x' => 0.1, 'y' => 0.1, 'width' => 0.3, 'height' => 0.3, 'rotation' => 0,
            'payload' => [
                'type' => 'shape', 'kind' => 'triangle', 'color' => '#123456',
                'stroke' => ['color' => '#000000', 'width' => 0.02],
            ],
        ]],
    ];
    $v = Validator::make($data, (new StoreBrandOverlayPresetRequest)->rules());
    expect($v->fails())->toBeFalse();
    expect($v->validated()['overlays'][0]['payload'])->toHaveKeys(['kind', 'color', 'stroke']);
});

test('StoreBrandOverlayPresetRequest rejects a shape with bad color', function () {
    $data = [
        'name' => 'Bad', 'overlays' => [[
            'type' => 'shape', 'x' => 0.1, 'y' => 0.1, 'width' => 0.3, 'height' => 0.3, 'rotation' => 0,
            'payload' => ['type' => 'shape', 'kind' => 'triangle', 'color' => 'nope'],
        ]],
    ];
    expect(Validator::make($data, (new StoreBrandOverlayPresetRequest)->rules())->fails())->toBeTrue();
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `php artisan test --compact --filter=ShapePresetValidation`
Expected: FAIL — preset request rejects `type: "shape"` and strips payload keys.

- [ ] **Step 3: Edit the request**

In `app/Http/Requests/Studio/StoreBrandOverlayPresetRequest.php`, apply the same three edits as Task 2 (this request has no `withValidator()` and no `id`/`board_generation_id` rules — just the type + payload.type + spread):

1. `use HasShapeOverlayPayloadRules;` inside the class (next to `use HasTextOverlayPayloadRules;`).
2. `'overlays.*.type' => ['required', Rule::in(['text', 'image', 'shape'])],`
3. `'overlays.*.payload.type' => ['required', Rule::in(['text', 'image', 'shape'])],`
4. Add `...$this->shapeOverlayPayloadRules(),` after `...$this->textOverlayPayloadRules(),`.

- [ ] **Step 4: Run to verify it passes**

Run: `php artisan test --compact --filter=ShapePresetValidation`
Expected: PASS (both tests).

- [ ] **Step 5: Format + commit**

```bash
vendor/bin/pint --dirty --format agent
git add app/Http/Requests/Studio/StoreBrandOverlayPresetRequest.php tests/Unit/Requests/ShapePresetValidationTest.php
git commit -m "feat(api): accept shapes in brand overlay presets"
```

---

### Task 4: Full-suite sanity + track update

**Files:**
- Modify: `docs/tracks/kv-canvas-shapes.track.md` (create if the track convention is in use; otherwise skip)

- [ ] **Step 1: Run all new + adjacent Unit tests**

Run: `php artisan test --compact --filter="Shape|Overlay"`
Expected: PASS — all shape + existing overlay validation tests green.

- [ ] **Step 2: Pint clean check**

Run: `vendor/bin/pint --dirty --format agent`
Expected: No files changed (already formatted).

- [ ] **Step 3: Commit any track/doc updates**

```bash
git add -A && git commit -m "docs(api): track KV canvas shape overlays" || echo "nothing to commit"
```

---

## Self-Review

**Spec coverage:** The API section of the spec (extend `UpdateStudioFileOverlaysRequest` + `StoreBrandOverlayPresetRequest` to accept the shape payload, whitelist every field, no controller/model change) is covered by Tasks 1–3. The "whitelist or silently dropped" constraint is enforced by the trait + asserted by `toHaveKeys` on `validated()`.

**Placeholder scan:** No TBD/TODO; all rule code and test code is complete.

**Type consistency:** The shape payload fields (`kind`, `color`, `gradient.{type,from,to,angle}`, `stroke.{color,width}`, `corner_radius`, `sides`) and enums (`rectangle|ellipse|triangle|polygon|line`; sides 3–12) match the web plan's `ShapePayload` type and the spec's data model exactly. Method name `shapeOverlayPayloadRules()` is used identically in Tasks 1–3.

**No controller/model tasks:** Confirmed unnecessary — both controllers rebuild overlays field-by-field but pass `payload` through whole, and `studio_files.overlays` is an `array`-cast column. Shapes introduce no new top-level overlay fields.
