# Smart Layer POC — Handoff & Next Steps

> **Pause point:** 2026-05-28 ~03:00 local. Continue from here next session.
> **Branch:** `feature/daffa/vc-smart-layer-poc` (ai-service + web)

## Where we are

End-to-end POC works: upload KV → vision detect → cutout → S3 → manifest → frontend renders.

**21 commits** total across ai-service (15) + web (4). All tests green (27/27). Branch tracking `origin/development` (ai-service) and `origin/develop` (web).

**Current setup (after V3.I rollback):**
- `VISION_MODEL = "gpt-4o"` — fast (~5s) but hallucinates occasionally
- `USE_GROUNDED_SAM = False` — using rembg directly (no Replicate cold-start tax)
- All V3.A–G post-processing intact: confidence floor 0.7, z-bands per kind, adjacent text merge, mask erosion

**Latency:** ~30–60s per request (gpt-4o + rembg × N + inpaint).

## Honest quality assessment (latest job `a30ed2e42dd5`)

| Asset | Opaque | Verdict |
|---|---|---|
| subject_1 (Person 1) | 55.8% | ✅ Great |
| subject_2 (Person 2) | 69.9% | ⚠️ Shows BOTH girls (bbox overlap, rembg can't instance-separate) |
| logo_1 (Logo on Headphones) | 0% | ❌ Hallucination (no headphones at that bbox) |
| logo_2 (Logo on Hoodie) | 23.4% | ⚠️ Captures wrong target (headphones strap) |
| logo_3 (Logo on Hoodie text) | 0% | ❌ Watermark "frnd Glow" — rembg can't cut text from same-color bg |

**Verdict:** subjects production-grade, logos/small features degraded.

## The 4 realistic next steps (presented as choice, no decision yet)

### Option A — Filter empty cutouts (~15 min)

Quick polish. Add post-rembg check: if `_opaque_ratio(asset) < 0.05`, drop the layer.

- **Pro:** Cleaner manifest, no more 0%-opaque junk layers. Easy.
- **Con:** Loses any layer rembg can't handle (watermarks, small text-on-image). Smaller layer count.
- **Best when:** you just want demo to look clean without revisiting architecture.

### Option B — Warm-up grounded-sam at boot (~30 min)

Send a dummy SAM call on ai-service startup so container stays hot. Re-enable `USE_GROUNDED_SAM = True` + `VISION_MODEL = "gpt-5"` with `REASONING_EFFORT = "low"`.

- **Pro:** Get back the V3.F quality (pixel-perfect masks, instance separation, hallucination filter).
- **Con:** ai-service boot slower. Ongoing keep-warm cost (~$0.05/hr Replicate pings).
- **Best when:** you want max quality and the ai-service runs continuously (staging/prod).

### Option C — Async/job pattern (~2–3 hours)

Refactor: `POST /ai/smart-layer/analyze` returns `job_id` immediately; frontend polls `GET /ai/smart-layer/jobs/{id}` for progress; UI shows per-stage progress.

- **Pro:** Tolerates gpt-5 + SAM cold starts (5+ min) without UX freeze. Most professional.
- **Con:** Backend + frontend refactor. New polling endpoint. WebSocket later optional.
- **Best when:** ready to ship to real users, not just dev demo.

### Option D — Stop, finalize POC, open PR

Accept current rollback trade-off (subjects great, logos meh). Open PR to `develop` with "logos work-in-progress" caveat. Document V4 roadmap as follow-up tasks.

- **Pro:** Ship the win, move on.
- **Con:** Logos aren't demo-worthy.
- **Best when:** other priorities are louder than smart-layer polish.

## Recommended path

**A → B → C** in that order if iterating.

- A is a cheap immediate polish that helps no matter what.
- B unlocks Canva-grade quality (V3.F validated) for any continuous deployment.
- C is the right long-term UX once we're past POC.

## Knobs to flip (one-liners)

```python
# ai-service/app/agents/smart_layer/vision.py
VISION_MODEL = "gpt-4o"        # → "gpt-5" for reasoning + better grounding
REASONING_EFFORT = "low"       # → "medium" / "high" (only used by gpt-5 family)

# ai-service/app/agents/smart_layer/pipeline.py
USE_GROUNDED_SAM = False       # → True for pixel-perfect masks (requires warm container)
```

## Things NOT yet done (V4 territory)

- Self-verify pass (after detection, ask vision "is this really [kind] at this bbox?") — second API call per layer.
- Interactive mask refinement (Canva-style brush to add/remove area).
- "Send to KV Generator" button — push manifest into real KV studio file flow.
- Per-image hash caching (re-analyze same image = instant).
- Auth gating on `/ai/smart-layer/analyze` route.

## Files touched (so you can jog memory)

- `ai-service/app/agents/smart_layer/{schema,vision,cutout,clean_background,pipeline,router,postprocess}.py`
- `ai-service/main.py` (CORS + router registration)
- `ai-service/app/utils/config.py` (`SMART_LAYER_CLEAN_BG_ENABLED`)
- `ai-service/.env.example`
- `web/src/lib/studio/smart-layers.ts`
- `web/src/types/studio.ts` (StudioOverlayDraft +kind/label/confidence)
- `web/src/app/(canvas)/studio/smart-layer-poc/SmartLayerPocClient.tsx`
- `web/.env.example` (`NEXT_PUBLIC_SMART_LAYER_ENDPOINT`)
