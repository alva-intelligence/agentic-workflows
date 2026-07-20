# Share Report: Public Link — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable brand-level public link sharing for all Brand Insights tabs with live data, using the same UX pattern as the existing RAFI share feature.

**Architecture:** New `brand_share_settings` table stores per-brand slug/password config. Public proxy endpoints validate the slug then delegate to the same `DataServiceClientInterface` used by internal controllers. Frontend creates a new `/share/brand/[slug]` route tree that reuses existing tab components with a `PublicShareContext` to swap API calls and hide restricted UI elements.

**Tech Stack:** Laravel 13 (PHP 8.5), Next.js 16, React 19, TypeScript, TanStack Query v5, Tailwind CSS

**Spec:** `docs/superpowers/specs/2026-04-14-share-report-public-link-design.md`

---

## File Structure

### Backend (api/)

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `database/migrations/2026_04_14_000000_create_brand_share_settings_table.php` | Migration for brand_share_settings table |
| Create | `app/Models/BrandShareSetting.php` | Eloquent model with slug generation, password encryption |
| Create | `app/Http/Requests/UpdateBrandShareSettingRequest.php` | Validation rules for settings update |
| Create | `app/Http/Controllers/Api/Brand/BrandShareSettingController.php` | Authenticated GET/PATCH for share settings |
| Create | `app/Http/Controllers/Api/Share/BrandShareController.php` | Public slug lookup + password validation |
| Create | `app/Http/Controllers/Api/Share/BrandShareInsightController.php` | Public proxy for all insight tab endpoints |
| Modify | `routes/api.php` | Register new routes |

### Frontend (web/)

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `src/app/share/brand/[slug]/layout.tsx` | Public share layout with password wall + tab navigation |
| Create | `src/app/share/brand/[slug]/page.tsx` | Overview tab (default) |
| Create | `src/app/share/brand/[slug]/campaigns/page.tsx` | Campaigns tab |
| Create | `src/app/share/brand/[slug]/paid-media/page.tsx` | Paid Media tab |
| Create | `src/app/share/brand/[slug]/owned-media/page.tsx` | Owned Media tab |
| Create | `src/app/share/brand/[slug]/earned-media/page.tsx` | Earned Media tab |
| Create | `src/app/share/brand/[slug]/atl/page.tsx` | ATL tab |
| Create | `src/contexts/PublicShareContext.tsx` | Context provider for public share state |
| Create | `src/hooks/usePublicShareData.ts` | Hooks for public share API calls |
| Modify | `src/services/query.ts` | Add public share query functions |
| Modify | `src/services/mutate.ts` | Add share settings mutation + password validation |
| Modify | `src/components/brands/BrandInsightLayoutWrapper.tsx` | Add share button handler + `isPublicView` support |

---

## Task 1: Database Migration + Model

**Files:**
- Create: `api/database/migrations/2026_04_14_000000_create_brand_share_settings_table.php`
- Create: `api/app/Models/BrandShareSetting.php`

- [ ] **Step 1: Create the migration**

```php
<?php
// api/database/migrations/2026_04_14_000000_create_brand_share_settings_table.php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('brand_share_settings', function (Blueprint $table) {
            $table->ulid('id')->primary();
            $table->foreignUlid('brand_id')->constrained()->cascadeOnDelete();
            $table->string('link_slug', 6)->unique()->nullable();
            $table->boolean('link_enabled')->default(false);
            $table->boolean('link_is_protected')->default(false);
            $table->string('link_password')->nullable();
            $table->foreignUlid('created_by')->nullable()->constrained('users')->nullOnDelete();
            $table->timestamps();

            $table->unique('brand_id');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('brand_share_settings');
    }
};
```

- [ ] **Step 2: Create the model**

```php
<?php
// api/app/Models/BrandShareSetting.php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Str;

class BrandShareSetting extends Model
{
    use HasUlids;

    protected $fillable = [
        'brand_id',
        'link_slug',
        'link_enabled',
        'link_is_protected',
        'link_password',
        'created_by',
    ];

    protected function casts(): array
    {
        return [
            'link_enabled' => 'boolean',
            'link_is_protected' => 'boolean',
            'link_password' => 'encrypted',
        ];
    }

    public function brand(): BelongsTo
    {
        return $this->belongsTo(Brand::class);
    }

    public function creator(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }

    public static function generateUniqueSlug(): string
    {
        do {
            $slug = Str::lower(Str::random(6));
        } while (self::where('link_slug', $slug)->exists());

        return $slug;
    }

    public function getShareUrl(): ?string
    {
        if (! $this->link_slug) {
            return null;
        }

        return config('app.frontend_url') . '/share/brand/' . $this->link_slug;
    }
}
```

- [ ] **Step 3: Run migration**

Run: `cd api && php artisan migrate`
Expected: Migration runs successfully, `brand_share_settings` table created.

- [ ] **Step 4: Commit**

```bash
cd api
git add database/migrations/2026_04_14_000000_create_brand_share_settings_table.php app/Models/BrandShareSetting.php
git commit -m "feat(api): add BrandShareSetting model and migration"
```

---

## Task 2: Form Request + Settings Controller (Authenticated)

**Files:**
- Create: `api/app/Http/Requests/UpdateBrandShareSettingRequest.php`
- Create: `api/app/Http/Controllers/Api/Brand/BrandShareSettingController.php`

- [ ] **Step 1: Create the form request**

```php
<?php
// api/app/Http/Requests/UpdateBrandShareSettingRequest.php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

class UpdateBrandShareSettingRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'link' => ['required', 'array'],
            'link.enable' => ['nullable', 'boolean'],
            'link.password' => [
                'nullable',
                'string',
                'min:8',
                'regex:/[A-Z]/',
                'regex:/[0-9]/',
                'regex:/[a-zA-Z]/',
            ],
        ];
    }

    public function messages(): array
    {
        return [
            'link.password.min' => 'Password must be at least 8 characters.',
            'link.password.regex' => 'Password must contain at least 1 uppercase letter and 1 number.',
        ];
    }
}
```

- [ ] **Step 2: Create the settings controller**

Follow the same pattern as `BrandInsightRafiSettingController` (`api/app/Http/Controllers/Api/Brand/BrandInsightRafiSettingController.php`).

