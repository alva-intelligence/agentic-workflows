---
title: Studio Projects & KV Generator
slug: studio-projects-kv-generator
author: daffa
created: 2026-04-23
status: draft
services: [web, api, ai-service]
---

# Studio Projects & KV Generator — Design Spec

## Overview

Introduce a **Project** (folder) layer in Studio that groups files produced by tools (KV Generator, Image Editor, Resizer, future). A Project carries a brief — name, description, and a "use brand knowledge" toggle — that seeds the AI context when KV Generator runs inside it. KV Generator is rebuilt with a chat-first experience (Chat vs. Image modes), a canvas that shows generated versions, and a streaming pipeline that reuses the existing chat infrastructure.

The existing Studio home layout (Projects section on top + All Tools below) is preserved. The Projects section now renders the new folder grid / empty state. The existing `studio_projects` table is repurposed: it's renamed to `studio_files` (since each record already represents one file tied to one tool), and `studio_projects` becomes the new folder entity.

## Goals

- Give users a durable, brand-scoped container (Project) for work across Studio tools.
- Seed KV Generator with project brief + optional brand knowledge automatically when launched from inside a Project.
- Rebuild KV Generator's interaction model around chat (with Chat / Image modes), a versioned canvas, and reusable existing chat components.
- Keep standalone (orphan) flows intact — launching KV Gen / Image Editor / Resizer from Studio home still works without a Project.

## Non-Goals

- Image Editor / Resizer are NOT made project-aware in this spec. They stay context-free; files they produce can be assigned to a project later.
- No project sharing, no ACLs beyond workspace scoping.
- No multi-project files (one file belongs to at most one project).
- No file move bulk operations (single-file move only).
- No resumable generation streams across page reloads (if the tab closes mid-render, the placeholder is lost; completed generations are persisted as they finish).

## User Stories

- As a marketer, I want a Project folder to group KV files + references for a specific campaign, so that I can resume and share context across sessions.
- As a creator, I want the KV Gen AI to know my project's brief so I don't re-explain it every time.
- As a creator, I want to toggle whether the AI uses our brand knowledge per project, without affecting other projects.
- As a creator in a hurry, I want to still use KV Gen from Studio home without creating a Project — a quick one-off.
- As a creator, I want to brainstorm with the AI (Chat mode) before generating, and switch to Image mode when I'm ready.

## Scope — services touched

- **api (Laravel)**: data model rename + new entities, new endpoints, internal callback for generation persistence.
- **web (Next.js)**: new routes (project detail, KV Gen canvas), new components, mode system, SSE wiring.
- **ai-service (FastAPI)**: new `kv_generator` agent, context builder (project brief + brand knowledge), streaming event protocol.

## Data Model

### Rename: `studio_projects` → `studio_files`

The existing `studio_projects` table is repurposed: each record already represents a single file produced by one tool. Renamed in place.

```
studio_files  (renamed from studio_projects)
  id                ulid PK
  workspace_id      ulid FK → workspaces        cascadeOnDelete
  brand_id          ulid nullable FK → brands   nullOnDelete
  tool_id           ulid FK → tools             cascadeOnDelete
  created_by        ulid FK → users             cascadeOnDelete
  last_edited_by    ulid FK → users             cascadeOnDelete
  name              string
  status            string default 'draft'
  thumbnail_url     string nullable
  last_edited_at    timestamp
  metadata          jsonb nullable
  created_at        timestamp
  updated_at        timestamp

  -- NEW columns added
  project_id        ulid nullable FK → studio_projects   SET NULL
  thread_id         ulid nullable FK → user_threads      SET NULL

  index (workspace_id, last_edited_at)
  index (workspace_id, last_edited_by, last_edited_at)
  index (project_id, last_edited_at)          -- NEW
```

`thread_id` links a file to its chat thread. Nullable because Image Editor / Resizer files don't have a thread.

### New table: `studio_projects` (the folder)

