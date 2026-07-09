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

- Only the **Veo** (`google`) and **Sora** (`openai`) branches of `generate_video`
  call `capture_ai_generation`. The **Replicate** branches — **Seedance**
  (`bytedance`), **Kling** (`kuaishou`), **Hunyuan** (`tencent`) — call it **not at
  all**, so most video generations are **absent from PostHog entirely**.
- None of the video generations attach the dimensions, so there's nothing to segment
  on beyond `$ai_model` / `$ai_provider`.

## Decisions (locked in brainstorming)

- **Scope:** all video models. Add `capture_ai_generation` to the 3 Replicate branches
  (fixing the absence) AND attach dimension props to all 5 branches.
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

**Per branch** — each already computes these dims for `token_usage`, so it's the same
values:

- **Replicate branches** (`bytedance`, `kuaishou`, `tencent`): **add** a
  `capture_ai_generation(model=..., provider=..., span_name="generate_video",
  start_time=start, **_video_trace_props(...))` call after the generation completes,
  including a `start = time.time()` timer at the branch top (mirroring how `google` /
  `openai` already do it). Map dims:
  - bytedance/Seedance: `resolution=seedance_resolution`, `video_in="reference_videos"
    in input`, `duration=length`.
  - kuaishou/Kling: `mode=mode`, `audio=bool(input.get("generate_audio"))`,
    `duration=length`.
  - tencent/Hunyuan: `duration=length` (fixed model, no resolution/mode/audio levers).
- **Existing captures** (`google`/Veo, `openai`/Sora): **add** `**_video_trace_props(
  resolution=resolution, duration=int(duration))` to the current
  `capture_ai_generation(...)` calls.

**Error-path captures:** where a branch has a capture in a failure path and the dims are
already in scope, attach the props there too (harmless — the parameters are known
regardless of success). Where dims aren't yet computed at the failure point, leave that
capture unchanged.

## Testing

Unit tests (ai-service, mock the PostHog capture — no real network):

- Patch `capture_ai_generation` (or `get_posthog`) and drive each provider branch of
  `generate_video` (replicate_run / genai / openai + `upload_file_to_s3` + `open`
  mocked, as in the existing `test_generate_video_*_billing.py`). Assert:
  - **Replicate branches now call `capture_ai_generation`** (regression against the
    current absence) with `provider` correct.
  - The `video_*` props are passed: Seedance → `video_resolution` + `video_in`;
    Kling → `video_mode` + `video_audio`; all → `video_duration_seconds`.
- `_video_trace_props` pure test: correct keys, bool coercion, `None` passthrough.

## Files touched (ai-service only)

- `app/tools/generate_video.py` — `_video_trace_props` helper; add
  `capture_ai_generation` to the 3 Replicate branches (+ `start` timers); add props to
  the `google`/`openai` captures.
- `tests/tools/test_generate_video_*_posthog.py` (new) — per-branch prop assertions.

## Out of scope (YAGNI)

- **Cost in PostHog** (`total_cost_usd`) — needs the API↔ai-service pricing bridge;
  cost stays authoritative in the DB `video_params`.
- **Trace-level properties** — generation-level is sufficient for segmentation.
- **Backfill** of past events — PostHog is schemaless; new events only.
- **API changes** — none.
