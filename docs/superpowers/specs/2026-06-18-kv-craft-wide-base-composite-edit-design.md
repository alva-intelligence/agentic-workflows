# KV Craft — Localized Edit on >3:1 Bases via Composite-Back (Phase 2) — Design

**Date:** 2026-06-18
**Author:** Daffa
**Status:** draft (ready for plan)
**Services:** ai-service (core), web, api (passthrough)
**Builds on:** [2026-06-18-kv-craft-upload-base-entry-design.md](2026-06-18-kv-craft-upload-base-entry-design.md)

## Problem

gpt-image-2 cannot output an aspect ratio beyond **3:1** — verified empirically:
`size=2048x592` (3.46:1) → `400 "maximum supported aspect ratio is 3:1"`; and a
wide >3:1 **input** with `size=auto` comes back at 2:1, not its original ratio.
So Phase 1 gates Craft entirely for >3:1 bases (e.g. a 3.44:1 banner).

But users want what ChatGPT does: upload the wide banner, prompt *"tambahin copy
di kiri atas"*, and get **the same banner at the same ratio** with the copy
added. ChatGPT achieves this with **product-side composition** (it edits at a
≤3:1 size, then composites the result back onto the original canvas) — the model
never returns >3:1. We can replicate that.

## Goal

Let a user run a **localized, prompt-driven edit** on a >3:1 Craft base and get
the **original banner ratio back**, with only the targeted area changed. Scope is
localized edits (add/alter a region), NOT a full re-render of the whole banner
(that needs tiling — out of scope).

## Mechanism — composite-back windowed edit

For a base whose ratio is > 3:1:

1. **Infer a coarse target region** from the prompt. A small LLM/vision step maps
   location language to a 3×3-ish anchor: horizontal `left | center | right`,
   vertical `top | middle | bottom` (e.g. "kiri atas" → left/top). Ambiguous /
   no location → default `left/top` for copy, else `center`.
2. **Crop a ≤3:1 window** around that anchor. The banner's short edge is its
   height `H`; the window is full height `H` × width `min(W, 3·H)`, positioned
   against the anchored side (left/center/right). For a 3.44:1 banner this window
   covers ~87% of the width — a large, valid ≤3:1 canvas.
3. **Build a mask** inside the window for the anchored sub-area (e.g. top-left
   quadrant). White = paint, black = preserve — same convention as the existing
   bounding-box edit + the resize outpaint primitive.
4. **Call gpt-image-2 `images/edits`** with the window canvas + mask + an explicit
   window size (≤3:1, conformed via the Phase-1 `conform_to_gpt_image_size`).
   gpt-image-2 accepts `size`+`mask` together (the resize outpaint primitive
   already does this). Only the masked sub-area is regenerated; the rest of the
   window stays byte-identical.
5. **Composite the edited window back** onto the original full-resolution base at
   the window's offset. Because the window's non-masked pixels equal the source,
   the join is seamless; the strip outside the window is the untouched original.
6. **Result:** an image at the **base's exact dimensions** (>3:1), with only the
   targeted area changed. Persisted as a new Craft generation.

This reuses the existing edit-mode mask machinery (`_build_mask`,
`_maybe_stamp_logo_url` compositing pattern) and the Phase-1 conform helper.

## Behavior

| Base ratio | Localized prompt edit | Full-polish craft |
|---|---|---|
| ≤ 3:1 | works (Phase 1 — explicit conformed size) | works (Phase 1) |
| > 3:1 | **NEW: composite-back windowed edit, ratio preserved** | still gated (tiling = future) |

- Trigger is the **chat prompt** (freeform, like ChatGPT) — no box drawing
  required. The region is inferred (step 1).
- The full-polish gate from Phase 1 stays for >3:1; this path is specifically the
  localized-edit branch.
- **Text-overlay note:** for literal, crisp, editable copy, the canvas text-overlay
  layer remains the higher-fidelity option (no model text artifacts). This feature
  covers the ChatGPT-style "AI renders the copy/visual into the image" expectation.

## Implementation

### ai-service (`alva-intelligence/frnd-ai-services`, `development`)

- **Region inference** — a small helper (LLM or rule-based) mapping the user
  prompt to a `{h: left|center|right, v: top|middle|bottom}` anchor. Start
  rule-based on location keywords (id + en: kiri/left, kanan/right, atas/top,
  bawah/bottom, tengah/center); fall back to an LLM classification only if needed.
- **Windowing + composite** — new module (e.g. `kv_generator/window_edit.py`):
  `plan_window(base_w, base_h, anchor) -> (crop_box, mask_box)` and
  `composite_back(base_img, edited_window, crop_box) -> bytes`. Reuse
  `conform_to_gpt_image_size` for the window size and the edit-mode mask builder.
- **Wire into the craft/edit path** — in `service.py`, when `canvas_mode == "craft"`,
  `mode == "image"`, and the base ratio is > 3:1, route through the windowed
  composite-back flow instead of the (gated) full-image craft.

### web (`alva-intelligence/frnd-web`, `develop`)

- **Open the localized path for >3:1.** The Phase-1 gate blocks all craft-image
  sends when `craft_supported === false`. Relax it so a **prompt-driven** craft
  on a >3:1 base is allowed (routes to composite-back); keep blocking only the
  cases that truly can't work (none, once composite-back exists — so effectively
  the >3:1 craft-image send becomes allowed again, handled server-side).
- Update the proactive notice copy: instead of "belum didukung", explain that
  edits on a wide base are applied to a region and the banner ratio is kept.

### api

- Passthrough — the existing craft stream already forwards `base_generation` and
  the prompt. No new endpoint. (Confirm no api-side >3:1 block was added in
  Phase 1 beyond the metadata flag the web reads.)

## Out of scope

- **Full-polish re-render of the whole >3:1 banner** (every pixel regenerated) —
  requires multi-pass tiling + stitch; deferred.

## Open Questions

1. **Region inference fidelity** — start rule-based (keyword → anchor) and measure;
   add an LLM step only if keyword mapping proves too coarse. Acceptable default
   when no location is given?
2. **Mask granularity** — coarse anchored sub-region vs the whole window. Coarse
   sub-region preserves more of the banner but may clip a large headline; whole
   window matches ChatGPT (art may shift). Decide per quality testing; start with
   the anchored sub-region (more preservation).
3. **Seam handling** — feather the window-to-strip join, or rely on mask-preserved
   edges. Start with mask-preserved (no feather) and add feather only if seams show.
