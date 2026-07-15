# Text Overlay Typography Revamp — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the new text-overlay `gradient` fill through the overlay save paths (it is stripped today because `$request->validated()` drops unlisted payload keys).

**Architecture:** Whitelist `payload.gradient` (and its `from`/`to`/`angle`) on the two overlay validation requests, mirroring the existing `fontFamily`/`fontSize` rules. Overlays are a JSON column — no migration.

**Tech Stack:** Laravel 13, PHP 8.5, Pest/PHPUnit.

## Global Constraints

- `gradient` is nullable. When present, `from`/`to` are `#RRGGBB`, `angle` numeric `0..360`. Absent ⇒ solid `color` (unchanged).
- Worktree = api repo root: `/Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/kv-canvas-custom-fonts`. Paths starting `api/` map here (strip `api/`). `vendor/` is a real copy; `.env` has `API_INTERNAL_TOKEN`.
- DB SAFETY: run ONLY the named Unit test file. NEVER `php artisan migrate` / migrate:fresh / the Feature suite (the worktree `.env` points at the shared dev DB). These validation tests touch NO database.
- Test base class: use `Tests\TestCase` (facades need the app booted); no `RefreshDatabase`.
- Run `vendor/bin/pint <files> --format agent` after editing PHP.

---

### Task 1: Whitelist `gradient` on both overlay requests

**Files:**
- Modify: `app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php` (after the `fontFamily`/`fontSize` rules)
- Modify: `app/Http/Requests/Studio/StoreBrandOverlayPresetRequest.php` (after the `fontFamily`/`fontSize` rules)
- Test: `tests/Unit/Requests/OverlayGradientValidationTest.php`

**Interfaces:**
- Produces: both requests accept `overlays.*.payload.gradient` (nullable array) with `from`/`to` (`#RRGGBB`) and `angle` (numeric 0–360), so `validated()` preserves the gradient.

- [ ] **Step 1: Write the failing test**

```php
<?php

namespace Tests\Unit\Requests;

use App\Http\Requests\Studio\UpdateStudioFileOverlaysRequest;
use Illuminate\Support\Facades\Validator;
use Tests\TestCase;

class OverlayGradientValidationTest extends TestCase
{
    private function base(array $payload): array
    {
        return [
            'overlays' => [[
                'type' => 'text',
                'x' => 0.1, 'y' => 0.1, 'width' => 0.4, 'height' => 0.08,
                'rotation' => 0,
                'payload' => array_merge([
                    'type' => 'text', 'content' => 'hi', 'color' => '#ffffff',
                ], $payload),
            ]],
        ];
    }

    private function validate(array $data): \Illuminate\Contracts\Validation\Validator
    {
        return Validator::make($data, (new UpdateStudioFileOverlaysRequest())->rules());
    }

    public function test_accepts_a_valid_gradient(): void
    {
        $v = $this->validate($this->base([
            'gradient' => ['from' => '#ff0000', 'to' => '#0000ff', 'angle' => 90],
        ]));
        $this->assertFalse($v->fails());
        $this->assertArrayHasKey(
            'gradient',
            $v->validated()['overlays'][0]['payload'] ?? []
        );
    }

    public function test_rejects_bad_hex_and_out_of_range_angle(): void
    {
        $this->assertTrue($this->validate($this->base([
            'gradient' => ['from' => 'red', 'to' => '#0000ff', 'angle' => 90],
        ]))->fails());
        $this->assertTrue($this->validate($this->base([
            'gradient' => ['from' => '#ff0000', 'to' => '#0000ff', 'angle' => 400],
        ]))->fails());
    }

    public function test_omitting_gradient_is_valid(): void
    {
        $this->assertFalse($this->validate($this->base([]))->fails());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && ./vendor/bin/phpunit tests/Unit/Requests/OverlayGradientValidationTest.php`
Expected: FAIL — `test_accepts_a_valid_gradient` fails its `validated()` assertion (gradient stripped), because the rules don't include it yet.

- [ ] **Step 3: Add the rules**

In BOTH `UpdateStudioFileOverlaysRequest::rules()` and `StoreBrandOverlayPresetRequest::rules()`, after the existing `overlays.*.payload.fontSize` rule, add:

```php
'overlays.*.payload.gradient' => ['nullable', 'array'],
'overlays.*.payload.gradient.from' => ['required_with:overlays.*.payload.gradient', 'regex:/^#[0-9A-Fa-f]{6}$/'],
'overlays.*.payload.gradient.to' => ['required_with:overlays.*.payload.gradient', 'regex:/^#[0-9A-Fa-f]{6}$/'],
'overlays.*.payload.gradient.angle' => ['required_with:overlays.*.payload.gradient', 'numeric', 'between:0,360'],
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd api && ./vendor/bin/phpunit tests/Unit/Requests/OverlayGradientValidationTest.php`
Expected: PASS (all three).

- [ ] **Step 5: Pint + commit**

```bash
cd api && ./vendor/bin/pint app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php app/Http/Requests/Studio/StoreBrandOverlayPresetRequest.php --format agent
git add app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php app/Http/Requests/Studio/StoreBrandOverlayPresetRequest.php tests/Unit/Requests/OverlayGradientValidationTest.php
git commit -m "fix(api): persist text overlay gradient fill (whitelist on overlay requests)"
```

---

## Self-Review

- **Spec coverage:** persistence of `gradient` on both the file-overlays PATCH and brand-preset store ✓. Shape (`from`/`to` `#RRGGBB`, `angle` 0–360) matches the web `payload.gradient` type exactly.
- **Placeholders:** none — complete rules + test.
- **DB safety:** the test uses `Validator::make(...)->rules()` only — no DB, no migrate.
