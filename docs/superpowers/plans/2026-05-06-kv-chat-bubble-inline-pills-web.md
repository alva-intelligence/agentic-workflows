# KV Chat Bubble — Inline Pills (Persisted) — Web Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the KV user-message bubble as a single rounded card whose prose interleaves text, `Region N` selection pills, and attachment-name pills inline — matching the prompt editor 1:1 and persisted across refreshes.

**Architecture:** Two pure pill components shared between the editor (edit mode, with `×`) and the bubble (view mode, click-only). The existing `SelectionRefNode` / `AttachmentRefNode` decorators delegate their JSX to the pills (`mode="edit"`); a new `KvUserBubbleInline` renders the pills (`mode="view"`) interleaved with text by walking `ContentBlock[]`. The hook gains a `blocks` field on `ChatStreamMessage` populated from both the optimistic-send and server-hydrated paths. `KvChat` forks on `m.blocks?.length > 0` — new bubble for new rows, the existing 3-section layout for legacy rows.

**Tech Stack:** Next.js 15, React 19, TypeScript, Storybook.

**Spec reference:** [docs/superpowers/specs/2026-05-06-kv-chat-bubble-inline-pills-design.md](../specs/2026-05-06-kv-chat-bubble-inline-pills-design.md)

**Service ordering:** API first ([2026-05-06-kv-chat-bubble-inline-pills-api.md](./2026-05-06-kv-chat-bubble-inline-pills-api.md) — adds `blocks` / `attachments` / `selections` to user-role chat-history entries), Web second (this plan — consumes those keys).

---

## File Structure

**Web — `frndos/web`:**

- Create: `src/components/studio/kv-generator/lexical/chips/SelectionPill.tsx` — pure presentational pill component with `mode: "edit" | "view"`. Replaces the inline JSX in `SelectionRefNode`'s decorator and is reused by the new bubble.
- Create: `src/components/studio/kv-generator/lexical/chips/AttachmentPill.tsx` — same pattern.
- Create: `src/components/studio/kv-generator/lexical/chips/SelectionPill.stories.tsx` — Storybook for both edit and view variants.
- Create: `src/components/studio/kv-generator/lexical/chips/AttachmentPill.stories.tsx` — same.
- Modify: `src/components/studio/kv-generator/lexical/SelectionRefNode.tsx` — `decorate()` returns `<SelectionPill mode="edit" .../>` instead of inline JSX. Handlers context unchanged.
- Modify: `src/components/studio/kv-generator/lexical/AttachmentRefNode.tsx` — same pattern.
- Create: `src/components/studio/kv-generator/KvUserBubbleInline.tsx` — block-iterating bubble renderer.
- Create: `src/components/studio/kv-generator/KvUserBubbleInline.stories.tsx` — text-only / +1 selection / +1 attachment / mixed / attachment-only / unresolved-ref stories.
- Modify: `src/hooks/useKvStream.ts` — add `blocks?: ContentBlock[]` to the `ChatStreamMessage` type and the `initialMessages` hydration shape; populate optimistic + hydration paths.
- Modify: `src/components/studio/kv-generator/KvChat.tsx` — fork the user-message render on `m.blocks?.length > 0` to use `KvUserBubbleInline`. Add a `focusBoxId` state pair next to the existing read-only `SelectionSummaryModal` mount.

---

## Phase 1 — Pure pill components (foundation, parallel-safe)

> Both pills are pure presentational — they take only props, no contexts, no side-effects. We build them first, ship them in Storybook, and validate the visual output before any consumer code touches them.

### Task 1: `SelectionPill` — view mode (the simpler path)

**Files:**
- Create: `src/components/studio/kv-generator/lexical/chips/SelectionPill.tsx`

- [ ] **Step 1: Create the file with the view-mode shape only**

```tsx
"use client";

import { SelectionPlus, X } from "@phosphor-icons/react";

export type SelectionPillProps = {
  /** 1-based, e.g. 1 → "Region 1". */
  index: number;
  mode: "edit" | "view";
  /** Both modes — the whole pill in view mode, the inner button in edit mode. */
  onClick?: () => void;
  /** Edit mode only — wires the × button. Ignored in view mode. */
  onRemove?: () => void;
};

/**
 * Selection chip pill, rendered in two contexts:
 *   - Lexical editor decorator (`mode="edit"`) — three children: icon,
 *     "Region N" button, × remove button.
 *   - Read-only chat bubble (`mode="view"`) — drops the ×; the whole pill
 *     is one click target that opens the read-only summary modal.
 *
 * The visual styling is byte-identical between the two modes (same
 * border, same bg, same paddings) so the user reads the same chip in
 * both surfaces.
 */
export function SelectionPill({
  index,
  mode,
  onClick,
  onRemove,
}: SelectionPillProps): JSX.Element {
  if (mode === "view") {
    return (
      <button
        type="button"
        onClick={onClick}
        className="inline-flex h-7 items-center gap-1.5 rounded-xl border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.05)] pl-1.5 pr-2 align-middle"
      >
        <SelectionPlus size={14} className="text-text-inverse" />
        <span className="font-geist text-textXsMedium font-medium leading-[1.4] tracking-[-0.12px] text-text-inverse">
          Region {index}
        </span>
      </button>
    );
  }

  return (
    <span className="inline-flex h-7 items-center gap-1.5 rounded-xl border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.05)] pl-1.5 pr-1 align-middle">
      <SelectionPlus size={14} className="text-text-inverse" />
      <button
        type="button"
        onClick={onClick}
        className="font-geist text-textXsMedium font-medium leading-[1.4] tracking-[-0.12px] text-text-inverse"
      >
        Region {index}
      </button>
      <button
        type="button"
        onClick={onRemove}
        aria-label={`Remove Region ${index}`}
        className="ml-1 flex h-4 w-4 items-center justify-center rounded-full text-text-inverse-subtle transition-colors hover:bg-[rgba(255,255,255,0.08)] hover:text-text-inverse"
      >
        <X size={10} />
      </button>
    </span>
  );
}
```

- [ ] **Step 2: TypeScript-check**

Run from `frndos/web`:

```bash
bunx tsc --noEmit
```

Expected: no errors related to the new file.

- [ ] **Step 3: Commit**