```php
<?php
// api/app/Http/Controllers/Api/Brand/BrandShareSettingController.php

namespace App\Http\Controllers\Api\Brand;

use App\Http\Controllers\Controller;
use App\Http\Requests\UpdateBrandShareSettingRequest;
use App\Models\Brand;
use App\Models\BrandShareSetting;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;

class BrandShareSettingController extends Controller
{
    public function index(string $brand_id, Request $request): JsonResponse
    {
        $user = $request->user();
        $workspace = $user->currentWorkspace;

        $brand = Brand::where('id', $brand_id)
            ->where('workspace_id', $workspace->id)
            ->first();

        if (! $brand) {
            return response()->json([
                'message' => 'Brand not found or you do not have access',
            ], 404);
        }

        $setting = BrandShareSetting::firstOrCreate(
            ['brand_id' => $brand->id],
            [
                'link_slug' => BrandShareSetting::generateUniqueSlug(),
                'created_by' => $user->id,
            ]
        );

        if (! $setting->link_slug) {
            $setting->update(['link_slug' => BrandShareSetting::generateUniqueSlug()]);
        }

        $setting->refresh();

        return response()->json([
            'message' => 'Brand share settings retrieved successfully',
            'data' => $this->formatResponse($setting),
        ]);
    }

    public function update(string $brand_id, UpdateBrandShareSettingRequest $request): JsonResponse
    {
        $user = $request->user();
        $workspace = $user->currentWorkspace;

        $brand = Brand::where('id', $brand_id)
            ->where('workspace_id', $workspace->id)
            ->first();

        if (! $brand) {
            return response()->json([
                'message' => 'Brand not found or you do not have access',
            ], 404);
        }

        $setting = BrandShareSetting::firstOrCreate(
            ['brand_id' => $brand->id],
            [
                'link_slug' => BrandShareSetting::generateUniqueSlug(),
                'created_by' => $user->id,
            ]
        );

        $updateData = [];
        $link = $request->input('link');

        if (array_key_exists('enable', $link)) {
            $updateData['link_enabled'] = (bool) $link['enable'];
        }

        if (array_key_exists('password', $link)) {
            if ($link['password'] === null) {
                $updateData['link_password'] = null;
                $updateData['link_is_protected'] = false;
            } else {
                $updateData['link_password'] = $link['password'];
                $updateData['link_is_protected'] = true;
            }
        }

        if (! empty($updateData)) {
            $setting->update($updateData);
        }

        Log::info('Brand share settings updated', [
            'brand_id' => $brand->id,
            'user_id' => $user->id,
            'updated_fields' => array_keys($updateData),
        ]);

        return response()->json([
            'message' => 'Brand share settings updated successfully',
            'data' => $this->formatResponse($setting->fresh()),
        ]);
    }

    private function formatResponse(BrandShareSetting $setting): array
    {
        return [
            'link' => [
                'enable' => $setting->link_enabled,
                'url' => $setting->getShareUrl(),
                'is_protected' => $setting->link_is_protected,
            ],
        ];
    }
}
```

- [ ] **Step 3: Commit**

```bash
cd api
git add app/Http/Requests/UpdateBrandShareSettingRequest.php app/Http/Controllers/Api/Brand/BrandShareSettingController.php
git commit -m "feat(api): add BrandShareSettingController with GET/PATCH endpoints"
```

---

## Task 3: Public Share Controller (Slug + Password)

**Files:**
- Create: `api/app/Http/Controllers/Api/Share/BrandShareController.php`

Follow the same pattern as `RafiShareController` (`api/app/Http/Controllers/Api/Share/RafiShareController.php`).

- [ ] **Step 1: Create the controller**

```php
<?php
// api/app/Http/Controllers/Api/Share/BrandShareController.php

namespace App\Http\Controllers\Api\Share;

use App\Http\Controllers\Controller;
use App\Models\BrandShareSetting;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

class BrandShareController extends Controller
{
    /**
     * Look up a brand share link by slug.
     *
     * - If link is disabled → 404
     * - If link is protected → returns { is_protected: true } with brand info
     * - If link is not protected → returns brand info for data fetching
     */
    public function show(string $slug): JsonResponse
    {
        $setting = BrandShareSetting::with('brand')->where('link_slug', $slug)->first();

        if (! $setting || ! $setting->link_enabled) {
            return response()->json([
                'message' => 'Share link not found or is no longer available.',
            ], 404);
        }

        if ($setting->link_is_protected) {
            return response()->json([
                'message' => 'This report is password-protected.',
                'data' => [
                    'brand_id' => $setting->brand_id,
                    'brand_name' => $setting->brand?->name,
                    'brand_logo' => $setting->brand?->logo,
                ],
                'is_protected' => true,
            ]);
        }

        return response()->json([
            'message' => 'Brand share link retrieved successfully',
            'data' => [
                'brand_id' => $setting->brand_id,
                'brand_name' => $setting->brand?->name,
                'brand_logo' => $setting->brand?->logo,
            ],
            'is_protected' => false,
        ]);
    }

    /**
     * Validate password for a protected brand share link.
     */
    public function validatePassword(string $slug, Request $request): JsonResponse
    {
        $setting = BrandShareSetting::with('brand')->where('link_slug', $slug)->first();

        if (! $setting || ! $setting->link_enabled) {
            return response()->json([
                'message' => 'Share link not found or is no longer available.',
            ], 404);
        }

        if (! $setting->link_is_protected) {
            return response()->json([
                'message' => 'Brand share link retrieved successfully',
                'data' => [
                    'brand_id' => $setting->brand_id,
                    'brand_name' => $setting->brand?->name,
                    'brand_logo' => $setting->brand?->logo,
                ],
                'is_protected' => false,
            ]);
        }

        $request->validate([
            'password' => ['required', 'string'],
        ]);

        if ($request->input('password') !== $setting->link_password) {
            return response()->json([
                'message' => 'Incorrect password.',
            ], 403);
        }

        return response()->json([
            'message' => 'Password validated successfully',
            'data' => [
                'brand_id' => $setting->brand_id,
                'brand_name' => $setting->brand?->name,
                'brand_logo' => $setting->brand?->logo,
            ],
            'is_protected' => false,
        ]);
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd api
git add app/Http/Controllers/Api/Share/BrandShareController.php
git commit -m "feat(api): add BrandShareController for public slug lookup and password validation"
```

---

## Task 4: Public Proxy Insight Controller

**Files:**
- Create: `api/app/Http/Controllers/Api/Share/BrandShareInsightController.php`

This controller validates the slug, extracts brand_id, then delegates to the same DataServiceClient + mapper services used by the existing internal controllers. Each method mirrors an existing internal controller method but skips user auth, using slug-based access instead.

