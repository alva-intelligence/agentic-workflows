# KV Shapes — Arrows, Opacity & Presets (API) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Widen the shape-overlay validation so the new `arrow`/`star`/`diamond`/`chevron` kinds and the new `opacity` + `arrow` payload fields are accepted and preserved by `validated()`.

**Architecture:** All shape validation lives in one trait, `HasShapeOverlayPayloadRules`, consumed by BOTH save paths — `UpdateStudioFileOverlaysRequest` (main canvas) and `KvResizeExportController::updateOverlays` (resize tiles). Editing the trait covers both, so they can't drift. No migration — overlays stay in the existing `studio_files.overlays` / resize-export JSON columns.

**Tech Stack:** Laravel 13, PHP 8.5, Pest (Unit). Test runner: `./vendor/bin/pest` (Unit only — see constraints).

## Global Constraints

- Work directly on `develop` in `api/` — no feature branch (user directive). Pull latest `develop` first.
- **`FormRequest::validated()` strips any payload sub-key with no matching rule.** Every new field (`opacity`, `arrow.*`) MUST be whitelisted in the trait or it is silently dropped on save — this is the load-bearing change.
- Field ranges must match the web contract: `opacity` `0..1`; `arrow.pointer_length` / `arrow.pointer_width` `0..1`; `arrow.at_start` / `arrow.at_end` boolean.
- Kinds allow-list must become exactly: `rectangle, ellipse, triangle, polygon, line, arrow, star, diamond, chevron`.
- Run **Unit** tests only. The api Feature suite is known-broken on fresh migrate (workspaces backfill + SoftDeletes) — verify via `tests/Unit`. Do NOT run the Feature suite as a gate.

---

### Task 1: Widen the shape validation trait

**Files:**
- Modify: `api/app/Http/Requests/Studio/Concerns/HasShapeOverlayPayloadRules.php:24-49`
- Test: `api/tests/Unit/Requests/ShapeOverlayValidationTest.php`

**Interfaces:**
- Produces: `shapeOverlayPayloadRules()` accepts the 4 new kinds + whitelists `opacity` and `arrow.*`.

- [ ] **Step 1: Write the failing tests**