```
studio_projects
  id                    ulid PK
  workspace_id          ulid FK → workspaces        cascadeOnDelete
  brand_id              ulid FK → brands            required, cascadeOnDelete
  created_by            ulid FK → users             cascadeOnDelete
  last_edited_by        ulid FK → users             cascadeOnDelete
  name                  string                      required (1–80 chars)
  description           text nullable
  use_brand_knowledge   boolean default false
  thumbnail_url         string nullable             (derived from latest file)
  last_edited_at        timestamp                   default now
  created_at            timestamp
  updated_at            timestamp
  deleted_at            timestamp nullable          (soft delete)

  index (workspace_id, brand_id, last_edited_at)
  index (workspace_id, created_by, last_edited_at)
```

Decisions:
- **Soft delete**: yes. On soft-delete, the project service explicitly updates its files' `project_id = NULL` in the same DB transaction (the FK `SET NULL` only fires on hard-delete; soft delete leaves the row in place, so we orphan files at the application layer). Files survive.
- **`brand_id` required**: Studio home is always brand-scoped; a project without a brand has no place to live.
- **`files_count`**: computed on the fly via `COUNT(studio_files WHERE project_id = ?)`. Not denormalized.
- **`thumbnail_url`**: nullable; updated by backend when a file inside the project updates its thumbnail. Web falls back to a generated initials tile if null.

### Update: `studio_activities`

```
studio_activities
  id             ulid PK
  workspace_id   ulid FK
  user_id        ulid FK
  file_id        ulid nullable FK → studio_files       SET NULL  -- renamed from project_id
  project_id     ulid nullable FK → studio_projects    SET NULL  -- NEW (the folder)
  tool_id        ulid nullable FK → tools              SET NULL
  brand_id       ulid nullable FK → brands             SET NULL
  action         string
  summary        string
  metadata       jsonb nullable
  created_at     timestamp
```

Activity rows now identify both the folder context and the file, independently nullable.

### New table: `kv_generations`

```
kv_generations
  id                      ulid PK
  studio_file_id          ulid FK → studio_files       cascadeOnDelete
  parent_generation_id    ulid nullable self-FK        SET NULL
  chat_message_id         ulid nullable FK → user_chat_histories  SET NULL
  version_number          int                          (auto-increment per file)
  image_url               string                       (final rendered image)
  thumbnail_url           string nullable
  prompt_snapshot         text                         (the expanded prompt used)
  model                   string                       (e.g. 'gemini-2.5-nano-banana')
  ai_service_run_id       string nullable              (correlation for debug)
  metadata                jsonb nullable               (aspect_ratio, style_preset, seed, etc.)
  created_at              timestamp
  created_by              ulid FK → users              cascadeOnDelete

  index (studio_file_id, version_number)
  index (studio_file_id, created_at)
```

### Reused chat tables (no schema change)

KV Gen reuses `user_threads` and `user_chat_histories`.
- `user_threads.thread_type` — add new enum value `kv_generator`.
- `user_threads.launch_context` (jsonb) — carries `{ project_id?, studio_file_id, use_brand_knowledge, brand_id }` so the AI service understands the scope without extra lookups.
- `studio_files.metadata.current_mode` — persisted mode: `'chat'` or `'image'`. Defaults to `'chat'` on file creation. Stored on the file (not on the thread) because mode is a KV-Gen-specific concept.

### ThreadType enum (PHP)

```
App\Enums\ThreadType
  Chat           = 'chat'
  PointAndAsk    = 'point-and-ask'
  KvGenerator    = 'kv_generator'   -- NEW
```

### Relationship diagram

```
studio_projects (folder)
    │  1
    │
    │  *
studio_files (file)  ──────►  user_threads  ──►  user_chat_histories
    │  1                           (chat messages, AI responses,
    │                               question cards, mode suggestions)
    │  *
kv_generations (canvas versions; self-ref for iteration chains)
```

## API Contracts

### Studio Projects (folders)

```
GET    /api/studio/projects?brand_id&search&page&limit    List projects (workspace + brand scope)
POST   /api/studio/projects                                Create { name, description?, brand_id, use_brand_knowledge }
GET    /api/studio/projects/{id}                           Detail (includes files_count, settings)
PATCH  /api/studio/projects/{id}                           Update { name?, description?, use_brand_knowledge? }
DELETE /api/studio/projects/{id}                           Soft delete; files → orphan

GET    /api/studio/projects/{id}/files?tool_slug&page      Files inside a project
```