```bash
git add src/components/studio/kv-generator/lexical/chips/SelectionPill.tsx
git commit -m "feat(web): add SelectionPill presentational component (edit + view modes)"
```

---

### Task 2: `SelectionPill` Storybook

**Files:**
- Create: `src/components/studio/kv-generator/lexical/chips/SelectionPill.stories.tsx`

- [ ] **Step 1: Create the stories file**

```tsx
import type { Meta, StoryObj } from "@storybook/react";
import { SelectionPill } from "./SelectionPill";

const meta: Meta<typeof SelectionPill> = {
  title: "Studio/KvGenerator/Chips/SelectionPill",
  component: SelectionPill,
  parameters: {
    backgrounds: { default: "dark" },
  },
};
export default meta;

type Story = StoryObj<typeof SelectionPill>;

export const EditMode: Story = {
  args: {
    index: 1,
    mode: "edit",
    onClick: () => console.log("clicked Region 1"),
    onRemove: () => console.log("removed Region 1"),
  },
};

export const ViewMode: Story = {
  args: {
    index: 1,
    mode: "view",
    onClick: () => console.log("opened summary for Region 1"),
  },
};

export const HighIndex: Story = {
  args: {
    index: 12,
    mode: "view",
  },
};
```

- [ ] **Step 2: Run Storybook locally and visually check**

Run from `frndos/web`:

```bash
bun run storybook
```

Open `http://localhost:6006`, navigate to **Studio / KvGenerator / Chips / SelectionPill** and confirm:
- EditMode renders icon + "Region 1" + × inside a single rounded pill.
- ViewMode renders icon + "Region 1" inside the same pill, no ×.
- HighIndex renders "Region 12" without truncation.

- [ ] **Step 3: Commit**

```bash
git add src/components/studio/kv-generator/lexical/chips/SelectionPill.stories.tsx
git commit -m "feat(web): add Storybook for SelectionPill"
```

---

### Task 3: `AttachmentPill`

**Files:**
- Create: `src/components/studio/kv-generator/lexical/chips/AttachmentPill.tsx`

- [ ] **Step 1: Create the file**

```tsx
"use client";

import { X } from "@phosphor-icons/react";

export type AttachmentPillProps = {
  name: string;
  thumbnailUrl?: string;
  mode: "edit" | "view";
  onClick?: () => void;
  /** Edit mode only — wires the × button. Ignored in view mode. */
  onRemove?: () => void;
};

/**
 * Attachment chip pill, rendered in two contexts:
 *   - Lexical editor decorator (`mode="edit"`) — thumbnail + truncated
 *     name + × remove button.
 *   - Read-only chat bubble (`mode="view"`) — drops the ×; the whole pill
 *     is one click target that opens the file URL in a new tab.
 *
 * Visual parity with `<SelectionPill>` — same height, border, bg.
 */
export function AttachmentPill({
  name,
  thumbnailUrl,
  mode,
  onClick,
  onRemove,
}: AttachmentPillProps): JSX.Element {
  const thumb = thumbnailUrl ? (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={thumbnailUrl}
      alt=""
      className="h-5 w-5 shrink-0 rounded-md object-cover"
    />
  ) : (
    <span className="h-5 w-5 shrink-0 rounded-md bg-[rgba(255,255,255,0.08)]" />
  );

  if (mode === "view") {
    return (
      <button
        type="button"
        onClick={onClick}
        className="inline-flex h-7 max-w-[180px] items-center gap-1.5 rounded-xl border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.05)] pl-1 pr-2 align-middle"
      >
        {thumb}
        <span
          className="truncate font-geist text-textXsMedium font-medium leading-[1.4] tracking-[-0.12px] text-text-inverse"
          title={name}
        >
          {name}
        </span>
      </button>
    );
  }

  return (
    <span className="inline-flex h-7 max-w-[180px] items-center gap-1.5 rounded-xl border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.05)] pl-1 pr-1 align-middle">
      {thumb}
      <span
        className="truncate font-geist text-textXsMedium font-medium leading-[1.4] tracking-[-0.12px] text-text-inverse"
        title={name}
      >
        {name}
      </span>
      <button
        type="button"
        onClick={onRemove}
        aria-label={`Remove ${name}`}
        className="ml-1 flex h-4 w-4 items-center justify-center rounded-full text-text-inverse-subtle transition-colors hover:bg-[rgba(255,255,255,0.08)] hover:text-text-inverse"
      >
        <X size={10} />
      </button>
    </span>
  );
}
```

- [ ] **Step 2: TypeScript-check**

Run: `bunx tsc --noEmit`
Expected: no new errors.

- [ ] **Step 3: Commit**

```bash
git add src/components/studio/kv-generator/lexical/chips/AttachmentPill.tsx
git commit -m "feat(web): add AttachmentPill presentational component (edit + view modes)"
```

---

### Task 4: `AttachmentPill` Storybook

**Files:**
- Create: `src/components/studio/kv-generator/lexical/chips/AttachmentPill.stories.tsx`

- [ ] **Step 1: Create the stories file**

```tsx
import type { Meta, StoryObj } from "@storybook/react";
import { AttachmentPill } from "./AttachmentPill";

const meta: Meta<typeof AttachmentPill> = {
  title: "Studio/KvGenerator/Chips/AttachmentPill",
  component: AttachmentPill,
  parameters: {
    backgrounds: { default: "dark" },
  },
};
export default meta;

type Story = StoryObj<typeof AttachmentPill>;

export const EditMode: Story = {
  args: {
    name: "sketch.png",
    thumbnailUrl: "https://placehold.co/40",
    mode: "edit",
    onClick: () => console.log("clicked sketch.png"),
    onRemove: () => console.log("removed sketch.png"),
  },
};

export const ViewMode: Story = {
  args: {
    name: "sketch.png",
    thumbnailUrl: "https://placehold.co/40",
    mode: "view",
    onClick: () => console.log("opened sketch.png"),
  },
};

export const NoThumbnail: Story = {
  args: {
    name: "moodboard.png",
    mode: "view",
  },
};

export const LongName: Story = {
  args: {
    name: "this-is-an-unreasonably-long-filename-that-should-truncate.png",
    thumbnailUrl: "https://placehold.co/40",
    mode: "view",
  },
};
```

