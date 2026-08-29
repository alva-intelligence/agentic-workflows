# KV Motion — Motion Templates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user save one layer's entire animation as a named, brand-scoped, server-persisted template and apply it to any other layer — in any KV, on any device, by anyone on the same brand.

**Architecture:** Keyframe values are absolute against the *source* layer's rest pose, so a raw copy teleports the target. A new engine module `templates.ts` stores **deltas against the rest pose** (`normalizeTrackToTemplate`) and re-bakes them against the target's rest pose (`bakeTemplateToTrack`). api stores the resulting document opaquely in a new `kv_motion_templates` table, brand-derived server-side from the studio file. The web surfaces it in the layer rail's existing ✨ menu: a **Saved** group at the top, plus "Save motion as template…".

**Tech Stack:** TypeScript, React 19, TanStack Query v5, `bun test` (web); Laravel 13, PHP 8.5, PostgreSQL, Pest (api).

**Spec:** `docs/superpowers/specs/2026-08-29-kv-motion-timeline-upgrades-design.md`

## Global Constraints

- Worktrees: `web/.worktrees/kv-motion-timeline-upgrades` and `api/.worktrees/kv-motion-timeline-upgrades`, both on `feature/daffa/vc-kv-motion-timeline-upgrades`. Each task states which repo it is in.
- **web:** tests run with `bun test`, never `bunx vitest`. No type gate (`ignoreBuildErrors` + large `tsc` baseline). `src/lib/video-editor/` must not import KV code.
- **api:** write **Unit** tests only. The Feature suite does not survive a fresh migrate (a `workspaces` backfill over `User::all()` plus SoftDeletes), so a Feature test here would fail for reasons unrelated to this work.
- **api:** `excludeUnvalidatedArrayKeys` is enabled. A `body.*` sub-rule would strip every unlisted key out of the JSON column. Validate the envelope in `withValidator()` reading `$this->input('body')` (raw), never with a `body.version` rule.
- **api:** run migrations with `TELESCOPE_ENABLED=false` — Telescope OOMs data migrations and the failure looks like a hung database.
- Brand scope is derived **server-side** from `$file->brand_id`. The client never sends a `brand_id`.
- Applying a template replaces the target layer's track wholesale, in exactly one `push()` — one undo step.

## File Structure

**web**

| File | Responsibility |
|---|---|
| `src/lib/video-editor/templates.ts` (create) | `MotionTemplateBody`, `normalizeTrackToTemplate`, `bakeTemplateToTrack` |
| `src/lib/video-editor/templates.test.ts` (create) | Round-trip and re-basing tests |
| `src/types/kv/motionTemplate.ts` (create) | The domain row shape |
| `src/services/kv/motionTemplates.ts` (create) | list / create / rename / delete |
| `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` (modify) | Saved group + save/rename/delete in the ✨ menu |

**api**

| File | Responsibility |
|---|---|
| `database/migrations/2026_08_29_100000_create_kv_motion_templates_table.php` (create) | The table |
| `app/Models/KvMotionTemplate.php` (create) | The model |
| `app/Http/Requests/Studio/StoreKvMotionTemplateRequest.php` (create) | Store validation |
| `app/Http/Requests/Studio/UpdateKvMotionTemplateRequest.php` (create) | Rename validation |
| `app/Http/Resources/Studio/KvMotionTemplateResource.php` (create) | Wire shape |
| `app/Http/Controllers/Api/Studio/KvMotionTemplateController.php` (create) | index / store / update / destroy |
| `routes/api.php` (modify) | Four routes beside the motion-project ones |
| `tests/Unit/Requests/KvMotionTemplateRequestsTest.php` (create) | Request rules |
| `tests/Unit/Resources/KvMotionTemplateResourceTest.php` (create) | Resource shape |

---

### Task 1 (web): The normalize/bake engine

**Files:**
- Create: `src/lib/video-editor/templates.ts`
- Create: `src/lib/video-editor/templates.test.ts`

**Interfaces:**
- Consumes: `MotionEasing`, `MotionProps`, `MotionTrack` types from `./timeline`.
- Produces:

```ts
export const MOTION_TEMPLATE_VERSION = 1;
export type MotionTemplateKeyframe = {
  t_ms: number;
  props: Partial<MotionProps>;
  easing: MotionEasing;
  label?: string;
};
export type MotionTemplateBody = {
  version: number;
  source_duration_ms: number;
  keyframes: MotionTemplateKeyframe[];
  absolute_props: (keyof MotionProps)[];
};
export function normalizeTrackToTemplate(
  track: MotionTrack, base: MotionProps, sourceDurationMs: number,
): MotionTemplateBody;
export function bakeTemplateToTrack(
  body: MotionTemplateBody, overlayId: string,
  targetBase: MotionProps, targetDurationMs: number,
): MotionTrack | null;
```

- [ ] **Step 1: Write the failing tests**

