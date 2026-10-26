# KV Motion Bumpers — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A brand-scoped bumper library — upload a logo-lockup image or short video once, list it, delete it — that the Motion editor fills its start/end slots from.

**Architecture:** One new table `kv_motion_bumpers` mirroring `kv_motion_templates` (workspace + brand scope, soft deletes), one controller with `index` / `store` / `destroy` hanging off `files/{file}/motion-bumpers`, a multipart store request that derives `kind` from the upload's mime and clamps the client-reported `duration_ms` / `width` / `height`. No change to `kv_motion_projects` — the per-project slots live inside the opaque `timeline` JSON, which the api never validates.

**Tech Stack:** Laravel 13 / PHP 8.5, Pest, PostgreSQL, S3 disk.

**Spec:** `docs/superpowers/specs/2026-09-20-kv-motion-bumpers-design.md` (§3.1, §3.9, §3.10)

## Global Constraints

- Upload rule is exactly `required|file|mimes:png,jpg,jpeg,webp,mp4,webm|max:51200` (50 MB, same ceiling as overlay assets).
- `kind` is derived server-side from the upload's mime — never read from the request body.
- `duration_ms` is clamped to `[0, 60000]`; `width` / `height` to `[0, 8192]`; an image is stored with `duration_ms = 0`.
- Storage key: `brands/{brand_id}/motion-bumpers/{ulid}.{ext}` on the `s3` disk.
- Soft delete only. No S3 object deletion.
- `excludeUnvalidatedArrayKeys` is on in this app: no nested `x.*` rules anywhere (see `StoreKvMotionTemplateRequest` for the regression this guards).
- Tests run with `php artisan test <path>`, **passing file paths** (a `--filter` run still boots the broken Feature suite loader — see memory `lesson_api_feature_tests_need_scratch_postgres`). Unit tests here never touch the database.
- Work happens on branch `feature/daffa/vc-kv-motion-bumpers` cut from `develop`, inside the `api/` repo.
- Commit format: `<type>(api): <description>`; end every commit message with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

## File Structure

| File | Responsibility |
|---|---|
| `database/migrations/2026_09_20_100000_create_kv_motion_bumpers_table.php` | Create the table + scope index |
| `app/Models/KvMotionBumper.php` | Eloquent model, casts, relations |
| `app/Http/Requests/Studio/StoreKvMotionBumperRequest.php` | Multipart validation + `kindFromUpload()` + clamp helpers |
| `app/Http/Resources/Studio/KvMotionBumperResource.php` | Wire shape the web client reads |
| `app/Http/Controllers/Api/Studio/KvMotionBumperController.php` | `index` / `store` / `destroy`, file→brand resolution, S3 put |
| `routes/api.php` | Three routes next to the motion-template routes |
| `tests/Unit/Requests/KvMotionBumperRequestsTest.php` | Rules, clamps, `kind` derivation |
| `tests/Unit/Resources/KvMotionBumperResourceTest.php` | Resource keys |
| `tests/Unit/Http/Controllers/Api/Studio/KvMotionBumperControllerTest.php` | Brand-less guard + wiring contract |
| `tests/Feature/Studio/KvMotionBumperControllerTest.php` | Full HTTP round-trip — written, runs only against a scratch Postgres |

---

### Task 1: Migration + model

**Files:**
- Create: `database/migrations/2026_09_20_100000_create_kv_motion_bumpers_table.php`
- Create: `app/Models/KvMotionBumper.php`
- Reference: `database/migrations/2026_08_29_100000_create_kv_motion_templates_table.php`, `app/Models/KvMotionTemplate.php`