### Studio Files

```
GET    /api/studio/files?project_id&tool_slug&scope&page   List; `project_id=null` → orphans only
PATCH  /api/studio/files/{id}                              Rename { name }
PATCH  /api/studio/files/{id}/move                         { project_id: string|null }  — reassign or orphan
DELETE /api/studio/files/{id}                              Soft delete; cascades kv_generations
```

Move validation: target project's `brand_id` must equal file's `brand_id`; else 422.

### KV Generator file lifecycle

```
POST   /api/studio/kv-generator/files                      Create file; body: { project_id?, initial_prompt? }
                                                           → creates studio_files row + user_thread; returns both
GET    /api/studio/kv-generator/files/{id}                 Detail: file + thread_id + generations + messages
GET    /api/studio/kv-generator/files/{id}/generations     Paginated versions
```

### Chat (existing, extended)

```
POST   /api/chat/stream
Body adds:
  thread_type:     'kv_generator'
  mode:            'chat' | 'image'
  launch_context:  { project_id?, studio_file_id, use_brand_knowledge, brand_id }
```

No new route; existing chat stream handler forwards appropriately to the AI service based on thread_type.

### Internal callback (signed, AI service → API)

```
POST /api/internal/kv-generator/generation-complete
Auth: signed internal token (existing pattern)
Body: {
  studio_file_id,
  image_url,
  thumbnail_url,
  prompt_snapshot,
  model,
  parent_generation_id?,
  chat_message_id,
  metadata,
}
→ API writes kv_generations row; updates studio_files.thumbnail_url + last_edited_at;
  logs studio_activities (action: 'kv_generated').
```

### Response shapes

- `StudioProjectResource`: `{ id, name, description, use_brand_knowledge, brand_id, thumbnail_url, files_count, last_edited_at, created_at }`
- `StudioFileResource`: `{ id, name, tool, status, thumbnail_url, project_id, thread_id, last_edited_at, ... }` (unchanged shape from current `StudioProjectResource` + two new fields)
- `KvGenerationResource`: `{ id, studio_file_id, version_number, image_url, thumbnail_url, prompt_snapshot, model, parent_generation_id, metadata, created_at }`

## AI Service — KV Generator Agent

### Agent layout

```
ai-service/app/agents/kv_generator/
  __init__.py
  request_schema.py      Stream request Pydantic model
  response_schema.py     SSE event types
  service.py             orchestration — brief injection, chat loop, image gen
  router.py              POST /ai/kv-generator/stream
  prompts/
    system_prompt.py     base KV prompt (role, output schema guidance)
    chat_mode.py         chat-mode-specific additions
    image_mode.py        image-mode-specific additions
  context_builder.py     loads project + brand knowledge; builds system context
```

### Stream request

```
POST /ai/kv-generator/stream
{
  thread_id, studio_file_id,
  mode: 'chat' | 'image',
  prompt: string,
  launch_context: { project_id?, use_brand_knowledge, brand_id },
  chat_history: [...],              # provided by API
  attached_generation_id?: string,  # when iterating on an existing version (image mode)
  style_preset_id?: string,         # from the "Style" chip
  aspect_ratio?: string,
}
```

### Stream events (SSE)

| Event                | Chat mode | Image mode | Payload                                                        |
|----------------------|:---------:|:----------:|----------------------------------------------------------------|
| `thinking`           |     ✓     |     ✓      | `{ chunk: string }`                                            |
| `message`            |     ✓     |     ✓      | `{ text, chat_message_id }`                                    |
| `question_card`      |     ✓     |     ✓      | `{ label, options: [{ id, label, thumbnail? }] }`              |
| `mode_suggestion`    |     ✓     |     ✓      | `{ from, to, reason }`                                         |
| `generating`         |     ✗     |     ✓      | `{ stage: 'prompt_expanded' \| 'image_rendering' \| 'finalizing', estimated_ms? }` |
| `generation_done`    |     ✗     |     ✓      | `{ generation: KvGenerationResource }`                         |
| `generation_failed`  |     ✗     |     ✓      | `{ error_code, message, placeholder_id }`                      |
| `done`               |     ✓     |     ✓      | `{}`                                                           |

