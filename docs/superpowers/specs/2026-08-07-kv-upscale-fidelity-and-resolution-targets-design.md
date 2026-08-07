# KV Upscale — Fidelity Engine Swap + Resolution Targets

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-08-07
> **Services:** ai-service, api, web
> **Topic slug:** kv-upscale-fidelity-and-resolution-targets

## Problem

Two problems, one fix.

**1. The upscaler rewrites people's faces.** Upscaling a KV with models in it
returns different people — facial contours, identity, and structural features
are all redrawn. On a five-subject KV it also corrupted the brand headline
(`MENDUKUNG GENERASI PENUH POTENSI` → `MENCUKUNG STNERASI PENCH POTENSI`).

This is not a tuning error. `philz1337x/clarity-upscaler` is a Stable
Diffusion img2img pipeline — its schema carries `sd_model`
(`juggernaut_reborn.safetensors`), `num_inference_steps: 18` ("Number of
denoising steps"), and `creativity` documented by the author as "try from
0.3 – 0.9". Generating new detail *is* the product.

We run it at `creativity=0.3` — the bottom of the author's own recommended
range — only because `0.0` crashes the model
(`local variable 'h' referenced before assignment`). The original spec asked
for `0.0` precisely because someone wanted strict fidelity. **The model cannot
do it.** The feature has never been able to meet its own requirement.

**2. Multipliers are the wrong unit.** The UI offers 1.5× and 2×. Users think
in deliverables — 2K, 4K — not in multiples of a source size they never see.

## Expected behaviour

Upscaling must strictly increase resolution, sharpness, and realistic texture
**without altering composition, object detail, text, or human facial
features**. Structural integrity and subject identity are preserved.

## Evidence

Four configurations, two real staging KVs, identical face crops, measured
against a Lanczos resize of the source as the structural baseline. Metrics are
mean absolute per-channel difference and the share of pixels deviating by more
than 25 levels.

| Image | Config | mean diff | pixels >25 |
|---|---|---|---|
| 1 face | clarity `c=0.3` (**production**) | 12.12 | 21.7% |
| 1 face | clarity-pro `c=0` | 4.61 | 1.7% |
| 1 face | clarity-pro `c=-5` | 3.30 | 0.7% |
| 1 face | **clarity-pro `c=-10`** | **2.72** | **0.6%** |
| 1 face | clarity-pro `c=-10` at 4× | 3.97 | 1.3% |
| 1 face | real-esrgan | 3.95 | 1.9% |
| 5 faces | clarity `c=0.3` (**production**) | 17.77 | 39.0% |
| 5 faces | **clarity-pro `c=-10`** | **3.89** | **1.8%** |

Conclusions:

- Production alters 22–39% of the face region and corrupts rendered text.
- `creativity=-10` is the optimum; `-5` is measurably worse, so there is no
  reason to back off the extreme.
- Fidelity holds at 4× (3.97), still ~3× better than production at 2×.
- **Real-ESRGAN loses on both fidelity and sharpness.** The architectural
  argument that a GAN must be safest because it has no generative prior did
  not survive measurement — it scores 3.95 and renders visibly waxy skin and
  soft hair. It is retained only as a fallback.

Baseline caveat: the Lanczos reference measures *structural deviation*. A good
upscaler that adds genuine texture should score slightly above zero, so lower
is not infinitely better — 0.00 would mean "did nothing but resample".

## Decisions

| Decision | Choice |
|---|---|
| Primary engine | `philz1337x/clarity-pro-upscaler`, version pinned |
| Creativity | `-10` (maximum fidelity) |
| Fallback | `nightmareai/real-esrgan` (identity-safe, `face_enhance` stays off) |
| `clarity-upscaler` | Deleted — no configuration of it can meet the requirement |
| User-facing sizes | `2K` / `4K`, replacing `1.5×` / `2×` |
| "2K"/"4K" means | **Long edge** = 2048 / 4096, aspect preserved |
| Cost guardrail | Confirmation dialog on 4K only |
| Credit metering | New `chargeUpscale()`, priced on output megapixels |

### Engine parameters

`clarity-pro-upscaler` accepts exactly four inputs. Everything else the
current code sends (`prompt`, `resemblance`, `dynamic`, `tiling_width`,
`tiling_height`, `sd_model`) does not exist on this model and must be dropped.

```
version         8e33eb474936d75d3ceaa787f3e66f5ba16f35db0853a7697a4ca4e5fc14b6cd
image           <file>
scale_factor    enum [2, 4, 8, 16]   -- computed, see below
creativity      -10
output_format   png
```

It is a **community** model, so the version pin is mandatory — a versionless
ref resolves via the official-model endpoint and 404s. Same trap as the
current pin; keep the comment explaining it.

### Cost

`clarity-pro` bills **$0.03 per output megapixel**, $0.03 minimum, 64 MP
ceiling. At observed source sizes: 2K ≈ **$0.18**, 4K ≈ **$0.75**.

`clarity-upscaler` billed by compute time (3–25s observed), roughly a cent or
two per run. So this is a **10–40× per-export cost increase**, accepted
deliberately: the current cheap result is unusable.

The per-`(parent, target)` cache means each KV is upscaled at most once per
size, so repeat downloads stay free.

### Credit metering

**Upscale is unmetered today.** The wiring looks present —
`KvGenerationUpscaleInternalController` injects `KvCreditMeteringService` and
calls `charge(costType: 'kv_generation_upscale', …)` — but it is guarded on
`! empty($validated['token_usage'])`, and ai-service's `post_completed()`
never sends that key. Staging: **10 completed upscales, 0 cost-history rows**,
while `kv_image_generation` has 256 and `kv_resize_export` 187.

The cause is structural. `charge()` prices from token counts via
`PricingHelper::calculateDetailedCostsAndCreditsAgno`. Replicate bills
compute-seconds or output megapixels, so there is no token count to send and
the existing path cannot express the cost.

Motion already solved this shape: `chargeVideo()` prices from duration +
dimensions and persists `video_params`. Upscale gets the same treatment
against its own cost driver.

**`chargeUpscale(user, workspace, costType, toolName, batchId, model,
outputMegapixels, target)`** — no new plumbing needed, because
`post_completed()` already sends `width` and `height`, and
`width × height` *is* the billable unit.

Rate: `$0.03` per output megapixel × `credits.upscale_multiplier`
(env-configurable, default `1.1`, mirroring `credits.video_multiplier`), at
the standing 1 credit = $0.01.

| Target | Output | Cost | ×1.1 | Credits |
|---|---|---|---|---|
| 2K | ~6 MP | $0.18 | $0.198 | **20** |
| 4K | ~24–25 MP | $0.72–0.75 | $0.79–0.83 | **79–84** |

For context, staging averages: image generation ~5 credits, resize export ~8,
video ~69. A 4K upscale therefore becomes the most expensive single operation
in the KV studio. That is accepted — it reflects real cost, and the multiplier
is env-tunable if it proves too steep.

**Billing measures the output the engine actually produced**, not the target
or the plan's projection. Superseded the original "keyed on target, not
engine" rule during PR #167 review: the plan projects clarity-pro's
enum-overshot size and is fixed before either engine runs, so billing from it
charged a fallback for a run that never happened — 25.2 MP (84 credits)
against real-esrgan's actual ~13.2 MP (44 credits) on a 1114×1412 source at
4K. Measuring the decoded output keeps the original intent (users never pay
more because our primary failed) while being accurate rather than flat: a
fallback now bills less.

Both `kv_generation_upscale` and `kv_resize_tile_upscale` cost types are
wired. The existing `batch_identifier` idempotency guard is reused unchanged.

## Design

### ai-service

`upscale()` takes a `target` (`"2k" | "4k"`) instead of a `factor` and does
the arithmetic itself:

1. Read source dimensions.
2. **Long edge already ≥ target** → Lanczos downscale locally, return. No
   Replicate call, no spend. No model improves on pixels already present.
3. Pick the **smallest** `scale_factor` in `[2, 4, 8, 16]` satisfying
   `source_long × sf ≥ target`.
4. **64 MP guard.** If `source_px × sf²` exceeds the ceiling, pre-downscale
   the source so the projected output fits. Harmless — the result is
   downscaled to the target anyway. This is reachable in practice: a
   2047 px square source targeting 4K forces `sf=4` and projects ~67 MP.
5. Run clarity-pro with the four parameters above.
6. Lanczos downscale the result to the exact target long edge.

Step 6 is what makes the coarse enum a non-issue — the model overshoots, we
land the pixel spec exactly, and we never upsample past what it produced.

Fallback: Real-ESRGAN takes an arbitrary `scale`, so it receives the exact
required ratio directly. Step 6 still runs on the fallback path — rounding
means an arbitrary ratio can land a pixel or two off, and both engines must
produce byte-identical dimensions for the same target. The existing failover
triggers (rate limit, transient 5xx/timeout, 404/401/403) are unchanged.
`face_enhance` must stay `False` — GFPGAN alters faces, which is the whole bug.

Request schemas in `kv_upscale` and `kv_resize_tile_upscale` change
`factor: float` → `target: Literal["2k", "4k"]`. Output filenames go from
`{upscale_id}-{factor}x.png` to `{upscale_id}-{target}.png`.

`post_completed()` gains `target` so the api can price without re-deriving it.
`width`/`height` are already sent and become the billable unit.

### api

Both `kv_generation_upscales` and `kv_resize_export_upscales` gain a
`target varchar(8)` nullable column. The unique index moves from
`(parent_id, factor)` to `(parent_id, target)`.

Legacy rows keep their `factor` with `target = NULL`. Postgres permits
multiple NULLs in a unique index, so historical rows neither collide nor need
backfilling.

Reusing the `factor` column with sentinel values (2.0 for 2K, 4.0 for 4K) was
rejected: it collides with existing 2× rows and would serve wrong-sized
cached pixels under a new label.

Request validation and the API resource swap `factor` → `target`.

### web

`UpscaleFactor` → `UpscaleTarget = "2k" | "4k"`; `UPSCALE_FACTORS` →
`UPSCALE_TARGETS`. Both `KvDownloadDropdown` and `KvTileDownloadDropdown`
consume the shared type, so both surfaces change together.

Rows render the target, its computed dimensions, and a credit estimate —
long-edge sizing is not self-evident on a portrait KV, and 4K costs ~4× 2K,
which the user should see *before* clicking:

```
2K · 2048×1638   ~20 credits
4K · 4096×3277   ~84 credits
```

When the source long edge already meets the target, no Replicate run happens,
so the row reads **Free** instead of an estimate. This is real: it steers
users toward variants that cost nothing.

The estimate is computed client-side — `kv_generations` has no `width`/
`height` columns, so only the browser knows the source dimensions.
`estimateUpscaleCredits(sourceW, sourceH, target)` mirrors the ai-service
selection: pick the smallest `scale_factor` reaching the target, multiply
source megapixels by `sf²`, apply `$0.03/MP × 1.1`, divide by `$0.01`.

Across real KV sizes (992–1536 px long edge) this lands at 20–21 credits for
2K and 79–84 for 4K. The UI computes per KV, so each row shows its own
exact figure; the `~` reflects that the model's output is estimated, not that
the number is a guess.

**Drift risk is real and mitigated deliberately.** The selection logic now
exists in Python and TypeScript. It lives in exactly one file per language,
the TS side carries a comment naming the Python function as source of truth,
and its tests pin the exact credit values above so a divergence fails loudly
rather than silently mispricing the UI.

#### 4K confirmation

4K costs ~4× a 2K export and ~16× an image generation, reached by one click in
a download dropdown. It gets a confirmation step; 2K does not — friction on
every export would cost more than it saves at 20 credits.

The dialog uses the existing `BaseModal` frndos component and states the
target, the output dimensions, the credit estimate, and the current balance:

```
Upscale to 4K?

  Output      4096 × 3277
  Cost        ~84 credits
  Balance     1,240 credits

  [ Cancel ]  [ Upscale ]
```

`Cancel` takes initial focus. There is no "don't ask again" — an opt-out on a
guardrail this new would hide the signal we are adding it to collect.

The dialog also **blocks** rather than warns when the workspace cannot afford
it. `useEffectiveCredits()` exposes `canSpend(cost)`; when it returns false the
confirm button is disabled with an insufficient-credit message. Without this,
a doomed job still runs and we still pay Replicate for output nobody is
billed for.

Rows that render **Free** skip the dialog entirely — nothing is being spent.

#### Analytics

PostHog events fire on target selection, and on the 4K dialog being shown,
confirmed, and cancelled. The confirm/cancel split is the measurement that
tells you whether this guardrail is doing anything or is pure friction; without
it there is no way to revisit the decision with evidence.

## Testing

All logic is pure and testable without live calls:

- `scale_factor` selection across source sizes and aspects (portrait, square,
  landscape)
- the 64 MP guard, including the 2047 px-square case that triggers it
- skip-Replicate-when-already-large
- downscale lands the exact target long edge, aspect preserved
- fallback receives the correct arbitrary ratio
- `face_enhance` is never enabled
- `chargeUpscale()` credit maths at both targets, the zero/negative-megapixel
  guard, and the `batch_identifier` idempotency guard
- a completed upscale writes exactly one `cost_history` row (the current
  bug is that it writes none)
- `estimateUpscaleCredits` returns 20/21 and 79/80/84 for the real source sizes
  in the table above, and `null` (→ "Free") when no run is needed. These
  values are pinned so a Python-side change that isn't mirrored fails here.
- the 4K dialog appears for 4K, not for 2K, and not for a Free row
- confirming starts the job; cancelling starts nothing
- the confirm button is disabled when `canSpend(estimate)` is false

Fidelity itself is not unit-testable. The evidence table above is the
regression baseline; re-run the bake-off if the engine or `creativity`
changes.

## Rollout

Existing 1.5×/2× rows remain readable as history but are no longer offered.
Caches are not invalidated — different key, no conflict.

`REPLICATE_READ_TIMEOUT` stays at 600s; the slowest observed run was 123s at
4×. Watch the S3 upload path instead: a 4× output is a ~27 MB PNG, and one
download during testing hit a client-side read timeout before succeeding on
retry.

## Open questions

- Should 8K be offered later? The enum supports it and the 64 MP ceiling
  allows it for smaller sources, but at ~$3/export it needs a cost
  conversation first. Out of scope for v1.
- Transform-mode edits (face swap, pose reference) remain broken for an
  unrelated reason — see the 2026-08-07 attachment place-mode work. Not
  addressed here.
