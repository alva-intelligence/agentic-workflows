# KV Craft Cold-Start — Design

**Date:** 2026-05-29
**Author:** Daffa
**Status:** approved (ready for implementation)
**Services:** web, api, ai-service

## Problem

In the KV generator, **Craft** mode is a polish pass (img-to-img) over an
existing generation. It requires a `base_generation_id` at **four** layers
(all must be relaxed for cold-start — missing any one re-blocks the flow):

- web guard — `useKvStream.ts:830` aborts `craft + no base`
- api validation — `StreamChatRequest.php:593` rejects `craft + no base`
- ai-service request schema — `request_schema.py:142` `KvStreamRequest`
  model_validator rejects `craft + no base` (returns HTTP 422)
- ai-service service logic — both craft sub-flows assume `base_generation`

Consequence: when a user is in **Craft** with an empty canvas, they cannot
generate the first image. Every entry point fails:

- "Start Crafting" pill → `disabled` (no base)
- typing a brief + Design send → aborted by the web guard
- the `kv_mode_suggestion` "Start generating" card → aborted by the web guard
  (fires silently, the button appears broken)

To get a polished result today the user must generate in **Sketch** first,
then switch to Craft. Style presets (`Pen Sketch`, `Outline Toon`,
`Wireframe`, `Ink Wash`) are intentionally *rough* — the "polish" comes from
the Craft pass, not a preset.

## Goal

Let a user **brainstorm and generate directly in Craft** with a polished
result, **without disturbing any existing flow**. Purely additive: a new
branch gated on `craft + no base + typed brief` (today simply rejected).

## Behavior

**Craft cold-start** triggers when: `canvas_mode === "craft"` AND no base
generation AND `mode === "image"` AND a non-empty user prompt.

- Runs **text-to-image** with a built-in **finished/photoreal directive**
  (`craft_mode.COLD_START_GUIDANCE`). The user's chat brief steers the look.
- Honors the selected **artboard aspect ratio** and **brand knowledge**
  (unlike a normal craft polish, which strips them because the parent
  dictates them).
- No style preset (Craft never carries one).
- Result is tagged `mode = craft` (natural — `canvas_mode` drives the column).
- Follow-up refinement uses the existing chat **freeform-edit** path (works
  once a base exists). The "Start Crafting" pill stays disabled on an empty
  canvas (it has no base to polish) — cold-start is chat-driven only.

**Brainstorm (chat) in empty Craft** also works: a chat turn needs no base,
it is a discussion. The Brainstorm/Design picker decides chat vs image.

## What does NOT change (gating)

| Scenario | Behavior |
|---|---|
| Sketch (any) | unchanged |
| Craft + base, empty prompt (Start Crafting) | strict polish — unchanged |
| Craft + base, typed prompt | freeform edit — unchanged |
| Craft + no base, **attachment** | existing "start-from-craft promotion" → polish |
| Craft + no base, **typed brief**, image | **NEW: cold-start** |
| Craft + no base, chat | brainstorm discussion (now reachable) |
| Craft + no base, **no prompt**, image | still no-op (nothing to generate) |

## Implementation

### web — `src/hooks/useKvStream.ts`

- Relax the guard (`:830`). Abort only when a craft **image/edit** turn has
  no base **and** no typed prompt and no boxes (i.e. nothing to act on).
  Allow `craft + no base + prompt` (cold-start) and `craft + chat`.
- Payload: define `isColdStartCraft = isCraft && !baseGenerationId`. Send
  `aspect_ratio` and `use_brand_knowledge` for cold-start (do not strip as a
  normal craft polish does at `:978-979`). `style_preset_key` stays
  undefined; `base_generation_id` stays undefined.

### web — `src/components/studio/kv-generator/KvChat.tsx`

- Chat-input send (`:1256-1283`): forward `mode` for **any** craft turn
  (`craftMode` = chat|image from the picker), not only when a base exists, so
  a Design cold-start generates and a Brainstorm cold-start chats. Keep
  `baseGenerationId` flowing only when a base (polish) or boxes exist.
- "Start generating" card (`:656-666`): already sends `mode:"image"`,
  `canvasMode`, aspect, brand, and `baseGenerationId: undefined` for the
  no-base case — works once the guard is relaxed. No change needed.

### api — `app/Http/Requests/StreamChatRequest.php`

- In the `canvas_mode === 'craft'` block (`:593`), do not require
  `base_generation_id` for a cold-start: `mode === 'image'` (or chat) with a
  non-empty `message`/`message_blocks` and no base. Keep requiring it for the
  polish/edit paths. Keep the `mode in (image,edit,chat)` check.

### ai-service — `app/agents/kv_generator/`

- `request_schema.py`: relax the `KvStreamRequest._validate_canvas_mode`
  model_validator. Require `base_generation` only for craft turns that
  operate on an existing image (strict polish: image + empty prompt; region
  edit). Allow cold-start (image + typed brief) and chat (brainstorm) with no
  base. **This is the layer that returns 422 if missed.**
- `prompts/craft_mode.py`: add `COLD_START_GUIDANCE` — a generative directive
  for a finished, production-grade photoreal KV from scratch (no
  "preserve composition" rules; the brief drives subjects/layout).
- `service.py`: detect
  `is_craft_cold_start = canvas_mode=="craft" and mode=="image"
  and base_generation is None and prompt.strip()`.
  Cold-start keeps the user prompt + chat history (falls in the existing
  non-strict craft branch that strips only the style preset). Pass
  `craft_cold_start=True` to `build_system_prompt`. `_run_image_mode` already
  handles the no-base (text-to-image) path used by Sketch.
- `context_builder.py`: add `craft_cold_start: bool = False`. When true,
  append `COLD_START_GUIDANCE` instead of the polish `GUIDANCE` /
  `image_mode.GUIDANCE`.

## Testing

- **web** (`useKvStream.test.ts`): cold-start (`craft + no base + prompt`,
  image) is allowed and the payload carries `aspect_ratio` +
  `use_brand_knowledge` with no `base_generation_id`; `craft + no base + no
  prompt` (image) still aborts.
- **ai-service**: `KvStreamRequest` accepts cold-start (image + brief, no
  base) and chat (no base) but still rejects strict polish / edit without a
  base; `is_craft_cold_start` selects `COLD_START_GUIDANCE`, does not attach a
  base, preserves the brief; strict polish + freeform edit branches unchanged.
- **api**: craft + image + message + no base passes validation; craft +
  image + no base + empty message still fails.

## Risks

- Cross-service (web + api + ai-service): needs coordination with rifki
  (ai-service) and arhen (api).
- Text-to-image cold-start is slightly less faithful than an img-to-img
  polish, but a cold start has no structure to preserve — acceptable.
