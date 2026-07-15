# KV Canvas Custom Fonts — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add brand-scoped custom font (OTF/TTF) storage and CRUD endpoints so the KV canvas can offer uploaded fonts for text overlays.

**Architecture:** New `brand_fonts` table + `BrandFont` model (workspace-scoped like `BrandOverlayPreset`). A `StudioBrandFontController` (index/store/destroy) mirrors `StudioBrandOverlayPresetController`; uploads land on the `s3` disk exactly like `StudioOverlayAssetController`. A stable `font_family` id (`bf_<ulid>`) is generated per upload for the browser to key its `FontFace` on.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL, S3 disk, Pest/PHPUnit.

## Global Constraints

- Brand authorization = `$brand->workspace_id === $request->user()->current_workspace_id` (copied from the preset controller). Never trust a raw `brand_id` without this check.
- Storage disk is `s3`; URL via `Storage::disk('s3')->url($path)`.
- Upload limits: **TTF + OTF only**, **max 5 MB (5120 KB)**.
- `workspace_id` is auto-filled by the `HasWorkspaceScope` trait — do NOT set it manually in `create()`.
- Known suite limitation: the api Feature suite fails on a fresh migrate (workspaces backfill + SoftDeletes). Prefer Unit-level tests for validation/model; only write a Feature test if the suite is confirmed runnable in the environment.
- Test base class: these Unit tests use Laravel facades (`Storage::fake`, `Validator`, `UploadedFile::fake`), so they MUST extend `Tests\TestCase` (boots the app). They do NOT use `RefreshDatabase` and touch NO database — `phpunit.xml` already isolates to in-memory sqlite, so running them is DB-safe. Run ONLY the named test file per task; never `php artisan migrate` or the Feature suite.

---

### Task 1: `brand_fonts` migration + `BrandFont` model

**Files:**
- Create: `api/database/migrations/2026_07_15_000001_create_brand_fonts_table.php`
- Create: `api/app/Models/BrandFont.php`
- Test: `api/tests/Unit/Models/BrandFontTest.php`

**Interfaces:**
- Produces: `BrandFont` model with fillable `['brand_id','created_by','name','font_family','file_path','original_filename','format','file_size']`, `url` accessor returning `Storage::disk('s3')->url($file_path)`.

- [ ] **Step 1: Write the failing test**

```php
<?php

namespace Tests\Unit\Models;

use App\Models\BrandFont;
use Illuminate\Support\Facades\Storage;
use Tests\TestCase; // boots the app so Storage::fake works; NO RefreshDatabase (no DB touched)

class BrandFontTest extends TestCase
{
    public function test_url_accessor_builds_s3_url(): void
    {
        Storage::fake('s3');
        $font = new BrandFont();
        $font->file_path = 'studio/brands/b1/fonts/x.ttf';

        $this->assertStringContainsString('studio/brands/b1/fonts/x.ttf', $font->url);
    }

    public function test_font_family_and_format_are_fillable(): void
    {
        $font = new BrandFont();
        $font->fill([
            'brand_id' => 'b1',
            'created_by' => 'u1',
            'name' => 'Acme Sans',
            'font_family' => 'bf_01H',
            'file_path' => 'p.ttf',
            'original_filename' => 'AcmeSans.ttf',
            'format' => 'ttf',
            'file_size' => 1234,
        ]);

        $this->assertSame('bf_01H', $font->font_family);
        $this->assertSame('ttf', $font->format);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && ./vendor/bin/phpunit tests/Unit/Models/BrandFontTest.php`
Expected: FAIL with "Class App\Models\BrandFont not found".

- [ ] **Step 3: Write the migration**

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('brand_fonts', function (Blueprint $table) {
            $table->ulid('id')->primary();
            $table->foreignUlid('workspace_id')->constrained('workspaces')->cascadeOnDelete();
            $table->foreignUlid('brand_id')->constrained('brands')->cascadeOnDelete();
            $table->foreignUlid('created_by')->constrained('users')->cascadeOnDelete();
            $table->string('name', 100);
            // Stable CSS family id the browser keys its FontFace on, e.g. "bf_<ulid>".
            $table->string('font_family', 64)->unique();
            $table->string('file_path');
            $table->string('original_filename');
            $table->string('format', 8); // ttf | otf
            $table->unsignedBigInteger('file_size');
            $table->timestamps();
            $table->softDeletes();

            $table->index(['brand_id', 'deleted_at']);
            $table->index('workspace_id');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('brand_fonts');
    }
};
```

- [ ] **Step 4: Write the model**

```php
<?php