Reference controllers for each method:
- Overview: `BrandInsightOverviewController` (`api/app/Http/Controllers/Api/Brand/BrandInsightOverviewController.php`)
- Campaign: `BrandInsightCampaignController` (`api/app/Http/Controllers/Api/Brand/BrandInsightCampaignController.php`)
- Paid Media: `BrandInsightPaidMediaController` (`api/app/Http/Controllers/Api/Brand/BrandInsightPaidMediaController.php`)
- Owned Media: `BrandInsightOwnedMediaController` (`api/app/Http/Controllers/Api/Brand/BrandInsightOwnedMediaController.php`)
- Earned Media: `BrandInsightEarnedMediaController` (`api/app/Http/Controllers/Api/Brand/BrandInsightEarnedMediaController.php`)
- ATL: `BrandInsightATLController` (`api/app/Http/Controllers/Api/Brand/BrandInsightATLController.php`)

- [ ] **Step 1: Create the proxy controller**

The controller needs to:
1. Resolve slug → `BrandShareSetting` → `Brand`
2. Call the same DataServiceClient methods as the internal controllers
3. Use the same mapper services to transform responses
4. Return the same data shape

```php
<?php
// api/app/Http/Controllers/Api/Share/BrandShareInsightController.php

namespace App\Http\Controllers\Api\Share;

use App\Contracts\DataServiceClientInterface;
use App\Data\BrandInsight\Overview\OverviewResource;
use App\Data\DataService\Overview\Response\OverviewDataResponse;
use App\Exceptions\DataParsingException;
use App\Exceptions\DataServiceException;
use App\Exceptions\DataServiceSchemaMissingException;
use App\Exceptions\DataServiceSchemaTypeException;
use App\Http\Controllers\Controller;
use App\Models\Brand;
use App\Models\BrandShareSetting;
use App\Services\BrandInsight\ATLMapperService;
use App\Services\BrandInsight\CampaignMapperService;
use App\Services\BrandInsight\EarnedMediaMapperService;
use App\Services\BrandInsight\OverviewMapperService;
use App\Services\BrandInsight\OwnedMediaMapperService;
use App\Services\BrandInsight\PaidMediaMapperService;
use Exception;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;

class BrandShareInsightController extends Controller
{
    public function __construct(
        protected DataServiceClientInterface $dataServiceClient,
        protected OverviewMapperService $overviewMapper,
        protected CampaignMapperService $campaignMapper,
        protected PaidMediaMapperService $paidMediaMapper,
        protected OwnedMediaMapperService $ownedMediaMapper,
        protected EarnedMediaMapperService $earnedMediaMapper,
        protected ATLMapperService $atlMapper,
    ) {}

    /**
     * Resolve slug to Brand, validating the share link is enabled.
     * Returns [setting, brand] or a JsonResponse error.
     */
    private function resolveSlug(string $slug): array|JsonResponse
    {
        $setting = BrandShareSetting::with('brand')->where('link_slug', $slug)->first();

        if (! $setting || ! $setting->link_enabled) {
            return response()->json([
                'message' => 'Share link not found or is no longer available.',
            ], 404);
        }

        $brand = $setting->brand;
        if (! $brand) {
            return response()->json([
                'message' => 'Brand not found.',
            ], 404);
        }

        return [$setting, $brand];
    }

    /**
     * Wrap DataServiceClient calls with standard exception handling.
     * Mirrors the try/catch pattern from BrandInsightOverviewController.
     */
    private function withExceptionHandling(string $section, string $brandId, callable $fn): JsonResponse
    {
        try {
            return $fn();
        } catch (DataServiceException $e) {
            Log::error("Data Service endpoint failed - {$section} (public share)", [
                'brand_id' => $brandId,
                'endpoint' => $e->getEndpoint(),
                'status_code' => $e->getStatusCode(),
            ]);
            return response()->json([
                'message' => 'Data Service endpoint failed.',
            ], 400);
        } catch (DataParsingException $e) {
            Log::error("Data parsing failed - {$section} (public share)", [
                'brand_id' => $brandId,
                'section' => $e->getSection(),
            ]);
            return response()->json([
                'message' => 'Failed to parse data.',
            ], 400);
        } catch (DataServiceSchemaTypeException|DataServiceSchemaMissingException $e) {
            Log::error("Data Service schema error - {$section} (public share)", [
                'brand_id' => $brandId,
                'section' => $e->getSection(),
            ]);
            return response()->json([
                'message' => 'Data format mismatch.',
            ], 400);
        } catch (Exception $e) {
            Log::error("Unexpected error - {$section} (public share)", [
                'brand_id' => $brandId,
                'error' => $e->getMessage(),
            ]);
            return response()->json([
                'message' => 'An unexpected error occurred.',
            ], 500);
        }
    }

    // ──────────────────────────────────────────────────────────
    // Each public method below mirrors the corresponding
    // internal controller. Read the internal controller's
    // index/overview/detail method and replicate the
    // DataServiceClient + Mapper calls here.
    //
    // The key difference: no user auth, no workspace check.
    // Brand is resolved via slug instead.
    // ──────────────────────────────────────────────────────────

    /**
     * Overview — mirrors BrandInsightOverviewController::index()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightOverviewController.php:34-138
     */
    public function overview(string $slug): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        return $this->withExceptionHandling('overview', $brand->id, function () use ($brand) {
            $response = $this->dataServiceClient->getOverview($brand->name, now()->year);
            $dsData = OverviewDataResponse::from($response['data']);
            $data = $this->overviewMapper->mapToOverviewData($dsData, $brand->logo, $brand->name);
            $resource = OverviewResource::fromData($data);

            return response()->json([
                'message' => 'Overview insights retrieved successfully',
                'data' => $resource->toArray(),
            ]);
        });
    }

    /**
     * Campaign — mirrors BrandInsightCampaignController::index()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightCampaignController.php
     *
     * IMPORTANT: Read the full BrandInsightCampaignController::index() method and
     * replicate the DataServiceClient + CampaignMapperService calls here.
     * Pass through all query params (campaign_name, year, etc.) from the request.
     */
    public function campaign(string $slug, Request $request): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        // Delegate to the internal controller's logic.
        // Instantiate and call the existing controller, passing brand_id.
        $controller = app(\App\Http\Controllers\Api\Brand\BrandInsightCampaignController::class);
        // We need to set the brand context on the request so the controller can find it.
        // Since the internal controller validates via workspace, we bypass by calling
        // the data service directly. Read BrandInsightCampaignController::index() for the exact calls.
        return $this->withExceptionHandling('campaign', $brand->id, function () use ($brand, $request) {
            $tower = $brand->name;
            $year = $request->input('year', now()->year);
            $campaignName = $request->input('campaign_name');

            $responses = $this->dataServiceClient->batchCampaignRequestsSmart($tower, $year, $campaignName);
            $data = $this->campaignMapper->mapToCampaignData($responses, $tower);

            return response()->json([
                'message' => 'Campaign insights retrieved successfully',
                'data' => $data->toArray(),
            ]);
        });
    }

    /**
     * Campaign filters — mirrors BrandInsightCampaignController::filters()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightCampaignController.php
     */
    public function campaignFilters(string $slug, Request $request): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        return $this->withExceptionHandling('campaign-filters', $brand->id, function () use ($brand, $request) {
            $tower = $brand->name;
            $year = $request->input('year', now()->year);
            $endDate = $request->input('end_date');

            $taxonomyResponse = $this->dataServiceClient->getPaidTaxonomy($tower, $year, $endDate);
            // Read BrandInsightCampaignController::filters() for exact mapping logic
            // and replicate the campaign filter transformation here.

            return response()->json([
                'message' => 'Campaign filters retrieved successfully',
                'data' => $taxonomyResponse['data'] ?? [],
            ]);
        });
    }

    /**
     * Paid Media Overview — mirrors BrandInsightPaidMediaController::overview()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightPaidMediaController.php
     */
    public function paidMediaOverview(string $slug, Request $request): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        return $this->withExceptionHandling('paid-media-overview', $brand->id, function () use ($brand, $request) {
            $tower = $brand->name;
            $year = $request->input('year', now()->year);
            $area = $request->input('area');

            // Read BrandInsightPaidMediaController::overview() for exact calls.
            // Replicate the DataServiceClient + PaidMediaMapperService logic.
            $response = $this->dataServiceClient->getPaidOverview($tower, $year, $area);
            $data = $this->paidMediaMapper->mapToPaidMediaOverviewData($response);

            return response()->json([
                'message' => 'Paid media overview retrieved successfully',
                'data' => $data->toArray(),
            ]);
        });
    }

    /**
     * Paid Media Detail — mirrors BrandInsightPaidMediaController::detail()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightPaidMediaController.php
     */
    public function paidMediaDetail(string $slug, Request $request): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        return $this->withExceptionHandling('paid-media-detail', $brand->id, function () use ($brand, $request) {
            $tower = $brand->name;
            // Pass through all filter query params from request.
            // Read BrandInsightPaidMediaController::detail() for exact calls
            // and replicate the batch request + mapper logic.
            $responses = $this->dataServiceClient->batchPaidMediaDetailRequests(
                $tower,
                $request->input('year', now()->year),
                $request->input('funnel'),
                $request->input('areas'),
                $request->input('campaigns'),
                $request->input('adsets'),
                $request->input('ads'),
                $request->input('start_date'),
                $request->input('end_date'),
            );
            $data = $this->paidMediaMapper->mapToPaidMediaDetailData($responses, $tower);

            return response()->json([
                'message' => 'Paid media detail retrieved successfully',
                'data' => $data->toArray(),
            ]);
        });
    }

    /**
     * Paid Media Filters — mirrors BrandInsightPaidMediaController::filters()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightPaidMediaController.php
     */
    public function paidMediaFilters(string $slug, Request $request): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        return $this->withExceptionHandling('paid-media-filters', $brand->id, function () use ($brand, $request) {
            $tower = $brand->name;
            $year = $request->input('year', now()->year);
            $endDate = $request->input('end_date');

            $taxonomyResponse = $this->dataServiceClient->getPaidTaxonomy($tower, $year, $endDate);

            return response()->json([
                'message' => 'Paid media filters retrieved successfully',
                'data' => $taxonomyResponse['data'] ?? [],
            ]);
        });
    }

    /**
     * Owned Media Overview — mirrors BrandInsightOwnedMediaController::overview()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightOwnedMediaController.php
     */
    public function ownedMediaOverview(string $slug, Request $request): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        return $this->withExceptionHandling('owned-media-overview', $brand->id, function () use ($brand, $request) {
            $tower = $brand->name;
            // Read BrandInsightOwnedMediaController::overview() for exact calls.
            $response = $this->dataServiceClient->getOwnedOverview($tower);
            $data = $this->ownedMediaMapper->mapToOwnedMediaOverviewData($response);

            return response()->json([
                'message' => 'Owned media overview retrieved successfully',
                'data' => $data->toArray(),
            ]);
        });
    }

    /**
     * Owned Media Detail — mirrors BrandInsightOwnedMediaController::detail()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightOwnedMediaController.php
     */
    public function ownedMediaDetail(string $slug, Request $request): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        return $this->withExceptionHandling('owned-media-detail', $brand->id, function () use ($brand, $request) {
            $tower = $brand->name;
            // Read BrandInsightOwnedMediaController::detail() for exact calls.
            // Pass through start_date, end_date from request.
            $responses = $this->dataServiceClient->batchOwnedMediaDetailRequests(
                $tower,
                $request->input('start_date'),
                $request->input('end_date'),
            );
            $data = $this->ownedMediaMapper->mapToOwnedMediaDetailData($responses, $tower);

            return response()->json([
                'message' => 'Owned media detail retrieved successfully',
                'data' => $data->toArray(),
            ]);
        });
    }

    /**
     * Owned Media Filters — mirrors BrandInsightOwnedMediaController::filters()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightOwnedMediaController.php
     */
    public function ownedMediaFilters(string $slug, Request $request): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        return $this->withExceptionHandling('owned-media-filters', $brand->id, function () use ($brand, $request) {
            $tower = $brand->name;
            $response = $this->dataServiceClient->getOwnedTaxonomy($tower);

            return response()->json([
                'message' => 'Owned media filters retrieved successfully',
                'data' => $response['data'] ?? [],
            ]);
        });
    }

    /**
     * Earned Media — mirrors BrandInsightEarnedMediaController::index()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightEarnedMediaController.php
     */
    public function earnedMedia(string $slug, Request $request): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        return $this->withExceptionHandling('earned-media', $brand->id, function () use ($brand, $request) {
            $tower = $brand->name;
            // Read BrandInsightEarnedMediaController::index() for exact calls.
            $responses = $this->dataServiceClient->batchEarnedMediaDetailRequests($tower);
            $data = $this->earnedMediaMapper->mapToEarnedMediaData($responses, $tower);

            return response()->json([
                'message' => 'Earned media insights retrieved successfully',
                'data' => $data->toArray(),
            ]);
        });
    }

    /**
     * Earned Media Influencers — mirrors BrandInsightEarnedMediaController::influencerDetail()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightEarnedMediaController.php
     */
    public function earnedMediaInfluencers(string $slug, Request $request): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        return $this->withExceptionHandling('earned-media-influencers', $brand->id, function () use ($brand) {
            $tower = $brand->name;
            // Read BrandInsightEarnedMediaController::influencerDetail() for exact calls.
            $response = $this->dataServiceClient->getEarnedInfluencerList($tower);

            return response()->json([
                'message' => 'Earned media influencers retrieved successfully',
                'data' => $response['data'] ?? [],
            ]);
        });
    }

    /**
     * Earned Media Filters — mirrors BrandInsightEarnedMediaController::filters()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightEarnedMediaController.php
     */
    public function earnedMediaFilters(string $slug, Request $request): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        return $this->withExceptionHandling('earned-media-filters', $brand->id, function () use ($brand) {
            $tower = $brand->name;
            $response = $this->dataServiceClient->getEarnedTaxonomy($tower);

            return response()->json([
                'message' => 'Earned media filters retrieved successfully',
                'data' => $response['data'] ?? [],
            ]);
        });
    }

    /**
     * ATL Overview — mirrors BrandInsightATLController::overview()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightATLController.php
     */
    public function atlOverview(string $slug, Request $request): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        return $this->withExceptionHandling('atl-overview', $brand->id, function () use ($brand) {
            $tower = $brand->name;
            // Read BrandInsightATLController::overview() for exact calls.
            $response = $this->dataServiceClient->getATLOverview($tower);
            $data = $this->atlMapper->mapToATLOverviewData($response);

            return response()->json([
                'message' => 'ATL overview retrieved successfully',
                'data' => $data->toArray(),
            ]);
        });
    }

    /**
     * ATL Detail — mirrors BrandInsightATLController::detail()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightATLController.php
     */
    public function atlDetail(string $slug, Request $request): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        return $this->withExceptionHandling('atl-detail', $brand->id, function () use ($brand, $request) {
            $tower = $brand->name;
            // Read BrandInsightATLController::detail() for exact calls.
            // Pass through media_types, start_date, end_date from request.
            $responses = $this->dataServiceClient->batchATLRequests(
                $tower,
                $request->input('media_types'),
                $request->input('start_date'),
                $request->input('end_date'),
            );
            $data = $this->atlMapper->mapToATLDetailData($responses, $tower);

            return response()->json([
                'message' => 'ATL detail retrieved successfully',
                'data' => $data->toArray(),
            ]);
        });
    }

    /**
     * ATL Filters — mirrors BrandInsightATLController::filters()
     * Reference: api/app/Http/Controllers/Api/Brand/BrandInsightATLController.php
     */
    public function atlFilters(string $slug, Request $request): JsonResponse
    {
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) return $resolved;
        [$setting, $brand] = $resolved;

        return $this->withExceptionHandling('atl-filters', $brand->id, function () use ($brand) {
            $tower = $brand->name;
            $response = $this->dataServiceClient->getATLTaxonomy($tower);

            return response()->json([
                'message' => 'ATL filters retrieved successfully',
                'data' => $response['data'] ?? [],
            ]);
        });
    }
}
```

