---
title: KV Agentic Canvas — Intent Layer
slug: kv-agentic-canvas-intent
parent_feature: kv-agentic-canvas
stacked_on: kv-agentic-canvas-p0
author: daffa
created: 2026-10-19
status: approved
services: [ai-service, api, web]
---

# KV Agentic Canvas — Intent Layer

## Overview

The P0 agent edits layers from one chat instruction, but it gets the user's intent right through a stack of prompt rules plus 11 deterministic backstops driven by ~20 bilingual regexes. Each was added for one failure found in manual testing: unstated target, stale refusal history, "logo" read as painted lettering, "brand logo" applied to a look-alike poster, and others. Every new phrasing risks a new failure and a new patch.

This feature puts a **structured intent layer** in front of the canvas agent. A one-shot resolver turns each canvas turn into a `CanvasIntent`: what to do, which layers the user means (candidates with confidence), where to apply it, and with what parameters. A deterministic **validator** then decides to write, ask, or hand off. Ambiguity is decided by code from candidates and confidence, not by the model in free text, and the decision is logged per turn so it can be measured and improved from real usage.

Users: same as P0 (KV Studio, internal scope). It ships behind its own flag, starts in shadow mode, and stacks on the P0 branches.

## Brainstorming Outcome

Build a structured intent layer in front of the KV canvas agent instead of growing per-case regex backstops. A one-shot resolver (house pattern `Agent(output_schema)`, like `kv_generator/edit_intent.py`) turns each canvas turn into `CanvasIntent`: action, references with candidate layers and confidence, targets with their source, params, and needs_clarification. A deterministic validator then writes through the existing canvas tools, asks with a card built from the candidates, or hands the turn to today's agent for brainstorm and pixel edits. The target-card, which-layer and reference-guard backstops fold into it; the stale-history filter and the FR-37b write guard stay as a final safety net.

The resolver gets richer context:
- the canvas selection (already sent since P0);
- per-layer visual descriptions, generated lazily and cached in a side table keyed by asset hash;
- a structured summary of recent runs from `kv_agent_runs`.

Card answers come back as a structured `card_answer`, so a clarification resolves exactly. Clarifications, fast undos and refused mismatches are recorded in a `kv_intent_events` table and as PostHog events, and they feed an exported golden set. The feature ships behind a new flag, `kv-agentic-canvas-intent`, in shadow mode first, so resolver decisions can be compared with the current agent before it is switched on. Its PRs stack on the P0 branches.

### Decisions

- **Resolver placement** → a separate pre-step, `Agent(output_schema=CanvasIntent)`, before the main agent. Not a mandatory tool inside the agent: AGENTS.md notes that output_schema + tools on one run makes the model narrate.
- **Existing backstops** → replaced in phases. The stale-history filter (FR-33) and the reference write guard (FR-37b) stay as the final safety net.
- **Layer descriptions** → side table `kv_layer_descriptions`, generated lazily on first need, cached per asset hash. The overlay payload is untouched (no whitelist churn, no Yjs change).
- **Card answers** → structured `card_answer {card_id, option_id, purpose}` next to the label text, persisted on the user row (precedent: deck `hidden_context.questionAnswers`).
- **Learning signals** → api table `kv_intent_events` + PostHog `kv_agent.intent_*`. Golden-set export script with anonymised prompts.
- **Rollout** → new flag `kv-agentic-canvas-intent`, shadow mode first.
- **Shadow → on** → after ≥1 week and ≥200 internal canvas turns, the resolver's decision matches the accepted outcome in ≥90% of turns, and the eval stays 66/66.
- **Latency** → resolver p95 ≤ 3 s. On timeout or error, fall back to today's path and log `resolver_timeout`.
- **Prompt logging** → verbatim in the api DB (internal, file-scoped access), anonymised on export. PostHog gets kinds and counts only, no prompts.
- **Composability (Studio growth, AskFRND best practice)** → intent first, refactor later. The KV stream stays and will share components later (it does not move into the AskFRND runner). Deck is not migrated now. This feature only keeps its new code surface-neutral (FR-14–19). The full Editor Surface foundation (SurfaceSpec registry, EditorChatContext, AgentRun base, `agent_runtime` fallback, web card registry) is a follow-up feature, `studio-agent-surface`.

## User Stories

