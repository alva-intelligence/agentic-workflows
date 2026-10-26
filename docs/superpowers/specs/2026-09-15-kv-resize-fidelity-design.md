# KV Resize Fidelity — Design

**Date:** 2026-09-15
**Author:** daffa (with Claude)
**Status:** approved in chat, awaiting implementation
**Services:** ai-service, api

## 1. Summary

Three user-stated rules for KV resize are not met today:

1. Do not add new elements, unless asked or unless the target aspect ratio is
   genuinely wider/taller than the original.
2. Do not change colours from the original.
3. Keep the product's aspect ratio proportional and faithful to the master.

This design fixes the causes found by investigating one real staging export
(studio file `01m2j7a3zdnvdj1w3e4qnxa5vp`, Sunlight KV 1962×1086 →
1080×1080 + 1080×1920) plus a five-pair model bake-off.

## 2. What is actually happening

Staging runs `KV_RESIZE_VISION_PREPASS=true` **and** `KV_RESIZE_RESTRUCTURE=true`
(`api/config/services.php:387,396`). Any KV whose vision prepass sees text
therefore takes `ai_restructure` — gpt-image-2 `/v1/images/edits` with **no
mask**. Nothing from the master survives as pixels; the entire frame is
repainted. All three violations follow from that.

### 2.1 Measured colour drift

Weighted mean over each image's chromatic palette (saturation > 0.20),
compared against its own master:

| sample | gpt-image-2 dSat / dVal | gpt-image-2.5-sunburst dSat / dVal |
|---|---|---|
| Sunlight 1:1 | +0.427 / −0.187 | +0.036 / +0.084 |
| Sunlight 9:16 | +0.304 / −0.159 | +0.158 / +0.031 |
| Tropical → 9:16 | +0.107 / −0.007 | +0.010 / −0.000 |
| Sunlight s2 → 9:16 | +0.241 / −0.110 | +0.070 / +0.056 |
| by.U → 1080×566 | −0.068 / −0.086 | +0.019 / −0.010 |

Sunburst is closer on |dSat| and |dVal| in 5/5. Hue: on `s2` gpt-image-2
missed by 24°, sunburst by 2°.

### 2.2 Known regression of sunburst

On a graphic-design-heavy KV (by.U — flat purple panel with halftone dots),
sunburst **photo-realises the flat design area** and adds lanterns and palms,
where gpt-image-2 kept the flat panel. Sunburst also invented stacks of
plates on the Sunlight 1:1. Switching models is a net win but not a clean one.

### 2.3 `input_fidelity` is not available

`input_fidelity` is a **gpt-image-1-only** parameter. `gpt-image-2` and
`gpt-image-2.5-*` both answer `invalid_input_fidelity_model`. Probe trap:
sending an invalid *value* returns "Supported values are 'high' and 'low'" for
every model, which reads as support — only a *valid* value reveals the truth.
This design does not use it.

### 2.4 One bug found on the way

- **CORRECTED 2026-09-15 — there is no OCR typo.** An earlier draft of this spec
  claimed `vision_prepass` misread the Sunlight pack copy as `"RHAMINO power"`
  against a master reading `"RHAMNO power"`. That was wrong: a 6x zoom on the
  master shows it reads **"RHAMINO power"**, so the OCR was correct and the
  renders that reproduced it were correct too. The claim came from misreading
  low-resolution print. §3.2 does NOT depend on it — splitting `product_text`
  out stands on its structural argument alone (dictating pack copy back forces
  the packaging to be redrawn), which the post-change runs bear out.
- **`subject_bbox` is a stub.** It comes back as ~`0.2/0.2/0.6/0.6` on every
  sample tested. `subject_aware_crop` depends on it entirely, so that strategy
  is effectively a centre crop.

### 2.5 Pricing blocker

`api/app/Helpers/LLMHelper.php` registers `gpt-image-1`, `gpt-image-1.5` and
`gpt-image-2` only. `getModelPricing()` returns null for an unknown model and
`PricingHelper::calculateImageCostAgno` then returns `0.0`. Switching the
resize model without adding a registry entry bills **every resize at zero
credits**. `_image_token_usage` additionally hardcodes `"model": "gpt-image-2"`.

## 3. Design

### 3.1 Rule 1 belongs to the mask, not the prompt

Only the mask path can guarantee "new pixels only where the frame grew" — the
mask *is* that region. The prompt has said `"Do not add or remove subjects or
focal elements"` since day one and is violated anyway. Two things make the
mask path dishonest today and both are fixed here:

- `fit_inside_target` reserves `frame_px` on **all four** sides
  (`ai-service/app/agents/kv_resize/canvas.py:88`). For 1962×1086 → 1080×1920
  the horizontal axis already matches, yet a 32px strip on the left and right
  is still handed to the model to repaint. Margin must be reserved only on the
  axis that actually needs extension.
- `legacy_smart_crop` deliberately shrinks the source to **95%**
  (`_INNER_SHRINK_RATIO`, `ai-service/app/agents/kv_resize/service.py:53`) so
  that "the API call has genuine work to do … instead of being a 'preserve
  everything' no-op call that would still bill tokens". The master is degraded
  to justify billing. A no-op resize should skip the model call and bill
  nothing, not damage the image.

