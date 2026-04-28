---
title: KV Generator — Craft Mode
slug: studio-kv-craft-mode
author: daffa
created: 2026-04-28
status: draft
services: [web, api, ai-service]
parent: studio-projects-kv-generator
figma:
  empty: https://www.figma.com/design/2C03HNjvUiOAZvEbP2fnr9/Studio?node-id=5277-98502
  crafted: https://www.figma.com/design/2C03HNjvUiOAZvEbP2fnr9/Studio?node-id=5281-4280
---

## Overview

Wire up the existing `Craft` tab in the canvas TopNav. Today `KvCanvasTopNav` already renders `Sketch | Craft | Resize` and `KvGeneratorLayout` already holds `canvasMode` state — but only `sketch` does anything. Craft becomes a **one-click polish pass** over the latest Sketch-generated KV: refines lighting, edge sharpness, text legibility, and color balance **without changing subjects, composition, or text content**. After the polish completes the user lands in the same chat-driven workspace as Sketch, with the polished image as a new version stamped `Craft`.

This is an in-implementation extension of `studio-projects-kv-generator`. No new feature branch — work continues on `feature/daffa/vc-studio-projects-kv-generator`.

## Why

`canvasMode === 'craft'` is dead UI today. The Figma `Empty` frame (`5277:98502`) shows the activation surface — a dimmed latest KV with a single floating `✦ Start Crafting` CTA — and the `Crafted` frame (`5281:4280`) shows the result: identical chat-driven workspace as Sketch, with one new version on the canvas. The work is therefore mostly trigger plumbing, not a new editor surface.

User intent for Craft is "make this image better, don't reinterpret it." Today users get that effect by re-prompting in chat, which often drifts the composition. A constrained polish pass with a canned preset gives a predictable, low-effort improvement step.

## User flow

1. User has at least one Sketch-generated KV on the canvas.
2. User clicks **Craft** in the TopNav segmented control.
3. Canvas dims the latest generation (opacity ~50%) and overlays a centered floating pill: `✦ Start Crafting`. Canvas tools (cursor / frame / text / image) hide; the chat panel stays open and unchanged.
4. User clicks **Start Crafting**.
   - Pill is replaced by a `KvVersionCardPlaceholder`-style skeleton + status line ("Polishing…").
   - Backend triggers a craft-mode generation against the latest Sketch generation as parent reference.
5. On `generation_done`, the polished image swaps in as a new version, stamped `Version N · Craft · Just now`. Canvas mode auto-switches back to `sketch` so the user can keep iterating on the new top version.
6. Chat panel logs an AI bubble: "Polished version N — composition preserved, refined lighting and legibility." Existing chat input continues to drive subsequent iterations as Sketch.

If no generation exists when the user enters Craft, the pill is replaced by a disabled state: `Generate a KV first to enable Craft`. Toggling back to Sketch returns the canvas to normal.

## Layout — Empty state (`5277:98502`)

```
┌─ TopNav (88px) ────────────────────────────────────────────┐
│  [Untitled / project subtitle]   ● Brand                   │
│            [ Sketch | ✦ Craft | Resize ]    [↓ Download]   │
├────────────────────────────────────────────────────────────┤
│ Canvas (full work area, dotted-grid bg)                    │
│                                                            │
│        ┌────── KV image (latest, dimmed 50%) ───────┐      │
│        │                                            │      │
│        │            ┌──────────────┐                │      │
│        │            │ ✦ Start      │                │      │
│        │            │   Crafting   │                │      │
│        │            └──────────────┘                │      │
│        │                                            │      │
│        └────────────────────────────────────────────┘      │
│         Version N · Just now                               │
├────────────────────────────────────────────────────────────┤
│ BottomNav — chat toggle pill only (tools hidden in Craft)  │
└────────────────────────────────────────────────────────────┘
```

Floating chat panel (per `studio-kv-canvas-reclaim`) stays anchored bottom-right, unchanged.

## Layout — Crafted state (`5281:4280`)

Identical to Sketch's normal post-generation layout — the just-polished image is the latest version on the canvas, chat panel shows the conversation thread, version stamp now reads `Version N · Craft`. After the polish lands the canvas mode flips back to `sketch` so the next user action is normal iteration; the user can re-enter Craft at any time to polish again.

## Versioning — hybrid model

Generations stack linearly across `sketch` and `craft`:

```
v1  [Sketch]   ← prompt
v2  [Craft]    ← polish of v1
v3  [Sketch]   ← user re-prompted, fresh take
v4  [Craft]    ← polish of v3
```

Each version has a `mode` badge (`Sketch` / `Craft`). `Resize`-produced outputs live separately as **exports** of a chosen version (out of scope here — Resize spec will land later). For v1, every Sketch and Craft generation increments `version_number`; only Resize is treated differently.