**IMPORTANT NOTE FOR IMPLEMENTER:** The method bodies above are approximations based on the patterns visible in the Overview controller. Before implementing each method, you **MUST** read the corresponding internal controller's method to get the exact DataServiceClient calls, parameter names, mapper method signatures, and DTO types. The internal controllers are the source of truth. Key files to reference:

- `api/app/Http/Controllers/Api/Brand/BrandInsightCampaignController.php` → `index()`, `filters()`
- `api/app/Http/Controllers/Api/Brand/BrandInsightPaidMediaController.php` → `overview()`, `detail()`, `filters()`
- `api/app/Http/Controllers/Api/Brand/BrandInsightOwnedMediaController.php` → `overview()`, `detail()`, `filters()`
- `api/app/Http/Controllers/Api/Brand/BrandInsightEarnedMediaController.php` → `index()`, `influencerDetail()`, `filters()`
- `api/app/Http/Controllers/Api/Brand/BrandInsightATLController.php` → `overview()`, `detail()`, `filters()`

For each, copy the data-fetching and mapping logic, removing only the user/workspace auth checks and replacing them with the `resolveSlug()` call.

- [ ] **Step 2: Commit**

```bash
cd api
git add app/Http/Controllers/Api/Share/BrandShareInsightController.php
git commit -m "feat(api): add BrandShareInsightController with public proxy endpoints for all insight tabs"
```