Neither `fit_inside_target`, `subject_aware_crop` nor `_INNER_SHRINK_RATIO`
has any test coverage today.

### 3.2 Stop forcing the product's own copy to be re-rendered

`vision_prepass`'s system prompt asks for *every* readable text block
(`ai-service/app/agents/kv_resize/vision_prepass.py:60`). In practice it
sweeps up copy printed on the packaging: `"RHAMNO POWER"`,
`"Cairan Pencuci Piring"`, `"100% BAHAN ANTI TUMBUHAN"`. `build_restructure_prompt`
then requires all of it back, verbatim.

As long as pack-surface copy is in that list, the model **must** redraw the
packaging — rule 3 cannot hold. Split the OCR output into two fields:

- `text_content` — campaign copy that may be re-laid-out (headline, price,
  tagline, CTA).
- `product_text` — copy that sits on the product, packaging, or label.

`build_restructure_prompt` consumes only `text_content`, and gains an explicit
instruction to leave the product's own artwork and lettering untouched.

#### Side effect: pack-only KVs now letterbox instead of restructuring

Unplanned but intended to stay. Moving pack copy out of `text_content` can
leave that list **empty** for a key visual whose only text is printed on the
packaging (a bare product shot with a labelled bottle and no headline).
`_decide_strategy` gates `ai_restructure` on `restructure_enabled and
vision.text_content` — with `text_content` now empty, such a KV falls through
to `fit_not_fill`, the preserve-100%-plus-letterbox path, even on staging where
`KV_RESIZE_RESTRUCTURE=true`.

That is the better outcome for fidelity: there is no campaign copy to re-lay
out, so a full mask-free repaint would only risk the product for nothing. But
it will read to a user as "my resize is suddenly letterboxed" on images that
used to be recomposed. Recorded here so that report is not re-investigated
from scratch. If we later want those KVs recomposed, the fix is a new strategy
gate (e.g. `has_visible_text and not text_content` → reframe-with-preservation),
not putting pack copy back into `text_content`.

### 3.3 A real subject box

`subject_bbox` must be a measured box. The system prompt is rewritten to
demand tight bounds and to forbid a default/centred guess, and the schema
grows a `subject_bbox_confidence` so the caller can tell a real detection from
a fallback. `_decide_strategy` treats low confidence as "no vision" and falls
back rather than trusting a stub.

### 3.4 The aspect gate must cover the text-bearing branch too

`_decide_strategy`'s aspect gate (`_ASPECT_DELTA_THRESHOLD = 0.30`) only ran
on the text-free path. The text-bearing branch returned `ai_restructure` (a
mask-free, full-frame repaint) whenever `restructure_enabled` and
`vision.text_content` were true — **before any aspect check at all**. A
6480×3240 master resized to 1280×720 (a 0.11 aspect delta, practically the
same shape) got a 100% repaint when only 11% of the frame actually needed
inventing.

The delta reading that makes the threshold meaningful: when the master is
preserved whole (fit, not fill) and only the leftover band is filled in, the
aspect delta below IS the fraction of the final frame that ends up invented
— delta 0.11 → 11.1% invented, 0.16 → 15.5%, 0.50 → 50.0%, 0.69 → 68.9%. So
`_ASPECT_DELTA_THRESHOLD = 0.30` reads as "only recompose when more than
~30% of the frame genuinely has to be invented," not a magic number.

Fixed by extracting a shared `_aspect_change_is_large(src_w, src_h,
target_w, target_h)` helper (orientation flip OR delta over the threshold)
and gating *both* branches on it: the text-bearing branch now returns
`ai_restructure` only when `restructure_enabled and vision.text_content and
_aspect_change_is_large(...)`; otherwise it falls back to `fit_not_fill`,
same as before.

Cropping was considered and rejected as the fallback for the small-delta
text-bearing case: a real master's headline was clipped by an 11%-width
crop, so any text-bearing KV must stay on a fit-preserving path
(`fit_not_fill`), never a crop, when the shape change is small.

### 3.5 Model selection becomes configuration

`app/tools/outpaint_image.py` is shared with KV Expand Image, so the resize
model must not be changed by editing a literal. A setting
`KV_RESIZE_IMAGE_MODEL` (default `gpt-image-2`) is threaded through
`outpaint()` / `reframe()` as a parameter, and `_image_token_usage` reports the
model actually used instead of a hardcoded string.

On the api side the registry gains a `gpt-image-2.5-sunburst` entry so pricing
resolves. **The rate values are a blocking input** — they must be copied from
OpenAI's published price list by a human. This design does not invent them.
The guard that *can* be tested without them: an active image model used by the
resize pipeline must resolve to non-null pricing.

## 4. Out of scope

- The composite path (cut the product out, rebuild only background and text,
  paste the real product back). That is the only way rule 3 becomes a
  guarantee rather than a hope, and it deserves its own design.
- Any web/UI change. No user-facing toggle is added here.

## 5. Open questions

1. Exact pricing for `gpt-image-2.5-sunburst` — needed before the model switch
   can ship.
2. Whether the sunburst flat-design regression (§2.2) is acceptable, or whether
   the model should be chosen per content type.
