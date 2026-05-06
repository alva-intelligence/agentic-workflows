# KV Chat Bubble — Inline Pills (Persisted) — Design Spec

**Status:** Approved (brainstorm done 2026-05-06).
**Pairs with:** `2026-05-05-kv-chat-inline-chips-design.md` (the editor side, already shipped: api PR #43, web PR #81).
**One-line:** Make the user-message bubble in KV chat history render attachments and selections as inline pills inside a single bubble — matching the prompt editor 1:1 — and persist that structure across page refreshes.

## Goal

Today the KV user bubble renders three stacked sections (selection preview tile → attachment thumbnail row → plain text bubble) and the structured `message_blocks` payload is flattened to plain text on the way to storage, so chip positions are lost. After a refresh, attachments and selections also disappear (a pre-existing rehydration TODO).

After this change:
- The bubble is a single rounded card whose prose interleaves text, `Region N` selection pills, and attachment-name pills inline — visually the same chips the editor uses, with `×` buttons stripped (sent message is read-only).
- Clicking a selection pill opens the existing `SelectionSummaryModal` scrolled / flashed to that box's row (the same wiring Task 14 built).
- Clicking an attachment pill opens its file URL in a new tab.
- The structure persists across refreshes — `blocks` is stored on `user_chat_history.message` JSONB and round-trips through the `GET /v1/threads/{id}` response.
- Pre-existing TODOs to rehydrate `attachments` and `selections` on user rows are closed in the same PR pair (without them, the new bubble has nothing to render against on refresh).
- Old user rows without `blocks` fall back to the existing layout — no migration, no backfill.

## Non-goals

- Phase-2 ref-label substitution at the AI service layer (e.g. flatten `selection_ref` → `"Region 1"` for the model). That stays in the api flatten code path; this design only concerns persistence and rendering.
- Editing or deleting persisted user messages.
- Read-only rendering for any non-KV chat surface (askFrnd main chat does not use this).
- Backfilling old user rows so their bubbles "look new". Old rows keep their existing rendering.

## Architecture

```
Wire (already shipped):  POST /v1/threads/{id}/stream
                           body.message_blocks: ContentBlock[]   (validated)
                           body.message: <flattened>             (back-compat)

Persistence (NEW):       user_chat_history.message JSONB
                           {
                             content:    "<flattened text>",      [today]
                             type:       "user"|"ai",              [today]
                             selections: [...],                    [today]
                             base_generation_id: "...",            [today]
                             blocks:     ContentBlock[]            [NEW, optional]
                           }

GET /v1/threads/{id}     ChatHelper::formatChatHistoryEntry()
  per-user-row payload now also includes:
    attachments: KvHistoryAttachment[]   [NEW, was a TODO]
    selections:  KvHistorySelections     [NEW, was a TODO]
    blocks:      ContentBlock[]          [NEW, this feature]

Web bubble fork:         m.blocks?.length > 0
                           YES → KvUserBubbleInline
                           NO  → existing layout (preview-tile + thumbs + text)
```

## File structure

**API — `frndos/api`:**
- Modify: `app/Http/Controllers/Api/Chat/ThreadController.php` — at all 5 prompt-string sites (lines ~180, ~225, ~421, ~458, ~562 post-merge), nest `blocks` into the `$message` blob when `message_blocks` was sent. The `$blocks` variable is already in scope from the flatten step.
- Modify: `app/Helpers/ChatHelper.php` — extend `formatChatHistoryEntry()` to emit `attachments`, `selections`, and `blocks` on user-role rows.
- Create: `tests/Unit/Helpers/ChatHelperTest.php` — Pest unit test covering the new fields. Pure-function level; no DB writes.

**Web — `frndos/web`:**
- Create: `src/components/studio/kv-generator/lexical/chips/SelectionPill.tsx` — pure presentational pill with `mode: "edit" | "view"`.
- Create: `src/components/studio/kv-generator/lexical/chips/AttachmentPill.tsx` — same pattern.
- Create: `src/components/studio/kv-generator/lexical/chips/SelectionPill.stories.tsx` — Storybook for edit / view variants.
- Create: `src/components/studio/kv-generator/lexical/chips/AttachmentPill.stories.tsx` — same.
- Modify: `src/components/studio/kv-generator/lexical/SelectionRefNode.tsx` — `decorate()` returns `<SelectionPill mode="edit" .../>` instead of inline JSX. Handlers context unchanged.
- Modify: `src/components/studio/kv-generator/lexical/AttachmentRefNode.tsx` — same pattern.
- Create: `src/components/studio/kv-generator/KvUserBubbleInline.tsx` — block-iterating bubble renderer.
- Create: `src/components/studio/kv-generator/KvUserBubbleInline.stories.tsx` — text-only, +1 selection, +1 attachment, mixed, attachment-only stories.
- Modify: `src/hooks/useKvStream.ts` — add `blocks?: ContentBlock[]` to wire shape + `ChatStreamMessage`; populate optimistic + hydration paths.
- Modify: `src/components/studio/kv-generator/KvChat.tsx` — fork user-message render on `m.blocks?.length > 0` to use `KvUserBubbleInline`; legacy layout stays as-is in the `else` branch.

## Wire format details

The `ContentBlock` type from `web/src/types/kvChatBlocks.ts` is unchanged. The persistence shape on `user_chat_history.message` is:

```jsonc
{
  "content": "tambahin gambar sketch ini di kanan atas : , kemudian tambahkan sketch logo berikut di kanan bawah:",
  "type": "user",
  "blocks": [
    { "type": "text", "text": "tambahin gambar sketch ini di kanan atas : " },
    { "type": "attachment_ref", "id": "att_abc" },
    { "type": "text", "text": ", kemudian tambahkan sketch logo berikut di " },
    { "type": "attachment_ref", "id": "att_def" },
    { "type": "text", "text": " bawah:" }
  ],
  "selections": [...],
  "base_generation_id": "..."
}
```

The `content` string stays for back-compat (askFrnd / P&A / legacy clients reading the user message via `$chat->message['content']` keep working).

> **Storage vs. wire shape note.** The persisted `selections` is a flat array of boxes (legacy nesting from `bounding_boxes` validation). The wire-shape `selections` returned by `formatChatHistoryEntry` reshapes it into `KvHistorySelections = { base_generation_id, boxes: [...] }` to match what the web already expects from in-session optimistic data. Same data, different envelope.

## Component contracts

### `<SelectionPill mode="edit" | "view">`

```ts
type SelectionPillProps = {
  index: number;                  // 1-based, e.g. 1 for "Region 1"
  mode: "edit" | "view";
  onClick?: () => void;           // both modes
  onRemove?: () => void;          // edit mode only — wires the × button
};
```

- **Edit mode:** the existing chip pill (icon + "Region N" button + `×` remove button). Lexical decorator (`SelectionRefNode`) renders this.
- **View mode:** drop the `×`. The whole pill becomes one `<button onClick={onClick}>` styled identically. The bubble renders this.

### `<AttachmentPill mode="edit" | "view">`

```ts
type AttachmentPillProps = {
  name: string;
  thumbnailUrl?: string;
  mode: "edit" | "view";
  onClick?: () => void;
  onRemove?: () => void;          // edit mode only
};
```

- Edit mode: existing thumbnail + truncated name + `×`.
- View mode: thumbnail + name, whole pill is the click target.

### `<KvUserBubbleInline>`

```ts
type Props = {
  blocks: ContentBlock[];
  attachments: KvHistoryAttachment[];   // for resolving attachment_ref
  selections?: KvHistorySelections;     // for resolving selection_ref → 1-based index
  onOpenSelectionSummary: (focusBoxId: string) => void;
};
```

Render: single bubble container (same `max-w-[348px] rounded-3xl bg-[rgba(255,255,255,0.15)] px-4 py-3 backdrop-blur-[8px]` as today's text bubble). Inner: `inline-flex flex-wrap items-baseline gap-1` with `whitespace-pre-wrap`.

Per-block rules:
- `text` → `<span>{text}</span>`.
- `selection_ref` → resolve `block.id` to its 1-based position in `selections.boxes`. If found, render `<SelectionPill mode="view" index={n} onClick={() => onOpenSelectionSummary(block.id)} />`. If not found (race or stale), render nothing.
- `attachment_ref` → resolve `block.id` against `attachments` for `name` / `url`. If found, render `<AttachmentPill mode="view" name={n} thumbnailUrl={url} onClick={() => window.open(url, "_blank")} />`. If not found, render nothing.

## Hydration paths

Two ways `m.blocks` enters the in-memory `ChatStreamMessage`:

1. **Optimistic** (in-session, `useKvStream.send`): when caller passes `ContentBlock[]`, the optimistic insert sets `blocks: promptBlocks` alongside the existing `text`, `attachments`, `selections`. The bubble immediately renders inline.
2. **Server-hydrated** (post-refresh, `hydrateInitialMessages`): the `chat_history[i]` wire shape gains `blocks?: ContentBlock[]`; `hydrateInitialMessages` copies it to the `ChatStreamMessage`.

`m.blocks` is `undefined` only for legacy rows without `blocks`. The bubble fork detects this and falls back.

## Bubble integration in `KvChat.tsx`

The user-message render (`~ line 467`) forks on `m.blocks?.length > 0`:

```tsx
if (m.role === "user") {
  if (m.blocks && m.blocks.length > 0) {
    return (
      <KvUserBubbleInline
        blocks={m.blocks}
        attachments={m.attachments ?? []}
        selections={m.selections ?? undefined}
        onOpenSelectionSummary={(id) => {
          setOpenSelections(m.selections?.boxes ?? null);
          setOpenSelectionsFocusId(id);
        }}
      />
    );
  }
  // legacy fallback — existing SelectionPreviewTile + thumbnail row + text bubble (unchanged)
  return <existing JSX>;
}
```

The read-only summary mount (the one that opens via historical bubble click — distinct from the live mount for editor chip clicks) needs a new `focusBoxId` so the click scrolls / flashes to the right row:

```ts
const [openSelections, setOpenSelections] = useState<KvBoundingBox[] | null>(null);
const [openSelectionsFocusId, setOpenSelectionsFocusId] = useState<string | undefined>(undefined);

// at the read-only modal mount:
{openSelections && (
  <SelectionSummaryModal
    boxes={openSelections}
    focusBoxId={openSelectionsFocusId}
    onClose={() => {
      setOpenSelections(null);
      setOpenSelectionsFocusId(undefined);
    }}
    // no onRemove — read-only mount for historical bubbles
  />
)}
```

`SelectionSummaryModal` already accepts `focusBoxId` (editor Task 14); the read-only mount just needs to pass it through. The live mount (used by the editor chip click) keeps its own state pair (`summaryOpen` + `summaryFocusId`) as today.

## Backwards compatibility

- Legacy `user_chat_history` rows have no `blocks` key. `formatChatHistoryEntry` omits the field when absent; the web bubble falls back to the existing 3-section layout (preview tile + thumbnails + text).
- AI-role rows are unaffected — none of the new fields apply to them.
- Non-KV chat surfaces (askFrnd main chat, P&A): the api change is additive on user rows. They never query `m.blocks` so they stay byte-identical to today.

## Error handling

- **Unresolved ref ids in the bubble** (e.g. an `attachment_ref` block whose id doesn't match any `attachments[]` entry): render nothing for that block. No console warning, no placeholder. Mirrors the editor's empty-resolved fallback.
- **Empty / malformed `blocks`**: if `blocks` is `[]` or all blocks have empty / missing fields, the fork condition `blocks.length > 0 && hasRenderableContent` short-circuits and the legacy bubble renders.
- **Selection ref points to a box not in `selections.boxes`**: same as above — render nothing for that pill. The text around it still renders.

## Testing strategy

**API (`frndos/api`):**
- Unit: `tests/Unit/Helpers/ChatHelperTest.php` covers `formatChatHistoryEntry()`. Pure-function tests (no DB) build a fake `UserChatHistory` model instance and assert the output shape:
  - User row with `message.blocks` set → output includes `blocks`.
  - User row without `blocks` → output omits the field.
  - User row with `files` containing image MIME → output includes `attachments`.
  - User row with `files` containing only non-image MIME → output omits `attachments`.
  - User row with `message.selections` set → output includes `selections` with `base_generation_id`.
  - AI row → output omits all three new fields.
- Persistence (controller wiring): no automated test, manual smoke via pgAdmin (`SELECT message FROM user_chat_history WHERE session_id = ... ORDER BY id DESC LIMIT 1` after a chip-laden send). Same approach as `flatten` from PR #43, justified by the SQLite-incompatible-migration env limitation.

**Web (`frndos/web`):**
- Storybook stories for both pills (edit / view variants) and `KvUserBubbleInline` (text-only / +1 selection / +1 attachment / mixed / attachment-only / unresolved ref).
- TypeScript check (`bunx tsc --noEmit`).
- Manual smoke (the canonical loop):
  1. Send a chip-laden message → optimistic bubble shows inline pills.
  2. Refresh → bubble re-renders with the same inline pills (data round-tripped through api).
  3. Click a selection pill → `SelectionSummaryModal` opens scrolled / flashed to that box's row.
  4. Click an attachment pill → file URL opens in a new tab.
  5. Open an OLD pre-feature thread → user bubbles render with the legacy 3-section layout (regression check).

## Rollout

- No PostHog flag. Ships as the default rendering path.
- API merges first (additive — chat-history responses gain new keys; legacy clients that don't read them are unaffected).
- Web merges second (consumes the new keys; falls back gracefully if they're absent so it doesn't strictly require api-first, but the inline-pill bubble only persists across refresh once api is live).

## Open questions

None at this point — design approved by user 2026-05-06.

## Service ordering

API first → Web second. Same convention as the editor PR pair.