Append to `api/tests/Unit/Requests/ShapeOverlayValidationTest.php` (reuse the file's existing `shapeValidate` / `shapeBase` / `shapeRules` helpers):

```php
test('accepts new preset kinds', function (string $kind) {
    $v = shapeValidate(shapeBase(['kind' => $kind]));
    expect($v->fails())->toBeFalse();
})->with(['star', 'diamond', 'chevron']);

test('accepts an arrow with arrowheads + opacity and preserves the keys', function () {
    $v = shapeValidate(shapeBase([
        'kind' => 'arrow',
        'opacity' => 0.5,
        'arrow' => ['at_start' => false, 'at_end' => true, 'pointer_length' => 0.05, 'pointer_width' => 0.05],
    ]));
    expect($v->fails())->toBeFalse();
    $payload = $v->validated()['overlays'][0]['payload'];
    expect($payload)->toHaveKeys(['kind', 'opacity', 'arrow']);
    expect($payload['arrow'])->toHaveKeys(['at_start', 'at_end', 'pointer_length', 'pointer_width']);
});

test('accepts opacity on any shape and preserves it through validated()', function () {
    $v = shapeValidate(shapeBase(['opacity' => 0.2]));
    expect($v->fails())->toBeFalse();
    expect($v->validated()['overlays'][0]['payload'])->toHaveKey('opacity');
});

test('rejects out-of-range opacity and pointer sizes', function () {
    expect(shapeValidate(shapeBase(['opacity' => 1.5]))->fails())->toBeTrue();
    expect(shapeValidate(shapeBase(['opacity' => -0.1]))->fails())->toBeTrue();
    expect(shapeValidate(shapeBase([
        'kind' => 'arrow',
        'arrow' => ['pointer_length' => 2],
    ]))->fails())->toBeTrue();
});

test('still rejects an unknown kind', function () {
    expect(shapeValidate(shapeBase(['kind' => 'hexagram']))->fails())->toBeTrue();
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd api && ./vendor/bin/pest tests/Unit/Requests/ShapeOverlayValidationTest.php`
Expected: FAIL — new kinds rejected by the `Rule::in`; `opacity`/`arrow` dropped by `validated()` so `toHaveKey`/`toHaveKeys` fail.

- [ ] **Step 3: Widen the trait**

In `HasShapeOverlayPayloadRules.php`, edit the `kind` allow-list (line 26) and add the `opacity` + `arrow.*` rules. Replace the returned array (lines 24-50) with:

```php
        return [
            'overlays.*.payload.kind' => [
                'required_if:overlays.*.payload.type,shape',
                Rule::in(['rectangle', 'ellipse', 'triangle', 'polygon', 'line', 'arrow', 'star', 'diamond', 'chevron']),
            ],
            'overlays.*.payload.color' => ['required_if:overlays.*.payload.type,shape', $hex],

            ...$this->gradientPayloadRules(),

            'overlays.*.payload.stroke' => ['sometimes', 'nullable', 'array'],
            'overlays.*.payload.stroke.color' => ['required_with:overlays.*.payload.stroke', $hex],
            'overlays.*.payload.stroke.width' => ['required_with:overlays.*.payload.stroke', 'numeric', 'between:0,1'],

            'overlays.*.payload.corner_radius' => ['sometimes', 'nullable', 'numeric', 'between:0,1'],
            'overlays.*.payload.sides' => ['sometimes', 'nullable', 'integer', 'between:3,12'],

            // Whole-shape opacity (0..1). Absent => 1 (applied client-side).
            'overlays.*.payload.opacity' => ['sometimes', 'nullable', 'numeric', 'between:0,1'],

            // arrow kind only — arrowhead direction + normalized pointer sizes.
            'overlays.*.payload.arrow' => ['sometimes', 'nullable', 'array'],
            'overlays.*.payload.arrow.at_start' => ['sometimes', 'nullable', 'boolean'],
            'overlays.*.payload.arrow.at_end' => ['sometimes', 'nullable', 'boolean'],
            'overlays.*.payload.arrow.pointer_length' => ['sometimes', 'nullable', 'numeric', 'between:0,1'],
            'overlays.*.payload.arrow.pointer_width' => ['sometimes', 'nullable', 'numeric', 'between:0,1'],

            'overlays.*.payload.line' => ['sometimes', 'nullable', 'array'],
            'overlays.*.payload.line.x1' => ['required_with:overlays.*.payload.line', 'numeric', 'between:-5,5'],
            'overlays.*.payload.line.y1' => ['required_with:overlays.*.payload.line', 'numeric', 'between:-5,5'],
            'overlays.*.payload.line.x2' => ['required_with:overlays.*.payload.line', 'numeric', 'between:-5,5'],
            'overlays.*.payload.line.y2' => ['required_with:overlays.*.payload.line', 'numeric', 'between:-5,5'],
        ];
```

- [ ] **Step 4: Run to verify pass**

Run: `cd api && ./vendor/bin/pest tests/Unit/Requests/ShapeOverlayValidationTest.php`
Expected: PASS (all new + all pre-existing tests in the file).

- [ ] **Step 5: Commit**

```bash
git add api/app/Http/Requests/Studio/Concerns/HasShapeOverlayPayloadRules.php api/tests/Unit/Requests/ShapeOverlayValidationTest.php
git commit -m "feat(api): accept arrow/opacity/preset shape fields in overlay validation"
```

---

### Task 2: Prove both save paths accept the new fields

**Files:**
- Test: `api/tests/Unit/Requests/ShapeOverlayValidationTest.php` (extend the existing real-request assertions, ~lines 96-143)

**Interfaces:**
- Consumes: the widened trait (Task 1). `UpdateStudioFileOverlaysRequest` and `KvResizeExportController` both spread `shapeOverlayPayloadRules()`, so both inherit the change — this task locks that in with a test against the real `UpdateStudioFileOverlaysRequest`.

- [ ] **Step 1: Write the failing test**

Add to the real-request section of `ShapeOverlayValidationTest.php` (mirror the existing `UpdateStudioFileOverlaysRequest` test at lines 96-143):

```php
test('UpdateStudioFileOverlaysRequest accepts a full arrow overlay', function () {
    $request = new \App\Http\Requests\Studio\UpdateStudioFileOverlaysRequest();
    $data = ['overlays' => [[
        'id' => 'ov-1',
        'type' => 'shape',
        'x' => 0.1, 'y' => 0.1, 'width' => 0.3, 'height' => 0.2,
        'rotation' => 0, 'z' => 0,
        'payload' => [
            'type' => 'shape',
            'kind' => 'arrow',
            'color' => '#4B5563',
            'opacity' => 0.8,
            'stroke' => ['color' => '#4B5563', 'width' => 0.01],
            'arrow' => ['at_start' => false, 'at_end' => true, 'pointer_length' => 0.05, 'pointer_width' => 0.05],
        ],
    ]]];
    $validator = \Illuminate\Support\Facades\Validator::make($data, $request->rules());
    expect($validator->fails())->toBeFalse();
    $payload = $validator->validated()['overlays'][0]['payload'];
    expect($payload)->toHaveKeys(['opacity', 'arrow']);
});
```

If the file's existing real-request tests instantiate the request differently (e.g. via a helper), match that pattern instead of the inline `Validator::make` above.

- [ ] **Step 2: Run to verify (should pass immediately after Task 1)**

Run: `cd api && ./vendor/bin/pest tests/Unit/Requests/ShapeOverlayValidationTest.php`
Expected: PASS — confirms the real request inherits the widened trait. (If it fails, the request re-declares an overriding rule; check `UpdateStudioFileOverlaysRequest.php:64-71` for a catch-all that shadows a shape sub-key.)

- [ ] **Step 3: Commit**

```bash
git add api/tests/Unit/Requests/ShapeOverlayValidationTest.php
git commit -m "test(api): assert overlay request accepts full arrow payload"
```

## Self-Review Notes (author)

- Spec coverage: kinds allow-list (T1), opacity rule (T1), arrow.* rules (T1), both-path coverage via shared trait (T2). ✅
- The `KvResizeExportController` inline validation spreads the same trait, so no separate controller edit is needed — the shared-trait design (from the 2026-07-21 fix) is what makes this a one-file change. Documented, not re-edited.
- Range parity with web contract (opacity 0..1, pointer 0..1). ✅