### Context builder

On every stream request:

1. **Project context** (if `launch_context.project_id`):
   - Fetch `{ name, description, use_brand_knowledge, brand_id }` from API internal endpoint.
   - Skip if not scoped.
2. **Brand knowledge** (if `use_brand_knowledge == true` AND `brand_id`):
   - Pull `brand_dna`, `brand_identity`, `brand_tonality` structured summaries from existing brand-knowledge extraction output.
   - Use structured JSON summaries rather than raw chunks; keeps the system prompt under ~4k tokens.
3. **Build system prompt** (pseudocode):

```
SYSTEM:
You are a KV (key visual) generator. You help the user create brand-safe campaign visuals.

[if project] Project: "{name}"
[if project + description] Brief: {description}

[if use_brand_knowledge]
Brand: {brand_name}
- DNA: {brand_dna_summary}
- Identity: {brand_identity_summary}
- Tonality: {brand_tonality_summary}

Current mode: {mode}
- In chat mode you may refine the brief, suggest directions, emit mode_suggestion when the user seems ready to generate.
- In image mode you generate images. If critical attributes are still ambiguous (style, aspect ratio, primary subject), emit a question_card first.

Respect the brief and brand guidance when generating.
```

### Image pipeline

Reuses existing `app/services/image_generation.py` + `app/tools/generate_image.py` + `app/tools/edit_image.py`. KV Gen passes:

- Expanded prompt (user prompt + brief + brand directives + style preset + aspect ratio)
- Optional `parent_generation_id` → loads parent image as reference for variation
- Aspect / style params from question card answers or chip

Output: image uploaded to the existing storage bucket; public URL returned in `generation_done`.

## Web — Routes, Pages, Components

### Route groups

```
app/(dashboard)/studio/
  page.tsx                                  Studio home
  all-files/page.tsx                        Flat files list (existing, kept)
  projects/
    new/page.tsx                            Intercepting modal (create project)
    [id]/page.tsx                           Project detail
  image-editor/...                          (existing, untouched)
  resizer/...                               (existing, untouched)

app/(canvas)/studio/kv-generator/           ← NEW route group, no dashboard chrome
  layout.tsx                                Minimal: auth + providers only
  new/page.tsx                              New session
  [file_id]/page.tsx                        Existing file
```

The `(canvas)` layout owns its full viewport — no top header, no bottom menu from the dashboard. KV Gen renders its own TopNav + BottomNav inside the canvas area.

### Studio home updates

`Studiofrndos.tsx` keeps its shell. Replace the "No Studio projects yet" placeholder with `StudioProjectsSection`:

- **Empty state**: centered folder icon + greeting text + "New Project" CTA (matches Figma Empty frame).
- **Populated state**: grid/horizontal scroll of `ProjectCard` components; first card is "+ New Project" (matches the screenshot reference).
- "All Tools" section below unchanged.

### Project detail page

Two-column layout:
- **Left (main)**: Title + back + files grid. Empty state centered with "Create New" CTA → deep-links to `/studio/kv-generator/new?project_id=[id]`. Populated: mixed-tool `FileCard` grid. Clicking a KV file → `/studio/kv-generator/[file_id]`; Image Editor / Resizer files → their respective routes.
- **Right (settings rail, ~328px wide)**: Description (TextArea, debounced autosave), "Use Brand Knowledge" Toggle (matches Figma). Autosave debounce 500ms.

### New Project modal

Intercepting route at `/studio/projects/new`. Uses `BaseModal`. Fields:
- Name (Input, required, 1–80 chars)
- Description (TextArea, optional)

Toggle `use_brand_knowledge` is NOT in the create modal (matches Figma) — only in the detail settings rail.

On submit → POST → redirect to `/studio/projects/[id]`.

### KV Generator canvas page

Two-column immersive layout (Figma KV Gen):
- **Left (Canvas, ~948px)**: `KvCanvasTopNav` + canvas area (version cards) + `KvCanvasBottomNav`. New versions stream in from SSE.
- **Right (Chat, ~468px)**: TopNav shows file/project name + ChatContent (reuses existing chat message components) + ChatInput (with mode picker + Style chip).