---

## Task 5: Register Routes

**Files:**
- Modify: `api/routes/api.php:115-117` (near existing RAFI share routes)
- Modify: `api/routes/api.php:286` (near existing brand insight routes)

- [ ] **Step 1: Add public share routes**

After the existing RAFI share routes (line 117 in `api/routes/api.php`), add:

```php
// Public Brand Share Link (no authentication required)
Route::get('share/brand/{slug}', [BrandShareController::class, 'show']);
Route::post('share/brand/{slug}', [BrandShareController::class, 'validatePassword']);

// Public Brand Share Insight Proxy (no authentication required)
Route::prefix('share/brand/{slug}/insight')->group(function () {
    Route::get('/overview', [BrandShareInsightController::class, 'overview']);
    Route::get('/campaign', [BrandShareInsightController::class, 'campaign']);
    Route::get('/campaign/filters', [BrandShareInsightController::class, 'campaignFilters']);
    Route::get('/paid-media/overview', [BrandShareInsightController::class, 'paidMediaOverview']);
    Route::get('/paid-media/detail', [BrandShareInsightController::class, 'paidMediaDetail']);
    Route::get('/paid-media/filters', [BrandShareInsightController::class, 'paidMediaFilters']);
    Route::get('/owned-media/overview', [BrandShareInsightController::class, 'ownedMediaOverview']);
    Route::get('/owned-media/detail', [BrandShareInsightController::class, 'ownedMediaDetail']);
    Route::get('/owned-media/filters', [BrandShareInsightController::class, 'ownedMediaFilters']);
    Route::get('/earned-media', [BrandShareInsightController::class, 'earnedMedia']);
    Route::get('/earned-media/influencers', [BrandShareInsightController::class, 'earnedMediaInfluencers']);
    Route::get('/earned-media/filters', [BrandShareInsightController::class, 'earnedMediaFilters']);
    Route::get('/atl/overview', [BrandShareInsightController::class, 'atlOverview']);
    Route::get('/atl/detail', [BrandShareInsightController::class, 'atlDetail']);
    Route::get('/atl/filters', [BrandShareInsightController::class, 'atlFilters']);
});
```

- [ ] **Step 2: Add authenticated settings routes**

Inside the protected route group (near line 286 in `api/routes/api.php`), within the `brands/{brand_id}/insight` prefix, add:

```php
// Brand Share Settings (public link management)
Route::get('/share/settings', [BrandShareSettingController::class, 'index'])
    ->middleware('permissions:brand.insight.read');
Route::patch('/share/settings', [BrandShareSettingController::class, 'update'])
    ->middleware('permissions:brand.insight.read');
```

- [ ] **Step 3: Add use statements at the top of api/routes/api.php**

