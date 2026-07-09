# Superadmin Tiered Video Pricing — Design

> **Status:** design (approved in brainstorming 2026-07-09)
> **Author:** daffa
> **Type:** superadmin feature (model catalog)
> **Services:** api, web
> **Depends on:** dimension-aware video pricing (`2026-07-06-video-dynamic-pricing-design.md`), superadmin Models Settings feature (`model_settings` table)

## Overview

The superadmin "Add model" form can only express a **flat** per-second price for video
models (`metadataRules` video block: `type=per_second` + `price_per_second`). But video
pricing is now **dimension-tiered** (Seedance `resolution × video_in`, Kling
`mode × audio`, Veo/Sora-pro `resolution`), and that tiering is **exclusive to the
hardcoded `LLMHelper::MODELS` registry** — a superadmin cannot create a tiered custom
video model without a code change.

This adds **preset-based tiered pricing** to the Add-model flow so a superadmin can
register a tiered video model self-service. The pricing **resolver is unchanged** — it
already consumes `priced_on` / `rates` / `fallback_per_second` from the merged registry
(custom models supply pricing via the `model_settings.pricing` JSON column, which the
resolver reads transparently).

## Current mechanism (verified)

- `LLMHelper::registry()` = hardcoded `MODELS` **+** `getCustomModelEntries()` (DB rows
  where `is_custom`, mapping `model_settings.pricing` JSON straight into the entry).
- `PricingHelper::calculateVideoCost` → `resolveVideoUnitRate` → `LLMHelper::getVideoPricing`
  reads `$model['pricing']` from the merged registry — so a custom model's DB `pricing`
  JSON flows through unchanged. **The resolver already handles `fixed`, flat `per_second`,
  and tiered `per_second` (priced_on + rates + fallback).**
- `AdminModelSettingController::store` → `buildCustomPricing` writes the `pricing` JSON.
  Today the video branch only writes `{type: per_second, price_per_second}`.
- Model values are **globally unique** across the registry, so there's no code-vs-custom
  pricing conflict — a value is either hardcoded or custom.

So the only gap is **expressive**: the writer (`metadataRules` + `buildCustomPricing`)
and the web form can't produce a tiered `pricing` JSON. The storage and resolver already
can.

## Decisions (locked in brainstorming)

- **Preset pricing shapes**, not a generic matrix builder — match real vendor shapes,
  hard to produce an invalid matrix.
- **Provider-aware presets** — the offered presets are constrained by the selected
  provider, so an admin can't pick a shape whose dimensions ai-service doesn't report for
  that provider.
- **`fallback_per_second` auto = highest entered rate** (conservative, never undercharge;
  matches the hardcoded tables), shown read-only.
- **Web sends structured tiers; the API builds the `rates` keys** — key format lives in
  one place (a shared `PricingHelper` helper mirroring `normalizeDim`), so the resolver
  and writer never diverge.
- **Resolver unchanged.** No `PricingHelper::resolveVideoUnitRate` / `calculateVideoCost`
  logic change.
- **Safe degradation** relied upon: if a charge-time dimension is missing/unknown, the
  resolver already falls back to `fallback_per_second` (highest tier) — over-charge at
  worst, never under-charge or crash.

## Presets and provider mapping

| Preset | `pricing` shape | Providers offered on |
|---|---|---|
| **Flat** | `{type: per_second, price_per_second}` | all (safe default) |
| **Fixed** | `{type: fixed, fixed_price}` | tencent |
| **Resolution** | `{type: per_second, priced_on: [resolution], rates, fallback_per_second}` | google, openai |
| **Resolution × video-in** | `{type: per_second, priced_on: [resolution, video_in], rates, fallback_per_second}` | bytedance |
| **Mode × audio** | `{type: per_second, priced_on: [mode, audio], rates, fallback_per_second}` | kuaishou |

Dimension value sets offered in the editor:
- `resolution`: `480p`, `720p`, `1080p`, `4k` (admin selects which apply)
- `video_in`: the two tiers `video_in` / `default` (a real reference-video vs not)
- `mode`: `standard`, `pro`, `4k` (admin selects which apply)
- `audio`: the two tiers `audio` / `default`

## Rate-key format (single-source)

The resolver keys `rates` by joining `normalizeDim` tokens with `|`, in `priced_on` order:
- `resolution` → the literal value (`1080p`)
- `video_in` → `video_in` if true else `default`
- `mode` → the literal value (`pro`)
- `audio` → `audio` if true else `default`

Examples: `1080p|video_in`, `1080p|default`, `pro|audio`, `standard|default`, `4k`.

**Refactor:** extract the per-dimension token mapping into a public
`PricingHelper::videoRateKey(array $pricedOn, array $dims): string` used by BOTH
`normalizeDim` (resolve time) and `buildCustomPricing` (write time). This guarantees the
keys written by the form match the keys the resolver looks up — no divergence.

## Data flow