Create `src/lib/video-editor/templates.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import type { MotionProps, MotionTrack } from "./timeline";
import {
  bakeTemplateToTrack,
  normalizeTrackToTemplate,
  type MotionTemplateBody,
} from "./templates";

const REST: MotionProps = { x: 0.2, y: 0.3, scale: 1, rotation: 0, opacity: 1 };

/** A slide-in-left-shaped track authored around REST. */
const slideInTrack: MotionTrack = {
  kind: "overlay",
  overlay_id: "src",
  keyframes: [
    { t_ms: 0, props: { x: 0.05, opacity: 0 }, easing: "linear", label: "Slide in left" },
    { t_ms: 500, props: { x: 0.2, opacity: 1 }, easing: "out", label: "Slide in left" },
  ],
};

describe("normalize -> bake round trip", () => {
  it("reproduces the original track exactly when baked against the SAME rest pose", () => {
    const body = normalizeTrackToTemplate(slideInTrack, REST, 5000);
    const baked = bakeTemplateToTrack(body, "src", REST, 5000);
    expect(baked).toEqual(slideInTrack);
  });

  it("carries the preset label through", () => {
    const body = normalizeTrackToTemplate(slideInTrack, REST, 5000);
    const baked = bakeTemplateToTrack(body, "dst", REST, 5000)!;
    expect(baked.keyframes[0].label).toBe("Slide in left");
  });
});

describe("re-basing onto a different layer", () => {
  it("offsets x/y against the TARGET's rest pose", () => {
    const body = normalizeTrackToTemplate(slideInTrack, REST, 5000);
    const target: MotionProps = { ...REST, x: 0.7 };

    const baked = bakeTemplateToTrack(body, "dst", target, 5000)!;

    // The source started 0.15 to the LEFT of its rest x (0.05 vs 0.2), so the
    // target must start 0.15 to the left of ITS rest x: 0.55, not 0.05.
    expect(baked.keyframes[0].props.x).toBeCloseTo(0.55, 6);
    expect(baked.keyframes[1].props.x).toBeCloseTo(0.7, 6);
  });

  it("scales multiplicatively against the target's rest scale", () => {
    const popTrack: MotionTrack = {
      kind: "overlay",
      overlay_id: "src",
      keyframes: [
        { t_ms: 0, props: { scale: 0.6 }, easing: "linear" },
        { t_ms: 500, props: { scale: 1 }, easing: "out" },
      ],
    };
    const body = normalizeTrackToTemplate(popTrack, REST, 5000);

    const baked = bakeTemplateToTrack(body, "dst", { ...REST, scale: 2 }, 5000)!;

    expect(baked.keyframes[0].props.scale).toBeCloseTo(1.2, 6);
    expect(baked.keyframes[1].props.scale).toBeCloseTo(2, 6);
  });

  it("adds rotation as a delta, not an absolute", () => {
    const spin: MotionTrack = {
      kind: "overlay",
      overlay_id: "src",
      keyframes: [
        { t_ms: 0, props: { rotation: 0 }, easing: "linear" },
        { t_ms: 500, props: { rotation: 360 }, easing: "out" },
      ],
    };
    const body = normalizeTrackToTemplate(spin, REST, 5000);

    const baked = bakeTemplateToTrack(body, "dst", { ...REST, rotation: 45 }, 5000)!;

    expect(baked.keyframes[0].props.rotation).toBeCloseTo(45, 6);
    expect(baked.keyframes[1].props.rotation).toBeCloseTo(405, 6);
  });

  it("clamps a baked opacity into [0, 1]", () => {
    const body = normalizeTrackToTemplate(slideInTrack, { ...REST, opacity: 0.5 }, 5000);
    const baked = bakeTemplateToTrack(body, "dst", { ...REST, opacity: 1 }, 5000)!;
    for (const k of baked.keyframes) {
      if (k.props.opacity === undefined) continue;
      expect(k.props.opacity).toBeGreaterThanOrEqual(0);
      expect(k.props.opacity).toBeLessThanOrEqual(1);
    }
  });
});

describe("degenerate rest poses", () => {
  it("stores scale absolutely when the source rests at scale 0, and bakes it through", () => {
    const track: MotionTrack = {
      kind: "overlay",
      overlay_id: "src",
      keyframes: [
        { t_ms: 0, props: { scale: 0 }, easing: "linear" },
        { t_ms: 400, props: { scale: 1 }, easing: "out" },
      ],
    };

    const body = normalizeTrackToTemplate(track, { ...REST, scale: 0 }, 5000);
    expect(body.absolute_props).toContain("scale");

    const baked = bakeTemplateToTrack(body, "dst", { ...REST, scale: 3 }, 5000)!;
    expect(baked.keyframes[0].props.scale).toBe(0);
    expect(baked.keyframes[1].props.scale).toBe(1);
    for (const k of baked.keyframes) {
      expect(Number.isNaN(k.props.scale)).toBe(false);
    }
  });

  it("does the same for an opacity-0 rest pose", () => {
    const track: MotionTrack = {
      kind: "overlay",
      overlay_id: "src",
      keyframes: [{ t_ms: 0, props: { opacity: 0.5 }, easing: "linear" }],
    };
    const body = normalizeTrackToTemplate(track, { ...REST, opacity: 0 }, 5000);
    expect(body.absolute_props).toContain("opacity");
    const baked = bakeTemplateToTrack(body, "dst", REST, 5000)!;
    expect(baked.keyframes[0].props.opacity).toBe(0.5);
  });
});

describe("timing", () => {
  it("preserves absolute timing when the target is LONGER", () => {
    const body = normalizeTrackToTemplate(slideInTrack, REST, 5000);
    const baked = bakeTemplateToTrack(body, "dst", REST, 10000)!;
    expect(baked.keyframes.map((k) => k.t_ms)).toEqual([0, 500]);
  });

  it("scales the whole template to fit when the target is SHORTER than its span", () => {
    const body = normalizeTrackToTemplate(slideInTrack, REST, 5000);
    const baked = bakeTemplateToTrack(body, "dst", REST, 250)!;
    expect(baked.keyframes.map((k) => k.t_ms)).toEqual([0, 250]);
  });
});

describe("unreadable bodies", () => {
  it("returns null for an unknown version instead of throwing", () => {
    const future = {
      version: 99,
      source_duration_ms: 5000,
      keyframes: [],
      absolute_props: [],
    } as MotionTemplateBody;
    expect(bakeTemplateToTrack(future, "dst", REST, 5000)).toBeNull();
  });

  it("returns null when keyframes is not a list", () => {
    const broken = {
      version: 1,
      source_duration_ms: 5000,
      keyframes: null,
      absolute_props: [],
    } as unknown as MotionTemplateBody;
    expect(bakeTemplateToTrack(broken, "dst", REST, 5000)).toBeNull();
  });

  it("returns null rather than emitting a non-finite value", () => {
    const nan = {
      version: 1,
      source_duration_ms: 5000,
      keyframes: [
        { t_ms: 0, props: { x: Number.NaN }, easing: "linear" as const },
      ],
      absolute_props: [],
    } as MotionTemplateBody;
    expect(bakeTemplateToTrack(nan, "dst", REST, 5000)).toBeNull();
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bun test src/lib/video-editor/templates.test.ts`
Expected: FAIL — cannot resolve `./templates`

- [ ] **Step 3: Implement `templates.ts`**

