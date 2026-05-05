# KV Chat — Inline Chips Editor (Lexical) Design Spec

**Date:** 2026-05-05
**Author:** Daffa Praramadhana
**Status:** Draft

## Summary

Refactor the KV Generator chat input ([web/src/components/studio/kv-generator/KvChat.tsx](../../../web/src/components/studio/kv-generator/KvChat.tsx)) so selection chips and attachment chips appear **inline with text** inside a single rich-text editor (Lexical), rather than as separate stacked rows above a plain `<input>`. On send, serialize the editor to a multi-modal `ContentBlock[]` payload. Backend accepts the new shape and flattens to today's plain-text behavior in Phase 1; Phase 2 unlocks position-aware labels for reliable multi-attachment / multi-selection prompts.

## Motivation

Today's KV chat input has three separate rows stacked vertically:

1. Selection chip row (custom shape: floating `✕` button outside the chip)
2. Attachment chip row (compact pills with `✕` inside)
3. Plain `<input>` textarea
4. Tools row (Attach, Mode, Model, Send)

This visually fragments the chat surface and makes it impossible to express *which* selection or *which* attachment a piece of text refers to. With a single attachment / single selection, users get away with prose like "use this as a reference" — the model has only one possible referent. With **two or more** attachments or selections, the model genuinely cannot disambiguate roles ("use file 1 as style, file 2 as subject") because today's payload sends a flat string + an unlabelled list.

Inline chips fix both problems: a unified visual surface, and a payload shape that lets the model reliably map words → images/regions.

## Goals

1. Replace the stacked rows with a single Lexical-powered editor where chips render inline as decorator nodes.
2. Restyle the selection chip to match the attachment chip pattern (compact pill, `✕` inside).
3. Send messages as `ContentBlock[]` (multi-modal array). Backend accepts both the legacy `string` shape and the new array shape.
4. Preserve identical model behavior in Phase 1 — backend flattens content blocks to today's plain-text + arrays input. No regressions.
5. Lay groundwork for Phase 2: backend renders chips as labels (`Image A`, `Region 1`) when calling the model, unlocking reliable multi-attachment / multi-selection disambiguation.

## Non-Goals

- Migrating askFrnd's main chat ([web/src/components/chat/ChatInput.tsx](../../../web/src/components/chat/ChatInput.tsx)) to Lexical. KV-only for now; main chat stays on `<textarea>`.
- Phase 2 backend label rendering. Ships in a follow-up PR once Phase 1 is in production and we have real multi-chip prompts to validate against.
- Drag-to-reorder chips inside the editor. Cut/paste works fine via Lexical defaults; explicit drag is YAGNI.
- Mobile-specific keyboard / IME tuning beyond Lexical's built-in handling.
- Changing the bottom-nav `StylePill` or the pinned-style chip (line 1064 of `KvChat.tsx`). The pinned-style chip stays as a separate above-input pill — it's read-only context, not user input.

## Architecture

### Component graph

```
KvChat (existing)
└── KvLexicalEditor (NEW) ─── Lexical <ContentEditable />
    ├── SelectionRefNode (NEW, decorator node) — renders selection chip pill
    ├── AttachmentRefNode (NEW, decorator node) — renders attachment chip pill
    └── useChipSync (NEW hook) — bidirectional state binding
```

### Layout

```
┌─────────────────────────────────────────────────────────────┐
│ Card container (rounded-2xl, glass bg)                      │
│ ┌─ optional pinned-style chip (unchanged) ──────────────┐   │
│ │ [🖼 Sketch · Photoreal]                                │   │
│ └────────────────────────────────────────────────────────┘   │
│                                                              │
│ ┌─ Lexical editor (single contenteditable) ─────────────┐   │
│ │ Make [▢ 1 selection ✕] brighter using                 │   │
│ │ [📎 ref.png ✕] as a style reference                   │   │
│ └────────────────────────────────────────────────────────┘   │
│                                                              │
│ ┌─ Tools row (unchanged) ────────────────────────────────┐   │
│ │ 📎  ✏️ Design  ✨ GPT Image 1.5                  ▲    │   │
│ └────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

The pinned-style chip and tools row are unchanged. The middle zone replaces today's selection-chip row + attachment-chip row + `<input>`.

## Data flow

### Wire format: `ContentBlock[]`

```ts
type ContentBlock =
  | { type: "text"; text: string }
  | { type: "selection_ref"; id: string }    // bounding-box id
  | { type: "attachment_ref"; id: string };  // attachment id