- [ ] **Step 2: Verify stories visually in Storybook**

Run: `bun run storybook` → open **Studio / KvGenerator / Chips / AttachmentPill**.

Expected:
- EditMode and ViewMode look identical except ViewMode has no ×.
- NoThumbnail shows a blank rounded square placeholder.
- LongName truncates with ellipsis at ~180px.

- [ ] **Step 3: Commit**

```bash
git add src/components/studio/kv-generator/lexical/chips/AttachmentPill.stories.tsx
git commit -m "feat(web): add Storybook for AttachmentPill"
```

---

## Phase 2 — Refactor existing decorators to use the pills

> Lifts the inline JSX out of `SelectionRefNode` and `AttachmentRefNode` so both surfaces share one component. The Lexical decorator contract (createDOM / decorate / handlers context) stays unchanged — only the rendered JSX changes.

### Task 5: `SelectionRefNode` delegates to `SelectionPill`

**Files:**
- Modify: `src/components/studio/kv-generator/lexical/SelectionRefNode.tsx`

- [ ] **Step 1: Replace the inline `SelectionRefChip` body**

Open `src/components/studio/kv-generator/lexical/SelectionRefNode.tsx`. Find the `SelectionRefChip` function (line ~102):

```tsx
function SelectionRefChip({
  refId,
  index,
  nodeKey,
}: {
  refId: string;
  index: number;
  nodeKey: NodeKey;
}) {
  const handlers = useContext(SelectionRefHandlersContext);
  return (
    <span
      contentEditable={false}
      data-lexical-decorator
      data-node-key={nodeKey}
      className="inline-flex h-7 items-center gap-1.5 rounded-xl border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.05)] pl-1.5 pr-1 align-middle"
    >
      <SelectionPlus size={14} className="text-text-inverse" />
      <button
        type="button"
        onClick={() => handlers?.onClick(refId)}
        className="font-geist text-textXsMedium font-medium leading-[1.4] tracking-[-0.12px] text-text-inverse"
      >
        Region {index}
      </button>
      <button
        type="button"
        onClick={() => handlers?.onRemove(refId)}
        aria-label={`Remove Region ${index}`}
        className="ml-1 flex h-4 w-4 items-center justify-center rounded-full text-text-inverse-subtle transition-colors hover:bg-[rgba(255,255,255,0.08)] hover:text-text-inverse"
      >
        <X size={10} />
      </button>
    </span>
  );
}
```

Replace with:

```tsx
function SelectionRefChip({
  refId,
  index,
  nodeKey,
}: {
  refId: string;
  index: number;
  nodeKey: NodeKey;
}) {
  const handlers = useContext(SelectionRefHandlersContext);
  return (
    <span
      contentEditable={false}
      data-lexical-decorator
      data-node-key={nodeKey}
      style={{ display: "inline-block", verticalAlign: "middle" }}
    >
      <SelectionPill
        index={index}
        mode="edit"
        onClick={() => handlers?.onClick(refId)}
        onRemove={() => handlers?.onRemove(refId)}
      />
    </span>
  );
}
```

- [ ] **Step 2: Update imports at the top of the file**

Replace the import block:

```tsx
import { SelectionPlus, X } from "@phosphor-icons/react";
import { createContext, useContext, type JSX } from "react";
```

with:

```tsx
import { createContext, useContext, type JSX } from "react";
import { SelectionPill } from "./chips/SelectionPill";
```

(`SelectionPlus` and `X` are no longer referenced — `SelectionPill` owns those imports.)

- [ ] **Step 3: TypeScript-check**

Run: `bunx tsc --noEmit`
Expected: no new errors.

- [ ] **Step 4: Visual smoke via the existing `KvLexicalEditor` story**

Run: `bun run storybook` → **Studio / KvGenerator / KvLexicalEditor / WithOneSelectionAndOneAttachment**.

Expected: the selection chip looks pixel-identical to before the refactor — same icon, same "Region 1" label, same × button, same rounded shape.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/lexical/SelectionRefNode.tsx
git commit -m "refactor(web): SelectionRefNode delegates JSX to SelectionPill"
```

---

### Task 6: `AttachmentRefNode` delegates to `AttachmentPill`

**Files:**
- Modify: `src/components/studio/kv-generator/lexical/AttachmentRefNode.tsx`

- [ ] **Step 1: Replace the inline `AttachmentRefChip` body**

Open `src/components/studio/kv-generator/lexical/AttachmentRefNode.tsx`. Find the `AttachmentRefChip` function (line ~89):

```tsx
function AttachmentRefChip({
  refId,
  nodeKey,
}: {
  refId: string;
  nodeKey: NodeKey;
}) {
  const handlers = useContext(AttachmentRefHandlersContext);
  const resolved = handlers?.resolve(refId) ?? null;
  // If parent state cleared the attachment but the chip hasn't been
  // pruned yet (race between React state and Lexical sync), render an
  // empty span so we don't crash. useChipSync will remove the node on
  // the next tick. contentEditable={false} keeps the cursor from landing
  // inside the transient empty decorator during the race.
  if (!resolved)
    return (
      <span
        contentEditable={false}
        data-lexical-decorator
        data-node-key={nodeKey}
      />
    );

  return (
    <span
      contentEditable={false}
      data-lexical-decorator
      data-node-key={nodeKey}
      className="inline-flex h-7 max-w-[180px] items-center gap-1.5 rounded-xl border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.05)] pl-1 pr-1 align-middle"
    >
      {resolved.thumbnailUrl ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={resolved.thumbnailUrl}
          alt=""
          className="h-5 w-5 shrink-0 rounded-md object-cover"
        />
      ) : (
        <span className="h-5 w-5 shrink-0 rounded-md bg-[rgba(255,255,255,0.08)]" />
      )}
      <span
        className="truncate font-geist text-textXsMedium font-medium leading-[1.4] tracking-[-0.12px] text-text-inverse"
        title={resolved.name}
      >
        {resolved.name}
      </span>
      <button
        type="button"
        onClick={() => handlers?.onRemove(refId)}
        aria-label={`Remove ${resolved.name}`}
        className="ml-1 flex h-4 w-4 items-center justify-center rounded-full text-text-inverse-subtle transition-colors hover:bg-[rgba(255,255,255,0.08)] hover:text-text-inverse"
      >
        <X size={10} />
      </button>
    </span>
  );
}
```

Replace with:

```tsx
function AttachmentRefChip({
  refId,
  nodeKey,
}: {
  refId: string;
  nodeKey: NodeKey;
}) {
  const handlers = useContext(AttachmentRefHandlersContext);
  const resolved = handlers?.resolve(refId) ?? null;
  // Race fallback (see prior comment): empty span if parent state
  // cleared the attachment but Lexical hasn't synced yet.
  if (!resolved)
    return (
      <span
        contentEditable={false}
        data-lexical-decorator
        data-node-key={nodeKey}
      />
    );

  return (
    <span
      contentEditable={false}
      data-lexical-decorator
      data-node-key={nodeKey}
      style={{ display: "inline-block", verticalAlign: "middle" }}
    >
      <AttachmentPill
        name={resolved.name}
        thumbnailUrl={resolved.thumbnailUrl}
        mode="edit"
        onRemove={() => handlers?.onRemove(refId)}
      />
    </span>
  );
}
```

- [ ] **Step 2: Update imports at the top of the file**

Replace:

```tsx
import { X } from "@phosphor-icons/react";
import { createContext, useContext, type JSX } from "react";
```

with:

```tsx
import { createContext, useContext, type JSX } from "react";
import { AttachmentPill } from "./chips/AttachmentPill";
```

- [ ] **Step 3: TypeScript-check**

Run: `bunx tsc --noEmit`
Expected: no new errors.

- [ ] **Step 4: Visual smoke**

Run: `bun run storybook` → **Studio / KvGenerator / KvLexicalEditor / WithOneSelectionAndOneAttachment**.

Expected: the attachment chip looks pixel-identical to before — thumbnail + truncated name + × button.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/lexical/AttachmentRefNode.tsx
git commit -m "refactor(web): AttachmentRefNode delegates JSX to AttachmentPill"
```

