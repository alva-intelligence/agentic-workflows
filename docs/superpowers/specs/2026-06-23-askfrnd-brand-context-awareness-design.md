# Design Spec — Brand-Aware AskFrnd

> **Date:** 2026-06-23
> **Author:** Daffa Praramadhana
> **Status:** draft
> **Surfaces:** Main conversational chat (`chat_agent` default agent) + Point-&-Ask (PAA) agent
> **Repos touched:** `web/`, `api/`, `ai-service/`

## 1. Problem

AskFrnd ("FRienD") has **no brand awareness**. Even when a user states a brand name, AskFrnd does not pull from our internal **Brand Knowledge** — it answers from general/external knowledge instead. We want AskFrnd to treat internal Brand Context as the primary source of truth, scoped to the user's current location.

We must **not** load brand data into every chat by default. A generic prompt ("translate this text") should not pay the token/compute cost of loading Brand DNA. Brand Context must be fetched **on demand, by intent**, and **cached for the rest of the session** once loaded.

### What "Brand Context" means

- **Brand Basic Info:** name + description.
- **Brand Knowledge (Brand IQ):** Brand DNA, Identity, and Tonality (whichever exist).

## 2. Goals (from requirements)

- **Location awareness:** AskFrnd reliably knows whether the user is on Home (Condition B) or inside a specific Brand Workspace (Condition A), and which brand is active.
- **Internal-first:** the agent anchors answers on internal Brand Knowledge; it only falls back to its **own general knowledge** when internal data does not cover the prompt (no forced live web search).
- **Intent-based fetching:** Brand Context is pulled only when the prompt actually requires brand-specific knowledge — via the LLM's native function-calling.
- **Session caching:** once Brand Context is fetched in a chat session, it is persisted for the remainder of that session; follow-up brand questions reuse it with **no duplicate DB fetch**.

### Non-goals

- No live external web search as the supplement mechanism (decided: general knowledge only). The main chat's existing `web_search` tool stays available under `tool_choice="auto"` but is not part of the brand-fallback design.
- No refactor of KV's existing brand pipeline in this scope (we may converge formats later).
- No new brand-editing/ingestion features.

## 3. Decisions locked during brainstorming

| Decision | Choice |
| --- | --- |
| Target surfaces | **Both** main conversational chat and PAA |
| Home (Condition B) overview depth | **Directory + drill-down** — lightweight `{id, name, description}` list of accessible brands; full knowledge fetched on demand for a specific named brand |
| External supplement | **Model general knowledge** (no live web call) |
| Fetch architecture | **B — direct DB read from ai-service** (no Laravel callback → no `php artisan serve` deadlock) |

## 4. Architecture

Two layers:

### 4a. Awareness layer (always on, cheap)
A small **location context** travels `web → api → ai-service` on every message and is injected as a one-line system hint. It never contains deep knowledge, so its token cost is negligible.

- **Condition A (inside `/brands/{id}`):** `active_brand = {id, name, description}`.
  Hint: *"The user is working inside brand **{name}**. Treat its Brand Knowledge as the primary source of truth for brand-related questions."*
- **Condition B (Home):** `brand_directory = [{id, name, description}, …]` of brands the user can access.
  Hint: *"The user is on Home with access to these brands: {names}. If they ask about a specific one, use that brand's Brand Knowledge as the primary source."*

`api` resolves this **before** opening the stream to ai-service (no deadlock). Web already sends `origin_brand_id` / `origin_brand_name` / `origin_path` on thread creation and PAA; `getUrlBrandId()` already distinguishes Home (null) from `/brands/{id}`.

### 4b. Knowledge layer (on-demand, LLM-pulled)
A new Agno tool **`get_brand_knowledge(brand_id)`** registered on both the default `chat_agent` and the PAA agent, under the existing `tool_choice="auto"`.

- The LLM evaluates intent natively: generic prompt → does **not** call the tool; brand-specific prompt → calls it first, then answers.
- The tool reads `brands` + `brand_tonalities` **directly from Postgres in ai-service** and returns DNA + Identity + Tonality + basic info.
- On Home, `brand_id` is resolved by matching the user-named brand against the `brand_directory` provided in the location context.

## 5. The smart trigger (intent gating)

Driven entirely by the LLM via function-calling — no separate classifier.

System-prompt instructions (added to both agents):

