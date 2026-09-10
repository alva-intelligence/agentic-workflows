# KV text run size + colour — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the overlays PATCH accept two new per-run overrides — `fontSize` and `color` — on a text overlay's `runs` array.

**Architecture:** Two validation rules added beside the three that already exist in `UpdateStudioFileOverlaysRequest::rules()`. Nothing else on the API changes: `runs` is stored inside an opaque JSON payload column, so there is no migration, no model change and no resource change. The rules mirror the layer-level units exactly, because the client stores a run's `fontSize` in the same normalized unit as `payload.fontSize`.

**Tech Stack:** Laravel 13, PHP 8.5, Pest 3.

**Spec:** `docs/superpowers/specs/2026-09-10-kv-text-run-size-color-design.md`

## Global Constraints

- Repo: `api/` (`alva-intelligence/frnd-api-php`). Branch from `develop`: `feature/daffa/vc-kv-text-run-size-color`.
- Run `fontSize` unit: normalized fraction of board height. Validation `between:0,5` — the **same** bounds as `overlays.*.payload.fontSize` in `HasTextOverlayPayloadRules`. The two must move together.
- Run `color` format: `#RRGGBB` only, regex `/^#[0-9A-Fa-f]{6}$/` — same as `overlays.*.payload.color`.
- The request validates the **shape** of a run only. There is deliberately NO check that run lengths sum to the content length: this endpoint is a full-array autosave, and a 422 on a derived value would poison every subsequent save for the file. Do not add one.
- Both rules go in `UpdateStudioFileOverlaysRequest` directly, NOT in the `HasTextOverlayPayloadRules` trait — that trait is shared with `StoreBrandOverlayPresetRequest`, and presets must keep rejecting `runs` entirely.
- Test command: `./vendor/bin/pest tests/Unit/Requests/TextOverlayStylingValidationTest.php`

---

### Task 1: Accept `fontSize` and `color` on a run

**Files:**
- Modify: `app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php:102-106`
- Test: `tests/Unit/Requests/TextOverlayStylingValidationTest.php`

**Interfaces:**
- Consumes: the existing `textOverlayData(array $payload): array` helper at `tests/Unit/Requests/TextOverlayStylingValidationTest.php:28`, which wraps a payload fragment in a full valid overlays array.
- Produces: two accepted payload keys, `overlays.*.payload.runs.*.fontSize` (numeric) and `overlays.*.payload.runs.*.color` (string). The web client depends on `validated()` preserving both.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Unit/Requests/TextOverlayStylingValidationTest.php`:

```php
test('UpdateStudioFileOverlaysRequest preserves per-run fontSize and color through validated()', function () {
    $runs = [
        ['length' => 5, 'fontSize' => 0.12, 'color' => '#FF0066'],
        ['length' => 7, 'fontWeight' => 'bold'],
        ['length' => 3, 'color' => '#00ff99'],
    ];
    $v = Validator::make(
        textOverlayData(['runs' => $runs]),
        (new UpdateStudioFileOverlaysRequest)->rules(),
    );
    expect($v->fails())->toBeFalse();
    expect($v->validated()['overlays'][0]['payload']['runs'])->toBe($runs);
});

test('UpdateStudioFileOverlaysRequest rejects malformed per-run fontSize and color', function () {
    $rules = (new UpdateStudioFileOverlaysRequest)->rules();

    // fontSize shares the layer-level bounds: a fraction of board height, 0..5
    expect(Validator::make(textOverlayData(['runs' => [['length' => 2, 'fontSize' => 5.5]]]), $rules)->fails())
        ->toBeTrue();
    expect(Validator::make(textOverlayData(['runs' => [['length' => 2, 'fontSize' => -0.1]]]), $rules)->fails())
        ->toBeTrue();
    expect(Validator::make(textOverlayData(['runs' => [['length' => 2, 'fontSize' => 'big']]]), $rules)->fails())
        ->toBeTrue();
    // color is solid #RRGGBB only — no shorthand, no alpha, no gradient object
    expect(Validator::make(textOverlayData(['runs' => [['length' => 2, 'color' => '#FFF']]]), $rules)->fails())
        ->toBeTrue();
    expect(Validator::make(textOverlayData(['runs' => [['length' => 2, 'color' => '#FF006600']]]), $rules)->fails())
        ->toBeTrue();
    expect(Validator::make(textOverlayData(['runs' => [['length' => 2, 'color' => 'red']]]), $rules)->fails())
        ->toBeTrue();
});