**Interfaces:**
- Produces: `App\Models\KvMotionBumper` with fillable `workspace_id, brand_id, created_by, name, kind, url, duration_ms, width, height`; casts `duration_ms|width|height => integer`; relations `brand()`, `creator()`.

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
        Schema::create('kv_motion_bumpers', function (Blueprint $t) {
            $t->ulid('id')->primary();
            // Workspace for HasWorkspaceScope; brand is the visibility scope —
            // a bumper uploaded on one brand's KV is offered on that brand's
            // other KVs, and nowhere else. Same shape as kv_motion_templates.
            $t->foreignUlid('workspace_id')->constrained('workspaces')->cascadeOnDelete();
            $t->foreignUlid('brand_id')->constrained('brands')->cascadeOnDelete();
            $t->foreignUlid('created_by')->constrained('users')->cascadeOnDelete();

            $t->string('name');
            // 'image' | 'video' — derived from the upload's mime by the
            // store request, never client-supplied.
            $t->string('kind', 16);
            // Public S3 url. Brand-keyed (brands/{brand}/motion-bumpers/…),
            // not file-keyed: the asset outlives any one KV.
            $t->string('url', 2048);
            // Natural length of a video; 0 for an image. Reported by the
            // client from <video> metadata (the api has no ffprobe) and
            // clamped, exactly as kv_motion_projects.duration_ms is.
            $t->unsignedInteger('duration_ms')->default(0);
            $t->unsignedInteger('width')->default(0);
            $t->unsignedInteger('height')->default(0);

            $t->timestamps();
            $t->softDeletes();

            $t->index(['workspace_id', 'brand_id', 'deleted_at'], 'kv_motion_bumpers_scope_idx');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('kv_motion_bumpers');
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

class KvMotionBumper extends Model
{
    use HasFactory, HasUlids, HasWorkspaceScope, SoftDeletes;

    public const KIND_IMAGE = 'image';

    public const KIND_VIDEO = 'video';

    protected $table = 'kv_motion_bumpers';

    protected $fillable = [
        'workspace_id',
        'brand_id',
        'created_by',
        'name',
        'kind',
        'url',
        'duration_ms',
        'width',
        'height',
    ];

    protected $casts = [
        'duration_ms' => 'integer',
        'width' => 'integer',
        'height' => 'integer',
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

- [ ] **Step 3: Run the migration against the dev database**

Run (from `api/`): `TELESCOPE_ENABLED=false php artisan migrate --path=database/migrations/2026_09_20_100000_create_kv_motion_bumpers_table.php`
Expected: `DONE` for that one migration. (`TELESCOPE_ENABLED=false` — see memory `lesson_telescope_ooms_data_migrations`.)

- [ ] **Step 4: Confirm the table shape**

Run: `php artisan tinker --execute='echo implode(",", Schema::getColumnListing("kv_motion_bumpers"));'`
Expected: `id,workspace_id,brand_id,created_by,name,kind,url,duration_ms,width,height,created_at,updated_at,deleted_at`

- [ ] **Step 5: Commit**

```bash
git add database/migrations/2026_09_20_100000_create_kv_motion_bumpers_table.php app/Models/KvMotionBumper.php
git commit -m "feat(api): add kv_motion_bumpers table and model

Brand-scoped bumper library for KV Motion (logo lockups played before/after
a motion). Mirrors kv_motion_templates' scope columns and soft deletes.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Store request — rules, `kind` derivation, clamps

**Files:**
- Create: `app/Http/Requests/Studio/StoreKvMotionBumperRequest.php`
- Test: `tests/Unit/Requests/KvMotionBumperRequestsTest.php`
- Reference: `tests/Unit/Requests/KvMotionTemplateRequestsTest.php` (harness), `app/Http/Requests/Studio/UploadStudioOverlayAssetRequest.php` (mime rule)

**Interfaces:**
- Produces:
  - `StoreKvMotionBumperRequest::rules(): array`
  - `StoreKvMotionBumperRequest::kindFromMime(string $mime): ?string` — `'image'` for `image/*`, `'video'` for `video/*`, `null` otherwise. Static, pure.
  - `StoreKvMotionBumperRequest::clampInt(mixed $value, int $min, int $max, int $default): int` — static, pure.
  - Constants `MAX_DURATION_MS = 60000`, `MAX_DIM = 8192`.

- [ ] **Step 1: Write the failing tests**

```php
<?php

use App\Http\Requests\Studio\StoreKvMotionBumperRequest;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Validator;
use Tests\TestCase;

uses(TestCase::class);

function validateBumperWith(array $payload): Illuminate\Validation\Validator
{
    $request = new StoreKvMotionBumperRequest;

    return Validator::make($payload, $request->rules());
}

function fakePng(): UploadedFile
{
    return UploadedFile::fake()->image('lockup.png', 400, 200);
}

/** A mime-correct mp4 without a real encoder: the `mimes` rule checks the
 *  guessed mime, which for `fake()->create()` comes from the extension. */
function fakeMp4(int $kb = 100): UploadedFile
{
    return UploadedFile::fake()->create('lockup.mp4', $kb, 'video/mp4');
}

it('accepts an image upload with its dimensions', function () {
    $v = validateBumperWith([
        'name' => 'Telkomsel lockup',
        'file' => fakePng(),
        'duration_ms' => 0,
        'width' => 400,
        'height' => 200,
    ]);
    expect($v->passes())->toBeTrue();
});

it('accepts a video upload with a duration', function () {
    $v = validateBumperWith([
        'name' => 'Simpati sting',
        'file' => fakeMp4(),
        'duration_ms' => 2500,
        'width' => 1920,
        'height' => 1080,
    ]);
    expect($v->passes())->toBeTrue();
});

it('requires name, file, duration_ms, width and height', function () {
    $v = validateBumperWith([]);
    expect($v->fails())->toBeTrue()
        ->and($v->errors()->has('name'))->toBeTrue()
        ->and($v->errors()->has('file'))->toBeTrue()
        ->and($v->errors()->has('duration_ms'))->toBeTrue()
        ->and($v->errors()->has('width'))->toBeTrue()
        ->and($v->errors()->has('height'))->toBeTrue();
});

it('rejects a mime outside the allow-list', function () {
    $v = validateBumperWith([
        'name' => 'x',
        'file' => UploadedFile::fake()->create('lockup.gif', 10, 'image/gif'),
        'duration_ms' => 0,
        'width' => 1,
        'height' => 1,
    ]);
    expect($v->fails())->toBeTrue()
        ->and($v->errors()->has('file'))->toBeTrue();
});

it('rejects an upload over 50 MB', function () {
    $v = validateBumperWith([
        'name' => 'x',
        'file' => fakeMp4(51201),
        'duration_ms' => 1000,
        'width' => 1,
        'height' => 1,
    ]);
    expect($v->fails())->toBeTrue()
        ->and($v->errors()->has('file'))->toBeTrue();
});

it('rejects negative numbers', function () {
    $v = validateBumperWith([
        'name' => 'x',
        'file' => fakePng(),
        'duration_ms' => -1,
        'width' => -5,
        'height' => 10,
    ]);
    expect($v->fails())->toBeTrue()
        ->and($v->errors()->has('duration_ms'))->toBeTrue()
        ->and($v->errors()->has('width'))->toBeTrue();
});

// `kind` must never come from the body — a client could otherwise store a
// PNG as "video" and the web decoder would choke on it at export time.
it('does not declare a kind rule (kind is derived from the mime)', function () {
    expect(array_key_exists('kind', (new StoreKvMotionBumperRequest)->rules()))->toBeFalse();
});

it('derives kind from the mime prefix', function () {
    expect(StoreKvMotionBumperRequest::kindFromMime('image/png'))->toBe('image')
        ->and(StoreKvMotionBumperRequest::kindFromMime('image/webp'))->toBe('image')
        ->and(StoreKvMotionBumperRequest::kindFromMime('video/mp4'))->toBe('video')
        ->and(StoreKvMotionBumperRequest::kindFromMime('video/webm'))->toBe('video')
        ->and(StoreKvMotionBumperRequest::kindFromMime('audio/mpeg'))->toBeNull()
        ->and(StoreKvMotionBumperRequest::kindFromMime(''))->toBeNull();
});

it('clamps ints into range and falls back to the default for junk', function () {
    expect(StoreKvMotionBumperRequest::clampInt(70000, 0, 60000, 0))->toBe(60000)
        ->and(StoreKvMotionBumperRequest::clampInt(-3, 0, 60000, 0))->toBe(0)
        ->and(StoreKvMotionBumperRequest::clampInt('2500', 0, 60000, 0))->toBe(2500)
        ->and(StoreKvMotionBumperRequest::clampInt('abc', 0, 60000, 7))->toBe(7)
        ->and(StoreKvMotionBumperRequest::clampInt(null, 0, 8192, 0))->toBe(0);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (from `api/`): `php artisan test tests/Unit/Requests/KvMotionBumperRequestsTest.php`
Expected: FAIL — `Class "App\Http\Requests\Studio\StoreKvMotionBumperRequest" not found`.

- [ ] **Step 3: Write the request**

```php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;

/**
 * Multipart upload of one bumper (logo lockup) into the brand library.
 *
 * `kind` is DERIVED from the upload's mime (see kindFromMime) — it is not a
 * request field, so a client cannot label a PNG as a video. `duration_ms`,
 * `width` and `height` are the client's reading of the asset's metadata
 * (the api has no ffprobe); they are validated as non-negative ints here and
 * clamped by the controller through clampInt().
 */
class StoreKvMotionBumperRequest extends FormRequest
{
    /** Hard ceiling on a bumper's natural length. Bumpers are stings, not
     *  films; the web slot trims below this anyway. */
    public const MAX_DURATION_MS = 60000;

    public const MAX_DIM = 8192;

    public function authorize(): bool
    {
        return true; // workspace/brand check happens in the controller on the file
    }

    public function rules(): array
    {
        return [
            'name' => ['required', 'string', 'max:255'],
            'file' => [
                'required',
                'file',
                'mimes:png,jpg,jpeg,webp,mp4,webm',
                'max:51200', // 50 MB — same ceiling as overlay assets
            ],
            'duration_ms' => ['required', 'integer', 'min:0'],
            'width' => ['required', 'integer', 'min:0'],
            'height' => ['required', 'integer', 'min:0'],
        ];
    }

    /** 'image' | 'video' from a mime type; null for anything else. */
    public static function kindFromMime(string $mime): ?string
    {
        if (str_starts_with($mime, 'image/')) {
            return 'image';
        }
        if (str_starts_with($mime, 'video/')) {
            return 'video';
        }

        return null;
    }

    /** Coerce + clamp an integer-ish value; `$default` for anything that
     *  is not numeric. Mirrors KvMotionProjectController::intFrom(). */
    public static function clampInt(mixed $value, int $min, int $max, int $default): int
    {
        if (! is_numeric($value)) {
            return $default;
        }

        return max($min, min($max, (int) $value));
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `php artisan test tests/Unit/Requests/KvMotionBumperRequestsTest.php`
Expected: 9 passed.

- [ ] **Step 5: Commit**

```bash
git add app/Http/Requests/Studio/StoreKvMotionBumperRequest.php tests/Unit/Requests/KvMotionBumperRequestsTest.php
git commit -m "feat(api): add StoreKvMotionBumperRequest with mime-derived kind

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Resource

**Files:**
- Create: `app/Http/Resources/Studio/KvMotionBumperResource.php`
- Test: `tests/Unit/Resources/KvMotionBumperResourceTest.php`
- Reference: `app/Http/Resources/Studio/KvMotionTemplateResource.php`

**Interfaces:**
- Produces: JSON keys `id, brand_id, name, kind, url, duration_ms, width, height, created_by, created_at, updated_at`. The web service (`web/src/services/kv/motionBumpers.ts`, web plan Task 3) maps exactly these.

- [ ] **Step 1: Write the failing test**

```php
<?php

use App\Http\Resources\Studio\KvMotionBumperResource;
use App\Models\KvMotionBumper;
use Illuminate\Http\Request;
use Tests\TestCase;

uses(TestCase::class);

it('exposes the bumper fields the web client reads', function () {
    $row = new KvMotionBumper([
        'brand_id' => '01J0000000000000000000000B',
        'created_by' => '01J0000000000000000000000U',
        'name' => 'Telkomsel lockup',
        'kind' => 'video',
        'url' => 'https://cdn/brands/b/motion-bumpers/x.mp4',
        'duration_ms' => 2500,
        'width' => 1920,
        'height' => 1080,
    ]);
    $row->id = '01J0000000000000000000000T';

    $out = (new KvMotionBumperResource($row))->toArray(Request::create('/'));

    expect($out)->toHaveKeys([
        'id', 'brand_id', 'name', 'kind', 'url', 'duration_ms', 'width', 'height',
        'created_by', 'created_at', 'updated_at',
    ])->and($out['kind'])->toBe('video')
        ->and($out['duration_ms'])->toBe(2500)
        ->and($out['width'])->toBe(1920);
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `php artisan test tests/Unit/Resources/KvMotionBumperResourceTest.php`
Expected: FAIL — resource class not found.

- [ ] **Step 3: Write the resource**

```php
<?php

namespace App\Http\Resources\Studio;

use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

class KvMotionBumperResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'id' => $this->id,
            'brand_id' => $this->brand_id,
            'name' => $this->name,
            'kind' => $this->kind,
            'url' => $this->url,
            'duration_ms' => $this->duration_ms,
            'width' => $this->width,
            'height' => $this->height,
            'created_by' => $this->created_by,
            'created_at' => $this->created_at,
            'updated_at' => $this->updated_at,
        ];
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `php artisan test tests/Unit/Resources/KvMotionBumperResourceTest.php`
Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add app/Http/Resources/Studio/KvMotionBumperResource.php tests/Unit/Resources/KvMotionBumperResourceTest.php
git commit -m "feat(api): add KvMotionBumperResource

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Controller + routes

**Files:**
- Create: `app/Http/Controllers/Api/Studio/KvMotionBumperController.php`
- Modify: `routes/api.php` (insert directly after the `motion-templates` `destroy` route, ~line 4891)
- Test: `tests/Unit/Http/Controllers/Api/Studio/KvMotionBumperControllerTest.php`
- Reference: `app/Http/Controllers/Api/Studio/KvMotionTemplateController.php`, `app/Http/Controllers/Api/Studio/StudioOverlayAssetController.php::store`

**Interfaces:**
- Consumes: `StoreKvMotionBumperRequest` (Task 2), `KvMotionBumperResource` (Task 3), `KvMotionBumper` (Task 1).
- Produces routes:
  - `GET v1/studio/files/{file}/motion-bumpers` → `{ data: KvMotionBumperResource[] }` newest first, max 100
  - `POST v1/studio/files/{file}/motion-bumpers` → `201 { data: KvMotionBumperResource }`
  - `DELETE v1/studio/files/{file}/motion-bumpers/{bumper}` → `{ ok: true }`

- [ ] **Step 1: Write the failing unit tests (guard + wiring, no DB)**

```php
<?php

use App\Http\Controllers\Api\Studio\KvMotionBumperController;
use App\Models\StudioFile;
use Symfony\Component\HttpKernel\Exception\HttpException;
use Tests\TestCase;

uses(TestCase::class);

/**
 * Same isolation as KvMotionTemplateControllerTest: `studio_files.brand_id`
 * is nullable, `kv_motion_bumpers.brand_id` is NOT NULL, and this Unit
 * suite has no Postgres — so the brand-less guard is exercised via
 * Reflection on an unsaved StudioFile.
 */
function invokeBumperEnsureBranded(StudioFile $file): void
{
    $controller = new KvMotionBumperController;
    $method = new ReflectionMethod($controller, 'ensureBranded');
    $method->invoke($controller, $file);
}

it('aborts with 422 when the file has no brand', function () {
    try {
        invokeBumperEnsureBranded(new StudioFile(['brand_id' => null]));
        $this->fail('Expected an HttpException to be thrown.');
    } catch (HttpException $e) {
        expect($e->getStatusCode())->toBe(422);
    }
});

it('lets a branded file through untouched', function () {
    invokeBumperEnsureBranded(new StudioFile(['brand_id' => '01J0000000000000000000000B']));
})->throwsNoExceptions();

// Wiring contract (same technique as the template controller test): a
// refactor that drops the guard call from store() must turn this red even
// though the guard itself still works.
it('store() calls ensureBranded before writing', function () {
    $src = (new ReflectionMethod(KvMotionBumperController::class, 'store'));
    $lines = array_slice(
        file($src->getFileName()),
        $src->getStartLine() - 1,
        $src->getEndLine() - $src->getStartLine() + 1,
    );
    $body = implode('', $lines);
    expect($body)->toContain('$this->ensureBranded($file);')
        ->and(strpos($body, 'ensureBranded'))->toBeLessThan(strpos($body, 'KvMotionBumper::create'));
});

// The mime→kind derivation is the ONLY source of `kind`: store() must not
// read it from the request. Pin by source text, same as above.
it('store() derives kind from the upload mime, never from input', function () {
    $src = (new ReflectionMethod(KvMotionBumperController::class, 'store'));
    $lines = array_slice(
        file($src->getFileName()),
        $src->getStartLine() - 1,
        $src->getEndLine() - $src->getStartLine() + 1,
    );
    $body = implode('', $lines);
    expect($body)->toContain('kindFromMime(')
        ->and($body)->not->toContain("\$v['kind']")
        ->and($body)->not->toContain("input('kind')");
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `php artisan test tests/Unit/Http/Controllers/Api/Studio/KvMotionBumperControllerTest.php`
Expected: FAIL — controller class not found.

- [ ] **Step 3: Write the controller**

```php
<?php

namespace App\Http\Controllers\Api\Studio;

use App\Http\Controllers\Controller;
use App\Http\Requests\Studio\StoreKvMotionBumperRequest;
use App\Http\Resources\Studio\KvMotionBumperResource;
use App\Models\KvMotionBumper;
use App\Models\StudioFile;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\Response;

/**
 * Brand-scoped bumper library for KV Motion: a logo lockup (image or short
 * video) uploaded once and dropped into the start/end slot of any motion
 * project on the same brand.
 *
 * The brand is ALWAYS derived server-side from the studio file in the route
 * — the client never sends a `brand_id` (same contract as
 * KvMotionTemplateController).
 */
class KvMotionBumperController extends Controller
{
    /** Newest-first ceiling. A brand with more bumpers than this needs real
     *  pagination on both sides, not a bigger constant. */
    private const INDEX_LIMIT = 100;

    public function index(Request $request, string $fileId): JsonResponse
    {
        $file = $this->fileFor($request, $fileId);

        $rows = KvMotionBumper::where('brand_id', $file->brand_id)
            ->orderByDesc('created_at')
            ->limit(self::INDEX_LIMIT)
            ->get();

        return response()->json([
            'data' => KvMotionBumperResource::collection($rows)->resolve(),
        ]);
    }

    public function store(StoreKvMotionBumperRequest $request, string $fileId): JsonResponse
    {
        $file = $this->fileFor($request, $fileId);
        $this->ensureBranded($file);

        $v = $request->validated();
        $upload = $request->file('file');

        // Derived from the upload, never from the body: the `mimes` rule has
        // already restricted this to image/* or video/*, so null here means
        // the guesser and the rule disagree — refuse rather than store junk.
        $kind = StoreKvMotionBumperRequest::kindFromMime((string) $upload->getMimeType());
        abort_if($kind === null, 422, 'Unsupported bumper file type.');

        $ext = $upload->getClientOriginalExtension();
        $name = Str::ulid().'.'.$ext;
        // Brand-keyed, not file-keyed: the bumper outlives any one KV.
        $path = $upload->storeAs("brands/{$file->brand_id}/motion-bumpers", $name, 's3');

        $row = KvMotionBumper::create([
            // workspace_id is stamped by HasWorkspaceScope on save.
            'brand_id' => $file->brand_id,
            'created_by' => $request->user()->id,
            'name' => $v['name'],
            'kind' => $kind,
            'url' => Storage::disk('s3')->url($path),
            // An image has no duration whatever the client reported.
            'duration_ms' => $kind === KvMotionBumper::KIND_IMAGE
                ? 0
                : StoreKvMotionBumperRequest::clampInt($v['duration_ms'], 0, StoreKvMotionBumperRequest::MAX_DURATION_MS, 0),
            'width' => StoreKvMotionBumperRequest::clampInt($v['width'], 0, StoreKvMotionBumperRequest::MAX_DIM, 0),
            'height' => StoreKvMotionBumperRequest::clampInt($v['height'], 0, StoreKvMotionBumperRequest::MAX_DIM, 0),
        ]);

        return response()->json(
            ['data' => (new KvMotionBumperResource($row))->resolve()],
            Response::HTTP_CREATED
        );
    }

    public function destroy(Request $request, string $fileId, string $bumperId): JsonResponse
    {
        $this->bumperFor($request, $fileId, $bumperId)->delete();

        return response()->json(['ok' => true]);
    }

    private function fileFor(Request $request, string $fileId): StudioFile
    {
        $file = StudioFile::findOrFail($fileId);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        return $file;
    }

    /**
     * Brand-less files (personal/workspace scratch) have no brand to store a
     * bumper against: kv_motion_bumpers.brand_id is NOT NULL, so an
     * unconditional insert would 500 with a raw QueryException.
     */
    private function ensureBranded(StudioFile $file): void
    {
        abort_if($file->brand_id === null, 422, 'This file has no brand to save a bumper against.');
    }

    private function bumperFor(Request $request, string $fileId, string $bumperId): KvMotionBumper
    {
        $file = $this->fileFor($request, $fileId);

        return KvMotionBumper::where('brand_id', $file->brand_id)
            ->where('id', $bumperId)
            ->firstOrFail();
    }
}
```

- [ ] **Step 4: Add the routes**

In `routes/api.php`, directly after the `motion-templates` destroy route (inside the same group), add:

```php
                            // KV Motion bumpers (brand-scoped logo lockups
                            // for the start/end slot of a motion project)
                            Route::get('files/{file}/motion-bumpers', [KvMotionBumperController::class, 'index']);
                            Route::post('files/{file}/motion-bumpers', [KvMotionBumperController::class, 'store']);
                            Route::delete('files/{file}/motion-bumpers/{bumper}', [KvMotionBumperController::class, 'destroy']);
```

and add `use App\Http\Controllers\Api\Studio\KvMotionBumperController;` next to the `KvMotionTemplateController` import at the top of the file.

- [ ] **Step 5: Run the unit tests**

Run: `php artisan test tests/Unit/Http/Controllers/Api/Studio/KvMotionBumperControllerTest.php`
Expected: 4 passed.

- [ ] **Step 6: Verify the routes are registered (and not shadowed by a stale route cache)**

Run: `php artisan route:clear && php artisan route:list --path=motion-bumpers`
Expected: three rows — `GET|HEAD`, `POST` on `…/motion-bumpers`, `DELETE` on `…/motion-bumpers/{bumper}`. (Memory `lesson_run_all_never_clears_laravel_caches`: a cached route table 405s every new route; clear it before probing the running server.)

- [ ] **Step 7: Smoke the running server**

With the api running on 9191 and a valid bearer token `$TOKEN` and a branded studio file id `$FILE`:

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:9191/api/v1/studio/files/$FILE/motion-bumpers
```
Expected: `{"data":[]}` (200). Then upload a small PNG:

```bash
curl -s -H "Authorization: Bearer $TOKEN" -F name=Lockup -F duration_ms=0 -F width=400 -F height=200 -F file=@/path/to/lockup.png http://localhost:9191/api/v1/studio/files/$FILE/motion-bumpers
```
Expected: 201 with `"kind":"image"`, `"duration_ms":0`, an `https://…/brands/<brand>/motion-bumpers/<ulid>.png` url. Re-run the GET — the row is listed. Then `DELETE …/motion-bumpers/<id>` → `{"ok":true}` and the GET is empty again.

- [ ] **Step 8: Commit**

```bash
git add app/Http/Controllers/Api/Studio/KvMotionBumperController.php routes/api.php tests/Unit/Http/Controllers/Api/Studio/KvMotionBumperControllerTest.php
git commit -m "feat(api): add motion-bumpers list/upload/delete endpoints

Brand-scoped, file-addressed like motion-templates. kind is derived from
the upload mime; duration/dims are the client's metadata reading, clamped.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Feature test (round-trip; runs only on a scratch Postgres)

**Files:**
- Create: `tests/Feature/Studio/KvMotionBumperControllerTest.php`
- Reference: any existing `tests/Feature/Studio/*` test for the auth/workspace bootstrap helpers it uses (copy its `beforeEach` user + workspace + brand + studio-file setup verbatim).

**Interfaces:**
- Consumes: routes from Task 4.

- [ ] **Step 1: Write the feature test**

Use the same fixture bootstrap as the nearest existing `tests/Feature/Studio/KvMotion*Test.php` (user, workspace, brand, `StudioFile` with `brand_id`) — copy it, do not invent a new one. Then:

```php
<?php

use App\Models\KvMotionBumper;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;

// …the copied beforeEach() that yields $this->user, $this->file (branded)…

it('uploads an image bumper into the brand library', function () {
    Storage::fake('s3');

    $res = $this->actingAs($this->user)->post(
        "/api/v1/studio/files/{$this->file->id}/motion-bumpers",
        [
            'name' => 'Telkomsel lockup',
            'file' => UploadedFile::fake()->image('lockup.png', 400, 200),
            'duration_ms' => 999, // ignored for an image
            'width' => 400,
            'height' => 200,
        ],
    );

    $res->assertCreated()
        ->assertJsonPath('data.kind', 'image')
        ->assertJsonPath('data.duration_ms', 0)
        ->assertJsonPath('data.width', 400)
        ->assertJsonPath('data.brand_id', $this->file->brand_id);

    $row = KvMotionBumper::first();
    expect($row->url)->toContain("brands/{$this->file->brand_id}/motion-bumpers/");
    Storage::disk('s3')->assertExists(
        "brands/{$this->file->brand_id}/motion-bumpers/".basename(parse_url($row->url, PHP_URL_PATH)),
    );
});

it('clamps a video duration to the ceiling', function () {
    Storage::fake('s3');

    $res = $this->actingAs($this->user)->post(
        "/api/v1/studio/files/{$this->file->id}/motion-bumpers",
        [
            'name' => 'Sting',
            'file' => UploadedFile::fake()->create('sting.mp4', 10, 'video/mp4'),
            'duration_ms' => 999999,
            'width' => 1920,
            'height' => 1080,
        ],
    );

    $res->assertCreated()
        ->assertJsonPath('data.kind', 'video')
        ->assertJsonPath('data.duration_ms', 60000);
});

it('lists the brand library newest first and hides soft-deleted rows', function () {
    $old = KvMotionBumper::create([
        'brand_id' => $this->file->brand_id, 'created_by' => $this->user->id,
        'name' => 'old', 'kind' => 'image', 'url' => 'https://x/a.png',
        'created_at' => now()->subMinute(),
    ]);
    $new = KvMotionBumper::create([
        'brand_id' => $this->file->brand_id, 'created_by' => $this->user->id,
        'name' => 'new', 'kind' => 'image', 'url' => 'https://x/b.png',
    ]);
    $gone = KvMotionBumper::create([
        'brand_id' => $this->file->brand_id, 'created_by' => $this->user->id,
        'name' => 'gone', 'kind' => 'image', 'url' => 'https://x/c.png',
    ]);
    $gone->delete();

    $res = $this->actingAs($this->user)->getJson(
        "/api/v1/studio/files/{$this->file->id}/motion-bumpers",
    );

    $res->assertOk();
    expect(collect($res->json('data'))->pluck('id')->all())->toBe([$new->id, $old->id]);
});

it('soft-deletes a bumper of the same brand', function () {
    $row = KvMotionBumper::create([
        'brand_id' => $this->file->brand_id, 'created_by' => $this->user->id,
        'name' => 'x', 'kind' => 'image', 'url' => 'https://x/a.png',
    ]);

    $this->actingAs($this->user)
        ->deleteJson("/api/v1/studio/files/{$this->file->id}/motion-bumpers/{$row->id}")
        ->assertOk()
        ->assertJson(['ok' => true]);

    expect(KvMotionBumper::withTrashed()->find($row->id)->trashed())->toBeTrue();
});

it('422s on a brand-less file', function () {
    $this->file->update(['brand_id' => null]);

    $this->actingAs($this->user)->post(
        "/api/v1/studio/files/{$this->file->id}/motion-bumpers",
        [
            'name' => 'x',
            'file' => UploadedFile::fake()->image('lockup.png', 10, 10),
            'duration_ms' => 0, 'width' => 10, 'height' => 10,
        ],
    )->assertStatus(422);
});
```

- [ ] **Step 2: Run it — only if a scratch Postgres is configured**

The Feature suite cannot run on SQLite (`DROP SEQUENCE`) and the shared `frnd_test` database is gone (memory `lesson_api_feature_tests_need_scratch_postgres`). If `phpunit.xml` / `.env.testing` point at a scratch Postgres you own:

Run: `php artisan test tests/Feature/Studio/KvMotionBumperControllerTest.php`
Expected: 5 passed.

If no scratch database is available, do NOT run it; record in the commit message that it is unrun.

- [ ] **Step 3: Commit**

```bash
git add tests/Feature/Studio/KvMotionBumperControllerTest.php
git commit -m "test(api): feature round-trip for motion-bumpers endpoints

Runs only against a scratch Postgres (see lesson_api_feature_tests_need_scratch_postgres).

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage:** §3.1 table (T1), storage path (T4), three endpoints (T4), validation incl. mime allow-list, `kind` derivation, clamps, image `duration_ms = 0` (T2 + T4), soft delete only (T1/T4), no nested rules (T2 test asserts no `kind` rule; no `x.*` rules exist), §3.10 unit tests + feature test gated on Postgres (T2–T5). No api change to `kv_motion_projects` — correct per §3.2.
- **Placeholders:** none. The Feature test's `beforeEach` is deliberately "copy the nearest sibling's bootstrap" because the exact helper names differ per file and inventing them would be a lie.
- **Type consistency:** `kindFromMime` / `clampInt` / `MAX_DURATION_MS` / `MAX_DIM` names match between T2 and T4; resource keys in T3 match what web plan Task 3 maps.