---

## Phase 3 — `KvUserBubbleInline`

> The block-iterating bubble. Renders one rounded card whose prose is `<span>` text, view-mode pills, more text, more pills — all inline, all wrapping naturally. Pure component; no contexts; resolution functions are passed in by the parent.

### Task 7: `KvUserBubbleInline` component

**Files:**
- Create: `src/components/studio/kv-generator/KvUserBubbleInline.tsx`

- [ ] **Step 1: Create the file**

```tsx
"use client";

import type { ContentBlock } from "@/types/kvChatBlocks";
import type {
  KvHistoryAttachment,
  KvHistorySelections,
} from "@/types/studio";
import { SelectionPill } from "./lexical/chips/SelectionPill";
import { AttachmentPill } from "./lexical/chips/AttachmentPill";

export type KvUserBubbleInlineProps = {
  blocks: ContentBlock[];
  /** Hydrated by the api file-show endpoint (see formatChatHistoryEntry).
   *  Used to resolve `attachment_ref` blocks → name + thumbnail. */
  attachments: KvHistoryAttachment[];
  /** Hydrated by the api file-show endpoint. Used to resolve
   *  `selection_ref` blocks → 1-based "Region N" index by position. */
  selections?: KvHistorySelections;
  /** Click handler for selection pills — opens the read-only summary
   *  modal scrolled / flashed to the matching box row. */
  onOpenSelectionSummary: (focusBoxId: string) => void;
};

/**
 * Inline-pill bubble for KV chat user messages. One rounded card that
 * walks `blocks` and renders text spans interleaved with view-mode pills.
 *
 * Resolution rules:
 *   - text → <span>
 *   - selection_ref → 1-based index = position of `block.id` inside
 *     `selections.boxes` (so "Region 1" maps to whichever box was drawn
 *     first). Unresolved → render nothing for that block.
 *   - attachment_ref → look up `block.id` in `attachments`. Unresolved →
 *     render nothing for that block.
 *
 * Unresolved blocks render nothing (no placeholder, no warning) — same
 * fallback as the editor's empty-resolved race in AttachmentRefNode.
 */
export function KvUserBubbleInline({
  blocks,
  attachments,
  selections,
  onOpenSelectionSummary,
}: KvUserBubbleInlineProps): JSX.Element {
  // Pre-build the box-id → 1-based-index map so we don't recompute
  // per block.
  const indexByBoxId = new Map<string, number>();
  selections?.boxes.forEach((b, i) => {
    indexByBoxId.set(b.id, i + 1);
  });
  const attachmentById = new Map<string, KvHistoryAttachment>();
  for (const a of attachments) attachmentById.set(a.id, a);

  return (
    <div className="max-w-[348px] rounded-3xl bg-[rgba(255,255,255,0.15)] px-4 py-3 backdrop-blur-[8px]">
      <p className="whitespace-pre-wrap font-geist text-textMdRegular leading-[1.4] tracking-[-0.16px] text-white">
        {blocks.map((block, i) => {
          if (block.type === "text") {
            return <span key={i}>{block.text}</span>;
          }
          if (block.type === "selection_ref") {
            const idx = indexByBoxId.get(block.id);
            if (idx === undefined) return null;
            return (
              <SelectionPill
                key={i}
                index={idx}
                mode="view"
                onClick={() => onOpenSelectionSummary(block.id)}
              />
            );
          }
          if (block.type === "attachment_ref") {
            const att = attachmentById.get(block.id);
            if (!att) return null;
            return (
              <AttachmentPill
                key={i}
                name={att.name}
                thumbnailUrl={att.url}
                mode="view"
                onClick={() => window.open(att.url, "_blank")}
              />
            );
          }
          return null;
        })}
      </p>
    </div>
  );
}
```

- [ ] **Step 2: TypeScript-check**

Run: `bunx tsc --noEmit`
Expected: no new errors.

- [ ] **Step 3: Commit**

```bash
git add src/components/studio/kv-generator/KvUserBubbleInline.tsx
git commit -m "feat(web): add KvUserBubbleInline block-iterating bubble"
```

---

### Task 8: `KvUserBubbleInline` Storybook

**Files:**
- Create: `src/components/studio/kv-generator/KvUserBubbleInline.stories.tsx`

- [ ] **Step 1: Create the stories file**

