---
title: KV LAYER 0–4 Prompt Framework in Refiner
slug: kv-layer-prompt-framework
author: daffa
created: 2026-06-05
status: draft
service: ai-service
---

# KV LAYER 0–4 Prompt Framework in Refiner

## Background

The KV generator's silent refiner (`_run_image_mode`, `service.py:248`) turns chat
context into a single-paragraph image prompt, guided by mode-specific prompt
strings (`image_mode.GUIDANCE`, `craft_mode.COLD_START_GUIDANCE`). Today that
guidance is freeform — prompt quality depends on the LLM's mood, with no explicit
scaffold for what a complete visual scene needs.

The frnd-lark `creative_kv_agent` ships a battle-tested **LAYER 0–4 prompt
enhancement framework** (Reference Foundation → Subject → Environment → Lighting →
Composition). We adapt that framework into our refiner guidance **without changing
any orchestration** — only the content of the guidance strings the refiner already
consumes.

## Goal

Improve refiner prompt quality by giving the LLM an explicit layered thinking
scaffold, while preserving the existing single-paragraph output contract and all
current guardrails.

## Non-goals

- No change to orchestration (`_run_image_mode`, `_llm_stream`,
  `build_system_prompt` signatures / call order).
- No new endpoints, request fields, or DB columns.
- No change to resize / upscale / platform-variant flows.
- Craft **polish** guidance is intentionally untouched (its job is to preserve the
  parent; layering would encourage drift).

## Key adaptation difference from frnd-lark

In frnd-lark, the brand logo is baked **into the prompt** and LAYER 0 treats it as
the hero element. In our flow the logo is **never** in the prompt — it is stripped
(`strip_logo_sentences`) and composited separately via PIL (`logo_stamp.py`).
Therefore **our LAYER 0 is about reference attachments / parent image / product —
explicitly NOT the brand logo.** The framework must keep the existing "do NOT
mention/describe/place the brand logo" instruction intact.

## Design

### New module: `prompts/layers.py`

Exports one constant `LAYER_FRAMEWORK: str` — the layered scaffold. Single source
of truth, imported by the mode modules. The scaffold instructs the refiner to
*think* in layers but **synthesize into one paragraph, <300 words, no headings or
layer labels**.

Layers:

- **LAYER 0 — Reference Foundation (conditional):** when a reference attachment or
  parent image exists, treat it as the visual source of truth — preserve and extend
  it as the core element; it overrides other layers on conflict. This is NOT the
  brand logo (logo is composited separately; never describe or place it). Skip this
  layer entirely when there is no reference.
- **LAYER 1 — Subject & Product:** concrete subject with material/texture/finish.
- **LAYER 2 — Environment & Scene:** surface, background, 2–4 contextual props,
  depth (foreground / midground / background).
- **LAYER 3 — Lighting, Color & Mood:** light type + direction, shadow quality,
  palette (use brand hex codes when present in the brand block), atmosphere.
- **LAYER 4 — Composition & Technical:** camera angle, depth of field, composition
  rule, style reference (editorial / commercial / cinematic), quality markers.

### Integration (the only changed behavior)

1. `image_mode.py` — `GUIDANCE` keeps its current text (single-paragraph, no-logo,
   <300 words) and appends `LAYER_FRAMEWORK`.
2. `craft_mode.py` — `COLD_START_GUIDANCE` keeps its current text (finished /
   photoreal output bar) and appends `LAYER_FRAMEWORK`. `GUIDANCE` (polish) and
   `DEFAULT_PROMPT` unchanged.
3. `chat_mode.py` — unchanged.

`context_builder.build_system_prompt` already concatenates these strings at lines
81 and 87; no change needed there.

### Preserved guardrails

- **No-logo:** framework restates "do NOT describe or place the brand logo".
- **Output format:** one paragraph, <300 words, no layer labels — so
  `apply_style_to_image_prompt` and the image model receive a clean prompt.
- **LAYER 0 conditional:** does not force a reference to exist for from-scratch
  sketch / cold-start.

## Testing

Pure prompt-content change, so no image-model calls:

- Assert `LAYER_FRAMEWORK` IS present in `build_system_prompt` output for
  `mode="image"` (sketch) and for craft cold-start.
- Assert `LAYER_FRAMEWORK` is NOT present for craft polish (`canvas_mode="craft"`,
  not cold-start) and for `mode="chat"`.

## Files touched

- `ai-service/app/agents/kv_generator/prompts/layers.py` (new)
- `ai-service/app/agents/kv_generator/prompts/image_mode.py`
- `ai-service/app/agents/kv_generator/prompts/craft_mode.py`
- `ai-service/app/agents/kv_generator/prompts/__init__.py` (export new module)
- test file under `ai-service/tests/` (or existing kv_generator test module)