```php
use App\Http\Controllers\Api\Share\BrandShareController;
use App\Http\Controllers\Api\Share\BrandShareInsightController;
use App\Http\Controllers\Api\Brand\BrandShareSettingController;
```

- [ ] **Step 4: Verify routes are registered**

Run: `cd api && php artisan route:list --path=share/brand`
Expected: All public share routes listed.

Run: `cd api && php artisan route:list --path=insight/share`
Expected: Authenticated settings routes listed.

- [ ] **Step 5: Commit**

```bash
cd api
git add routes/api.php
git commit -m "feat(api): register brand share public and settings routes"
```

---

## Task 6: FE — Types + Service Functions

**Files:**
- Modify: `web/src/services/query.ts`
- Modify: `web/src/services/mutate.ts`

- [ ] **Step 1: Add query functions to `web/src/services/query.ts`**

Add near the existing RAFI share functions (around line 1497):

```typescript
// ─── Brand Public Share ────────────────────────────────────

export interface BrandShareInfoResponse {
  message: string;
  data: {
    brand_id: string;
    brand_name: string;
    brand_logo: string | null;
  };
  is_protected: boolean;
}

export interface BrandShareSettingsResponse {
  message: string;
  data: {
    link: {
      enable: boolean;
      url: string;
      is_protected: boolean;
    };
  };
}

// Public (no auth)
export const getBrandShareInfo = async (slug: string): Promise<BrandShareInfoResponse> => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}`);
  return data;
};

// Public proxy endpoints — same data shape as internal endpoints
export const getBrandShareOverview = async (slug: string) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/overview`);
  return data;
};

export const getBrandShareCampaign = async (slug: string, params?: Record<string, unknown>) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/campaign`, { params });
  return data;
};

export const getBrandShareCampaignFilters = async (slug: string, params?: Record<string, unknown>) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/campaign/filters`, { params });
  return data;
};

export const getBrandSharePaidMediaOverview = async (slug: string, params?: Record<string, unknown>) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/paid-media/overview`, { params });
  return data;
};

export const getBrandSharePaidMediaDetail = async (slug: string, params?: Record<string, unknown>) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/paid-media/detail`, { params });
  return data;
};

export const getBrandSharePaidMediaFilters = async (slug: string, params?: Record<string, unknown>) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/paid-media/filters`, { params });
  return data;
};

export const getBrandShareOwnedMediaOverview = async (slug: string, params?: Record<string, unknown>) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/owned-media/overview`, { params });
  return data;
};

export const getBrandShareOwnedMediaDetail = async (slug: string, params?: Record<string, unknown>) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/owned-media/detail`, { params });
  return data;
};

export const getBrandShareOwnedMediaFilters = async (slug: string, params?: Record<string, unknown>) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/owned-media/filters`, { params });
  return data;
};

export const getBrandShareEarnedMedia = async (slug: string, params?: Record<string, unknown>) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/earned-media`, { params });
  return data;
};

export const getBrandShareEarnedMediaInfluencers = async (slug: string, params?: Record<string, unknown>) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/earned-media/influencers`, { params });
  return data;
};

export const getBrandShareEarnedMediaFilters = async (slug: string, params?: Record<string, unknown>) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/earned-media/filters`, { params });
  return data;
};

export const getBrandShareATLOverview = async (slug: string, params?: Record<string, unknown>) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/atl/overview`, { params });
  return data;
};

export const getBrandShareATLDetail = async (slug: string, params?: Record<string, unknown>) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/atl/detail`, { params });
  return data;
};

export const getBrandShareATLFilters = async (slug: string, params?: Record<string, unknown>) => {
  const { data } = await axiosPublic.get(`v1/share/brand/${slug}/insight/atl/filters`, { params });
  return data;
};

// Authenticated — for the settings modal
export const getBrandShareSettings = async (brandId: string): Promise<BrandShareSettingsResponse> => {
  const { data } = await axiosInstance.get(`v1/brands/${brandId}/insight/share/settings`);
  return data;
};
```

**NOTE:** Check if `axiosPublic` (an axios instance without auth headers) already exists in the services. If not, create one — the RAFI share page uses `getRafiShareLink` which should show the pattern. If it uses the regular `axiosInstance`, check how auth is handled for public routes.

- [ ] **Step 2: Add mutation functions to `web/src/services/mutate.ts`**

Add near the existing RAFI mutation functions (around line 1692):

```typescript
// ─── Brand Public Share ────────────────────────────────────

export interface BrandShareSettingsPayload {
  link: {
    enable: boolean;
    password?: string | null;
  };
}

export const mutateUpdateBrandShareSettings = async (
  brandId: string,
  payload: BrandShareSettingsPayload
) => {
  const { data } = await axiosInstance.patch(
    `v1/brands/${brandId}/insight/share/settings`,
    payload
  );
  return data;
};

export const mutateBrandSharePassword = async (slug: string, password: string) => {
  const { data } = await axiosPublic.post(`v1/share/brand/${slug}`, { password });
  return data;
};
```

- [ ] **Step 3: Commit**

```bash
cd web
git add src/services/query.ts src/services/mutate.ts
git commit -m "feat(web): add brand share query and mutation service functions"
```

---

## Task 7: FE — PublicShareContext

**Files:**
- Create: `web/src/contexts/PublicShareContext.tsx`

This context provides the slug and `isPublicView` flag to all child components, enabling them to conditionally hide restricted UI elements and use public API endpoints.

- [ ] **Step 1: Create the context**

```tsx
// web/src/contexts/PublicShareContext.tsx
"use client";

import { createContext, useContext, ReactNode } from "react";

interface PublicShareContextType {
  slug: string;
  brandId: string;
  brandName: string;
  brandLogo: string | null;
  isPublicView: true;
}

const PublicShareContext = createContext<PublicShareContextType | null>(null);

export const usePublicShare = () => useContext(PublicShareContext);

/**
 * Returns true if we are inside a public share view.
 * Safe to call from any component — returns false outside PublicShareContext.
 */
export const useIsPublicView = (): boolean => {
  const ctx = useContext(PublicShareContext);
  return ctx?.isPublicView ?? false;
};

interface PublicShareProviderProps {
  slug: string;
  brandId: string;
  brandName: string;
  brandLogo: string | null;
  children: ReactNode;
}