For `/new` without a file yet: chat is in "pre-session" mode. When user sends the first message, web calls `POST /api/studio/kv-generator/files` (creates file + thread), navigates to `/studio/kv-generator/[file_id]`, and the stream starts.

### Chat input — modes and chip

```
┌─────────────────────────────────────────────┐
│ What do you want to ask...                  │
│                                             │
│ [+] [Chat ▾]  [Style]           [⬆ Send]    │
└─────────────────────────────────────────────┘
```

- `[+]` — attach reference (image upload)
- `[Chat ▾]` — mode dropdown: `● Chat` / `○ Image`. Current mode shown as pill.
- `[Style]` — style preset chip (matches Figma). Opens popover with presets; selecting one attaches a style directive to the next message. Detailed preset list deferred to implementation.
- `[⬆ Send]` — submits

### Mode system

- **Chat mode** (default): AI explores, refines, can ask question cards, can suggest mode switch. Never generates.
- **Image mode**: AI aims at generation. Can ask a question card for missing style/aspect/subject. Generates on sufficient context.

Mode stored per-file in `studio_files.metadata.current_mode`. Persisted across reloads. Switching modes is a PATCH to `/api/studio/files/{id}` updating the metadata field, reflected optimistically.

Auto-switch: AI may emit `mode_suggestion` when signal suggests readiness (e.g., user says "let's go" or brief attributes are saturated). Chat renders inline suggestion card — "Start generating" (primary) / "Keep chatting" (secondary). Click "Start generating" sets mode to `image` and re-sends intent.

### Image generation lifecycle (client)

```
[User sends message]
  → optimistic user bubble; POST /api/chat/stream with mode
  
[SSE: thinking]
  → chat: ThinkingIndicator streaming

[SSE: question_card]  (any mode)
  → chat: QuestionCardMessage; stream pauses
  → User picks → user message with { question_card_answer: { option_id } } → stream resumes

[SSE: mode_suggestion]  (any mode)
  → chat: inline suggestion card with Start generating / Keep chatting

[SSE: generating { stage: 'prompt_expanded' }]  (image mode)
  → chat: status line

[SSE: generating { stage: 'image_rendering', estimated_ms }]  (image mode)
  → canvas: placeholder KvVersionCard appears with skeleton + elapsed timer

[SSE: generation_done { generation }]  (image mode)
  → canvas: placeholder swaps to real image (crossfade)
  → chat: AI bubble "Here's version N" with small thumbnail link

[SSE: generation_failed]  (image mode)
  → canvas: placeholder shows error + Retry
  → chat: AI bubble with error text

[SSE: done]
  → input re-enabled
```

Placeholder on the **canvas** (not the chat) — the canvas is the primary output surface.

### Client state — `useKvStream(fileId)` hook

Single SSE subscription shared by canvas + chat. Exposes:

```ts
{
  messages,            // fed to chat panel
  pendingGeneration,   // { placeholderId, startedAt, estimatedMs } | null
  generations,         // completed versions, newest first
  mode,                // 'chat' | 'image'
  send(prompt, opts),  // user message + stream
  setMode(mode),       // PATCH thread metadata + local update
  abort(),             // user cancel
}
```

### Server-side persistence ordering (critical)

On `generation_done`:
1. AI service uploads final image to storage (blocking).
2. AI service calls `POST /api/internal/kv-generator/generation-complete` (signed).
3. API writes `kv_generations` row + updates `studio_files.thumbnail_url` + `last_edited_at` + logs `studio_activities`.
4. AI service emits `generation_done` SSE with the persisted row.

By the time the client receives `generation_done`, the DB already has the row. If the client reloads mid-stream, `useKvGenerations(fileId)` refetch returns the completed row — no duplicate, no missing.

### New components (web)