```tsx
import type { Meta, StoryObj } from "@storybook/react";
import { KvUserBubbleInline } from "./KvUserBubbleInline";

const meta: Meta<typeof KvUserBubbleInline> = {
  title: "Studio/KvGenerator/KvUserBubbleInline",
  component: KvUserBubbleInline,
  parameters: {
    backgrounds: { default: "dark" },
  },
};
export default meta;

type Story = StoryObj<typeof KvUserBubbleInline>;

const sampleAttachment = {
  id: "att_1",
  name: "sketch.png",
  mime_type: "image/png",
  size: 12345,
  url: "https://placehold.co/120",
};

const sampleSelections = {
  base_generation_id: "gen_xyz",
  boxes: [
    { id: "bx_1", x: 0.1, y: 0.1, width: 0.2, height: 0.2 },
    { id: "bx_2", x: 0.5, y: 0.5, width: 0.1, height: 0.1 },
  ],
};

export const TextOnly: Story = {
  args: {
    blocks: [{ type: "text", text: "make this brighter" }],
    attachments: [],
    onOpenSelectionSummary: (id) => console.log("open summary", id),
  },
};

export const WithOneSelection: Story = {
  args: {
    blocks: [
      { type: "text", text: "brighten " },
      { type: "selection_ref", id: "bx_1" },
      { type: "text", text: " a bit" },
    ],
    attachments: [],
    selections: sampleSelections,
    onOpenSelectionSummary: (id) => console.log("open summary", id),
  },
};

export const WithOneAttachment: Story = {
  args: {
    blocks: [
      { type: "text", text: "use " },
      { type: "attachment_ref", id: "att_1" },
      { type: "text", text: " as the reference" },
    ],
    attachments: [sampleAttachment],
    onOpenSelectionSummary: () => {},
  },
};

export const Mixed: Story = {
  args: {
    blocks: [
      { type: "text", text: "add " },
      { type: "attachment_ref", id: "att_1" },
      { type: "text", text: " in " },
      { type: "selection_ref", id: "bx_2" },
      { type: "text", text: " for emphasis" },
    ],
    attachments: [sampleAttachment],
    selections: sampleSelections,
    onOpenSelectionSummary: (id) => console.log("open summary", id),
  },
};

export const AttachmentOnly: Story = {
  args: {
    blocks: [{ type: "attachment_ref", id: "att_1" }],
    attachments: [sampleAttachment],
    onOpenSelectionSummary: () => {},
  },
};

export const UnresolvedRefs: Story = {
  args: {
    // selection_ref points to a box NOT in `selections.boxes`; attachment_ref
    // points to an id NOT in `attachments`. The text around them must still
    // render — the unresolved blocks just disappear.
    blocks: [
      { type: "text", text: "before " },
      { type: "selection_ref", id: "bx_missing" },
      { type: "text", text: " middle " },
      { type: "attachment_ref", id: "att_missing" },
      { type: "text", text: " after" },
    ],
    attachments: [],
    selections: sampleSelections,
    onOpenSelectionSummary: () => {},
  },
};
```

- [ ] **Step 2: Run Storybook and visually verify each story**

Run: `bun run storybook` → **Studio / KvGenerator / KvUserBubbleInline**.

Expected:
- TextOnly: bubble with the prose, no pills.
- WithOneSelection: bubble reads "brighten [Region 1] a bit" with the pill inline.
- WithOneAttachment: bubble reads "use [sketch.png pill] as the reference".
- Mixed: bubble reads "add [sketch.png] in [Region 2] for emphasis".
- AttachmentOnly: bubble is just the pill.
- UnresolvedRefs: bubble reads "before  middle  after" — both pills missing, text intact.

- [ ] **Step 3: Click the pills in the Mixed story**

In the Mixed story, click the selection pill — verify the action logger shows `["open summary", "bx_2"]`. Click the attachment pill — verify a new tab opens to `https://placehold.co/120`.

- [ ] **Step 4: Commit**

```bash
git add src/components/studio/kv-generator/KvUserBubbleInline.stories.tsx
git commit -m "feat(web): add Storybook for KvUserBubbleInline (6 variants)"
```

---

## Phase 4 — Hook wiring (`useKvStream`)

> Two hydration paths: the optimistic `send()` insert (already runs in-session) and the post-refresh `hydrateInitialMessages` (the wire-shape entry returned by the api). Both gain `blocks?: ContentBlock[]`.

### Task 9: Add `blocks` to `ChatStreamMessage` and `initialMessages`

**Files:**
- Modify: `src/hooks/useKvStream.ts`

- [ ] **Step 1: Add `blocks` to `ChatStreamMessage`**

Open `src/hooks/useKvStream.ts`. Find the `ChatStreamMessage` type (line ~65):

```ts
export type ChatStreamMessage = {
  id: string;
  role: "user" | "assistant";
  text: string;
  metadata?: ChatMessageMeta;
  /** Image attachments the user shipped with this turn (paperclip).
   *  Carried on user messages only; rendered as a thumbnail strip above
   *  the bubble. */
  attachments?: KvHistoryAttachment[];
  /** Bounding-box selections the user drew on the canvas for this turn,
   *  joined to the parent generation by `base_generation_id`. Carried on
   *  user messages only; rendered as an annotated mini-preview tile. */
  selections?: KvHistorySelections;
};
```

Replace with:

```ts
export type ChatStreamMessage = {
  id: string;
  role: "user" | "assistant";
  text: string;
  metadata?: ChatMessageMeta;
  /** Image attachments the user shipped with this turn (paperclip).
   *  Carried on user messages only; rendered as a thumbnail strip above
   *  the bubble. */
  attachments?: KvHistoryAttachment[];
  /** Bounding-box selections the user drew on the canvas for this turn,
   *  joined to the parent generation by `base_generation_id`. Carried on
   *  user messages only; rendered as an annotated mini-preview tile. */
  selections?: KvHistorySelections;
  /** Structured ContentBlock[] for this turn — present when the user
   *  sent inline chips (selections / attachments) and the api persisted
   *  the original blocks alongside the flattened `text`. The chat panel
   *  forks on `blocks?.length > 0` to render the inline-pill bubble.
   *  Absent on legacy / pre-feature rows. */
  blocks?: ContentBlock[];
};
```

- [ ] **Step 2: Verify `ContentBlock` is already imported**

