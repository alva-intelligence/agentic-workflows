# Video Generation Parameters → PostHog — Design

> **Status:** design (approved in brainstorming 2026-07-09)
> **Author:** daffa
> **Type:** observability enrichment
> **Services:** ai-service only
> **Related:** dimension-aware video pricing + DB cost-audit (`2026-07-06`, `2026-07-09-video-cost-audit-metadata`)

## Overview

Every video generation should emit a PostHog `$ai_generation` event carrying its
billing **dimensions** as flat, filterable properties, so the AI-observability
**Generations** view can segment video traces by resolution / mode / audio without
SQL. Dimensions only — no cost. ai-service only, no pricing duplication.

This is the analytics complement to the DB `video_params` column (financial audit):
same dimension values, different store, different shape — flat properties for
click-to-filter analytics vs. one `jsonb` column for ad-hoc SQL audit.

## Problem

`capture_ai_generation` (`app/observability/ai_clients.py:297`) already emits
`$ai_generation` events and accepts `**extra_properties` (verified: non-null values
become **top-level** event properties via `ph_ai_kwargs`, `ai_clients.py:266-268`).
But today:

- **Replicate** models (**Seedance**/`bytedance`, **Kling**/`kuaishou`,
  **Hunyuan**/`tencent`) are **already captured** at the shared chokepoint
  `replicate_client.py::run_with_retry` (`provider="replicate"`,
  `span_name="replicate_run"`, success + error paths). **Veo** (`google`) and
  **Sora** (`openai`) are captured by their own branch-level
  `capture_ai_generation` calls in `generate_video`.
- But **none attach the video dimensions**, so there's nothing to segment on beyond
  `$ai_model` / `$ai_provider`. That gap is what this closes.
- **Do not add new captures.** The tracing house rule (`.claude/skills/ai-tracing`)
  is *one chokepoint per provider — never sprinkle captures at each call site*.
  Adding captures in the Replicate branches would double-count.

## Decisions (locked in brainstorming)

- **Scope:** all video models, by **enriching the existing captures** (no new
  captures): the `run_with_retry` chokepoint (Seedance/Kling/Hunyuan) gets a new
  `extra_properties` param that its `capture_ai_generation` calls forward; the Veo/Sora
  branch captures get the props attached directly.
- **Dimensions only, no cost.** `total_cost_usd` is not sent (video shows $0 in
  PostHog). Authoritative cost stays in the DB `video_params`. No rate tables in
  ai-service.
- **Flat, `video_`-prefixed properties** (not one JSON blob): PostHog point-and-click
  filter / breakdown / column config only works on top-level properties. A nested blob
  would force HogQL and defeat the whole reason to send it to PostHog.
- **Generation-level only.** Props live on the `$ai_generation` event (Generations
  view — "Configure columns", Property filters, breakdowns). Not promoted to
  trace-level (out of scope).
- **ai-service only.** No API change (the API's DB `video_params` work is separate and
  already done). Lands on `feature/daffa/vc-video-dynamic-pricing`.
- **No backfill.** Properties appear on new events after deploy (PostHog is schemaless;
  past events are unchanged).

## Properties emitted

Flat, top-level, on each video `$ai_generation` event (values mirror the DB dims):

| Property | Type | Example | Notes |
|---|---|---|---|
| `video_resolution` | string | `1080p` | omitted when null (Kling reports null) |
| `video_in` | bool | `false` | Seedance video-to-video tier flag |
| `video_mode` | string | `pro` | omitted when null (only Kling sets it) |
| `video_audio` | bool | `true` | |
| `video_duration_seconds` | int | `8` | |

`$ai_model` / `$ai_provider` already carry model + provider. **Null dims are omitted**
(PostHog `ph_ai_kwargs` drops `None` values) — correct: a property is only present when
that lever applies to the model.

## Design

**One helper (DRY across 5 branches)** in `app/tools/generate_video.py` (or a small
observability util):