- As a KV user, when I say "the logo", "this", "the headline on the story", the edit lands on the layer I mean, even when its name is a PSD default.
- As a KV user, when it is genuinely unclear, I get one short card listing the real candidates (with board and position), and my pick is applied exactly.
- As a KV user, a request about a layer never turns into a paid re-render unless I ask to change the picture itself.
- As the team, I can see per turn what the system understood (action, references, confidence, decision), and measure how often it was wrong (clarifications, fast undos).
- As the team, the golden set grows from real prompts, not only from cases we invent.

## Requirements

### Functional Requirements

**Resolver (ai-service)**

- **FR-1:** On a flagged canvas turn (P0 conditions + flag `kv-agentic-canvas-intent`), before the agent runs, a one-shot resolver produces `CanvasIntent`:
  ```jsonc
  { "action": "resize|move|rotate|hide|show|restack|text|style|add|remove|undo|pixel_edit|brainstorm|other",
    "references": [{ "phrase": "brand logo",
        "candidates": [{ "layer_id": "…", "board_id": "…", "confidence": 0.0-1.0, "why": "…" }] }],
    "targets": { "board_ids": [], "size_ids": [], "include_sizes": null, "source": "stated|selection|active_board|reference|none" },
    "params": { /* action-specific: scale, dx/dy, text, style keys, anchor… */ },
    "needs_clarification": false, "clarify_reason": null }
  ```
  It uses the house pattern (`Agent(model=internal_model("conversation", vision=…), output_schema=CanvasIntent)`, tracing post-hook `kv_canvas_intent`). Its context: the prompt, the inventory (`kv_canvas_state`), `active.selected_layer_ids`, layer descriptions (FR-6), the recent-runs summary (FR-7), and the `card_answer` when the turn answers a card (FR-8). No raw history.
- **FR-2:** Candidates are only layer ids present in the inventory. Ids that are not present are dropped. Every reference lists all plausible candidates, not just the best one.

**Validator (ai-service, deterministic)**

- **FR-3:** Decision rules, first match wins:
  1. `action ∈ {brainstorm, other}` → **handoff** to today's agent path, unchanged.
  2. `action = pixel_edit` and no reference has a candidate with confidence ≥ 0.6 → **handoff** (the agent may offer the re-render). The floor equals the rule-5 minimum (raised from 0.4 on 2026-10-20): below it, a which-layer card could only lead to the same handoff.
  3. A `card_answer` resolves a reference → that candidate wins with confidence 1.0.
  4. A selected layer that is a candidate → it wins.
  5. Any reference whose top candidate is < 0.6, or whose top two are within 0.15 → **ask**: a which-layer card from those candidates (max 5, "<name or position> on <board>").
  6. Targets `source = none` and the reference spans more than one board → **ask**: the target card (existing options).
  7. Otherwise → **write**: build the `update_kv_layers` / `add_kv_layer` / `remove_kv_layers` / `undo_kv_agent_run` call(s) from the intent and run them through the existing canvas tools (ledger, guard, run, run card all unchanged). Then a short agent turn writes the reply from the tool results (the honesty footnote still applies).
- **FR-4:** The validator's thresholds are constants in one module, covered by tests, and tunable from shadow data.
- **FR-5:** Backstops fold in, in phases. With the flag on, the target card (FR-18 backstop), which-layer cards (FR-35 B/C) and the reference guard come from the validator. The stale-history filter (FR-33 D/E) and the FR-37b write guard remain as the final safety net. With the flag off, P0 behaviour is unchanged.

**Context (api + ai-service)**

- **FR-6:** Per-layer visual descriptions.
  - Storage: api table `kv_layer_descriptions(studio_file_id, layer_id, asset_hash, description ≤ 160 chars, model, created_at)`.
  - On a flagged canvas turn, api sends known descriptions in the inventory (`layer.description`). For image layers without one (or with a changed asset hash), it enqueues one batch job: an ai-service vision endpoint describes up to N layer PNGs in one call, and the results are stored.
  - Layer-decomposition commits store the vendor `description` that is dropped today.
  - The turn never waits for descriptions; missing ones are just absent.