- `StudioProjectsSection` — home section wrapper (empty/grid)
- `ProjectCard` — folder tile
- `NewProjectModal` — name + description form
- `ProjectDetailLayout` — two-col shell with right-rail
- `ProjectSettingsRail` — description + toggle (autosave)
- `FileCard` — per-file tile (thumbnail, name, tool badge, updated-at)
- `FileEmptyState` — centered empty inside project
- `KvGeneratorLayout` — two-col immersive canvas + chat
- `KvCanvas` / `KvCanvasTopNav` / `KvCanvasBottomNav`
- `KvVersionCard` — single version tile (image + menu: Variation / Image Editor / Resize / Download)
- `QuestionCardMessage` — chat message rendering an option picker
- `ModeSuggestionMessage` — inline chat card for auto-switch
- `ChatInputModeDropdown`, `ChatInputStyleChip` — input chrome additions
- `useKvStream`, `useStudioProjects`, `useStudioProject(id)`, `useKvFile(id)`, `useKvGenerations(fileId)`

### Reused components

Existing chat components in `web/src/components/chat/*` that apply to KV Gen's chat panel: `ChatMessage`, `ChatInput`, `ChatInputToolbar`, `ThinkingIndicator`, `GeneratedFiles`, `useChatInterface`, the SSE client. Plus frndos primitives: `BaseLayout`, `BaseModal`, `Button`, `Input`, `TextArea`, `Toggle`, `Breadcrumbs`.

Note: `ImageGenerationStreamingIndicator` is NOT reused — it was built to render an image-generation placeholder inline in a chat bubble. In KV Gen the generation placeholder lives on the canvas (left pane), not in the chat. Canvas gets its own `KvVersionCard` skeleton state.

### Wireframe deliverable (pre-implementation)

Per CLAUDE.md convention: `web/src/app/(dashboard)/wireframes/<feature-slug>/<wireframe-slug>/`.

```
wireframes/studio-projects-kv-generator/
  page.tsx                              feature index → links into the wireframe
  studio/
    page.tsx                            Main: Studio home (Projects empty + populated)
    components/                         Shared across sub-pages
    projects/
      new/page.tsx                      Create project modal
      [id]/page.tsx                     Project detail (empty + populated + settings rail)
      [id]/kv-generator/page.tsx        KV canvas (empty session, thinking, question card,
                                        mode suggestion, generating placeholder, generated versions)
```

One wireframe (`studio`) with sub-pages. Dummy data, frndos components, no API calls. Uses useState for local interactions (mode dropdown, question card selection, placeholder swap animation).

## Edge Cases

### Projects

| Case                                                 | Behavior                                                       |
|------------------------------------------------------|----------------------------------------------------------------|
| Soft-delete project with files                       | Files `project_id = NULL` (orphan); files survive              |
| Brand deleted                                        | Project's `brand_id` cascade-deletes project (cascadeOnDelete) |
| Rename collision within workspace+brand              | Allowed; no uniqueness                                         |
| Empty project name                                   | 422 validation                                                 |
| Toggle brand knowledge mid-session                   | Next stream request reads new value; prior messages unaffected |

### Files

| Case                                                 | Behavior                                                       |
|------------------------------------------------------|----------------------------------------------------------------|
| Move orphan file into project                        | Works; `last_edited_at` bumped                                 |
| Move file across brands                              | Blocked; 422 with clear error                                  |
| Delete file with generations                         | Cascades `kv_generations`                                      |
| Reopen orphan KV file                                | Works; AI runs without brief context                           |

### KV Gen

| Case                                                 | Behavior                                                       |
|------------------------------------------------------|----------------------------------------------------------------|
| Tab closed during generation                         | Server stream dies; best-effort abort; activity logs failure   |
| SSE reconnect after `generation_done`                | Client refetches on mount; sees row; no double-insert          |
| Concurrent settings edits                            | Last write wins; autosave debounced 500ms                      |
| Question card answered twice                         | First answer wins; dedupe by question_card id in history       |
| Mode switched mid-stream                             | New mode takes effect on NEXT message                          |
| Abort mid-thinking                                   | Stream closes; nothing persisted                               |
| Abort mid-image-rendering                            | Best-effort model abort; placeholder removed                   |
| Generation fails                                     | `generation_failed` event; placeholder shows Retry             |
| Brand knowledge toggle on but no brand               | Toggle disabled with tooltip                                   |

### UX error catalog