```ts
import type { MotionEasing, MotionProps, MotionTrack } from "./timeline";

/** A motion template is ONE layer's whole animation — its In, every
 *  Emphasis, and its Out — saved as a named, reusable recipe.
 *
 *  THE PROBLEM THIS MODULE EXISTS TO SOLVE: keyframe values are ABSOLUTE
 *  against the SOURCE layer's rest pose. `fade-in` ends at `base.opacity`;
 *  `slide-in-left` starts at `base.x - 0.15`. Pasting those numbers onto a
 *  layer that rests somewhere else teleports it. So a template stores
 *  DELTAS against the rest pose, and applying it re-bakes those deltas
 *  against the TARGET layer's rest pose.
 *
 *  Encoding, per prop:
 *    x, y      additive offset      `v - base`
 *    rotation  additive delta       `v - base.rotation`
 *    scale     multiplicative ratio `v / base.scale`
 *    opacity   fraction of rest     `v / base.opacity`
 *
 *  A source layer resting at `scale: 0` or `opacity: 0` makes its ratio
 *  undefined. Those props are stored ABSOLUTELY instead and listed in
 *  `absolute_props`, so `bakeTemplateToTrack` passes them through rather
 *  than multiplying — silently emitting `NaN` keyframes is not an
 *  acceptable failure mode for a rare-but-real rest pose. */
export const MOTION_TEMPLATE_VERSION = 1;

export type MotionTemplateKeyframe = {
  t_ms: number;
  /** Same sparse shape as `MotionKeyframe.props`, but every value is
   *  RELATIVE to the rest pose — see the table above. */
  props: Partial<MotionProps>;
  easing: MotionEasing;
  label?: string;
};

export type MotionTemplateBody = {
  version: number;
  source_duration_ms: number;
  keyframes: MotionTemplateKeyframe[];
  /** Props stored absolutely rather than relatively, because the source
   *  layer's rest pose made a ratio undefined. Empty for every normal
   *  template. */
  absolute_props: (keyof MotionProps)[];
};

const OFFSET_PROPS = ["x", "y", "rotation"] as const;
const RATIO_PROPS = ["scale", "opacity"] as const;

function clamp01(n: number): number {
  return Math.min(1, Math.max(0, n));
}

/** Turn one layer's track into a rest-pose-relative template body. Pure. */
export function normalizeTrackToTemplate(
  track: MotionTrack,
  base: MotionProps,
  sourceDurationMs: number,
): MotionTemplateBody {
  const absolute: (keyof MotionProps)[] = RATIO_PROPS.filter(
    (p) => base[p] === 0,
  );

  const keyframes: MotionTemplateKeyframe[] = track.keyframes.map((k) => {
    const props: Partial<MotionProps> = {};
    for (const p of OFFSET_PROPS) {
      const v = k.props[p];
      if (v !== undefined) props[p] = v - base[p];
    }
    for (const p of RATIO_PROPS) {
      const v = k.props[p];
      if (v === undefined) continue;
      props[p] = absolute.includes(p) ? v : v / base[p];
    }
    return {
      t_ms: k.t_ms,
      props,
      easing: k.easing,
      ...(k.label !== undefined ? { label: k.label } : {}),
    };
  });

  return {
    version: MOTION_TEMPLATE_VERSION,
    source_duration_ms: sourceDurationMs,
    keyframes,
    absolute_props: absolute,
  };
}

/** Re-bake a template body onto `overlayId`, against ITS rest pose.
 *
 *  Timing: absolute times are preserved when the target timeline is long
 *  enough to hold them — a 700ms entrance stays a 700ms entrance on a longer
 *  clip. When the template's span overruns `targetDurationMs`, the WHOLE
 *  template is scaled proportionally to fit, so nothing is silently
 *  truncated past the end of the clip.
 *
 *  Returns `null` — never throws — for a body this build cannot read: an
 *  unknown `version`, a missing/!Array `keyframes`, or any value that comes
 *  out non-finite. One bad row must not be able to take the editor down, and
 *  a `NaN` written into the timeline would corrupt it silently. */
export function bakeTemplateToTrack(
  body: MotionTemplateBody,
  overlayId: string,
  targetBase: MotionProps,
  targetDurationMs: number,
): MotionTrack | null {
  if (body?.version !== MOTION_TEMPLATE_VERSION) return null;
  if (!Array.isArray(body.keyframes)) return null;

  const absolute = Array.isArray(body.absolute_props) ? body.absolute_props : [];
  const times = body.keyframes.map((k) => k.t_ms);
  const spanEnd = times.length > 0 ? Math.max(...times) : 0;
  const timeScale =
    spanEnd > targetDurationMs && spanEnd > 0 ? targetDurationMs / spanEnd : 1;

  const keyframes = [];
  for (const k of body.keyframes) {
    const props: Partial<MotionProps> = {};
    for (const p of OFFSET_PROPS) {
      const v = k.props?.[p];
      if (v !== undefined) props[p] = targetBase[p] + v;
    }
    for (const p of RATIO_PROPS) {
      const v = k.props?.[p];
      if (v === undefined) continue;
      const baked = absolute.includes(p) ? v : targetBase[p] * v;
      props[p] = p === "opacity" ? clamp01(baked) : baked;
    }
    const t_ms = Math.round(k.t_ms * timeScale);
    if (!Number.isFinite(t_ms)) return null;
    for (const v of Object.values(props)) {
      if (!Number.isFinite(v)) return null;
    }
    keyframes.push({
      t_ms,
      props,
      easing: k.easing,
      ...(k.label !== undefined ? { label: k.label } : {}),
    });
  }

  return { kind: "overlay", overlay_id: overlayId, keyframes };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bun test src/lib/video-editor/templates.test.ts`
Expected: PASS (13 tests)

- [ ] **Step 5: Run the engine suite, including the import-boundary guard**

Run: `bun test src/lib/video-editor/`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/lib/video-editor/templates.ts src/lib/video-editor/templates.test.ts
git commit -m "feat(web): motion template normalize/bake against the layer rest pose"
```

---

### Task 2 (api): Table and model

**Files:**
- Create: `database/migrations/2026_08_29_100000_create_kv_motion_templates_table.php`
- Create: `app/Models/KvMotionTemplate.php`

**Interfaces:**
- Consumes: `studio_files`, `brands`, `workspaces`, `users` tables; `App\Traits\HasWorkspaceScope`.
- Produces: `App\Models\KvMotionTemplate` with `$fillable = ['workspace_id','brand_id','created_by','name','body','source_duration_ms']` and `body` cast to `array`.

- [ ] **Step 1: Write the migration**

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('kv_motion_templates', function (Blueprint $t) {
            $t->ulid('id')->primary();
            // Workspace for HasWorkspaceScope; brand is the visibility scope —
            // a template saved on one brand's KV is offered on that brand's
            // other KVs, and nowhere else.
            $t->foreignUlid('workspace_id')->constrained('workspaces')->cascadeOnDelete();
            $t->foreignUlid('brand_id')->constrained('brands')->cascadeOnDelete();
            $t->foreignUlid('created_by')->constrained('users')->cascadeOnDelete();

            $t->string('name');
            // One layer's animation, stored rest-pose-RELATIVE (see web's
            // lib/video-editor/templates.ts). Opaque to the api; web owns the
            // schema, exactly as it owns kv_motion_projects.timeline.
            $t->json('body');
            // The duration the template was authored against — displayed
            // ("built for 5s"), never used to reject an apply.
            $t->unsignedInteger('source_duration_ms')->default(5000);

            $t->timestamps();
            $t->softDeletes();

            $t->index(['workspace_id', 'brand_id', 'deleted_at'], 'kv_motion_templates_scope_idx');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('kv_motion_templates');
    }
};
```