- "Internal Brand Knowledge is your primary source of truth for any brand-specific question."
- "For a brand-specific question, call `get_brand_knowledge` **before** answering. For a generic question that needs no brand data (e.g. 'translate this text', 'summarize this'), answer directly and do NOT call the tool."
- "If internal Brand Knowledge does not cover the question, you may answer from your general knowledge — state when you are doing so."
- "Never invent brand facts. If no Brand Knowledge exists for the brand, say so."

## 6. Session caching

- Cache store: **`agno_sessions.session_data`** JSON column (already present), under key `brand_knowledge.{brand_id}`.
- Tool flow:
  1. Look up `session_data.brand_knowledge[brand_id]`. **Hit → return cached, no DB query.**
  2. **Miss →** query Postgres, build the context payload, write it back to `session_data` (write-through), return it.
- This satisfies the DOD: subsequent brand questions in the same thread reuse the loaded context with zero duplicate DB fetch.
- Cache is keyed per `brand_id`, so a multi-brand conversation (Home drill-down across two brands) caches each independently.

## 7. Brand data layer in ai-service

- **`app/repositories/brand_repository.py`** (new) — read-only queries against `brands` + `brand_tonalities`, scoped by workspace/user so a user cannot fetch a brand they don't have access to. Uses the existing SQLAlchemy engine in `app/database.py` (assumes ai-service and api share the same Postgres database — **to be confirmed in planning**).
- **`app/agents/.../brand_context_builder.py`** (new) — Python port of KV's `buildBrandDna` / `buildBrandIdentity` / tonality serialization from `api/app/Services/ChatService.php`, producing the same human-readable block KV already uses (`Brand: …`, `- DNA: …`, `- Identity: …`, `- Tonality: …`). This keeps AskFrnd and KV on one format.

## 8. Changes per repo

### web/
- Verify `origin_brand_id` / `origin_brand_name` / `origin_path` reach the **main chat** stream (already sent on thread creation) and that **PAA** passes equivalent location context.
- If the Home brand directory is not already available server-side, ensure web supplies enough for api to build it (or api derives it from the user's brand list). Expected to be minimal.

### api/
- Resolve A/B **location context** (active brand `{id,name,description}` or `brand_directory`) and add it to the ai-service chat + PAA request payload, **before** streaming. No deep brand knowledge fetched here.
- Extend the ai-service request DTO/payload with the location-context fields.

### ai-service/
- `brand_repository.py`, `brand_context_builder.py`.
- `get_brand_knowledge` tool + registration on `chat_agent` (default) and PAA agents.
- Session-cache read/write in `agno_sessions.session_data`.
- Location-context fields added to `AgentRunDto` (request schema) and injected into both agents' system prompts.
- Prompt updates for internal-first + intent gating.

## 9. Data model (reference — existing)

- `brands`: `id`, `workspace_id`, `user_id`, `name`, `description`, DNA columns (`mission`, `vision`, `target_audience`, `competitors`, `market_positioning`, `brand_purpose`, `brand_pillars`), Identity columns (`color_palettes`, `fonts`, `typographies`, `visual_dos`, `visual_donts`).
- `brand_tonalities` (HasOne on `brand_id`): `archetype`, `target_audience_context`, `key_phrases`, `voice_tone`, `tone_descriptors`, `forbidden_words`.

## 10. Testing

- **ai-service (unit):** `brand_context_builder` output format; `brand_repository` query + access scoping; `get_brand_knowledge` cache hit vs miss (DB queried exactly once); intent-gating behavior (generic prompt does not trigger the tool, brand prompt does).
- **api:** location-context resolution (Condition A vs B) is added to the ai-service payload correctly; access scoping for the directory.
- **web:** location context (`origin_brand_id/name/path` + directory) is sent for both surfaces.

## 11. Edge cases & error handling

- **Brand has no knowledge yet:** tool returns "no brand knowledge available"; model says so / falls back to general knowledge.
- **No active brand and none named on Home:** tool effectively not callable; answer generically.
- **brand_id for a brand the user cannot access:** repository scopes by workspace/user → returns empty; tool reports no access.
- **DB read failure in ai-service:** tool returns a soft error; model degrades to general knowledge rather than failing the turn.
- **Shared-DB assumption false:** if ai-service cannot reach the brand tables directly, fall back to Approach A (api internal callback) for the fetch only — flagged as the primary planning-time risk.

## 12. Open questions (resolve in planning)

1. Confirm `ai-service` and `api` share the same Postgres database (required for direct read).
2. Confirm exactly where api injects payload for the **default chat agent** vs **PAA** so location context lands on both.
3. Confirm whether the Home `brand_directory` is best built in api (from the user's brand list) or supplied by web.