Search the imports at the top of `useKvStream.ts` for `ContentBlock`:

```bash
grep -n "ContentBlock" src/hooks/useKvStream.ts
```

If not imported, add to the existing `kvChatBlocks` import (the file already uses `isContentBlockArray` and `flattenBlocksToText` per the existing send code at line ~770):

```ts
import {
  type ContentBlock,
  isContentBlockArray,
  flattenBlocksToText,
} from "@/types/kvChatBlocks";
```

- [ ] **Step 3: Add `blocks` to the `initialMessages` props shape**

Find the `initialMessages` declaration in `Props` (line ~158):

```ts
  initialMessages?: Array<{
    id: string;
    role: "user" | "assistant";
    text: string;
    tools?: Array<Record<string, unknown>> | null;
    kind?: "question_card" | "mode_suggestion";
    payload?: Record<string, unknown> | null;
    /** User-only: image attachments persisted on this turn. Hydrated by
     *  the api file-show endpoint once that lands; pre-api this stays
     *  undefined and only optimistic in-session sends carry attachments. */
    attachments?: KvHistoryAttachment[];
    /** User-only: bounding-box selections persisted on this turn.
     *  Hydrated by the api file-show endpoint; pre-api this stays
     *  undefined for refreshed sessions. */
    selections?: KvHistorySelections | null;
  }>;
```

Append a new `blocks` field inside the array element type:

```ts
  initialMessages?: Array<{
    id: string;
    role: "user" | "assistant";
    text: string;
    tools?: Array<Record<string, unknown>> | null;
    kind?: "question_card" | "mode_suggestion";
    payload?: Record<string, unknown> | null;
    /** User-only: image attachments persisted on this turn. */
    attachments?: KvHistoryAttachment[];
    /** User-only: bounding-box selections persisted on this turn. */
    selections?: KvHistorySelections | null;
    /** User-only: structured block payload — present when the api
     *  persisted `message_blocks` for this row. Drives the inline-pill
     *  bubble fork in KvChat. Pre-api or legacy rows: undefined. */
    blocks?: ContentBlock[];
  }>;
```

- [ ] **Step 4: TypeScript-check**

Run: `bunx tsc --noEmit`
Expected: no new errors. (If `ContentBlock` was missing from the import, fix and re-run.)

- [ ] **Step 5: Commit**

```bash
git add src/hooks/useKvStream.ts
git commit -m "feat(web): add blocks field to ChatStreamMessage and initialMessages shape"
```

---

### Task 10: Hydrate `blocks` in `hydrateInitialMessages`

**Files:**
- Modify: `src/hooks/useKvStream.ts`

- [ ] **Step 1: Update `hydrateInitialMessages` signature**

Open `src/hooks/useKvStream.ts`. Find `hydrateInitialMessages` (line ~188):

```ts
function hydrateInitialMessages(
  initial: Array<{
    id: string;
    role: "user" | "assistant";
    text: string;
    tools?: Array<Record<string, unknown>> | null;
    kind?: "question_card" | "mode_suggestion";
    payload?: Record<string, unknown> | null;
    attachments?: KvHistoryAttachment[];
    selections?: KvHistorySelections | null;
  }>
): ChatStreamMessage[] {
```

Add `blocks?: ContentBlock[]` to the parameter:

```ts
function hydrateInitialMessages(
  initial: Array<{
    id: string;
    role: "user" | "assistant";
    text: string;
    tools?: Array<Record<string, unknown>> | null;
    kind?: "question_card" | "mode_suggestion";
    payload?: Record<string, unknown> | null;
    attachments?: KvHistoryAttachment[];
    selections?: KvHistorySelections | null;
    blocks?: ContentBlock[];
  }>
): ChatStreamMessage[] {
```

- [ ] **Step 2: Copy `blocks` through in the user-row branch**

Find the user-row return inside the function (line ~201):

```ts
    if (m.role !== "assistant") {
      return {
        id: m.id,
        role: m.role,
        text: m.text,
        attachments:
          Array.isArray(m.attachments) && m.attachments.length > 0
            ? m.attachments
            : undefined,
        selections:
          m.selections &&
          Array.isArray(m.selections.boxes) &&
          m.selections.boxes.length > 0
            ? m.selections
            : undefined,
      };
    }
```

Replace with:

```ts
    if (m.role !== "assistant") {
      return {
        id: m.id,
        role: m.role,
        text: m.text,
        attachments:
          Array.isArray(m.attachments) && m.attachments.length > 0
            ? m.attachments
            : undefined,
        selections:
          m.selections &&
          Array.isArray(m.selections.boxes) &&
          m.selections.boxes.length > 0
            ? m.selections
            : undefined,
        blocks:
          Array.isArray(m.blocks) && m.blocks.length > 0 ? m.blocks : undefined,
      };
    }
```

- [ ] **Step 3: TypeScript-check**

Run: `bunx tsc --noEmit`
Expected: no new errors.

- [ ] **Step 4: Commit**

```bash
git add src/hooks/useKvStream.ts
git commit -m "feat(web): hydrate blocks from initial chat-history into ChatStreamMessage"
```

---

### Task 11: Populate `blocks` in the optimistic `send()` insert

**Files:**
- Modify: `src/hooks/useKvStream.ts`

- [ ] **Step 1: Add `blocks` to the optimistic user message**

Open `src/hooks/useKvStream.ts`. Find the optimistic insert in `send()` (line ~820):

```ts
      setMessages((prev) => [
        ...prev,
        {
          id: genId(),
          role: "user",
          text: promptText,
          attachments: optimisticAttachments,
          selections: optimisticSelections,
        },
      ]);
```

Replace with:

```ts
      // promptBlocks (computed earlier in this function) is the canonical
      // ContentBlock[] for this send — either what the caller passed, or
      // a single text block wrapping a plain-string prompt. We only carry
      // it on the optimistic message when the caller actually sent
      // structured blocks; plain-text prompts shouldn't trigger the
      // inline-pill bubble fork.
      const optimisticBlocks: ContentBlock[] | undefined = isContentBlockArray(
        prompt
      )
        ? promptBlocks
        : undefined;
      setMessages((prev) => [
        ...prev,
        {
          id: genId(),
          role: "user",
          text: promptText,
          attachments: optimisticAttachments,
          selections: optimisticSelections,
          blocks: optimisticBlocks,
        },
      ]);
```