export const PublicShareProvider = ({
  slug,
  brandId,
  brandName,
  brandLogo,
  children,
}: PublicShareProviderProps) => {
  return (
    <PublicShareContext.Provider
      value={{ slug, brandId, brandName, brandLogo, isPublicView: true }}
    >
      {children}
    </PublicShareContext.Provider>
  );
};
```

- [ ] **Step 2: Commit**

```bash
cd web
git add src/contexts/PublicShareContext.tsx
git commit -m "feat(web): add PublicShareContext for public share view state"
```

---

## Task 8: FE — Public Share Layout + Password Wall

**Files:**
- Create: `web/src/app/share/brand/[slug]/layout.tsx`

This layout handles: slug lookup, password wall (if protected), tab navigation, and wrapping children in `PublicShareProvider`.

Reference: `web/src/app/rafi/share/[id]/page.tsx` for the RAFI share page pattern.

- [ ] **Step 1: Create the layout**

```tsx
// web/src/app/share/brand/[slug]/layout.tsx
"use client";

import { useState, ReactNode } from "react";
import { useParams, useRouter, usePathname } from "next/navigation";
import { useQuery, useMutation } from "@tanstack/react-query";
import { WallAccess, PageLoader } from "@/components/base";
import { getBrandShareInfo } from "@/services/query";
import { mutateBrandSharePassword } from "@/services/mutate";
import { PublicShareProvider } from "@/contexts/PublicShareContext";
import { AxiosError } from "axios";
import TabsLine from "@/components/frndos/TabsLine";

const TABS = [
  { id: "overview", name: "Overview", path: "" },
  { id: "campaigns", name: "Campaigns", path: "/campaigns" },
  { id: "paid-media", name: "Paid Media", path: "/paid-media" },
  { id: "owned-media", name: "Owned Media", path: "/owned-media" },
  { id: "earned-media", name: "Earned Media", path: "/earned-media" },
  { id: "atl", name: "ATL", path: "/atl" },
];

export default function BrandShareLayout({ children }: { children: ReactNode }) {
  const params = useParams();
  const router = useRouter();
  const pathname = usePathname();
  const slug = params.slug as string;

  const [isAuthenticated, setIsAuthenticated] = useState(false);

  const { data, isLoading, isError } = useQuery({
    queryKey: ["brand-share-info", slug],
    queryFn: () => getBrandShareInfo(slug),
    retry: false,
    enabled: !!slug,
  });

  const isProtected = data?.is_protected ?? false;
  const brandId = data?.data?.brand_id ?? "";
  const brandName = data?.data?.brand_name ?? "";
  const brandLogo = data?.data?.brand_logo ?? null;

  const passwordMutation = useMutation({
    mutationFn: (password: string) => mutateBrandSharePassword(slug, password),
    onSuccess: () => {
      setIsAuthenticated(true);
    },
  });

  if (isError) {
    router.push("/login");
    return null;
  }

  if (isLoading) {
    return (
      <div className="flex h-screen w-full items-center justify-center">
        <PageLoader variant="minimal" />
      </div>
    );
  }

  if (isProtected && !isAuthenticated) {
    return (
      <WallAccess
        onSubmit={(password) => passwordMutation.mutate(password)}
        isLoading={passwordMutation.isPending}
        errorMessage={
          passwordMutation.error
            ? (passwordMutation.error as AxiosError<{ message: string }>)
                ?.response?.data?.message || "Incorrect password."
            : undefined
        }
      />
    );
  }

  // Determine active tab from pathname
  const basePath = `/share/brand/${slug}`;
  const relativePath = pathname.replace(basePath, "") || "";
  const activeTab = TABS.find((tab) => tab.path === relativePath)?.id ?? "overview";

  const handleTabChange = (tabId: string) => {
    const tab = TABS.find((t) => t.id === tabId);
    if (tab) {
      router.push(`${basePath}${tab.path}`);
    }
  };

  return (
    <PublicShareProvider
      slug={slug}
      brandId={brandId}
      brandName={brandName}
      brandLogo={brandLogo}
    >
      <main className="bg-new-dark relative flex h-screen w-full flex-col overflow-hidden">
        {/* Header */}
        <div className="flex items-center gap-3 border-b border-white/10 px-6 py-4">
          {brandLogo && (
            <img src={brandLogo} alt={brandName} className="h-8 w-8 rounded-full" />
          )}
          <h1 className="text-lg font-semibold text-white">{brandName}</h1>
        </div>

        {/* Tab Navigation */}
        <div className="border-b border-white/10 px-6">
          <TabsLine
            tabs={TABS.map((t) => ({ id: t.id, name: t.name }))}
            activeTab={activeTab}
            onTabChange={handleTabChange}
          />
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto">
          {children}
        </div>
      </main>
    </PublicShareProvider>
  );
}
```

- [ ] **Step 2: Commit**

```bash
cd web
git add src/app/share/brand/\[slug\]/layout.tsx
git commit -m "feat(web): add public share layout with password wall and tab navigation"
```

---

## Task 9: FE — Public Share Tab Pages

**Files:**
- Create: `web/src/app/share/brand/[slug]/page.tsx`
- Create: `web/src/app/share/brand/[slug]/campaigns/page.tsx`
- Create: `web/src/app/share/brand/[slug]/paid-media/page.tsx`
- Create: `web/src/app/share/brand/[slug]/owned-media/page.tsx`
- Create: `web/src/app/share/brand/[slug]/earned-media/page.tsx`
- Create: `web/src/app/share/brand/[slug]/atl/page.tsx`

Each page uses `usePublicShare()` to get the slug, then calls the public proxy query functions and passes data to the existing presentational components.

**IMPORTANT FOR IMPLEMENTER:** Before implementing each page, read the corresponding internal page to understand:
1. Which hooks it uses (e.g., `useOverviewData`, `usePaidMediaData`)
2. What presentational components it renders
3. What props those components expect

Then create a similar page that uses the public share query functions instead.

- [ ] **Step 1: Create overview page (default tab)**

```tsx
// web/src/app/share/brand/[slug]/page.tsx
"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicShare } from "@/contexts/PublicShareContext";
import { getBrandShareOverview } from "@/services/query";
import { PageLoader } from "@/components/base";
// Import the same presentational component used by the internal overview page.
// Reference: web/src/app/(dashboard)/brands/[id]/page.tsx
// The exact import depends on how OverviewContent is exported.
// Read the internal page to find the correct component.
import BrandInsightsOverview from "@/components/brands/BrandInsightsOverview";