- [ ] **Step 2: Write the model**

```php
<?php

namespace App\Models;

use App\Traits\HasWorkspaceScope;
use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\SoftDeletes;

class KvMotionTemplate extends Model
{
    use HasFactory, HasUlids, HasWorkspaceScope, SoftDeletes;

    protected $table = 'kv_motion_templates';

    protected $fillable = [
        'workspace_id',
        'brand_id',
        'created_by',
        'name',
        'body',
        'source_duration_ms',
    ];

    protected $casts = [
        'body' => 'array',
        'source_duration_ms' => 'integer',
    ];

    public function brand(): BelongsTo
    {
        return $this->belongsTo(Brand::class);
    }

    public function creator(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }
}
```

- [ ] **Step 3: Run the migration**

Run: `TELESCOPE_ENABLED=false php artisan migrate`
Expected: `kv_motion_templates` created. (Telescope must be off — it OOMs migrations, and the failure looks like a hung database.)

- [ ] **Step 4: Confirm the table shape**

Run: `php artisan db:table kv_motion_templates`
Expected: the columns and the `kv_motion_templates_scope_idx` index listed

- [ ] **Step 5: Commit**

```bash
git add database/migrations/2026_08_29_100000_create_kv_motion_templates_table.php app/Models/KvMotionTemplate.php
git commit -m "feat(api): kv_motion_templates table and model"
```

---

### Task 3 (api): Requests, resource, controller, routes

**Files:**
- Create: `app/Http/Requests/Studio/StoreKvMotionTemplateRequest.php`
- Create: `app/Http/Requests/Studio/UpdateKvMotionTemplateRequest.php`
- Create: `app/Http/Resources/Studio/KvMotionTemplateResource.php`
- Create: `app/Http/Controllers/Api/Studio/KvMotionTemplateController.php`
- Modify: `routes/api.php`
- Create: `tests/Unit/Requests/KvMotionTemplateRequestsTest.php`
- Create: `tests/Unit/Resources/KvMotionTemplateResourceTest.php`

**Interfaces:**
- Consumes: `KvMotionTemplate` (Task 2), `App\Rules\MaxJsonBytes`, `App\Models\StudioFile`.
- Produces: `GET|POST v1/studio/files/{file}/motion-templates`, `PATCH|DELETE v1/studio/files/{file}/motion-templates/{template}`, returning `{ data: { id, brand_id, name, body, source_duration_ms, created_by, created_at, updated_at } }`.

- [ ] **Step 1: Write the failing tests**

Create `tests/Unit/Requests/KvMotionTemplateRequestsTest.php`:

```php
<?php

use App\Http\Requests\Studio\StoreKvMotionTemplateRequest;
use App\Http\Requests\Studio\UpdateKvMotionTemplateRequest;
use Illuminate\Support\Facades\Validator;
use Tests\TestCase;

uses(TestCase::class);

function validateTemplateWith(string $requestClass, array $payload): Illuminate\Validation\Validator
{
    $request = new $requestClass;

    return Validator::make($payload, $request->rules());
}

const VALID_BODY = [
    'version' => 1,
    'source_duration_ms' => 5000,
    'absolute_props' => [],
    'keyframes' => [
        ['t_ms' => 0, 'props' => ['opacity' => 0.0], 'easing' => 'linear'],
        ['t_ms' => 500, 'props' => ['opacity' => 1.0], 'easing' => 'out'],
    ],
];

it('accepts a minimal valid store payload', function () {
    $v = validateTemplateWith(StoreKvMotionTemplateRequest::class, [
        'name' => 'Hero pop',
        'body' => VALID_BODY,
        'source_duration_ms' => 5000,
    ]);
    expect($v->passes())->toBeTrue();
});

it('requires a name and a body', function () {
    $v = validateTemplateWith(StoreKvMotionTemplateRequest::class, []);
    expect($v->fails())->toBeTrue()
        ->and($v->errors()->has('name'))->toBeTrue()
        ->and($v->errors()->has('body'))->toBeTrue();
});

it('rejects a non-array body', function () {
    $v = validateTemplateWith(StoreKvMotionTemplateRequest::class, [
        'name' => 'Hero pop',
        'body' => 'not-json',
    ]);
    expect($v->fails())->toBeTrue();
});

// The regression this file exists for: a `body.*` sub-rule combined with
// excludeUnvalidatedArrayKeys strips every unlisted key out of the JSON
// column, which has silently emptied a payload here before. The rules must
// declare NO sub-rules under `body`, so `validated()` returns it intact.
it('passes the whole body document through validated() untouched', function () {
    $request = new StoreKvMotionTemplateRequest;
    $v = Validator::make(
        ['name' => 'Hero pop', 'body' => VALID_BODY],
        $request->rules(),
    );

    expect($v->passes())->toBeTrue()
        ->and($v->validated()['body'])->toBe(VALID_BODY);
});

it('accepts a rename-only update payload', function () {
    $v = validateTemplateWith(UpdateKvMotionTemplateRequest::class, [
        'name' => 'Hero pop v2',
    ]);
    expect($v->passes())->toBeTrue();
});

it('rejects an empty name on update', function () {
    $v = validateTemplateWith(UpdateKvMotionTemplateRequest::class, ['name' => '']);
    expect($v->fails())->toBeTrue();
});
```

Create `tests/Unit/Resources/KvMotionTemplateResourceTest.php`:

```php
<?php

use App\Http\Resources\Studio\KvMotionTemplateResource;
use App\Models\KvMotionTemplate;
use Illuminate\Http\Request;
use Tests\TestCase;

uses(TestCase::class);

it('exposes the template fields the web client reads', function () {
    $row = new KvMotionTemplate([
        'brand_id' => '01J0000000000000000000000B',
        'created_by' => '01J0000000000000000000000U',
        'name' => 'Hero pop',
        'body' => ['version' => 1, 'keyframes' => [], 'absolute_props' => []],
        'source_duration_ms' => 5000,
    ]);
    $row->id = '01J0000000000000000000000T';

    $out = (new KvMotionTemplateResource($row))->toArray(Request::create('/'));

    expect($out)->toHaveKeys([
        'id', 'brand_id', 'name', 'body', 'source_duration_ms',
        'created_by', 'created_at', 'updated_at',
    ])->and($out['name'])->toBe('Hero pop')
        ->and($out['body']['version'])->toBe(1);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `php artisan test tests/Unit/Requests/KvMotionTemplateRequestsTest.php tests/Unit/Resources/KvMotionTemplateResourceTest.php`
Expected: FAIL — the request and resource classes do not exist

> Pass test **paths**, not `--filter`: the api's suite loader is broken for filtered runs.

- [ ] **Step 3: Write the two requests**

`StoreKvMotionTemplateRequest.php`:

```php
<?php

namespace App\Http\Requests\Studio;

use App\Rules\MaxJsonBytes;
use Illuminate\Contracts\Validation\Validator;
use Illuminate\Foundation\Http\FormRequest;

class StoreKvMotionTemplateRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true; // workspace/brand check happens in the controller on the file
    }

    public function rules(): array
    {
        return [
            'name' => ['required', 'string', 'max:255'],
            // Opaque JSON document — web owns the schema (see
            // lib/video-editor/templates.ts). Deliberately NO `body.*`
            // sub-rules: `excludeUnvalidatedArrayKeys` is on in this app, so
            // declaring even one would strip every key not explicitly listed
            // straight out of the stored column. The envelope is checked in
            // withValidator() below, against the RAW input.
            'body' => ['required', 'array', new MaxJsonBytes],
            'source_duration_ms' => ['sometimes', 'integer', 'min:1', 'max:600000'],
        ];
    }

    public function withValidator(Validator $validator): void
    {
        $validator->after(function (Validator $v) {
            $body = $this->input('body');
            if (! is_array($body)) {
                return; // the 'array' rule already reported this
            }
            if (($body['version'] ?? null) !== 1) {
                $v->errors()->add('body', 'Unsupported template version.');
            }
            if (! is_array($body['keyframes'] ?? null)) {
                $v->errors()->add('body', 'The template body must carry a keyframes list.');
            }
        });
    }
}
```

`UpdateKvMotionTemplateRequest.php`:

```php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;

class UpdateKvMotionTemplateRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    /** Rename only — a template's body is immutable once saved. Re-saving a
     *  changed animation creates a NEW template, so an existing one can never
     *  change out from under a KV that was built expecting it. */
    public function rules(): array
    {
        return [
            'name' => ['required', 'string', 'max:255'],
        ];
    }
}
```

- [ ] **Step 4: Write the resource**

```php
<?php

namespace App\Http\Resources\Studio;

use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

class KvMotionTemplateResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'id' => $this->id,
            'brand_id' => $this->brand_id,
            'name' => $this->name,
            'body' => $this->body,
            'source_duration_ms' => $this->source_duration_ms,
            'created_by' => $this->created_by,
            'created_at' => $this->created_at,
            'updated_at' => $this->updated_at,
        ];
    }
}
```

- [ ] **Step 5: Write the controller**

```php
<?php

namespace App\Http\Controllers\Api\Studio;

use App\Http\Controllers\Controller;
use App\Http\Requests\Studio\StoreKvMotionTemplateRequest;
use App\Http\Requests\Studio\UpdateKvMotionTemplateRequest;
use App\Http\Resources\Studio\KvMotionTemplateResource;
use App\Models\KvMotionTemplate;
use App\Models\StudioFile;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Brand-scoped motion templates: one layer's whole animation, saved as a
 * named recipe and offered on every KV of the same brand.
 *
 * The brand is ALWAYS derived server-side from the studio file in the route
 * — the client never sends a `brand_id`, so there is no client-supplied
 * scope whose ownership would have to be validated.
 */
class KvMotionTemplateController extends Controller
{
    public function index(Request $request, string $fileId): JsonResponse
    {
        $file = $this->fileFor($request, $fileId);

        $rows = KvMotionTemplate::where('brand_id', $file->brand_id)
            ->orderByDesc('created_at')
            ->get();

        return response()->json([
            'data' => KvMotionTemplateResource::collection($rows)->resolve(),
        ]);
    }

    public function store(StoreKvMotionTemplateRequest $request, string $fileId): JsonResponse
    {
        $file = $this->fileFor($request, $fileId);
        $v = $request->validated();

        $row = KvMotionTemplate::create([
            // workspace_id is stamped by HasWorkspaceScope on save.
            'brand_id' => $file->brand_id,
            'created_by' => $request->user()->id,
            'name' => $v['name'],
            'body' => $v['body'],
            'source_duration_ms' => $v['source_duration_ms'] ?? 5000,
        ]);

        return response()->json(
            ['data' => (new KvMotionTemplateResource($row))->resolve()],
            Response::HTTP_CREATED
        );
    }

    public function update(UpdateKvMotionTemplateRequest $request, string $fileId, string $templateId): JsonResponse
    {
        $row = $this->templateFor($request, $fileId, $templateId);
        $row->update(['name' => $request->validated()['name']]);

        return response()->json(['data' => (new KvMotionTemplateResource($row->fresh()))->resolve()]);
    }

    public function destroy(Request $request, string $fileId, string $templateId): JsonResponse
    {
        $this->templateFor($request, $fileId, $templateId)->delete();

        return response()->json(['ok' => true]);
    }

    private function fileFor(Request $request, string $fileId): StudioFile
    {
        $file = StudioFile::findOrFail($fileId);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        return $file;
    }

    private function templateFor(Request $request, string $fileId, string $templateId): KvMotionTemplate
    {
        $file = $this->fileFor($request, $fileId);

        return KvMotionTemplate::where('brand_id', $file->brand_id)
            ->where('id', $templateId)
            ->firstOrFail();
    }
}
```

- [ ] **Step 6: Add the routes**

In `routes/api.php`, add the import next to the other Studio controllers:

```php
use App\Http\Controllers\Api\Studio\KvMotionTemplateController;
```

and, directly after the motion-project route block (inside the same `feature.flag:show-kv-generator` group):

```php
                            // KV Motion templates (one layer's animation,
                            // saved brand-scoped and reusable across KVs)
                            Route::get('files/{file}/motion-templates', [KvMotionTemplateController::class, 'index']);
                            Route::post('files/{file}/motion-templates', [KvMotionTemplateController::class, 'store']);
                            Route::patch('files/{file}/motion-templates/{template}', [KvMotionTemplateController::class, 'update']);
                            Route::delete('files/{file}/motion-templates/{template}', [KvMotionTemplateController::class, 'destroy']);
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `php artisan test tests/Unit/Requests/KvMotionTemplateRequestsTest.php tests/Unit/Resources/KvMotionTemplateResourceTest.php`
Expected: PASS (8 tests)