| Scenario                              | UI feedback                                                    |
|---------------------------------------|----------------------------------------------------------------|
| Create project validation error       | Inline field error in modal                                    |
| Delete project with files             | Confirmation: "N files will become orphan. Continue?"          |
| Move file to cross-brand project      | Toast: "Can't move — brand mismatch"                           |
| AI service down                       | Chat toast: "Assistant unavailable"; input disabled until retry|
| Image storage upload fail             | `generation_failed` → Retry available                          |
| Orphan file opened in KV Gen          | Banner: "This file isn't in a project — [Assign to project]"   |

## Migration & Rollout

### Migration sequence

1. **Pre-flight**: count rows in current `studio_projects` on staging/production.
2. **A** — rename: `ALTER TABLE studio_projects RENAME TO studio_files`.
3. **B** — add columns: `studio_files.project_id` (nullable FK), `studio_files.thread_id` (nullable FK).
4. **C** — create new `studio_projects` (folder entity) with columns from Data Model.
5. **D** — `studio_activities`: rename `project_id` → `file_id`; add new `project_id` nullable FK to (new) `studio_projects`.
6. **E** — create `kv_generations`.
7. **F** — PHP enum update: add `ThreadType::KvGenerator`.
8. **G** — application-level: ensure web writes `launch_context` with `{ project_id?, studio_file_id, use_brand_knowledge, brand_id }` for KV threads.

All migrations are additive or reversible; the rename is the only non-trivial step. Audit for raw SQL references to `studio_projects` in data pipelines before running.

### Feature flag

Wrap the new Projects section in `NEXT_PUBLIC_STUDIO_PROJECTS_ENABLED`. Default ON for develop/staging; OFF for production until signed off. When off, Studio home hides Projects section entirely.

### Backward compatibility

`/studio/all-files` keeps working throughout the rollout — it reads `studio_files` (post-rename) and shows the same flat list. Worst case during rollout: users see an empty Projects section.

## Analytics / Activity

New `studio_activities.action` values:

- `project_created`, `project_updated`, `project_deleted`
- `file_moved` (metadata: `{ from_project_id, to_project_id }`)
- `kv_generated`, `kv_generation_failed`
- `mode_switched` (metadata: `{ from, to }`)
- `question_card_answered` (metadata: `{ question_card_id, option_id }`)

## Testing

- **API**: feature tests per controller (projects CRUD, files move cross-brand block, kv-generator lifecycle, internal callback signing). Unit tests for model scopes and validators.
- **AI service**: unit tests for `context_builder` (project fetch, brand chunks selection, prompt size cap). Mocked `image_generation` for full agent flow.
- **Web**: Playwright happy path — new project → new KV file → chat mode → auto-switch suggestion → image mode → generate → version on canvas. Component tests for `KvCanvas`, `QuestionCardMessage`, `ProjectSettingsRail`.
- **Integration**: one end-to-end harness hitting api + ai-service with real image model, gated by env flag for CI cost control.

## Acceptance Criteria

- From Studio home, a user can create a new Project, land on its detail page, and see an empty-state CTA that launches KV Gen with the project's brief as AI context.
- KV Gen opened from inside a Project has the project name in chat TopNav. AI responses reference the brief when relevant. Toggling `use_brand_knowledge` ON causes the next response to incorporate brand DNA/identity/tonality.
- Default mode on a new KV file is Chat. AI emits `mode_suggestion` when appropriate; user can accept, ignore, or switch manually.
- In Image mode, the AI generates images; placeholder skeleton appears on the canvas immediately; completed generation swaps in on `generation_done`.
- KV Gen opened from Studio home (not from a project) works without any brief context; resulting file is orphan (no `project_id`); appears in `/studio/all-files`.
- A file can be moved into a project only if brands match.
- Soft-deleting a project orphans its files; files remain accessible via All Files.

## Open Questions

- Style chip preset list — which presets ship on day one? (deferred to implementation)
- Question card schema — how structured do option metadata need to be (e.g., `preview_url`, `semantic_label`)? For MVP: `{ id, label, thumbnail? }`.
- Internal signing — confirm existing pattern used for AI service → API callbacks (reuse rather than reinvent).
- How to prune `chat_history` passed to AI service when threads grow long (truncation strategy). Defer to a follow-up.