Lineage is implicit — every Craft version has a `parent_generation_id` pointing at the version that was polished. Hover on a Craft version's badge to see "Polished from v1".

## Data model — extend `kv_generations`

No new table. Add one column:

```
kv_generations
  + mode  string  default 'sketch'   -- 'sketch' | 'craft' | 'resize'
  index (studio_file_id, mode, created_at)
```

`metadata` is not used because mode is a stable enum used in indexes and resource payloads — column is cleaner. Existing rows are backfilled to `'sketch'` (implicit via default).

`KvGenerationResource` adds `mode`. No other resource changes.

## API contract additions

### Trigger via existing chat stream

Reuse `POST /api/chat/stream`. Existing payload has `mode: 'chat' | 'image'` (input mode). Add a parallel field `canvas_mode: 'sketch' | 'craft' | 'resize'` (default `'sketch'`) — kept separate so the two dimensions don't conflate. When `canvas_mode === 'craft'`:

- Validates the request includes `attached_generation_id` (the version being polished). 422 if missing.
- Forces `mode = 'image'` server-side (Craft always generates).
- Forwards to AI service `/ai/kv-generator/stream` with `canvas_mode: 'craft'`, `attached_generation_id`, and the standard launch context.
- Persists the resulting generation with `mode = 'craft'` (DB column from §Data model) and `parent_generation_id = attached_generation_id`.

Naming: the DB column is `kv_generations.mode` (the *operation* that produced the generation: sketch / craft / resize). The chat stream uses `canvas_mode` for the same concept on the wire — distinct name, identical values, mapped 1:1 by the API. The chat-stream `mode` field continues to mean **input mode** (chat vs. image) and is unchanged.

A user-visible chat message **is** persisted for the trigger ("✦ Started crafting Version N"); the AI's reply on completion is also a real chat message (consistent with how Sketch generations already log to chat).

### No new public endpoint

The Start Crafting button does not need a dedicated endpoint — it sends a chat-stream request with a synthetic prompt and `mode: 'craft'`. Keeps the wire surface tight.

### Internal callback

`POST /api/internal/kv-generator/generation-complete` body adds:

```
mode: 'sketch' | 'craft' | 'resize'   (required, defaults to 'sketch' if AI service omits)
```

API persists this on the new column. No other change.

## AI service — Craft prompt

New file `ai-service/app/agents/kv_generator/prompts/craft_mode.py`:

```py
GUIDANCE = (
    "In craft mode you are POLISHING an existing key visual. The user has "
    "approved its composition and just wants it refined. You MUST preserve: "
    "the subjects, their pose and identity, the layout and framing, the "
    "background scene, the brand elements, and any text content (wording, "
    "language, position, hierarchy). You MAY refine: lighting consistency, "
    "edge sharpness, color balance, contrast, micro-details, text rendering "
    "quality (fix garbled or warped letterforms while keeping the same "
    "wording), and overall production polish. Do NOT add or remove subjects. "
    "Do NOT redesign layouts. Do NOT change wording or language. Do NOT "
    "change aspect ratio. Your reply MUST be a single paragraph image prompt "
    "that describes the SAME scene as the reference image with these "
    "refinements applied. Reference the parent image as the source of "
    "truth for everything visual; only the refinements above are additive. "
    "Do not address the user, ask questions, or include meta commentary."
)
```

### Request schema

`request_schema.py` — add a new `canvas_mode` Literal field (`'sketch' | 'craft' | 'resize'`, default `'sketch'`). The existing `mode: 'chat' | 'image'` stays as input mode. When `canvas_mode == 'craft'`:

- `attached_generation_id` is required (validated by API before forwarding); service double-checks and returns a 4xx-equivalent SSE error if missing.
- `mode` is forced to `'image'` (validated; reject if caller passed `'chat'`).
- `prompt` is optional — if absent, the service uses a canned default ("Refine this key visual — preserve composition, subjects, and text. Improve lighting, sharpness, color balance, and text legibility.").
- `style_preset_id` is ignored (Craft is presupposed-styled — the parent dictates style).
- `aspect_ratio` is ignored (parent's aspect is preserved).

### Service flow

`service.py` — when `canvas_mode == 'craft'`:

1. Load parent generation by `attached_generation_id` (image URL + metadata) via the existing `api_client`.
2. Build the system prompt: base + `craft_mode.GUIDANCE`.
3. Run the model with the parent image as a reference (image-to-image with the existing `generate_image` tool — same plumbing Sketch already uses for `attached_generation_id`).
4. Emit `generating` SSE events as today (`prompt_expanded` → `image_rendering` → `finalizing`).
5. On success, post the internal callback with `mode = 'craft'` and `parent_generation_id` set.
6. Emit `generation_done` with the persisted resource.

The chat history passed to the model is **trimmed** in craft mode — only the parent generation's `prompt_snapshot` plus the polish guidance go into the prompt. Prior chat turns are excluded so the polish doesn't drift into prior creative directions. The user's chat thread is unchanged client-side.

### Failure handling

`generation_failed` event identical to Sketch's. The placeholder shows Retry. Retry re-sends the same craft request.

## Web — changes

### Files touched

- `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` — Craft overlay rendering, Start Crafting handler, auto-revert to sketch on completion, hide canvas tools when canvasMode === 'craft'.
- `web/src/components/studio/kv-generator/KvCanvas.tsx` — overlay slot for the dim layer + pill (renders only when `canvasMode === 'craft'` and a generation exists).
- `web/src/components/studio/kv-generator/KvCraftOverlay.tsx` — **new**. The dim layer + `Start Crafting` pill / placeholder / disabled state.
- `web/src/components/studio/kv-generator/KvVersionCard.tsx` — show `Sketch` / `Craft` mode badge below version number.
- `web/src/components/studio/kv-generator/KvVersionHistoryPanel.tsx` — version row badge (same `Sketch` / `Craft` chip).
- `web/src/lib/studio/kv/useKvStream.ts` (or equivalent) — accept `mode: 'craft'` in `send()`, validate `attachedGenerationId` is present.
- `web/src/components/studio/kv-generator/KvCanvasBottomNav.tsx` — hide tool cluster when `canvasMode === 'craft'`; chat pill stays.

### `KvCraftOverlay` component

```tsx
type Props = {
  status: "ready" | "polishing" | "disabled";
  onStartCrafting: () => void;
};
```

States:

- `ready` — visible Start Crafting pill with `MagicWand` icon + "Start Crafting" label, white pill on dimmed image, drop shadow `0 8px 24px rgba(0,0,0,0.18)`.
- `polishing` — pill replaced by spinner + "Polishing…" + elapsed timer (mirrors `KvVersionCardPlaceholder`).
- `disabled` — neutral pill `Generate a KV first to enable Craft`, no click handler.

The dim layer uses `<div class="absolute inset-0 bg-black/45" />` over the underlying KV image; the original image is unchanged behind it. Tapping outside the pill does nothing — only the pill or the TopNav mode toggle act.

### Mode lifecycle

- Switching from `sketch` → `craft` is local UI state. No persistence.
- Switching to `craft` while a generation is already in flight: ignored — show a toast `Wait for the current generation to finish`. (The chat input is already disabled mid-stream.)
- On `generation_done` where the completed generation's `mode === 'craft'`: layout calls `setCanvasMode("sketch")` so the user is back to normal iteration. The polished version is the latest, and the user can click Craft again to polish further.
- On `generation_failed` where the in-flight mode was `craft`: keep the user in `craft` mode, surface Retry on the placeholder.

### Mode badge

`KvVersionCard` and version-history rows render a small chip under the version number:

- Sketch — neutral pill, `PencilRuler` icon, `Sketch` label
- Craft — accent pill, `MagicWand` icon, `Craft` label
- (Resize will be added when Resize ships)

Hover on a `Craft` chip shows tooltip: `Polished from v{parent.version_number}`.

### Tools hidden in Craft

`KvCanvasBottomNav` — when `canvasMode === 'craft'`, the cursor/frame/text/image tool group is hidden (or its container is `display: none`). The chat toggle pill stays. Bounding-box / overlays / layers are inactive in Craft because the canvas is read-only during this mode.

This is a UX decision matching the Figma — the `Empty` frame does not render the tool palette tools, only the chat pill. Layers panel auto-collapses on Craft entry; pre-Craft state is restored on return to Sketch.

## Edge cases

| Case | Behavior |
|---|---|
| User enters Craft with no generations | Pill renders disabled state; click is a no-op |
| User enters Craft mid-Sketch-generation | Toast: wait for current generation; mode flips to Sketch |
| Craft polish fails | Placeholder shows Retry; user stays in Craft until retry succeeds or they switch modes |
| User clicks Craft, then switches to Resize before clicking Start | No request fired; UI state resets cleanly |
| Tab closed during Craft polish | Same behavior as Sketch — server best-effort abort, activity logs failure |
| User polishes a Craft version (chain polish) | Allowed — parent is just whatever the latest version is, regardless of its mode |
| Polish drift (the model changes too much) | Acceptance criteria #6; user can either keep polishing, switch to Sketch and re-prompt, or roll back via version history |
| Concurrent Craft + manual chat message | Chat input is disabled mid-stream; not possible |
| Brand knowledge toggle | Honored — the polish prompt still receives brand context if `use_brand_knowledge` is on |

## Migration

```
2026_04_28_xxxxxx_add_mode_to_kv_generations
  ALTER TABLE kv_generations ADD COLUMN mode VARCHAR(16) NOT NULL DEFAULT 'sketch';
  CREATE INDEX kv_generations_studio_file_id_mode_created_at_index
    ON kv_generations (studio_file_id, mode, created_at);
```

Existing rows pick up `'sketch'` via the default. No data migration needed. Reversible: `DROP COLUMN mode`.

## Analytics

New `studio_activities.action` values:
- `kv_craft_started` — metadata: `{ parent_generation_id }`
- `kv_craft_completed` — metadata: `{ parent_generation_id, generation_id }`
- `kv_craft_failed` — metadata: `{ parent_generation_id, error_code }`

`mode_switched` already exists — extended to log canvas-mode switches as well as input-mode switches: `{ scope: 'canvas' | 'input', from, to }`.

## Testing

- **API**: feature test for `mode: 'craft'` chat-stream payload (validates `attached_generation_id`); unit test for `KvGenerationResource` includes `mode`; feature test for internal callback persisting `mode = 'craft'`.
- **AI service**: unit tests for `craft_mode.GUIDANCE` injection; service flow test for `mode == 'craft'` skipping `style_preset_id` and `aspect_ratio`; chat-history-trimming test.
- **Web**: component tests for `KvCraftOverlay` (3 states), version-card mode badge, `useKvStream.send({ mode: 'craft' })` validation; Playwright happy path — Sketch generate → switch to Craft → Start Crafting → polished version appears with badge.

## Acceptance criteria

1. With at least one Sketch generation present, switching `canvasMode` to `craft` dims the latest generation and shows a centered `✦ Start Crafting` pill.
2. With no generations, switching to `craft` shows a disabled `Generate a KV first to enable Craft` pill.
3. Clicking `Start Crafting` triggers a chat-stream request with `mode: 'craft'`, `attached_generation_id: <latest>` and replaces the pill with a polishing placeholder.
4. The placeholder shows elapsed time and a Retry button on `generation_failed`.
5. On `generation_done`, the polished image becomes the new latest version with `version_number = previous + 1`, `mode = 'craft'`, and `parent_generation_id` pointing at the polished version.
6. The polished image preserves the parent's subjects, composition, layout, text wording, and aspect ratio. Subjective acceptance: side-by-side review by Daffa + brand reviewer of 5 test cases.
7. After `generation_done`, `canvasMode` reverts to `sketch` automatically.
8. `KvVersionCard` and the version-history panel render a `Craft` badge with `MagicWand` icon for craft generations and `Sketch` badge with `PencilRuler` for sketch generations.
9. Hovering a `Craft` badge shows tooltip `Polished from v{parent.version_number}`.
10. Canvas tools (cursor/frame/text/image) are hidden in Craft; chat toggle pill stays.
11. Switching to Craft mid-generation surfaces a toast and reverts to Sketch.
12. Existing rows in `kv_generations` (pre-migration) display `Sketch` badges via the column default.

## Out of scope (v1)

- Resize mode (separate spec).
- Custom polish prompt input — every craft pass uses the canned guidance for v1.
- Multi-version comparison UI (split view for v1 sketch ↔ v2 craft).
- Polish "intensity" slider (subtle / standard / strong).
- Per-region polish (mask + craft) — overlays already cover composition; bounding-box-edit covers regional re-prompt.
- Treating Resize outputs as exports — that DB shape is decided when Resize lands.

## Trade-offs accepted

- **Polish drift risk.** A constrained prompt is not a guarantee; the model may still alter subjects or text. Mitigation: explicit guidance, parent-image conditioning, side-by-side review during QA. If drift remains common after launch, follow up with image-edit (in-painting style) calls instead of full re-render.
- **Chat history excluded from craft prompt.** Prevents drift but means a polish pass cannot incorporate "fix the awkward shadow on the left" guidance the user typed in chat. Documented; can be revisited if users hit it.
- **No persistence of `canvasMode` across reloads.** Reloading drops the user back to Sketch. Cheap to add later if needed (`studio_files.metadata.canvas_mode`).
- **Single canned polish preset.** No "polish style" choice in v1. Future presets (e.g., `Cinematic`, `Editorial`, `Minimal`) live alongside the existing chat style chip when needed.

## Future work

- Custom polish prompt input ("polish but make it warmer").
- Resize mode (separate spec) — outputs as exports of the chosen version, not new versions.
- Polish "intensity" with three levels.
- In-place comparison: split-view of parent vs polished version with a slider.
- Auto-suggest Craft from chat ("Looks like the lighting on v2 was a bit flat — try Craft?").