- [ ] **Step 2: TypeScript-check**

Run: `bunx tsc --noEmit`
Expected: no new errors.

- [ ] **Step 3: Commit**

```bash
git add src/hooks/useKvStream.ts
git commit -m "feat(web): populate blocks on optimistic user-message insert in useKvStream.send"
```

---

## Phase 5 — `KvChat` integration

### Task 12: Fork the user-message render

**Files:**
- Modify: `src/components/studio/kv-generator/KvChat.tsx`

- [ ] **Step 1: Import the new bubble**

Open `src/components/studio/kv-generator/KvChat.tsx`. Add the import next to the existing studio imports (near line ~52, alongside `SelectionPreviewTile`):

```tsx
import { SelectionPreviewTile } from "./SelectionPreviewTile";
import { KvUserBubbleInline } from "./KvUserBubbleInline";
```

- [ ] **Step 2: Add the `focusBoxId` state pair next to `openSelections`**

Find the state declarations near the top of the chat-history list component (search the file for `openSelections` — the `useState<KvBoundingBox[] | null>(null)` declaration). Today there is only:

```tsx
const [openSelections, setOpenSelections] = useState<KvBoundingBox[] | null>(
  null
);
```

Append a sibling `useState`:

```tsx
const [openSelections, setOpenSelections] = useState<KvBoundingBox[] | null>(
  null
);
const [openSelectionsFocusId, setOpenSelectionsFocusId] = useState<
  string | undefined
>(undefined);
```

- [ ] **Step 3: Fork the user-message render on `m.blocks?.length > 0`**

Find the user-message render block (line ~454):

```tsx
        if (m.role === "user") {
          const userAttachments = m.attachments ?? [];
          const userSelections = m.selections;
          const baseGen = userSelections
            ? generations.find(
                (g) => g.id === userSelections.base_generation_id
              )
            : null;
          const baseGenMeta =
            (baseGen?.metadata as
              | { natural_width?: number; natural_height?: number }
              | null
              | undefined) ?? null;
          return (
            <div
              key={m.id}
              data-testid="kv-user-message"
              className="flex w-full flex-col items-end gap-2 px-2 py-6"
            >
              {userSelections && (
                <SelectionPreviewTile
```

Wrap with the fork. Replace the `if (m.role === "user") { … }` block with:

```tsx
        if (m.role === "user") {
          const userAttachments = m.attachments ?? [];
          const userSelections = m.selections;

          // New inline-pill bubble (post-feature rows). Falls back to
          // the legacy 3-section layout when `blocks` is absent —
          // pre-feature rows, plain-prose sends, or rows hydrated from
          // a thread that pre-dates the api persistence change.
          if (m.blocks && m.blocks.length > 0) {
            return (
              <div
                key={m.id}
                data-testid="kv-user-message"
                className="flex w-full flex-col items-end gap-2 px-2 py-6"
              >
                <KvUserBubbleInline
                  blocks={m.blocks}
                  attachments={userAttachments}
                  selections={userSelections ?? undefined}
                  onOpenSelectionSummary={(id) => {
                    setOpenSelections(userSelections?.boxes ?? null);
                    setOpenSelectionsFocusId(id);
                  }}
                />
              </div>
            );
          }

          // Legacy fallback (preview tile + thumbnails + text bubble).
          const baseGen = userSelections
            ? generations.find(
                (g) => g.id === userSelections.base_generation_id
              )
            : null;
          const baseGenMeta =
            (baseGen?.metadata as
              | { natural_width?: number; natural_height?: number }
              | null
              | undefined) ?? null;
          return (
            <div
              key={m.id}
              data-testid="kv-user-message"
              className="flex w-full flex-col items-end gap-2 px-2 py-6"
            >
              {userSelections && (
                <SelectionPreviewTile
                  imageUrl={baseGen?.image_url}
                  naturalWidth={baseGenMeta?.natural_width}
                  naturalHeight={baseGenMeta?.natural_height}
                  boxes={userSelections.boxes}
                  onClick={() => setOpenSelections(userSelections.boxes)}
                />
              )}
              {userAttachments.length > 0 && (
                <div className="flex max-w-[348px] flex-wrap justify-end gap-2">
                  {userAttachments.map((a) => {
                    const tile =
                      userAttachments.length === 1 ? "h-24 w-24" : "h-16 w-16";
                    return (
                      <a
                        key={a.id}
                        href={a.url}
                        target="_blank"
                        rel="noreferrer"
                        className="group flex flex-col items-end gap-1"
                      >
                        {/* eslint-disable-next-line @next/next/no-img-element */}
                        <img
                          src={a.url}
                          alt={a.name}
                          className={`${tile} rounded-2xl object-cover ring-1 ring-white/10 transition group-hover:ring-white/30`}
                        />
                        <span className="max-w-[120px] truncate font-geist text-[10px] text-text-inverse-subtlest">
                          {a.name}
                        </span>
                      </a>
                    );
                  })}
                </div>
              )}
              {m.text && (
                <div className="max-w-[348px] rounded-3xl bg-[rgba(255,255,255,0.15)] px-4 py-3 backdrop-blur-[8px]">
                  <p className="whitespace-pre-wrap font-geist text-textMdRegular leading-[1.4] tracking-[-0.16px] text-white">
                    {m.text}
                  </p>
                </div>
              )}
            </div>
          );
        }
```

- [ ] **Step 4: Pass `focusBoxId` to the read-only summary modal mount**

Find the read-only `SelectionSummaryModal` mount (line ~661):

```tsx
      {openSelections && (
        <SelectionSummaryModal
          boxes={openSelections}
          onClose={() => setOpenSelections(null)}
        />
      )}
```

Replace with:

```tsx
      {openSelections && (
        <SelectionSummaryModal
          boxes={openSelections}
          focusBoxId={openSelectionsFocusId}
          onClose={() => {
            setOpenSelections(null);
            setOpenSelectionsFocusId(undefined);
          }}
        />
      )}
```

(The live mount near line ~1057, used by the editor chip click, keeps its own `summaryFocusId` state pair as today — only the read-only mount changes.)

- [ ] **Step 5: TypeScript-check**