**Web → API payload (structured tiers, not pre-built keys):**
```json
{
  "name": "Seedance 3.0", "model_id": "seedance-3.0", "model_provider": "bytedance",
  "model_type": "video",
  "pricing": {
    "type": "per_second",
    "priced_on": ["resolution", "video_in"],
    "tiers": [
      {"dims": {"resolution": "1080p", "video_in": true},  "rate": 0.60},
      {"dims": {"resolution": "1080p", "video_in": false}, "rate": 0.50},
      {"dims": {"resolution": "720p",  "video_in": true},  "rate": 0.25},
      {"dims": {"resolution": "720p",  "video_in": false}, "rate": 0.20}
    ]
  }
}
```

**API builds the stored `pricing` JSON:**
```json
{
  "type": "per_second",
  "priced_on": ["resolution", "video_in"],
  "rates": { "1080p|video_in": 0.60, "1080p|default": 0.50, "720p|video_in": 0.25, "720p|default": 0.20 },
  "fallback_per_second": 0.60
}
```
`rates` keys built via `videoRateKey`; `fallback_per_second` = `max(rate)`.

## API changes (`AdminModelSettingController` + `PricingHelper`)

- **`metadataRules` video block** — accept three shapes:
  - `pricing.type in [per_second, fixed]`.
  - `fixed` → `pricing.fixed_price required|numeric|min:0`.
  - `per_second` flat → `pricing.price_per_second required|numeric|min:0` (when no
    `priced_on`).
  - `per_second` tiered → `pricing.priced_on` (array, subset of the provider's allowed
    dims), `pricing.tiers` (non-empty array of `{dims, rate}`), each `rate numeric|min:0`;
    validate the tier set is **complete** for the selected dimension values (no blank
    combos) and dims match `priced_on`.
- **Provider ↔ preset guard** — reject a tiered `priced_on` the selected
  `model_provider` doesn't support (per the mapping table above). A small
  `provider → allowed pricing shapes` config, referenced by validation and returned to
  the web form so it can render the right presets.
- **`buildCustomPricing` video branch** — build the shape:
  - `fixed` → `{type: fixed, fixed_price}`.
  - flat → `{type: per_second, price_per_second}` (unchanged).
  - tiered → `{type: per_second, priced_on, rates: <built via videoRateKey>,
    fallback_per_second: max(rate)}`.
- **`UpdateCustomModelAction`** — same tiered build on edit (full-replace of `pricing`
  JSON, as today).
- **Free-model default** — a free video model stays `{type: per_second,
  price_per_second: 0.0}` (flat, unchanged).

## Web changes (Add-model / edit-model form)

- When `model_type = video`, after selecting **Provider**, show a **Pricing shape**
  dropdown populated with only that provider's allowed presets (from the API config).
- **Flat / Fixed** → single numeric field (existing pattern).
- **Tiered** presets → a **rate editor**: checkboxes for the applicable dimension values
  (e.g. resolutions), rendering a matrix of tier rows (value-combo × variant); one $/s
  input per cell. Show the auto `fallback_per_second` (= max) read-only.
- Submit the **structured `tiers`** payload (not pre-built keys).
- Client validation: every rendered cell filled before enabling submit.

## Testing

- **api unit tests** (pure where possible; Feature suite blocked — Unit only): for each
  preset, `buildCustomPricing` produces the correct `pricing` JSON (keys via
  `videoRateKey`, `fallback = max`); `videoRateKey` round-trips against the resolver
  (a built key resolves back to the entered rate through `resolveVideoUnitRate`); the
  provider↔preset guard rejects a mismatched shape; validation rejects incomplete tier
  sets.
- **Resolver regression** — existing `KvMotionMeteringPricingTest` / video pricing tests
  stay green (no resolver change).
- **web** — form renders provider-appropriate presets, generates a complete `tiers`
  payload, blocks submit on empty cells.

## Out of scope (YAGNI)

- **No new dimensions** — only the four the resolver + ai-service already know
  (`resolution`, `video_in`, `mode`, `audio`). A genuinely novel pricing axis would need
  ai-service to report it first.
- **No ai-service change** — a custom model registers "under an existing provider" and
  reuses that provider's existing `generate_video` branch (which already reports its dims).
- **No migration of hardcoded models to DB** — the hardcoded registry stays the home for
  the built-in models; this only adds the *ability* to create tiered custom ones.
- **No resolver change.**

## Files touched

**api**
- `app/Http/Controllers/Api/Admin/AdminModelSettingController.php` — `metadataRules`,
  `buildCustomPricing`, provider↔preset config + guard.
- `app/Actions/UpdateCustomModelAction.php` — tiered build on edit.
- `app/Helpers/PricingHelper.php` — extract `videoRateKey(pricedOn, dims)` (shared by
  `normalizeDim` and `buildCustomPricing`).
- `tests/Unit/...` — validation + builder + key round-trip tests.

**web**
- The Add/edit-model form component under the superadmin Models Settings page —
  pricing-shape dropdown + tiered rate editor + structured payload.
