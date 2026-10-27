---
title: Internal Model Tiers — Superadmin Control
slug: internal-model-tiers-superadmin
author: daffa
created: 2026-10-27
status: draft
services: [api, web, ai-service]
---

# Internal Model Tiers — Superadmin Control

## Overview

Internal model tiers (`glue`, `workhorse`, `premium`, `conversation`, `decision`) decide which model ai-service picks for the work **we** choose — memory extraction, summaries, brand tonality, KV chat, edit-intent, listening decisions. Today the only way to change a tier is to edit `ai-service/.env` and restart the service, because `app/utils/config.py` freezes pydantic settings at import.

That cost showed during the 2026-10-26 KV incident: an Anthropic billing failure took down KV chat, and the fix required an env edit plus a restart on every worker — while a superadmin was already sitting in front of an admin panel that can flip Claude routing without a restart.

This feature moves tier configuration into that same panel. The mechanism already exists and is proven in production for LLM routing: a `platform_settings` row written by a superadmin, polled by ai-service over an internal token-guarded endpoint with a 60 s stale-while-revalidate cache plus a push-invalidate on save.

**Who it's for:** superadmins responding to a provider outage, and engineers who need to move one lane (e.g. `conversation`) onto another provider without a deploy.

**Design principles:**
- Reuse the LLM-routing pipeline end to end; no new storage mechanism, no new auth scheme.
- Unset = env default. Every tier field falls back to the existing `INTERNAL_*` env var, so the feature is additive and safe to ship dark.
- Never hard-fail a request on config: a fetch failure keeps the last known value, exactly like `llm_routing`.

## User Stories

| ID | Story | Priority |
|----|-------|----------|
| US-1 | As a superadmin, I want to switch the master internal provider from the admin panel so that a provider outage is resolved without an env edit and a restart. | P0 |
| US-2 | As a superadmin, I want to override one tier (e.g. `conversation`) independently so that I can move only the affected lane. | P0 |
| US-3 | As a superadmin, I want to see which provider/model each tier is *actually* running right now so that I can confirm the flip took effect. | P0 |
| US-4 | As a superadmin, I want to clear an override back to "use env default" so that a temporary incident change does not become permanent drift. | P1 |
| US-5 | As an engineer, I want every tier change recorded in the audit log so that a model change is traceable to a person and a time. | P1 |

## Requirements

### Functional

- **FR-1** — `platform_settings` stores one key per tier field, named 1:1 with the env var it overrides, lowercased: `internal_model_provider`, `internal_<tier>_provider`, `internal_<tier>_model`, `internal_<tier>_effort`.
- **FR-2** — A key that was never saved, or holds a value unknown to the tier tables, resolves to `null` and ai-service falls back to its env var. A stored-but-invalid value is logged as a warning, never raised.
- **FR-3** — `GET /api/v1/admin/internal-models` returns, for every tier: the stored override, the ai-service effective resolution (provider + model + effort), the allowed providers per tier, and the model choices per provider.
- **FR-4** — `PUT /api/v1/admin/internal-models` accepts a partial map of tier fields, validates against the tier tables reported by ai-service, saves every changed key plus a single aggregate audit-log entry in one `DB::transaction`, then pushes to ai-service.
- **FR-5** — Sending `null` for a field clears the override (deletes the key) and returns that lane to its env default.
- **FR-6** — `GET /api/v1/internal/internal-models` (guard `VerifyInternalToken`) returns the stored overrides as a flat map for ai-service polling.
- **FR-7** — `POST /internal/model-tiers/invalidate` on ai-service applies a pushed override map without calling back into api-php.
- **FR-8** — ai-service resolves tier config per call: remote override first, env var second, tier table default third. No restart required.
- **FR-9** — If the push to ai-service fails, the value stays saved and the response carries `warning: "ai_unreachable"`; ai-service picks it up on its next poll.
- **FR-10** — The `decision` tier accepts the `typesafe`, `clef` and `clef-flash` providers; the other tiers must not offer them, because those tables only populate a `decision` entry.
- **FR-11** — Vision lanes keep the existing deepseek→openai auto-fallback; an explicit superadmin override is respected as-is, matching current env-override semantics.
- **FR-12** — The four agents constructed at module import (`brand_tonality_agent`, `report_narrative_agent`, `image_translation`, `benchmarks/explain`) become lazily constructed, so an override reaches them without a restart.

### Non-Functional