- [ ] **Step 8: Confirm the routes registered**

Run: `php artisan route:list --path=motion-templates`
Expected: four routes listed under the `v1/studio` prefix

- [ ] **Step 9: Commit**

```bash
git add app/Http/Requests/Studio/StoreKvMotionTemplateRequest.php app/Http/Requests/Studio/UpdateKvMotionTemplateRequest.php app/Http/Resources/Studio/KvMotionTemplateResource.php app/Http/Controllers/Api/Studio/KvMotionTemplateController.php routes/api.php tests/Unit/Requests/KvMotionTemplateRequestsTest.php tests/Unit/Resources/KvMotionTemplateResourceTest.php
git commit -m "feat(api): brand-scoped KV motion template endpoints"
```

---

### Task 4 (web): Types and service

**Files:**
- Create: `src/types/kv/motionTemplate.ts`
- Create: `src/services/kv/motionTemplates.ts`

**Interfaces:**
- Consumes: `MotionTemplateBody` (Task 1); `axiosInstance` from `@/services/axios`; the endpoints from Task 3.
- Produces:

```ts
export type KvMotionTemplate = {
  id: string; brandId: string; name: string;
  body: MotionTemplateBody; sourceDurationMs: number;
  createdBy: string; createdAt: string; updatedAt: string;
};
export const motionTemplatesKey: (fileId: string) => readonly [string, string];
export function listMotionTemplates(fileId: string): Promise<KvMotionTemplate[]>;
export function createMotionTemplate(fileId: string, body: { name: string; body: MotionTemplateBody; sourceDurationMs: number }): Promise<KvMotionTemplate>;
export function renameMotionTemplate(fileId: string, templateId: string, name: string): Promise<KvMotionTemplate>;
export function deleteMotionTemplate(fileId: string, templateId: string): Promise<void>;
```

- [ ] **Step 1: Write the type module**

`src/types/kv/motionTemplate.ts`:

```ts
// ──────────────────────────────────────────────
// KV Motion — motion template domain types
// Mirrors api's kv_motion_templates rows.
// ──────────────────────────────────────────────

import type { MotionTemplateBody } from "@/lib/video-editor/templates";

/** One saved layer animation, visible to everyone on the same brand. The
 *  `body` is rest-pose-RELATIVE — it must be baked against the target
 *  layer's own rest pose before it becomes a track (see
 *  `bakeTemplateToTrack`). */
export type KvMotionTemplate = {
  id: string;
  brandId: string;
  name: string;
  body: MotionTemplateBody;
  /** The timeline duration this template was authored against — shown in the
   *  menu, never used to reject an apply. */
  sourceDurationMs: number;
  createdBy: string;
  createdAt: string;
  updatedAt: string;
};
```

- [ ] **Step 2: Write the service**

`src/services/kv/motionTemplates.ts`:

```ts
// ──────────────────────────────────────────────
// KV Motion — motion template API service functions
// All calls go through the shared axios instance
// which handles auth tokens automatically.
// ──────────────────────────────────────────────

import axiosInstance from "@/services/axios";
import type { MotionTemplateBody } from "@/lib/video-editor/templates";
import type { KvMotionTemplate } from "@/types/kv/motionTemplate";

/** Unwrap Laravel's `{ message, data }` response envelope. */
function unwrap<T>(response: { message?: string; data: T }): T {
  return response.data;
}

type WireMotionTemplate = {
  id: string;
  brand_id: string;
  name: string;
  body: MotionTemplateBody;
  source_duration_ms: number;
  created_by: string;
  created_at: string;
  updated_at: string;
};

function toMotionTemplate(w: WireMotionTemplate): KvMotionTemplate {
  return {
    id: w.id,
    brandId: w.brand_id,
    name: w.name,
    body: w.body,
    sourceDurationMs: w.source_duration_ms,
    createdBy: w.created_by,
    createdAt: w.created_at,
    updatedAt: w.updated_at,
  };
}

/** The route is file-addressed, but the LIST it returns is brand-scoped: the
 *  api derives the brand from the file. Two different files on the same brand
 *  return the same templates. */
const TEMPLATES_BASE = (fileId: string) =>
  `v1/studio/files/${fileId}/motion-templates`;

/** Query key for a file's template list. Exported from the service rather
 *  than a component, for the same reason `motionProjectsKey` is: every writer
 *  invalidates it, and a re-typed literal is how two of them end up agreeing
 *  only by coincidence. */
export const motionTemplatesKey = (fileId: string) =>
  ["kv-motion-templates", fileId] as const;

export async function listMotionTemplates(
  fileId: string,
): Promise<KvMotionTemplate[]> {
  const { data } = await axiosInstance.get(TEMPLATES_BASE(fileId));
  const rows: WireMotionTemplate[] = unwrap(data);
  return rows.map(toMotionTemplate);
}

export async function createMotionTemplate(
  fileId: string,
  body: { name: string; body: MotionTemplateBody; sourceDurationMs: number },
): Promise<KvMotionTemplate> {
  const { data } = await axiosInstance.post(TEMPLATES_BASE(fileId), {
    name: body.name,
    body: body.body,
    source_duration_ms: body.sourceDurationMs,
  });
  return toMotionTemplate(unwrap<WireMotionTemplate>(data));
}

export async function renameMotionTemplate(
  fileId: string,
  templateId: string,
  name: string,
): Promise<KvMotionTemplate> {
  const { data } = await axiosInstance.patch(
    `${TEMPLATES_BASE(fileId)}/${templateId}`,
    { name },
  );
  return toMotionTemplate(unwrap<WireMotionTemplate>(data));
}

export async function deleteMotionTemplate(
  fileId: string,
  templateId: string,
): Promise<void> {
  await axiosInstance.delete(`${TEMPLATES_BASE(fileId)}/${templateId}`);
}
```