test('a run may still omit every override — length alone stays valid', function () {
    $v = Validator::make(
        textOverlayData(['runs' => [['length' => 5]]]),
        (new UpdateStudioFileOverlaysRequest)->rules(),
    );
    expect($v->fails())->toBeFalse();
});

test('runs carrying fontSize/color are STILL rejected on a brand overlay preset', function () {
    $data = [
        'name' => 'My preset',
        'overlays' => textOverlayData(['runs' => [['length' => 5, 'fontSize' => 0.2, 'color' => '#123456']]])['overlays'],
    ];
    $v = Validator::make($data, (new StoreBrandOverlayPresetRequest)->rules());
    expect($v->fails())->toBeFalse();
    expect($v->validated()['overlays'][0]['payload'])->not->toHaveKey('runs');
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
./vendor/bin/pest tests/Unit/Requests/TextOverlayStylingValidationTest.php
```

Expected: the first test FAILS — `validated()` strips the unwhitelisted `fontSize`/`color` keys, so the returned runs array does not equal `$runs`. The "rejects malformed" test also FAILS, because unwhitelisted keys are ignored rather than rejected. The last two PASS already (they assert existing behaviour is preserved).

- [ ] **Step 3: Add the two rules**

In `app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php`, directly after the `fontStyle` run rule (line 106):

```php
            'overlays.*.payload.runs.*.fontStyle' => ['sometimes', 'nullable', Rule::in(['normal', 'italic'])],
            // Per-run size and colour. `fontSize` carries the SAME unit as the
            // layer-level `overlays.*.payload.fontSize` — a normalized fraction
            // of the board height, not a multiple of the layer size — so the
            // bounds here must track HasTextOverlayPayloadRules' `between:0,5`.
            // `color` is solid #RRGGBB only: a run never carries a gradient,
            // because gradient coordinates are computed over the whole text box
            // and have no meaning for a sub-range of it.
            'overlays.*.payload.runs.*.fontSize' => ['sometimes', 'nullable', 'numeric', 'between:0,5'],
            'overlays.*.payload.runs.*.color' => ['sometimes', 'nullable', 'regex:/^#[0-9A-Fa-f]{6}$/'],
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
./vendor/bin/pest tests/Unit/Requests/TextOverlayStylingValidationTest.php
```

Expected: PASS, all tests in the file.

- [ ] **Step 5: Run the wider studio suite for regressions**

```bash
./vendor/bin/pest tests/Feature/Studio tests/Unit/Requests
```

Expected: PASS. Nothing else reads `runs`, so a failure here means a rule was pasted into the wrong array literal — check that the two new lines landed inside `rules()` and above the final `overlays.*.payload.color` definition, which must stay last (it deliberately overrides the shape rule's `required_if`).

- [ ] **Step 6: Commit**

```bash
git add app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php tests/Unit/Requests/TextOverlayStylingValidationTest.php
git commit -m "feat(api): accept per-run fontSize and color on text overlays

A run may now override size and colour, not just font identity. fontSize
shares the layer-level unit and bounds (a normalized fraction of board
height, 0..5) so the two cannot drift; color is solid #RRGGBB, since a
run never carries a gradient.

Shape validation only, as with the existing run rules: run lengths are
still not checked against the content length, because this endpoint is a
full-array autosave and a 422 on a derived value would poison every
later save for the file."
```