export default function PublicShareOverviewPage() {
  const ctx = usePublicShare();
  if (!ctx) return null;

  const { slug } = ctx;

  const { data, isLoading } = useQuery({
    queryKey: ["brand-share-overview", slug],
    queryFn: () => getBrandShareOverview(slug),
    retry: false,
  });

  if (isLoading) {
    return (
      <div className="flex h-64 items-center justify-center">
        <PageLoader variant="minimal" />
      </div>
    );
  }

  if (!data?.data) return null;

  // Pass data to the same presentational component as the internal page.
  // Read web/src/app/(dashboard)/brands/[id]/page.tsx to see the exact
  // prop mapping from API response → component props.
  return (
    <div className="p-6">
      <BrandInsightsOverview
        dailyBrandSummary={data.data.dailyBrandSummary}
        kpiCards={data.data.kpiCards}
        statCards={data.data.statCards}
      />
    </div>
  );
}
```

- [ ] **Step 2: Create remaining tab pages**

Create each tab page following the same pattern. For each:
1. Read the internal page at `web/src/app/(dashboard)/brands/[id]/<tab>/page.tsx`
2. Find which component it renders and what props it needs
3. Create the public version using `getBrandShare*` query functions

Files to create:
- `web/src/app/share/brand/[slug]/campaigns/page.tsx` — reference: `web/src/app/(dashboard)/brands/[id]/campaigns/page.tsx`
- `web/src/app/share/brand/[slug]/paid-media/page.tsx` — reference: `web/src/app/(dashboard)/brands/[id]/paid-media/page.tsx`
- `web/src/app/share/brand/[slug]/owned-media/page.tsx` — reference: `web/src/app/(dashboard)/brands/[id]/owned-media/page.tsx`
- `web/src/app/share/brand/[slug]/earned-media/page.tsx` — reference: `web/src/app/(dashboard)/brands/[id]/earned-media/page.tsx`
- `web/src/app/share/brand/[slug]/atl/page.tsx` — reference: `web/src/app/(dashboard)/brands/[id]/atl/page.tsx`

Each page follows the same structure:
```tsx
"use client";
import { useQuery } from "@tanstack/react-query";
import { usePublicShare } from "@/contexts/PublicShareContext";
import { getBrandShare<Tab> } from "@/services/query";
import { PageLoader } from "@/components/base";
import <TabComponent> from "@/components/brands/<TabComponent>";

export default function PublicShare<Tab>Page() {
  const ctx = usePublicShare();
  if (!ctx) return null;
  const { slug } = ctx;

  const { data, isLoading } = useQuery({
    queryKey: ["brand-share-<tab>", slug],
    queryFn: () => getBrandShare<Tab>(slug),
    retry: false,
  });

  if (isLoading) return <PageLoader />;
  if (!data?.data) return null;

  return (
    <div className="p-6">
      <TabComponent {...mapDataToProps(data.data)} />
    </div>
  );
}
```

- [ ] **Step 3: Commit**

```bash
cd web
git add src/app/share/brand/
git commit -m "feat(web): add public share tab pages for all brand insight tabs"
```

---

## Task 10: FE — Share Modal on Brand Insights Page

**Files:**
- Modify: `web/src/components/brands/BrandInsightLayoutWrapper.tsx`

The existing layout wrapper already has a share icon (ShareIcon import at line 19). We need to wire it to open a share settings modal.

- [ ] **Step 1: Identify where the share icon is rendered**

Read `BrandInsightLayoutWrapper.tsx` fully and find where the `ShareIcon` is rendered (likely near `PencilIcon` and `Cog6ToothIcon`). The share icon handler needs to open a modal.

- [ ] **Step 2: Add share settings modal**

Reuse the same modal pattern from the RAFI `SettingsModal` component (`web/src/app/(dashboard)/brands/rafi/components/SettingsModal.tsx`), but with only the "Share Reports" tab (no "Mail Setup" tab for V1.0).

The modal should:
- Fetch share settings via `getBrandShareSettings(brandId)`
- Display toggle for "Share link publicly"
- Display shareable link with copy button
- Display password field with set/reset
- Save via `mutateUpdateBrandShareSettings(brandId, payload)`

**Implementation approach:** Either:
1. Create a new `BrandShareModal.tsx` component in `web/src/components/brands/` — simpler, no risk of breaking RAFI
2. Or extract the share tab from `SettingsModal.tsx` into a reusable component — DRY but requires touching RAFI code

Option 1 is safer for V1.0. Read the RAFI `SettingsModal.tsx` (lines 195-310 for the share tab) and replicate just the share portion.

- [ ] **Step 3: Wire the share icon click to open the modal**

In `BrandInsightLayoutWrapper.tsx`, add state for modal visibility and pass the open handler to the share icon's onClick.

- [ ] **Step 4: Commit**

```bash
cd web
git add src/components/brands/BrandShareModal.tsx src/components/brands/BrandInsightLayoutWrapper.tsx
git commit -m "feat(web): add brand share settings modal to insights layout"
```

---

## Task 11: FE — Hide Restricted UI in Public View

**Files:**
- Modify: `web/src/components/brands/BrandInsightLayoutWrapper.tsx`

- [ ] **Step 1: Add `isPublicView` checks**

In `BrandInsightLayoutWrapper.tsx`, use the `useIsPublicView()` hook to conditionally hide:

```tsx
import { useIsPublicView } from "@/contexts/PublicShareContext";

// Inside the component:
const isPublicView = useIsPublicView();
```

Hide the following when `isPublicView` is true:
- Share icon (`ShareIcon`)
- Edit/pencil icon (`PencilIcon`)
- Settings gear icon (`Cog6ToothIcon`)
- Ask FRND button (`AskFRNDButton`)
- Any export/download buttons

Keep visible:
- Tab navigation
- All charts, tables, metrics
- Filter controls (date range, campaign selector)
- Brand name/logo

- [ ] **Step 2: Check individual tab components for export buttons**

Search each tab component for export/download functionality:
```bash
cd web && grep -rn "export\|download\|Export\|Download" src/components/brands/ --include="*.tsx" -l
```

For any component that has export buttons, add `isPublicView` checks to hide them. The `useIsPublicView()` hook works from any component inside the `PublicShareProvider`.

- [ ] **Step 3: Commit**

```bash
cd web
git add -A
git commit -m "feat(web): hide export, Ask FRND, settings icons in public share view"
```

---

## Task 12: Verification

- [ ] **Step 1: Run API migration and verify routes**

```bash
cd api
php artisan migrate
php artisan route:list --path=share/brand
php artisan route:list --path=insight/share
```

- [ ] **Step 2: Build frontend**

```bash
cd web
bun run build
```

Expected: No TypeScript errors, build succeeds.

- [ ] **Step 3: Manual E2E test**

1. Start all services: `./run-all.sh`
2. Log in to the dashboard, navigate to a brand's insights page
3. Click the share icon → settings modal opens
4. Enable "Share link publicly" → save
5. Copy the shareable link
6. Open the link in an incognito window
7. Verify: all tabs load with live data, no auth required
8. Verify: no export buttons, no Ask FRND, no settings/edit icons
9. Test password protection: set a password, save, re-open incognito → password wall appears
10. Enter correct password → all tabs accessible
11. Enter wrong password → 403 error shown

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat: complete brand-level public share link feature (V1.0)"
```
