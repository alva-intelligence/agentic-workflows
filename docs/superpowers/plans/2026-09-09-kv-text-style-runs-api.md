# KV text style runs — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the overlays PATCH accept and persist a text payload's `runs` array without stripping it.

**Architecture:** One block of validation rules added directly to `UpdateStudioFileOverlaysRequest::rules()`. Shape validation only — no cross-field check against `content`, because a 422 fails the whole full-array autosave.

**Tech Stack:** Laravel FormRequest, Pest.

**Spec:** `docs/superpowers/specs/2026-09-09-kv-text-style-runs-design.md`

**Worktree:** `api/.worktrees/kv-text-runs` on branch `feature/daffa/vc-kv-text-runs`.

## Global Constraints

- `FormRequest::validated()` strips any payload sub-key without a rule. Every new key must be whitelisted or it silently vanishes on save.
- The rules go on `UpdateStudioFileOverlaysRequest` **directly**, NOT in `app/Http/Requests/Studio/Concerns/HasTextOverlayPayloadRules.php` — that trait is shared with `StoreBrandOverlayPresetRequest`, and a brand preset must never carry runs.
- Per-run properties are `fontFamily`, `fontWeight`, `fontStyle` only. `fontWeight` ∈ `normal|bold`; `fontStyle` ∈ `normal|italic`; `fontFamily` is a string, max 255 — identical to the layer-level rules.
- No rule may compare `sum(runs[].length)` against `content`. That relationship is normalized client-side at read time by design.
- Cap the array at 200 entries.

---

### Task 1: Whitelist `payload.runs`

**Files:**
- Modify: `app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php` (inside `rules()`, right after the `...$this->textOverlayPayloadRules(),` spread)
- Test: `tests/Unit/Requests/TextOverlayStylingValidationTest.php`

**Interfaces:**
- Consumes: nothing.
- Produces: a validated payload that retains `runs` as an array of `['length' => int, 'fontFamily' => ?string, 'fontWeight' => ?string, 'fontStyle' => ?string]`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Unit/Requests/TextOverlayStylingValidationTest.php`:

```php
test('UpdateStudioFileOverlaysRequest preserves per-run font styling through validated()', function () {
    $runs = [
        ['length' => 5, 'fontWeight' => 'bold'],
        ['length' => 7, 'fontFamily' => 'bf_01hzzz', 'fontStyle' => 'italic'],
        ['length' => 3],
    ];
    $v = Validator::make(
        textOverlayData(['runs' => $runs]),
        (new UpdateStudioFileOverlaysRequest)->rules(),
    );
    expect($v->fails())->toBeFalse();
    expect($v->validated()['overlays'][0]['payload']['runs'])->toBe($runs);
});

test('UpdateStudioFileOverlaysRequest rejects malformed runs', function () {
    $rules = (new UpdateStudioFileOverlaysRequest)->rules();

    // length is required on every entry
    expect(Validator::make(textOverlayData(['runs' => [['fontWeight' => 'bold']]]), $rules)->fails())
        ->toBeTrue();
    // length must be a positive integer
    expect(Validator::make(textOverlayData(['runs' => [['length' => 0]]]), $rules)->fails())
        ->toBeTrue();
    // weight / style are the same closed sets as the layer level
    expect(Validator::make(textOverlayData(['runs' => [['length' => 2, 'fontWeight' => 'heavy']]]), $rules)->fails())
        ->toBeTrue();
    expect(Validator::make(textOverlayData(['runs' => [['length' => 2, 'fontStyle' => 'oblique']]]), $rules)->fails())
        ->toBeTrue();
});

test('runs are NOT accepted on a brand overlay preset (presets are content-free style templates)', function () {
    $data = [
        'name' => 'My preset',
        'overlays' => textOverlayData(['runs' => [['length' => 5, 'fontWeight' => 'bold']]])['overlays'],
    ];
    $v = Validator::make($data, (new StoreBrandOverlayPresetRequest)->rules());
    expect($v->fails())->toBeFalse();
    expect($v->validated()['overlays'][0]['payload'])->not->toHaveKey('runs');
});

test('a run count over the cap is rejected rather than silently truncated', function () {
    $runs = array_fill(0, 201, ['length' => 1]);
    expect(Validator::make(textOverlayData(['runs' => $runs]), (new UpdateStudioFileOverlaysRequest)->rules())->fails())
        ->toBeTrue();
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
./vendor/bin/pest tests/Unit/Requests/TextOverlayStylingValidationTest.php
```

Expected: the four new tests FAIL. The first fails because `validated()` strips `runs` (the assertion sees a missing key), the malformed-runs and cap tests fail because nothing rejects them yet, and the preset test is the only one that may already pass — it asserts today's behaviour and must keep passing after the change.

- [ ] **Step 3: Add the rules**

In `app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php`, immediately after the `...$this->textOverlayPayloadRules(),` line:

```php
            // Per-run font overrides — a text layer that mixes fonts/weights
            // within one string. NOT in HasTextOverlayPayloadRules on purpose:
            // that trait is shared with StoreBrandOverlayPresetRequest, and a
            // preset is a style template re-stamped onto different content, so
            // a stored run length would be meaningless there.
            //
            // Shape only. There is deliberately NO check that the run lengths
            // sum to the content length: this request validates a FULL-ARRAY
            // autosave, so a 422 on one derived value would poison every
            // subsequent save for the file. The client normalizes runs against
            // the content at read time instead (see overlays/textRuns.ts).
            'overlays.*.payload.runs' => ['sometimes', 'nullable', 'array', 'max:200'],
            'overlays.*.payload.runs.*.length' => ['required', 'integer', 'min:1'],
            'overlays.*.payload.runs.*.fontFamily' => ['sometimes', 'nullable', 'string', 'max:255'],
            'overlays.*.payload.runs.*.fontWeight' => ['sometimes', 'nullable', Rule::in(['normal', 'bold'])],
            'overlays.*.payload.runs.*.fontStyle' => ['sometimes', 'nullable', Rule::in(['normal', 'italic'])],
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
./vendor/bin/pest tests/Unit/Requests/TextOverlayStylingValidationTest.php
```

Expected: PASS, including the two pre-existing tests in the file.

- [ ] **Step 5: Commit**

```bash
git add app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php tests/Unit/Requests/TextOverlayStylingValidationTest.php
git commit -m "feat(api): accept per-run font styling on text overlays"
```