- [ ] **Step 3: Verify it compiles into the app**

Run: `bun run build`
Expected: build succeeds

- [ ] **Step 4: Commit**

```bash
git add src/types/kv/motionTemplate.ts src/services/kv/motionTemplates.ts
git commit -m "feat(web): motion template types and API service"
```

---

### Task 5 (web): Saved group and save/rename/delete in the ✨ menu

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionEditor.tsx`

**Interfaces:**
- Consumes: everything from Tasks 1 and 4; `useMotionEditorState`'s `timeline`, `base`, and `push`; `useToastStore` from `@/store/useToast`; `BaseModal` from `@/components/frndos/BaseModal`.
- Produces: an `applyTemplateTo(trackId, template)` handler and the menu UI. No new engine exports.

- [ ] **Step 1: Add the apply command to `useMotionEditorState`**

In `src/components/studio/kv-generator/motion/useMotionEditorState.ts`, import `bakeTemplateToTrack` and `type MotionTemplateBody` from `@/lib/video-editor/templates`, then add next to `applyEmphasis`:

```ts
  // Applying a template REPLACES the layer's whole track — a template is a
  // whole-layer recipe, not an additive one. One push() = one undo step.
  // Returns false when the body can't be baked (unknown version, or a value
  // that comes out non-finite), so the caller can toast instead of writing a
  // corrupt timeline.
  const applyTemplate = useCallback(
    (trackId: string, body: MotionTemplateBody): boolean => {
      const restPose = base.get(trackId);
      if (!restPose) return false;
      const track = bakeTemplateToTrack(
        body,
        trackId,
        restPose,
        timeline.duration_ms,
      );
      if (!track) return false;
      const others = timeline.tracks.filter(
        (t) => !(t.kind === "overlay" && t.overlay_id === trackId),
      );
      push({ ...timeline, tracks: [...others, track] });
      return true;
    },
    [base, timeline, push],
  );
```

Add `applyTemplate,` to the object the hook returns.

- [ ] **Step 2: Load the templates in `MotionEditorCanvas`**

Add the imports:

```ts
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import BaseModal from "@/components/frndos/BaseModal";
import { useToastStore } from "@/store/useToast";
import { normalizeTrackToTemplate } from "@/lib/video-editor/templates";
import {
  createMotionTemplate,
  deleteMotionTemplate,
  listMotionTemplates,
  motionTemplatesKey,
  renameMotionTemplate,
} from "@/services/kv/motionTemplates";
import type { KvMotionTemplate } from "@/types/kv/motionTemplate";
```

(`useQuery` is already imported in this file — extend the existing import rather than duplicating it.)

Inside `MotionEditorCanvas`:

```ts
  const queryClient = useQueryClient();
  const showToast = useToastStore((s) => s.showToast);

  const templatesQuery = useQuery({
    queryKey: motionTemplatesKey(fileId),
    queryFn: () => listMotionTemplates(fileId),
    enabled: Boolean(fileId),
  });
  const templates = templatesQuery.data ?? [];

  const invalidateTemplates = () =>
    queryClient.invalidateQueries({ queryKey: motionTemplatesKey(fileId) });

  // No optimistic insert: a failure leaves the list exactly as it was, so
  // there is nothing to roll back and no window where the menu shows a
  // template the server never accepted.
  const saveTemplate = useMutation({
    mutationFn: (v: { trackId: string; name: string }) => {
      const track = state.timeline.tracks.find(
        (t) => t.kind === "overlay" && t.overlay_id === v.trackId,
      );
      const restPose = state.base.get(v.trackId);
      if (!track || !restPose) {
        return Promise.reject(new Error("That layer has no animation to save."));
      }
      return createMotionTemplate(fileId, {
        name: v.name,
        body: normalizeTrackToTemplate(track, restPose, state.timeline.duration_ms),
        sourceDurationMs: state.timeline.duration_ms,
      });
    },
    onSuccess: () => {
      invalidateTemplates();
      showToast("Motion saved", "It's now in Saved for this brand.", "success");
    },
    onError: () =>
      showToast("Couldn't save that motion", "Try again in a moment.", "error"),
  });

  const renameTemplate = useMutation({
    mutationFn: (v: { id: string; name: string }) =>
      renameMotionTemplate(fileId, v.id, v.name),
    onSuccess: invalidateTemplates,
    onError: () =>
      showToast("Couldn't rename that motion", "Try again in a moment.", "error"),
  });

  const removeTemplate = useMutation({
    mutationFn: (id: string) => deleteMotionTemplate(fileId, id),
    onSuccess: invalidateTemplates,
    onError: () =>
      showToast("Couldn't delete that motion", "Try again in a moment.", "error"),
  });

  function applyTemplateTo(trackId: string, template: KvMotionTemplate) {
    if (!state.applyTemplate(trackId, template.body)) {
      showToast(
        "That saved motion couldn't be applied",
        "It was saved by a newer version of the editor.",
        "error",
      );
    }
  }
```

`state.base` and `state.timeline` are already on the hook's returned object — no change needed there beyond adding `applyTemplate` in Step 1.

- [ ] **Step 3: Add the name dialog**

Add state and a single dialog reused by both save and rename — one dialog, because "give this motion a name" is one job whether the row exists yet or not:

```ts
  const [nameDialog, setNameDialog] = useState<
    | { mode: "save"; trackId: string; value: string }
    | { mode: "rename"; templateId: string; value: string }
    | null
  >(null);
```

Render it beside the editor's other modals:

```tsx
      <BaseModal
        isOpen={nameDialog !== null}
        onClose={() => setNameDialog(null)}
        title={nameDialog?.mode === "rename" ? "Rename motion" : "Save motion as template"}
        description={
          nameDialog?.mode === "rename"
            ? undefined
            : "Everyone on this brand will be able to apply it to any layer."
        }
        footer={
          <div className="flex justify-end gap-2 border-t border-white/10 px-6 py-4">
            <Button variant="secondary" size="medium" onClick={() => setNameDialog(null)}>
              Cancel
            </Button>
            <Button
              variant="primary"
              size="medium"
              disabled={!nameDialog?.value.trim()}
              onClick={() => {
                if (!nameDialog) return;
                const name = nameDialog.value.trim();
                if (!name) return;
                if (nameDialog.mode === "save") {
                  saveTemplate.mutate({ trackId: nameDialog.trackId, name });
                } else {
                  renameTemplate.mutate({ id: nameDialog.templateId, name });
                }
                setNameDialog(null);
              }}
            >
              Save
            </Button>
          </div>
        }
      >
        <div className="px-6 py-4">
          <Input
            autoFocus
            value={nameDialog?.value ?? ""}
            placeholder="e.g. Hero pop"
            onChange={(e) =>
              setNameDialog((d) => (d ? { ...d, value: e.target.value } : d))
            }
          />
        </div>
      </BaseModal>