namespace App\Models;

use App\Traits\HasWorkspaceScope;
use Illuminate\Database\Eloquent\Casts\Attribute;
use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\SoftDeletes;
use Illuminate\Support\Facades\Storage;

class BrandFont extends Model
{
    use HasFactory, HasUlids, HasWorkspaceScope, SoftDeletes;

    protected $table = 'brand_fonts';

    protected $fillable = [
        'workspace_id',
        'brand_id',
        'created_by',
        'name',
        'font_family',
        'file_path',
        'original_filename',
        'format',
        'file_size',
    ];

    protected function url(): Attribute
    {
        return Attribute::get(fn () => Storage::disk('s3')->url($this->file_path));
    }

    public function brand(): BelongsTo
    {
        return $this->belongsTo(Brand::class);
    }

    public function createdBy(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd api && ./vendor/bin/phpunit tests/Unit/Models/BrandFontTest.php`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add api/database/migrations/2026_07_15_000001_create_brand_fonts_table.php api/app/Models/BrandFont.php api/tests/Unit/Models/BrandFontTest.php
git commit -m "feat(api): add brand_fonts table and BrandFont model"
```

---

### Task 2: `UploadBrandFontRequest` (validation + magic-byte sniff)

**Files:**
- Create: `api/app/Http/Requests/Studio/UploadBrandFontRequest.php`
- Test: `api/tests/Unit/Requests/UploadBrandFontRequestTest.php`

**Interfaces:**
- Consumes: nothing.
- Produces: `UploadBrandFontRequest` with `rules()` validating `name` (required, string, max:100) and `file` (required, file, `mimes:ttf,otf`, `max:5120`) plus a `withValidator` magic-byte check that rejects files whose header is not a known font signature. Adds a public `resolvedFormat(): string` returning `ttf`|`otf` from the uploaded extension.

- [ ] **Step 1: Write the failing test**

```php
<?php

namespace Tests\Unit\Requests;

use App\Http\Requests\Studio\UploadBrandFontRequest;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Validator;
use Tests\TestCase; // boots the app so Validator/UploadedFile facades work; NO RefreshDatabase

class UploadBrandFontRequestTest extends TestCase
{
    private function validate(array $data): \Illuminate\Contracts\Validation\Validator
    {
        $req = new UploadBrandFontRequest();
        $v = Validator::make($data, $req->rules());
        $req->withValidator($v);

        return $v;
    }

    public function test_rejects_oversized_file(): void
    {
        $file = UploadedFile::fake()->create('big.ttf', 6000); // 6 MB
        $v = $this->validate(['name' => 'X', 'file' => $file]);
        $this->assertTrue($v->fails());
    }

    public function test_rejects_non_font_extension(): void
    {
        $file = UploadedFile::fake()->create('note.txt', 10);
        $v = $this->validate(['name' => 'X', 'file' => $file]);
        $this->assertTrue($v->fails());
    }

    public function test_rejects_ttf_with_bad_magic_bytes(): void
    {
        // .ttf extension but text content — magic-byte check must fail it.
        $path = tempnam(sys_get_temp_dir(), 'font').'.ttf';
        file_put_contents($path, 'not a real font at all');
        $file = new UploadedFile($path, 'fake.ttf', 'font/ttf', null, true);

        $v = $this->validate(['name' => 'X', 'file' => $file]);
        $this->assertTrue($v->fails());
    }

    public function test_accepts_valid_ttf_signature(): void
    {
        $path = tempnam(sys_get_temp_dir(), 'font').'.ttf';
        // 0x00010000 TrueType signature + padding.
        file_put_contents($path, "\x00\x01\x00\x00".str_repeat("\x00", 64));
        $file = new UploadedFile($path, 'ok.ttf', 'font/ttf', null, true);

        $v = $this->validate(['name' => 'Acme', 'file' => $file]);
        $this->assertFalse($v->fails());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && ./vendor/bin/phpunit tests/Unit/Requests/UploadBrandFontRequestTest.php`
Expected: FAIL with "Class App\Http\Requests\Studio\UploadBrandFontRequest not found".

- [ ] **Step 3: Write the request**

```php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Contracts\Validation\Validator;
use Illuminate\Foundation\Http\FormRequest;

class UploadBrandFontRequest extends FormRequest
{
    public function authorize(): bool
    {
        // Brand authorization happens in the controller (workspace scope).
        return true;
    }

    public function rules(): array
    {
        return [
            'name' => ['required', 'string', 'min:1', 'max:100'],
            'file' => ['required', 'file', 'mimes:ttf,otf', 'max:5120'],
        ];
    }

    public function withValidator(Validator $validator): void
    {
        $validator->after(function (Validator $v) {
            $file = $this->file('file');
            if (! $file || ! $file->isValid()) {
                return;
            }
            $header = (string) file_get_contents($file->getRealPath(), false, null, 0, 4);
            // TrueType: 0x00010000 or "true"; OpenType/CFF: "OTTO".
            $signatures = ["\x00\x01\x00\x00", 'true', 'OTTO'];
            if (! in_array($header, $signatures, true)) {
                $v->errors()->add('file', 'The uploaded file is not a valid OTF or TTF font.');
            }
        });
    }

    public function resolvedFormat(): string
    {
        return strtolower($this->file('file')->getClientOriginalExtension()) === 'otf' ? 'otf' : 'ttf';
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd api && ./vendor/bin/phpunit tests/Unit/Requests/UploadBrandFontRequestTest.php`
Expected: PASS (all 4).

- [ ] **Step 5: Commit**

```bash
git add api/app/Http/Requests/Studio/UploadBrandFontRequest.php api/tests/Unit/Requests/UploadBrandFontRequestTest.php
git commit -m "feat(api): add UploadBrandFontRequest with font signature validation"
```

---

### Task 3: `BrandFontResource` + `StudioBrandFontController` + routes

**Files:**
- Create: `api/app/Http/Resources/Studio/BrandFontResource.php`
- Create: `api/app/Http/Controllers/Api/Studio/StudioBrandFontController.php`
- Modify: `api/routes/api.php` (add routes next to the overlay-presets block, ~line 3038–3050)
- Test: `api/tests/Unit/Resources/BrandFontResourceTest.php`

**Interfaces:**
- Consumes: `BrandFont` (Task 1), `UploadBrandFontRequest` + `resolvedFormat()` (Task 2).
- Produces: routes `GET brands/{brand}/fonts`, `POST brands/{brand}/fonts`, `DELETE fonts/{id}`. Store returns 201 with a `BrandFontResource` (`{id, brand_id, name, font_family, url, format, file_size, original_filename, created_at, updated_at}`).

- [ ] **Step 1: Write the failing test (resource shape)**

```php
<?php

namespace Tests\Unit\Resources;

use App\Http\Resources\Studio\BrandFontResource;
use App\Models\BrandFont;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Storage;
use Tests\TestCase; // boots the app so Storage::fake works; NO RefreshDatabase (no DB touched)

class BrandFontResourceTest extends TestCase
{
    public function test_resource_exposes_url_and_family(): void
    {
        Storage::fake('s3');
        $font = new BrandFont();
        $font->forceFill([
            'id' => '01H',
            'brand_id' => 'b1',
            'name' => 'Acme Sans',
            'font_family' => 'bf_01H',
            'file_path' => 'studio/brands/b1/fonts/x.ttf',
            'format' => 'ttf',
            'file_size' => 1234,
            'original_filename' => 'AcmeSans.ttf',
        ]);

        $arr = (new BrandFontResource($font))->toArray(new Request());

        $this->assertSame('bf_01H', $arr['font_family']);
        $this->assertSame('ttf', $arr['format']);
        $this->assertArrayHasKey('url', $arr);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && ./vendor/bin/phpunit tests/Unit/Resources/BrandFontResourceTest.php`
Expected: FAIL with "Class ...BrandFontResource not found".

- [ ] **Step 3: Write the resource**

```php
<?php

namespace App\Http\Resources\Studio;

use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

class BrandFontResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'id' => $this->id,
            'brand_id' => $this->brand_id,
            'name' => $this->name,
            'font_family' => $this->font_family,
            'url' => $this->url,
            'format' => $this->format,
            'file_size' => $this->file_size,
            'original_filename' => $this->original_filename,
            'created_at' => $this->created_at?->toISOString(),
            'updated_at' => $this->updated_at?->toISOString(),
        ];
    }
}
```

- [ ] **Step 4: Write the controller**

```php
<?php

namespace App\Http\Controllers\Api\Studio;

use App\Http\Controllers\Controller;
use App\Http\Requests\Studio\UploadBrandFontRequest;
use App\Http\Resources\Studio\BrandFontResource;
use App\Models\Brand;
use App\Models\BrandFont;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

class StudioBrandFontController extends Controller
{
    public function index(Request $request, string $brandId): AnonymousResourceCollection
    {
        $brand = Brand::query()->findOrFail($brandId);
        $this->authorizeBrand($brand, $request);

        $fonts = BrandFont::query()
            ->where('brand_id', $brand->id)
            ->orderByDesc('created_at')
            ->get();

        return BrandFontResource::collection($fonts);
    }

    public function store(UploadBrandFontRequest $request, string $brandId): JsonResponse
    {
        $brand = Brand::query()->findOrFail($brandId);
        $this->authorizeBrand($brand, $request);

        $upload = $request->file('file');
        $format = $request->resolvedFormat();
        $name = Str::ulid().'.'.$format;
        $path = $upload->storeAs("studio/brands/{$brand->id}/fonts", $name, 's3');

        $font = BrandFont::create([
            'brand_id' => $brand->id,
            'created_by' => $request->user()->id,
            'name' => $request->validated('name'),
            'font_family' => 'bf_'.Str::ulid(),
            'file_path' => $path,
            'original_filename' => $upload->getClientOriginalName(),
            'format' => $format,
            'file_size' => $upload->getSize(),
        ]);

        return (new BrandFontResource($font))->response()->setStatusCode(201);
    }

    public function destroy(Request $request, string $id): JsonResponse
    {
        $font = BrandFont::query()->findOrFail($id);
        abort_unless(
            $font->workspace_id === $request->user()->current_workspace_id,
            403,
            'You do not have access to this font.'
        );

        Storage::disk('s3')->delete($font->file_path);
        $font->delete();

        return response()->json(null, 204);
    }

    private function authorizeBrand(Brand $brand, Request $request): void
    {
        abort_unless(
            $brand->workspace_id === $request->user()->current_workspace_id,
            403,
            'You do not have access to this brand.'
        );
    }
}
```

- [ ] **Step 5: Add the routes**

In `api/routes/api.php`, immediately after the `overlay-presets` `DELETE` route (the closing of that block, ~line 3049), add:

```php
                    // Per-brand custom fonts for KV canvas text overlays.
                    Route::get('brands/{brand}/fonts', [
                        StudioBrandFontController::class,
                        'index',
                    ]);
                    Route::post('brands/{brand}/fonts', [
                        StudioBrandFontController::class,
                        'store',
                    ]);
                    Route::delete('fonts/{id}', [
                        StudioBrandFontController::class,
                        'destroy',
                    ]);
```

And add the import near the other studio controller imports (~line 143):

```php
use App\Http\Controllers\Api\Studio\StudioBrandFontController;
```

- [ ] **Step 6: Run tests + route check**

Run: `cd api && ./vendor/bin/phpunit tests/Unit/Resources/BrandFontResourceTest.php`
Expected: PASS.
Run: `cd api && php artisan route:list --path=fonts`
Expected: the three `fonts` routes are listed.

- [ ] **Step 7: Commit**

```bash
git add api/app/Http/Resources/Studio/BrandFontResource.php api/app/Http/Controllers/Api/Studio/StudioBrandFontController.php api/routes/api.php api/tests/Unit/Resources/BrandFontResourceTest.php
git commit -m "feat(api): add brand font CRUD endpoints"
```

---

## Self-Review

- **Spec coverage:** migration/model (Task 1) ✓, endpoints + validation + S3 storage + `font_family` id (Tasks 2–3) ✓, workspace-scoped delete + S3 object delete (Task 3) ✓. No ai-service work (spec) ✓.
- **Placeholders:** none — every step has runnable code/commands.
- **Type consistency:** `resolvedFormat()` (Task 2) consumed in Task 3; `font_family`, `file_path`, `format`, `url` names consistent across model/resource/controller.