type ChatPrompt = string | ContentBlock[];
```

### Send flow

1. User types prose, draws bounding boxes (chips inserted at cursor), attaches files (chips inserted at cursor), and presses Enter / Send.
2. **Editor → blocks:** `serializeToContentBlocks(editorState)` walks the Lexical paragraph tree, emitting one block per `TextNode` and one block per chip decorator node. Consecutive `TextNode`s are coalesced. Empty leading/trailing text blocks are stripped.
3. **Send call:** `stream.send(blocks, { attachments, boundingBoxes, ...existingOpts })`. The structured `attachments` and `boundingBoxes` arrays continue to carry the actual data (image bytes, box coords); blocks only carry references by ID.
4. **Backend (Phase 1):** receives blocks, flattens `selection_ref` and `attachment_ref` to empty strings, joins all `text` blocks → plain prose. Calls model with `(prose, attachments, boundingBoxes)` exactly as today. **No model behavior change.**
5. **Backend (Phase 2):** receives blocks, replaces refs with labels (`Image A`, `Region 1`), tags the corresponding attachment / region with the same label in the model API call. Model can now reliably map words → images/regions.

### Bidirectional state binding (`useChipSync`)

Parent (`KvChat`) is the single source of truth for `boxes` and `attachments` state. The editor reflects this state via decorator nodes.

| Event source | Effect |
|---|---|
| User draws bounding box on canvas → `boxes` adds entry | `useChipSync` inserts `SelectionRefNode` at current cursor position (or end of editor if no focus) |
| User picks file via paperclip → `attachments` adds entry | `useChipSync` inserts `AttachmentRefNode` at current cursor position |
| User clicks chip's `✕` button in editor | Decorator node calls `onRemoveBox(id)` / `onRemoveAttachment(id)` → parent state updates → `useChipSync` removes the node (idempotent) |
| User backspaces against chip boundary | Lexical default deletes the decorator node → parent state observer detects missing chip → `onRemoveBox(id)` / `onRemoveAttachment(id)` fires |
| External clear (canvas "clear all" button, attachment removed elsewhere) | Parent state changes → `useChipSync` removes corresponding decorator node from editor |

Idempotency: every sync operation is a diff between parent state and editor chip presence; same operation applied twice is a no-op.

## Components

### `KvLexicalEditor`

```ts
type KvLexicalEditorProps = {
  value: ContentBlock[];                            // controlled
  onChange: (blocks: ContentBlock[]) => void;
  onSend: () => void;                               // Enter w/o shift
  placeholder?: string;
  attachments: Attachment[];
  boxes: BoundingBox[];
  onRemoveBox?: (id: string) => void;
  onRemoveAttachment?: (id: string) => void;
  onOpenSelectionSummary: (focusBoxId?: string) => void; // chip click
};
```

- Wraps `<LexicalComposer>` with a custom config that registers `SelectionRefNode` and `AttachmentRefNode`.
- Single paragraph node only (no multi-paragraph editing — KV chat is short-form). Enter without shift sends; shift+enter inserts a soft line break within the same paragraph.
- Controlled value via Lexical's `OnChangePlugin`.

### `SelectionRefNode` (Lexical decorator node)

- Renders a React component (the pill) inline.
- Visual: matches existing attachment chip pattern (`h-8 rounded-xl bg-[rgba(255,255,255,0.05)] border ... pl-1 pr-2`), with `SelectionPlus` icon, label `Region {n}` where `{n}` is the box's 1-based draw order from parent state (e.g., `Region 1`, `Region 2`), and integrated `✕`.
- Click on label → `onOpenSelectionSummary(id)` (opens existing modal scoped to this box, or to all boxes — see decision below).
- Click on `✕` → `onRemoveBox(id)`.

**Decision: one chip per bounding box (not one merged chip).** This makes positional semantics work — "edit Region 1 but not Region 2" needs separate inline tokens, which is the entire point of Phase 2 disambiguation. Today's "1 selection" / "N selections" merged-pill UX is replaced.

The existing `SelectionSummaryModal` is updated to accept an optional focused-box id: when opened from a chip click, scroll/highlight that box's row; when opened from elsewhere (currently no other entry point), show all boxes equally.

### `AttachmentRefNode` (Lexical decorator node)

- Renders inline pill matching today's attachment chip exactly (thumbnail + truncated name + `✕`).
- Click on `✕` → `onRemoveAttachment(id)`.

### `useChipSync(editor, boxes, attachments)`

- `useEffect` on `boxes` length / IDs: diff against editor's current chip nodes; insert missing, remove extra.
- `useEffect` on `attachments` length / IDs: same.
- Insertion position: editor's last known cursor position (tracked via `SELECTION_CHANGE_COMMAND`), falling back to end of paragraph.

### `serializeToContentBlocks(editorState)`

```ts
function serializeToContentBlocks(state: EditorState): ContentBlock[] {
  const blocks: ContentBlock[] = [];
  state.read(() => {
    const root = $getRoot();
    const paragraph = root.getFirstChild();
    if (!paragraph) return;
    for (const child of paragraph.getChildren()) {
      if ($isTextNode(child)) {
        blocks.push({ type: "text", text: child.getTextContent() });
      } else if ($isSelectionRefNode(child)) {
        blocks.push({ type: "selection_ref", id: child.getRefId() });
      } else if ($isAttachmentRefNode(child)) {
        blocks.push({ type: "attachment_ref", id: child.getRefId() });
      }
    }
  });
  return coalesceText(stripEmptyEdges(blocks));
}
```

Helpers:
- `coalesceText`: merges consecutive text blocks into one (Lexical can split text nodes mid-word during edits).
- `stripEmptyEdges`: removes leading/trailing empty-text blocks.

### `useKvStream.send` extension

Existing signature ([web/src/hooks/useKvStream.ts:699](../../../web/src/hooks/useKvStream.ts:699)):

```ts
send(prompt: string, opts?: { attachments?, boundingBoxes?, ... })
```

New signature:

```ts
send(prompt: string | ContentBlock[], opts?: { attachments?, boundingBoxes?, ... })
```

Implementation: if `prompt` is a string, wrap as `[{ type: "text", text: prompt }]`. Send to backend as a JSON-encoded `prompt_blocks` field (FormData) alongside the existing `message` field for backwards compat. Backend prefers `prompt_blocks` when present.

## Backend changes (Phase 1)

KV stream endpoint (the equivalent of `POST /v1/threads/stream` for KV — exact path lives in api/):

1. Accept new optional FormData field `prompt_blocks` containing JSON-encoded `ContentBlock[]`.
2. If `prompt_blocks` is present:
   - Validate schema (allowed `type` values, `id` references must match a provided attachment / box).
   - Flatten: replace each `selection_ref` and `attachment_ref` block with `""` (empty string), concatenate all `text` blocks. Result is the plain prose passed to the model.
   - Continue to pass `attachments` and `boundingBoxes` as today.
3. If `prompt_blocks` is absent: read legacy `message` string field. No change for non-KV consumers.

Result: model receives `(plain prose, attachments, boundingBoxes)` — identical to today's input. **Zero behavior change in Phase 1.**

## Phase 2 (out of scope for this PR; documented for context)

Backend label rendering — when `prompt_blocks` contains refs, replace each ref with a generated label (`Image A`, `Image B`, ... for attachments; `Region 1`, `Region 2`, ... for selections) before calling the model, and pass the same labels alongside the attachment / region in the model API call (e.g., `image_label` field if supported, otherwise system-prompt instruction). This is what enables reliable multi-attachment / multi-selection disambiguation.

Phase 2 ships separately once we have:
- Phase 1 in production for ≥1 week with no regressions
- Real user prompts with 2+ chips to validate label rendering against
- Confirmed which model APIs support image-label fields (GPT Image 1.5, Nano Banana / Gemini 2.5 Flash Image, FLUX Kontext, etc.)

## Visual design

Chips reuse the existing attachment-chip CSS pattern verbatim (compact pill, glass background, integrated `✕`, `h-8 rounded-xl pl-1 pr-2`). The current selection-chip's separate floating `✕` button is removed; `✕` moves inside the pill. This unifies the visual language across both chip types and makes them feel like first-class inline citizens of the editor.

Editor placeholder uses today's "What do you want to ask..." copy with the same color (`text-text-inverse-subtlest`) and font (`font-geist text-textSmRegular`).

Vertical alignment: chips render with `align-items: baseline` relative to surrounding text, with a small `mx-1` to breathe.

## Testing strategy

### Unit (Vitest)

- `serializeToContentBlocks` — empty, only text, only chips, mixed, leading/trailing whitespace
- `useChipSync` — state→editor diffing for adds, removes, no-ops
- Decorator node rendering — chip `✕` fires correct callback

### Integration

- Type prose, draw a box, see chip appear at cursor — assert editor state
- Type prose, attach file, see chip appear at cursor — assert editor state
- Click chip `✕`, assert parent state's box/attachment removed
- Click outside-editor "clear all" canvas button, assert chips removed
- Send: assert `stream.send` called with correct `ContentBlock[]`

### E2E (existing Playwright suite under web/e2e/)

- Happy path: prose + 1 chip → send → existing backend flatten preserves model output
- Multi-chip: prose + 2 selections + 2 attachments → send → asserted backend receives `prompt_blocks` of length 5+, flattens to expected prose

### Backend (Pest, api/)

- Endpoint accepts new `prompt_blocks` field, flattens correctly, falls back to `message` when absent
- Schema validation: invalid ref ID → 422; unknown `type` → 422

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Lexical bundle adds ~50KB gz | Code-split: KV studio is its own route; load Lexical only inside the KV chunk. Already-heavy bundle absorbs it. |
| Bidirectional state-sync infinite loops | Single source of truth (parent owns state); editor diffs are idempotent; sync runs in `useEffect` not in render. |
| Backend payload migration breaks existing KV traffic in production | Phase 1 backend reads `message` when `prompt_blocks` absent. Frontend continues sending `message` as plain-text fallback even when `prompt_blocks` is present (double-write). After 1 week of clean traffic, drop the `message` write. |
| Contenteditable cursor / IME edge cases | Lexical handles these — chosen specifically over DIY contenteditable for this reason. |
| Pinned-style chip (existing) confused with new inline chips | Keep pinned-style chip as a *separate row above the editor*, not inside it. It's read-only context, not user input. |

## Migration plan

1. Land backend Phase 1 changes (accept `prompt_blocks`, flatten) — deploys behind no flag, default off; new field is purely additive.
2. Land frontend KvLexicalEditor + nodes + sync hook + serialization, behind a feature flag (`kv_inline_chips_editor`). Gate at `KvChat.tsx` render — if flag off, render existing input; if on, render `KvLexicalEditor`.
3. Internal QA on flag-on builds for ~1 week.
4. Roll flag to 100% in production. Remove flag + dead code in a follow-up cleanup PR.
5. Phase 2 (separate PR after this is stable): backend label rendering.

## Open questions

1. **Does the KV stream endpoint live in api/ Laravel or in a separate service?** Confirms which test framework (Pest vs whatever) for backend tests. _Resolve before writing the implementation plan._
2. **Are bounding boxes currently stable across re-renders by the same `id`, or does drawing a new box generate a new id every time the canvas re-renders?** Affects `useChipSync` correctness. _Resolve during implementation by reading existing canvas state code._
3. **Is there an existing feature-flag system in the web app?** If yes, use it. If no, fall back to a hardcoded constant we flip in the deploy. _Resolve during implementation._

## References

- Existing input: [web/src/components/studio/kv-generator/KvChat.tsx](../../../web/src/components/studio/kv-generator/KvChat.tsx) lines 1020-1170
- Stream send: [web/src/hooks/useKvStream.ts](../../../web/src/hooks/useKvStream.ts) line 699
- Existing askFrnd `<textarea>` (NOT being migrated): [web/src/components/chat/ChatInput.tsx](../../../web/src/components/chat/ChatInput.tsx) line 658
- Lexical docs: https://lexical.dev/
- Memory: KV chat reuses askFrnd chat infra wherever practical — this PR introduces NEW shared infra (Lexical editor + content blocks) that askFrnd can adopt later if it wants positional chips.