```python
def _video_trace_props(resolution=None, video_in=False, mode=None, audio=False, duration=None):
    return {
        "video_resolution": resolution,
        "video_in": bool(video_in),
        "video_mode": mode,
        "video_audio": bool(audio),
        "video_duration_seconds": duration,
    }
```

(Null-valued keys are dropped downstream by `ph_ai_kwargs`, so passing `None` is safe.)

Each branch already computes these dims for `token_usage`, so it's the same values.

**Replicate models (Seedance/Kling/Hunyuan) — enrich the chokepoint, don't add a
capture.** `run_with_retry` in `app/utils/replicate_client.py` gains an optional
`extra_properties: dict | None = None` param, forwarded to all three of its
`capture_ai_generation` calls (success + both error paths) via
`**(extra_properties or {})`. The Replicate branches then pass the props into the
`replicate_run(...)` call they already make:
- bytedance/Seedance: `extra_properties=_video_trace_props(resolution=seedance_resolution, video_in="reference_videos" in input, duration=length)`.
- kuaishou/Kling: `extra_properties=_video_trace_props(mode=mode, audio=bool(input.get("generate_audio")), duration=length)`.
- tencent/Hunyuan: `extra_properties=_video_trace_props(duration=int(duration))` (fixed model, no resolution/mode/audio levers).

No new capture, no `start` timer in the branch — the chokepoint already captures and
times the run (spanning retries). These events keep `provider="replicate"` and
`$ai_model = "<owner>/<model>:<version>"` (existing convention); the `video_*` props are
the new segmentation keys.

**Veo/Sora — enrich the existing branch captures directly.** The `google` (Veo) and
`openai` (Sora) branches have their own `capture_ai_generation` (not via
`run_with_retry`). Add `**_video_trace_props(resolution=..., duration=int(duration))` to
their **success-path** capture. For Sora, compute `sora_resolution` before the capture.

**Error-path captures** (`google` `GeminiServerError`, `openai` `APIStatusError`, and
the Replicate chokepoint's error paths): the Replicate error captures receive the props
automatically (same `extra_properties` forwarding). The Veo/Sora branch error captures
are left unchanged (they still fire; dims omitted — intentional).

## Testing

Unit tests (ai-service, mock the PostHog capture — no real network):

- `_video_trace_props` pure test: correct keys, bool coercion, `None` passthrough.
- **`run_with_retry` forwards `extra_properties`** — patch
  `replicate_client.capture_ai_generation`, call `run_with_retry(model_ref, input,
  extra_properties={...})` (mock the replicate client), assert the props reach the
  success capture; and on an error path.
- **Replicate branches pass the props through `replicate_run`** — patch
  `replicate_run`/`upload_file_to_s3`/`open` and drive `generate_video` for Seedance +
  Kling (as in `test_generate_video_*_billing.py`); assert the `replicate_run` call
  received `extra_properties` with the right `video_*` values (Seedance →
  `video_resolution` + `video_in`; Kling → `video_mode` + `video_audio`).
- Veo/Sora branch captures: SDK-chain mocking is disproportionate — verify by
  reading + `py_compile` (consistent with the pricing work).

## Files touched (ai-service only)

- `app/utils/replicate_client.py` — add `extra_properties` param to `run_with_retry`,
  forward to its 3 `capture_ai_generation` calls.
- `app/tools/generate_video.py` — `_video_trace_props` helper; pass
  `extra_properties=_video_trace_props(...)` into the `replicate_run(...)` call in the 3
  Replicate branches; add props to the `google`/`openai` branch captures.
- `tests/tools/test_video_trace_props.py`, `tests/tools/test_replicate_client_trace.py`,
  `tests/tools/test_generate_video_posthog.py` (new).

## Out of scope (YAGNI)

- **Cost in PostHog** (`total_cost_usd`) — needs the API↔ai-service pricing bridge;
  cost stays authoritative in the DB `video_params`.
- **Trace-level properties** — generation-level is sufficient for segmentation.
- **Backfill** of past events — PostHog is schemaless; new events only.
- **API changes** — none.