- **NFR-1** — Config lookup adds no blocking network call to the hot path: 60 s SWR cache, 2 s fetch timeout, background refresh thread per uvicorn worker (tick 5 s).
- **NFR-2** — A superadmin save is visible to every worker within `TTL_SECONDS + REFRESH_TICK_SECONDS` (≈65 s) even if the push reaches only one worker.
- **NFR-3** — api-php read path stays cached (`PlatformSetting::get`, TTL 3600 s, bust after commit) so ai-service polling does not hit the DB.
- **NFR-4** — Write access is superadmin-only (`auth:api` + `scope_role:internal` + `superadmin`); the internal read endpoint is guarded by `X-Internal-Token`.

## Service Breakdown

| Service | Scope |
|---|---|
| **api** | New `PlatformSetting::KEY_INTERNAL_*` constants, `InternalModelTiersService`, `AdminInternalModelTiersController` (GET/PUT), `InternalModelTiersStateController` (internal GET), request validation, audit log, feature tests. |
| **ai-service** | New `app/utils/internal_model_config.py` (SWR cache cloned from `llm_routing`), `app/routes/model_tiers_internal.py` (`/status`, `/invalidate`), `internal_models.py` reads override before env, lifespan wiring, lazy module-level agents, tests. |
| **web** | Third tab in `/admin/models-settings` (`InternalTiersSection`), `useAdminInternalModelTiers` query + mutation, TS types, confirm modal reusing the routing pattern. |
| **data-service** | Not touched. |

## UI/UX

`/admin/models-settings` gains a third pill tab, `Internal tiers`, next to `AskFrnd` and `Routing`.

The section mirrors `LlmRoutingSection`:
- An AdminCard "Currently running" showing each tier's effective provider/model/effort and its source (`admin` / `env` / `last_known`).
- An AdminCard per tier with a provider select, a model select (filtered to that provider's table), an effort select (from the provider's effort vocabulary), and a "Use env default" clear action.
- Saved/Running badges, disabled options with a reason when ai-service reports the provider has no key configured.
- Save opens a confirm modal stating the impact, then toasts success — or a second toast when `warning === "ai_unreachable"`.

Wireframe phase is skipped: this is an admin-only surface that reuses an existing page, existing components (`AdminCard`, frndos `Button`/`Label`), and an existing visual pattern on the same route.

## Data Model

No new table. New rows in `platform_settings` (`key` unique, `value` varchar(255), `updated_by`, timestamps):

| Key | Value domain |
|---|---|
| `internal_model_provider` | `openai` \| `anthropic` \| `deepseek` |
| `internal_<tier>_provider` | provider valid for that tier |
| `internal_<tier>_model` | model id listed in that provider's tier table |
| `internal_<tier>_effort` | effort token accepted by that provider |

`<tier>` ∈ `glue`, `workhorse`, `premium`, `conversation`, `decision`. Clearing an override deletes the row.

## API Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/v1/admin/internal-models` | superadmin | stored overrides + effective state + choices |
| PUT | `/api/v1/admin/internal-models` | superadmin | save partial override map |
| GET | `/api/v1/internal/internal-models` | `X-Internal-Token` | flat override map for ai-service |
| GET | `/internal/model-tiers/status` (ai-service) | `X-Internal-Token` | effective resolution per tier |
| POST | `/internal/model-tiers/invalidate` (ai-service) | `X-Internal-Token` | apply pushed overrides |

## Acceptance Criteria

- **AC-1** — With no rows in `platform_settings`, every tier resolves exactly as it does today from env; `GET /api/v1/internal/internal-models` returns an empty map.
- **AC-2** — A superadmin sets `internal_conversation_provider = openai`; within one request (push) and without any restart, `GET /internal/model-tiers/status` reports `conversation` resolving to `openai`/`gpt-6-luna`, and a KV chat turn runs on it.
- **AC-3** — Clearing that override returns `conversation` to the env value, again without a restart.
- **AC-4** — A non-superadmin receives 403 on both admin endpoints; a missing/invalid `X-Internal-Token` receives 401 on the internal endpoint when the secret is configured.
- **AC-5** — An invalid provider/model/effort combination is rejected 422 and nothing is written.
- **AC-6** — With ai-service down, a save still persists and responds with `warning: "ai_unreachable"`; ai-service adopts the value on its next poll.
- **AC-7** — Every save produces one audit-log entry with the before/after map and the acting user.
- **AC-8** — The four previously import-frozen agents pick up an override without a restart.

## Open Questions

1. Should the panel expose `INTERNAL_DECISION_TASK_PROVIDERS` (JSON per-task map) in v1, or keep it env-only? *Proposal: env-only for now — it is a listening-specific map, not an incident lever.*
2. Should `INTERNAL_TRANSLATE_PROVIDER` join the panel? It is pinned to openai by a latency/cost bench. *Proposal: include it read-only so the panel is a complete picture.*
3. Should a tier override expire automatically (incident TTL) so temporary flips do not drift? *Proposal: out of scope for v1; the audit log plus the "source: admin" badge makes drift visible.*