- **FR-7:** Recent-runs summary. `KvAgentCanvasTurn` adds `recent_runs` (last 3 runs on the file: action/change, layer name or hint, targets, status incl. undone, age) to `agent_canvas`. The resolver uses it to read "again / lagi / undo that" and must not copy a previous target when the user names a different thing.
- **FR-8:** Structured card answers.
  - ai-service gives every question card a `card_id`, and every option keeps its `id`.
  - Web sends `card_answer {card_id, option_ids[], purpose, surface: "kv_canvas"}` with the label text when an option is picked.
  - api validates it in a standalone `CardAnswer` value object (not inline in the KV branch), persists it on the user row as `message.card_answer`, and forwards it to ai-service on the next turn.

**Shadow mode + learning**

- **FR-9:** Shadow mode (flag variant `shadow`). The resolver and validator run and their decision is logged, but the turn follows the P0 path. Shadow runs in parallel with the agent and never delays the turn.
- **FR-10:** `agent_intent_events` (api, `surface = kv_canvas`) records:
  - `decision` (every flagged turn: intent JSON, validator decision, latency, shadow|live, model);
  - `clarified` (card_answer received: card purpose, candidates shown, option picked);
  - `undone_fast` (a run undone within 5 min of creation, derived when undo happens);
  - `mismatch_refused` (FR-37b guard fired);
  - `resolver_timeout`.

  Prompt text is stored verbatim; rows are scoped to the studio file.
- **FR-11:** PostHog `agent_intent.decision`, `agent_intent.clarified`, `agent_intent.fast_undo` (property `surface: kv_canvas`) with kinds, counts, confidence buckets and latency. No prompt text.
- **FR-12:** A golden-set export script (ai-service `scripts/`) turns `agent_intent_events` into eval cases with expected references and targets. It anonymises brand names, emails and numbers, and remaps ids. Cases land in the FR-18 runner, which gains intent-level scoring: action, reference → layer ids, targets, ask vs write.
- **FR-13:** A shadow comparison report (script or SQL): agreement between the resolver decision and the accepted outcome, broken down by action and language.

**Composability seams** (KV stays the only surface now; these keep the later `studio-agent-surface` refactor a move, not a rewrite)

