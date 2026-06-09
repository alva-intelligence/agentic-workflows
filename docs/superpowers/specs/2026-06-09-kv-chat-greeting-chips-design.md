---
title: KV Chat Greeting Chips — Brand-Aware + Dynamic LLM Suggestion
date: 2026-06-09
author: daffa
status: design
services: [web, api, ai-service]
---

# KV Chat Greeting Chips — Brand-Aware + Dynamic LLM Suggestion

## Problem

The KV chat empty state shows three hardcoded suggestion chips
(`GREETING_CHIPS` in `web/src/components/studio/kv-generator/KvChat.tsx:69`):
"Brainstorm an idea for this project", "Start making a key visual from a
sketch", "Who is XG?". The third is a stale placeholder unrelated to the user's
project. We want chip 3 to be brand-aware and to add a 4th chip that is an
LLM-generated, project-context-aware prompt suggestion.

## Solution

Replace the static chip array with a computed set of up to four chips, rendered
only in the empty state (no chat history):

1. `Brainstorm an idea for this project` — static (kept).
2. `Start making a key visual from a sketch` — static (kept).
3. **Brand-aware:** `Brainstorm a campaign for {brand}` using the active brand
   name. When the file has no brand, fall back to the static
   `Explore brand ideas`.
4. **Dynamic (LLM):** one short, actionable prompt generated from the project
   context (brand + file title + recent generation prompts). Rendered only when
   the backend returns a suggestion; omitted on null/failure. The empty state
   always shows at least three chips.

Clicking any chip behaves exactly as today (`onPickChip(chip)` — fills/sends the
chip text as the user's message).

## Architecture

### web
- Thread `brandName: string | null` from `KvGeneratorLayout` (already resolved
  via `getBrandDetail`, `KvGeneratorLayout.tsx:127`) into `KvChat`.
- New hook `useKvChatSuggestion(fileId)` (TanStack Query):
  - `enabled` only when the empty state is visible (chat has no messages), so it
    never fires once a conversation exists.
  - `staleTime: Infinity` (session cache) — generate once per file-open; do not
    refetch on re-render.
  - Returns `{ suggestion: string | null, isLoading }`.
- Empty state builds the chip list:
  - chips 1–2 static; chip 3 brand-aware (or static fallback); chip 4 =
    `suggestion` when present.
  - While the suggestion is loading, render a subtle skeleton chip in slot 4;
    when it resolves to `null`, drop slot 4 entirely (progressive — chips 1–3
    are always immediate).

### api
- New endpoint: `GET /api/v1/studio/files/{file}/chat-suggestion` → `{ data: { suggestion: string | null } }`.
- Controller authorizes the file (same `workspace_id` guard as the other studio
  endpoints), gathers context:
  - `brandName` — resolve from `file.brand_id` (fallback to the parent project's
    brand) → brand name.
  - `title` — the studio file's name/title.
  - `recentPrompts` — the prompts of up to the 3 most recent `KvGeneration` rows
    for the file (whatever prompt/source text the row stores).
- POSTs the context to ai-service `/ai/kv-chat/suggestion` and returns
  `{ suggestion }`. **Any failure (ai-service down, timeout, bad response) →
  `{ suggestion: null }`** — the endpoint never errors the empty state.

### ai-service
- New endpoint `POST /ai/kv-chat/suggestion` with body
  `{ brand_name?: string|null, title?: string|null, recent_prompts?: string[] }`.
- A focused **gpt-4o-mini JSON-mode** call — the same one-off structured-call
  pattern as `classify_logo_directive` (NOT a parallel chat-agent integration;
  reuses the established focused-call approach, consistent with
  `[[feedback_kv_chat_reuses_main_chat_infra]]`).
- System prompt: produce ONE short, actionable chat prompt a designer could send
  to start working on this Key Visual — imperative, brand-aware, no surrounding
  quotes, ≤ ~8 words. Returns `{ "suggestion": "<text>" }`.
- Returns `{ suggestion: null }` on any unhappy path (no API key, bad/blocked
  response, exception) — never raises.

## Data flow

```
empty-state mount (chat empty)
  → web useKvChatSuggestion(fileId)
    → GET api /studio/files/{file}/chat-suggestion
      → gather {brandName, title, recentPrompts}
      → POST ai-service /ai/kv-chat/suggestion  (gpt-4o-mini)
        ← { suggestion: "<text>" }  | null on any failure
      ← { suggestion }
    ← { suggestion }
  → render chip 4 (or skip if null)
```

## Error handling / edge cases

| Case | Behavior |
|------|----------|
| No brand on file | Chip 3 → static `Explore brand ideas` |
| ai-service down / timeout / no key / bad JSON | api returns `suggestion: null`; chip 4 omitted |
| File brand-new (no generations) | Context = brand + title only; suggestion still generated |
| Suggestion loading | Skeleton in slot 4; chips 1–3 immediate |
| Chat already has history | Hook disabled; chips not shown at all (existing empty-state-only behavior) |

## Cost / latency

One gpt-4o-mini call per empty-state open (cheap; only on a fresh/new chat,
never after the conversation starts). Session-cached so re-renders don't refetch.
No DB persistence (YAGNI).

## Testing

- **ai-service** (unit): valid model JSON → `suggestion` string; missing key /
  exception / blocked → `suggestion: null`. Mirror `classify_logo_directive`
  tests (patch the OpenAI client).
- **api** (feature/unit): endpoint gathers context and forwards it; returns the
  ai-service suggestion; returns `suggestion: null` when the ai-service call
  fails (HTTP fake). Respect DB isolation rules (`[[lesson_test_db_isolation]]`,
  `[[lesson_api_feature_suite_blocked_softdeletes]]`).
- **web**: chip 3 renders brand-aware when `brandName` present, static fallback
  when null; chip 4 renders the suggestion when present and is omitted when
  null; the suggestion query is disabled once chat has history.

## Done criteria

- "Who is XG?" is gone; chip 3 is `Brainstorm a campaign for {brand}` (or the
  static fallback when no brand).
- A 4th chip shows an LLM-generated, context-aware prompt when the backend
  returns one; the empty state degrades gracefully to 3 chips otherwise.
- The suggestion endpoint never errors the empty state, and the call is made
  only in the empty state, once per file-open.