```

Import `Input` from `@/components/frndos/Input` if it is not already imported. If `BaseModal` in this codebase takes its content only through props rather than children, follow `KvMotionProjectsPanel`'s usage exactly — that file is the reference for this component's real API.

- [ ] **Step 4: Extend `TrackPresetMenu`**

Add props:

```ts
  templates: KvMotionTemplate[];
  hasKeyframes: boolean;
  onApplyTemplate: (template: KvMotionTemplate) => void;
  onSaveTemplate: () => void;
  onRenameTemplate: (template: KvMotionTemplate) => void;
  onDeleteTemplate: (template: KvMotionTemplate) => void;
```

Render a **Saved** group at the TOP of the popover content — above Entrance, because "reuse one of ours" should be reachable before "start from a stock preset" — followed by the existing entrance list and Emphasis group:

```tsx
          {templates.length > 0 && (
            <>
              <div className="px-2 py-1 text-textXsMedium text-text-inverse-subtlest">
                Saved
              </div>
              {templates.map((tpl) => (
                <div key={tpl.id} className="group/tpl flex items-center gap-1">
                  <button
                    type="button"
                    role="menuitem"
                    onClick={() => {
                      onApplyTemplate(tpl);
                      setOpen(false);
                    }}
                    className="flex min-w-0 flex-1 items-center gap-2 rounded-lg p-2 text-left text-textSm text-text-inverse outline-none transition-all duration-200 ease-out hover:bg-white/5 focus-visible:ring-2 focus-visible:ring-white/40"
                  >
                    <span className="truncate">{tpl.name}</span>
                  </button>
                  {/* Manage controls stay hidden until the row is hovered or
                   *  focused: a list of saved motions should read as a list of
                   *  things to APPLY, not a list of things to administer. */}
                  <button
                    type="button"
                    aria-label={`Rename ${tpl.name}`}
                    onClick={() => {
                      onRenameTemplate(tpl);
                      setOpen(false);
                    }}
                    className="flex size-6 shrink-0 items-center justify-center rounded text-text-inverse-subtlest opacity-0 outline-none transition-opacity hover:text-text-inverse focus-visible:opacity-100 focus-visible:ring-2 focus-visible:ring-white/40 group-hover/tpl:opacity-100"
                  >
                    <PencilSimple size={13} />
                  </button>
                  <button
                    type="button"
                    aria-label={`Delete ${tpl.name}`}
                    onClick={() => {
                      onDeleteTemplate(tpl);
                      setOpen(false);
                    }}
                    className="flex size-6 shrink-0 items-center justify-center rounded text-text-inverse-subtlest opacity-0 outline-none transition-opacity hover:text-red-400 focus-visible:opacity-100 focus-visible:ring-2 focus-visible:ring-white/40 group-hover/tpl:opacity-100"
                  >
                    <Trash size={13} />
                  </button>
                </div>
              ))}
              <div className="my-1 border-t border-border-default" />
            </>
          )}
```

and, at the BOTTOM of the same content, after the Emphasis group:

```tsx
          <div className="my-1 border-t border-border-default" />
          <button
            type="button"
            role="menuitem"
            disabled={!hasKeyframes}
            title={hasKeyframes ? undefined : "This layer has no animation yet"}
            onClick={() => {
              onSaveTemplate();
              setOpen(false);
            }}
            className={cn(
              "flex w-full items-center gap-2 rounded-lg p-2 text-left text-textSm text-text-inverse outline-none transition-all duration-200 ease-out hover:bg-white/5 focus-visible:ring-2 focus-visible:ring-white/40",
              !hasKeyframes && "cursor-not-allowed opacity-50 hover:bg-transparent",
            )}
          >
            Save motion as template…
          </button>
```

Import `PencilSimple` and `Trash` from `@phosphor-icons/react`.

- [ ] **Step 5: Pass the new props at the call site**

At the `<TrackPresetMenu ... />` in the layers rail:

```tsx
                    templates={templates}
                    hasKeyframes={state.timeline.tracks.some(
                      (tr) => tr.kind === "overlay" && tr.overlay_id === t.id && tr.keyframes.length > 0,
                    )}
                    onApplyTemplate={(tpl) => applyTemplateTo(t.id, tpl)}
                    onSaveTemplate={() =>
                      setNameDialog({ mode: "save", trackId: t.id, value: "" })
                    }
                    onRenameTemplate={(tpl) =>
                      setNameDialog({ mode: "rename", templateId: tpl.id, value: tpl.name })
                    }
                    onDeleteTemplate={(tpl) => removeTemplate.mutate(tpl.id)}
```

- [ ] **Step 6: Run the web tests**

Run: `bun test src/components/studio/kv-generator/motion/ src/lib/video-editor/`
Expected: PASS

- [ ] **Step 7: Build**

Run: `bun run build`
Expected: build succeeds

- [ ] **Step 8: Commit**

```bash
git add src/components/studio/kv-generator/motion/KvMotionEditor.tsx src/components/studio/kv-generator/motion/useMotionEditorState.ts
git commit -m "feat(web): save and apply brand-scoped motion templates from the layer menu"
```

---

## Manual verification

Both services running (`./run-all.sh`), api migrated.

1. Open a KV motion project. Animate a layer with an entrance **and** an emphasis.
2. ✨ on that layer → **Save motion as template…** → name it → toast confirms.
3. ✨ on a **different** layer, one resting somewhere else on the canvas → the template appears under **Saved** → apply it.
4. The second layer animates the same way **from its own position** — it does not jump to where the first layer sits. This is the whole point of the feature; if it teleports, the normalize/bake path is wrong.
5. One `Cmd+Z` undoes the apply completely.
6. Open a *different* KV on the **same brand** → the template is in its Saved list too.
7. Open a KV on a **different brand** → it is not.
8. Rename it; the new name shows everywhere. Delete it; it disappears and applying is no longer offered.
9. A layer with no keyframes shows "Save motion as template…" greyed out.

## Before calling this done

Invoke the `frndos-analytics-events` agent over the changed web files.