- **FR-14:** The resolver and validator live in a surface-neutral package `app/agents/canvas_intent/`. They depend on an `IntentSurface` protocol: render the inventory for the prompt, validate candidate ids, list allowed actions, build tool calls from an intent. `KvCanvasIntentSurface` is the only implementation. Nothing in the package imports `kv_generator`.
- **FR-15:** `card_answer` (FR-8) is the generic shape the deck `questionAnswers` protocol will later migrate to. No KV-specific key names on the wire or in message metadata.
- **FR-16:** The intent event table is `agent_intent_events`, with a `surface` column (`kv_canvas`), not `kv_intent_events`. PostHog events are `agent_intent.*` with a `surface` property.
- **FR-17:** The canvas context and resolver prompts use `fence_nonce(thread_id)` (`chat_agent/project_context_prompt.py`) instead of a per-turn nonce, so the provider prompt cache stays warm across turns.
- **FR-18:** The eval harness is committed as a surface-neutral runner (`evals/surface_runner/`): golden JSON per surface (`evals/golden/kv_canvas/*.json`), real or scripted model, faked `mcp/tools`. The P0 golden set (G01–G22) moves into it unchanged.
- **FR-19:** New AskFRND-convention rules apply to anything this feature adds: tool labels come only from `TOOL_NAME_ENUM` (no new entries in KV's hand map `_tool_name_slug`), and new tool or endpoint access goes through `mcp/tools` + `ResolveToolContext` with an `FrndosServer` mirror, per `build-askfrnd-tool`.

### Non-Functional Requirements

- **NFR-1 (latency):** resolver p95 ≤ 3 s. Hard timeout 4 s, then fall back to the P0 path (`resolver_timeout`). Live mode adds at most one resolver call per canvas turn; non-canvas turns pay nothing.
- **NFR-2 (cost):** the resolver uses the conversation tier with a compact prompt (inventory capped as in P0). Description generation is batched per file and cached by asset hash.
- **NFR-3 (safety):** flag fail-closed. Shadow never writes. Every write still goes through the P0 tools, ledger, guard and undo.
- **NFR-4 (privacy):** prompts are stored only in the api DB, scoped to the studio file. They are anonymised on export and absent from PostHog.
- **NFR-5 (quality gate):** eval G01–G22 stays 66/66 (3 trials, default model), plus new intent cases (FR-12) at ≥ 90%. Shadow → on needs ≥ 90% agreement over ≥ 200 internal turns and ≥ 1 week.

## Service Breakdown

### AI Service (`ai-service/`)
- `app/agents/canvas_intent/`: `CanvasIntent` schema, resolver agent, prompt, validator (FR-3/4), `IntentSurface` protocol (FR-14).
- `app/agents/kv_generator/canvas_intent_surface.py`: `KvCanvasIntentSurface` (inventory render, id checks, tool-call builder).
- Wiring in `_run_chat_mode`: live vs shadow, the timeout fallback, and the reply turn after validator writes.
- Phased removal of the backstops behind the flag (FR-5).
- Card ids (FR-8).
- Vision batch-describe endpoint (FR-6).
- Committed surface-neutral eval runner (FR-18), intent scoring and golden export script (FR-12).

### API (`api/`)
- Migrations: `kv_layer_descriptions`, `agent_intent_events`.
- Inventory: `layer.description` and `recent_runs` (FR-6/7).
- Description job dispatch + callback.
- Store the decomposition vendor descriptions.
- `card_answer` on the stream request: `CardAnswer` value object, persisted as `message.card_answer`, forwarded (FR-8/15).
- Intent event ingestion: ai-service → api internal route, plus fast-undo derivation in the reverter.
- Flag `kv-agentic-canvas-intent` with a shadow variant.
- Shadow comparison query.

### Frontend (`web/`)
- Send `card_answer` with card picks.
- Flag plumbing (none visible beyond P0 cards).
- `agent_intent.*` events where web-side (clarified).
- No new UI; the cards are the existing P0 cards.

### Data Service (`data-service/`)
No changes.

## UI/UX

No new screens. The which-layer and target cards from P0 become the single clarification surface, now built from resolver candidates. Option descriptions keep the "<board> · <position>" format.

No wireframe is needed: the UI is unchanged from the approved P0 wireframe (frnd-web #1022).

## Data Model

### New Tables
- `kv_layer_descriptions`: `id`, `studio_file_id` FK, `layer_id`, `asset_hash`, `description` (≤160), `model`, `created_at`. Unique on (`studio_file_id`, `layer_id`, `asset_hash`).
- `agent_intent_events`: `id` ULID, `surface` (`kv_canvas`), `studio_file_id` FK (nullable for future non-file surfaces), `thread_id`, `run_id` (nullable), `user_id`, `workspace_id`, `kind` (decision|clarified|undone_fast|mismatch_refused|resolver_timeout), `mode` (shadow|live), `prompt` (text, nullable), `payload` jsonb, `latency_ms`, `created_at`. Index on (`surface`, `studio_file_id`, `created_at`) and on (`kind`, `created_at`).

### Modified Tables
- User chat message rows: `card_answer` in message metadata (no column change).

## API Endpoints

| Method | Endpoint | Description | Service |
|--------|----------|-------------|---------|
| POST | `/ai/kv-canvas/describe-layers` | Batch vision descriptions for layer PNGs | ai-service |
| POST | `internal/kv-files/{id}/layer-descriptions` | Store descriptions (callback) | api |
| POST | `internal/agent-intent-events` | Ingest intent events from ai-service | api |
| POST | `v1/threads/{id}/stream` (modified) | Accepts `card_answer` | api |
| POST | `/ai/kv-generator/stream` (modified) | `agent_canvas.recent_runs`, `layer.description`, `card_answer` | ai-service |

## Existing System Reconciliation

- **Backstops inventoried** (ai-service p0): target card, which-layer card (×2), history filter, stale retry, card purpose, reference guard, targets_required, honesty footnote, plus the pre-P0 refusal and concept-card guarantees. FR-5 maps which ones fold in and which stay.
- **Structured output:** follows `kv_generator/edit_intent.py` (output_schema, confidence threshold, fails safe). The forced-tool pattern in `kv_chat/suggestion.py` is legacy per the agno-first audit and is not used.
- **Decision tier (Jev/Clef):** fits closed-label questions only. It cannot produce free-form params, so the resolver uses the conversation tier.
- **Overlay payload whitelist:** `StudioOverlayNormalizer` + `StoreBrandOverlayPresetRequest` strip unknown keys. This is why descriptions go to a side table rather than the payload.
- **Layer decomposition:** the vendor already returns descriptions (`kv_layer_decompose/mapping.to_layer`), and they are dropped at commit today; FR-6 keeps them.
- **Card answers:** today they are label text only. Deck chat's `hidden_context.questionAnswers` is the precedent for a structured answer.
- **Telemetry:** `StudioActivityAction::QuestionCardAnswered` exists but nothing writes it. FR-10 either uses `agent_intent_events` or writes that action too; decided in the api service PRD.
- **AskFRND / Deck parity (mapped 2026-10-19, deferred to `studio-agent-surface`):** KV P0 shares the low-level pieces with AskFRND (`mcp/tools` + MCP mirror, `internal_models` tiers, `tracing_post_hooks`, `TOOL_NAME_ENUM`, `ToolUsageIndicators`). It duplicates the layers above them:
  - tool assembly: `_agno_chat_stream` vs `_build_scoped_tools` + `ChatToolTogglesDto`;
  - surface context: `KvAgentCanvasTurn` vs the `*ChatContextAssembler` convention;
  - the question-card protocol: the `present_question_card` shim vs `ask_deck_questions` + `questionAnswers`;
  - the run ledger: `KvAgentRun*` vs `DeckAgentRun*`;
  - the stream mapper;
  - web chat: `useKvStream`/`KvChat` vs `useChatStore`/`ChatMessage`/`DeckChatActionsContext`.

  KV also has no model fallback (`_paa_stream_with_fallback`). This feature does not refactor them (decision: intent first); FR-14–19 keep the new code on the shared side of each seam.

## Assumptions and Clarifications

- The resolver sees the board image only when needed: `vision=True` only if a reference cannot be matched from names, kinds or descriptions. This keeps latency inside NFR-1 [to validate in shadow].
- Shadow-mode comparison treats "the user accepted" as no fast undo, no follow-up correction within 2 turns, and no card re-ask.
- P0 must be merged (or at least frozen) before this feature's PRs are retargeted. Until then they stack on `feature/daffa/vc-kv-agentic-canvas-p0`.

## Acceptance Criteria

- [ ] AC-1: With `kv-agentic-canvas-intent` off, behaviour is byte-identical to P0 (eval G01–G22 66/66).
- [ ] AC-2: In shadow mode, every flagged canvas turn writes one `decision` event. The turn's latency and output are unchanged vs P0.
- [ ] AC-3: In live mode:
  - "kecilkan brand logo 20%" on the HUT-RI Variant 6 history case resolves to the `brand logo` layer without the FR-37b guard firing;
  - "Kecilkan logonya" with 4 logo layers produces a which-layer card from candidates;
  - "kecilkan ini" with a selected layer writes that layer.
- [ ] AC-4: Picking a card option sends `card_answer`, and the next turn writes exactly that layer (no re-interpretation).
- [ ] AC-5: Layer descriptions are generated once per asset, reused on later turns, and appear in the inventory. A decomposed layer keeps the vendor description.
- [ ] AC-6: An undo within 5 min writes an `undone_fast` event, and a card pick writes a `clarified` event. The PostHog events carry no prompt text.
- [ ] AC-7: The golden export produces anonymised cases. The committed surface runner scores intent-level cases, and the new cases score ≥ 90% on the default model.
- [ ] AC-8: Resolver p95 ≤ 3 s in shadow over ≥ 200 turns. Timeouts fall back cleanly and are logged.
- [ ] AC-9: With the flag live, the folded-in backstop code paths are removed from the live path (kept only for flag-off), and eval stays 66/66.
- [ ] AC-10: `app/agents/canvas_intent/` has no import of `kv_generator`, and its validator tests run against a fake `IntentSurface`. `card_answer` and `agent_intent_events` carry `surface`. No new entries in `_tool_name_slug`.

## Open Questions

- [ ] Q-1: Description model and batch size (gpt-6-luna vision vs workhorse) — decided from a cost/latency check in implementation.
- [ ] Q-2: Retention for `kv_intent_events.prompt` (90 days?).
- [ ] Q-3: Whether `StudioActivityAction::QuestionCardAnswered` should also be written for the activity feed.