Run: `bunx tsc --noEmit`
Expected: no new errors.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/KvChat.tsx
git commit -m "feat(web): fork KvChat user-message render to inline-pill bubble when blocks present"
```

---

## Phase 6 — End-to-end smoke + PR

### Task 13: Manual smoke (the canonical loop)

**Files:** none (verification only)

Both api and web must be running locally; the api-side PR must be merged into the same local branch (or have its changes cherry-picked).

- [ ] **Step 1: Boot api + web locally**

In `frndos/api`:

```bash
php artisan serve
```

In `frndos/web`:

```bash
bun run dev
```

- [ ] **Step 2: Open a KV-generator file**

Navigate to a studio project → KV-generator file. Confirm the chat panel is present.

- [ ] **Step 3: Send a chip-laden message**

In the editor:
1. Draw a bounding box on the canvas → a "Region 1" chip auto-appears in the editor.
2. Add an attachment via the paperclip → an attachment chip auto-appears in the editor.
3. Type some text around them, e.g. "make this in [Region 1] using [sketch.png]".
4. Press Enter to send.

Expected (optimistic): the bubble that appears is the new inline-pill bubble — single rounded card, prose interleaving the pills with the text. NO stacked preview tile or thumbnail row above it.

- [ ] **Step 4: Refresh the page**

Press F5 / Cmd-R.

Expected (server-hydrated): the bubble re-renders with identical structure — same pills, same text, same single-card layout. Data round-tripped through api.

- [ ] **Step 5: Click the selection pill**

Expected: the read-only `SelectionSummaryModal` opens scrolled / flashed to that box's row (NOT the first row). The flash is the same UX as the editor's chip-click behavior from the inline-chips PR.

- [ ] **Step 6: Click the attachment pill**

Expected: a new tab opens to the attachment's S3 URL.

- [ ] **Step 7: Open an OLD pre-feature thread (regression check)**

Find a KV thread created before this PR pair (any thread whose user messages were sent without `message_blocks`). Open it.

Expected: the user bubbles render with the legacy 3-section layout (preview tile + thumbnail row + text bubble) — exactly as they did before this PR.

- [ ] **Step 8: Document smoke results in the PR description**

---

### Task 14: TypeScript + lint final pass

**Files:** none

- [ ] **Step 1: Run the full type check**

Run from `frndos/web`:

```bash
bunx tsc --noEmit
```

Expected: 0 errors.

- [ ] **Step 2: Run the linter**

Run:

```bash
bun run lint
```

Expected: 0 errors. Warnings about pre-existing files are fine; warnings on files touched by this PR must be resolved.

- [ ] **Step 3: If anything fails, fix and re-run before commit**

- [ ] **Step 4: Commit any lint fixes**

```bash
git add <touched files>
git commit -m "chore(web): lint fixes for KV inline-pill bubble"
```

---

### Task 15: PR

**Files:** none

- [ ] **Step 1: Push the branch and open a PR**

Run from `frndos/web`:

```bash
git push -u origin HEAD
gh pr create --title "feat(web): KV chat — inline-pill user-message bubble (persisted)" --body "$(cat <<'EOF'
## Summary
- New inline-pill bubble (`KvUserBubbleInline`) for KV chat user messages — single rounded card with prose interleaving text, `Region N` selection pills, and attachment-name pills, matching the editor 1:1.
- Two new pure components — `SelectionPill` and `AttachmentPill` — shared between the editor (`mode="edit"`, with ×) and the bubble (`mode="view"`, click-only). Existing `SelectionRefNode` / `AttachmentRefNode` decorators delegate their JSX to the pills.
- `useKvStream` carries `blocks` on `ChatStreamMessage` from both the optimistic-send path and the server-hydrated `initialMessages` path.
- `KvChat` forks user-message render on `m.blocks?.length > 0` — new bubble for new rows, legacy 3-section layout for legacy rows.
- Read-only `SelectionSummaryModal` mount now passes `focusBoxId` so a click on a selection pill scrolls / flashes the right row.
- Storybook coverage: SelectionPill (3 stories), AttachmentPill (4 stories), KvUserBubbleInline (6 stories — text-only, +1 selection, +1 attachment, mixed, attachment-only, unresolved-refs).

## Why
Pairs with the api PR `feat(api): persist message_blocks + hydrate KV chat-history user rows` (api-first). Together they make the bubble structure persist across refreshes — one of the goals from the spec.

Spec: `docs/superpowers/specs/2026-05-06-kv-chat-bubble-inline-pills-design.md`

## Test plan
- [x] Storybook: all SelectionPill / AttachmentPill / KvUserBubbleInline stories render correctly on the dark background.
- [x] `bunx tsc --noEmit` (0 errors)
- [x] `bun run lint` (0 errors)
- [x] Manual smoke (canonical loop):
  - [x] Send chip-laden message → optimistic inline-pill bubble.
  - [x] Refresh → bubble re-renders identically.
  - [x] Click selection pill → SelectionSummaryModal opens flashed to the right row.
  - [x] Click attachment pill → file URL opens in new tab.
  - [x] Open OLD pre-feature thread → legacy 3-section bubble (regression check).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Wait for CI to go green and request review**

---

## Self-Review Checklist

Before handing off:

- [ ] Both pills support `mode: "edit" | "view"` and the visuals match between modes (same border, bg, height, paddings).
- [ ] `SelectionRefNode` / `AttachmentRefNode` no longer carry inline JSX — they only wire the handlers context and delegate to the pill component.
- [ ] `KvUserBubbleInline` correctly resolves selection refs to 1-based indices by box-id position, attachment refs by id, and renders nothing for unresolved refs (no console warnings, no placeholders).
- [ ] `ChatStreamMessage.blocks` populated on BOTH paths: optimistic `send()` insert + server-hydrated `hydrateInitialMessages`.
- [ ] `KvChat` fork is `m.blocks && m.blocks.length > 0` — falsy `blocks` falls through to the legacy layout intact.
- [ ] Read-only `SelectionSummaryModal` mount passes `focusBoxId` and clears it on close. Live (editor) mount unchanged.
- [ ] No new dependencies. No PostHog flag (ships as the default rendering path per spec).
- [ ] All commits TDD-leaning (test in Storybook → adjust → ship; type-check at every milestone).
