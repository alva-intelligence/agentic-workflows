---
title: KV Resize — Prompt-Driven Logo Placement (iteration 2)
date: 2026-06-09
author: daffa
status: design
scope: ai-service only — move/resize the stamped brand logo via additional_prompt
services: [ai-service]
parent: 2026-06-09-kv-resize-additional-prompt-design.md
---

# KV Resize — Prompt-Driven Logo Placement (iteration 2)

## Problem

Iteration 1 (`2026-06-09-kv-resize-additional-prompt-design.md`) scoped logo
control OUT: the `additional_prompt` steers the outpaint/reframe scene only, and
the brand logo is stamped deterministically at a fixed anchor. So a prompt like
"pindahin logo ke kanan atas" does nothing useful today — worse, the raw logo
instruction reaches gpt-image-2 and can make it hallucinate a fake logo while
the real stamped logo stays put (a double-logo artifact).

This iteration makes the **stamped brand logo** actually move/resize from the
prompt.

## Scope (locked)

- **Honor `place` (move) + `scale`** parsed from the prompt. Apply to the
  deterministic `stamp_logo` step via an anchor/scale override.
- **Ignore `remove`** — the brand logo stays mandatory; a "hapus logo" prompt is
  a no-op (logo keeps its persisted placement).
- **Per-export, ephemeral.** The override is recomputed from the export's
  persisted `additional_prompt` at bake time. The file-level `brand_logo_stamp`
  is NOT modified, so other tiles / future generations are unaffected.
- **ai-service only.** `additional_prompt` already flows (iter 1); the chat
  marker already shows the user's raw prompt. No api or web change.

### Explicit non-goals / known limitations

- **Only the stamped logo moves — NOT brand elements the model drew into the
  scene** (e.g. a "Telkomsel" billboard rendered on a wall). Those are scene
  pixels in the source image, outside `stamp_logo`'s control. Controlling them
  is smart-layer territory (`project_smart_layer_poc`, paused) and out of scope.
- **Combined scene+logo in ONE sentence** (e.g. "background lebih gelap, logo ke
  kanan atas") may have the scene part dropped too, because `strip_logo_sentences`
  works at sentence granularity. The logo still moves correctly; the scene tweak
  may be lost. Safe (no hallucinated logo), just lossy. Mitigation: phrase as two
  sentences. A future iteration can extend the classifier to return the scene
  residual.

## Reused building blocks (all already in `app/agents/kv_generator/`)

- `classify_logo_directive(*, chat_history, user_prompt, logo_available)`
  (`logo_directive.py`) — gpt-4o-mini JSON-mode classifier. Already handles
  Indonesian ("kiri atas"→top-left, "kanan bawah"→bottom-right, "hapus"→remove)
  and returns `LogoDirective(action: place|remove|none, anchor, scale)`. Falls
  back to `action="none"` on any unhappy path (no key, bad response, exception).
- `strip_logo_sentences(prompt, brand_name=None)` (`logo_stamp.py`) — removes
  logo-naming sentences from an image prompt. Currently never returns empty
  (defensive for the kv_generator flow).
- `stamp_logo(scene, brand_logo, stamp)` (`logo_stamp.py`) — composites the logo
  at `stamp.anchor` / `stamp.scale`. Unchanged.

> `resolve_stamp` is NOT reused: its `place` branch resets unspecified fields to
> defaults (`bottom-right`/`medium`). Resize needs **overlay** semantics instead
> (see below).

## Design

### Overlay semantics (the key refinement)

The logo already exists on the file with a known anchor/scale. The prompt is an
*adjustment*, so unspecified fields must be KEPT, not reset:

```
def _overlay_stamp(persisted: BrandLogoStamp, directive: LogoDirective) -> BrandLogoStamp:
    # Only `place` adjusts placement; remove is ignored (scope), none = no change.
    if directive.action != "place":
        return persisted
    return BrandLogoStamp(
        anchor=directive.anchor or persisted.anchor,   # keep persisted if unspecified
        scale=directive.scale or persisted.scale,
    )
```

So "pindahin ke kanan atas" (anchor only) keeps the persisted scale; "logo lebih
kecil" (scale only) keeps the persisted anchor.

### Wiring in `process_resize_export` (`app/agents/kv_resize/service.py`)

Before the strategy branch, derive three values once:

```
logo_present = req.brand_logo is not None and req.brand_logo_stamp is not None

if req.additional_prompt and logo_present:
    directive = asyncio.run(classify_logo_directive(
        chat_history=[], user_prompt=req.additional_prompt, logo_available=True))
    effective_stamp = _overlay_stamp(req.brand_logo_stamp, directive)
    # Strip logo sentences so gpt-image-2 never draws a logo. allow_empty=True:
    # a pure-logo prompt strips to "" → no scene instruction is sent.
    scene_prompt = strip_logo_sentences(req.additional_prompt, allow_empty=True)
else:
    effective_stamp = req.brand_logo_stamp   # may be None (no logo)
    scene_prompt = req.additional_prompt
```

- Strategy branches merge **`scene_prompt`** into the guidance (replacing the
  iter-1 `req.additional_prompt` at the two `_merge_additional_prompt` sites).
- The logo re-bake block uses **`effective_stamp`** instead of
  `req.brand_logo_stamp` when calling `stamp_logo`.

`classify_logo_directive` is async and `process_resize_export` is sync, so the
call is wrapped in `asyncio.run(...)` (the function runs as a FastAPI background
task — a fresh event loop per export is fine).

### Required change to a shared helper

Add `allow_empty: bool = False` to `strip_logo_sentences`. When `True`, return
the stripped result even if empty (instead of falling back to the original). The
default preserves kv_generator's current behavior exactly.

## Error handling / edge cases

| Case | Behavior |
|------|----------|
| `classify` fails / no API key | `action="none"` → no override; scene_prompt still stripped (safe) |
| No `additional_prompt` | No classify call, no strip → byte-identical to iteration 1 |
| No brand logo on file | No classify, no strip; `scene_prompt = raw additional_prompt` (iter-1 behavior); nothing stamped |
| `action="remove"` ("hapus logo") | Ignored → `effective_stamp = persisted`; logo still stamped |
| Pure-logo prompt ("logo ke kanan atas") | anchor overridden; `scene_prompt = ""` → base guidance unchanged |
| Combined in one sentence | logo moves; scene clause may be dropped (documented limitation) |

## Cost / latency

One extra gpt-4o-mini call (~1–2s) ONLY when the export has both an
`additional_prompt` AND a brand logo. Skipped otherwise. Comparable to the
existing vision prepass.

## Testing (ai-service, unit)

- `_overlay_stamp`: `place`+anchor only → anchor changed, persisted scale kept;
  `place`+scale only → scale changed, persisted anchor kept; `none`/`remove` →
  persisted returned unchanged.
- `strip_logo_sentences(..., allow_empty=True)` returns `""` when every sentence
  is a logo sentence; `allow_empty=False` (default) still returns the original
  (kv_generator regression).
- `process_resize_export` (patched OpenAI, mirroring `test_service.py`):
  - "pindahin logo ke kanan atas" → `stamp_logo` receives anchor=top-right; the
    guidance passed to reframe/outpaint contains NO logo instruction.
  - "background lebih gelap" (action=none) → stamp anchor unchanged; guidance
    ends with the scene clause.
  - "hapus logo" → stamp still applied at persisted anchor.
  - no `additional_prompt` → guidance + stamp byte-identical to iteration 1.
  - classify raises → `action="none"` path, no override.

## Done criteria

- A `place` prompt moves/resizes the stamped logo via an anchor/scale overlay on
  the persisted stamp (unspecified fields kept).
- `remove` is ignored; the logo is always stamped (unless no logo on file).
- The logo instruction never reaches gpt-image-2 (stripped); the scene clause,
  if any, still does.
- No `additional_prompt` reproduces iteration-1 behavior exactly.
- `stamp_logo`, api, and web are otherwise unchanged.
