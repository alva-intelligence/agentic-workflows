# KV Agentic Canvas Intent — implementation handoff (paused 2026-10-19)

Paused by the user. Resume with: read this file + `docs/superpowers/plans/2026-10-19-kv-agentic-canvas-intent-contracts.md`, then re-spawn IntentApi + IntentAi with these decisions as context (web is done).

State at pause:
- web: TASK-1..4 done, pushed (`f88722c92`).
- api: no code yet; research complete (decisions below). Clean worktree.
- ai-service: no code yet; research complete (decisions below). Clean worktree.
- Pending contract edits: I5 `payload.canvas` snapshot on `decision` events (agreed api+ai); `intent_mode` enum on events needs `off` for undone_fast without a decision; I3 unknown card_id returns an SSE error frame (StreamChatRequest convention), not HTTP 422 — decide.
- Open questions for the user: non-prod flag default (`studio.kv_agent_intent_mode` env, default off); eval fixtures (4 MB base PNGs + crafter config from /tmp) — commit to repo or skip those cases.
- Env: intent worktrees provisioned (.env, vendor, .venv, node_modules). Disk was full (Postgres crashed once on createdb, recovered); do not create DBs — tests reuse `frnd_kv_p0_test`, manual stack `frnd_kv_p0_manual` via `.pids/kv-intent-stack.sh`. Local stack is stopped.

## IntentApi

```json

```

## IntentAi

```json

```

## IntentWeb

```json

```

## IntentApi

```json
{
  "status": "paused_by_user",
  "tasks_done": [],
  "commits": [],
  "files_touched": [],
  "uncommitted_changes": "none (git status clean; no wip commit needed)",
  "decisions_reached": {
    "internal_route": "POST /api/internal/agent-intent-events in the RequireInternalToken group (routes/api.php ~L7682, next to internal/kv-files/{studioFile}/overlays), NOT /api/v1/internal. Controller in App\\Http\\Controllers\\Api\\Internal, guard abort_unless(auth.via==='internal_token'). Scoping is done in the controller: user must be a workspace member and the file must belong to workspace_id, else 404. Told IntentAi this path; it posts there.",
    "I5_payload": "Accepted IntentAi's request: payload is an opaque object, capped only at 32KB JSON-encoded, with no key whitelist. IntentAi will propose the additive `canvas` snapshot in the decision payload in its own contract edit.",
    "export_line_shape_agreed_with_IntentAi": "{id,surface,mode,prompt,payload,outcome:accepted|clarified|undone_fast,clarified:{option_ids,purpose}|null,created_at} + thread_id,run_id,latency_ms",
    "flag_variant_api": "FeatureFlagService has no variant API. PostHog SDK getFeatureFlag is deprecated (it triggers E_USER_DEPRECATED). Plan: add FeatureFlagService::variantForWorkspace(key,user,workspaceId): ?string using PostHog::evaluateFlags($email, ['workspace'=>id], personProps, flagKeys:[key])->getFlag(key), with the same L1/L2 cache (store '' for null) and fail-closed on throw. KvAgentCanvasIntentFlag::mode returns 'off' unless KvAgentCanvasFlag::enabledFor is true and the variant is in [shadow, live]. Open question: isEnabledForWorkspace force-opens outside production, so mode() needs a non-prod default. Proposal: config `studio.kv_agent_intent_mode` (env, default off) for non-prod, PostHog in prod. Tests mock FeatureFlagService.",
    "intent_mode_wiring": "ChatService::streamKvGenerator ~L1934: when $agentCanvas !== null, also set $payload['intent_mode'] = KvAgentCanvasIntentFlag::mode(...). recent_runs goes inside KvAgentCanvasTurn::forTurn's returned array.",
    "recent_runs": "KvAgentRunView::of runs a per-run tiles query. Plan: refactor so the view has a static headline(ops) path without tiles (board_id from op.board_id or the target for boards), then one query KvAgentRun where studio_file_id, latest 3, and map to {run_id,status,change,layers,surfaces,boards,age_s}. A null change becomes 'edited'.",
    "descriptions": "KvCanvasContextAssembler::layerItem is static and called from inventory() and sizeItem(). Plan: preload KvLayerDescription rows for the file into the assembler/state, add 'description' when (layer_id, sha256(asset_url)) matches, and collect missing image layers. DescribeKvLayersJob goes on the low queue under Cache::lock('kv-describe:{file}',120) and chunks 12. It posts to config('services.ai.url').'/ai/kv-canvas/describe-layers' with X-Internal-Token = config('services.internal.workflow_token'), following ExtractProposalBrandLookJob. Vendor descriptions are already validated and stored on kv_layer_decompositions.layers[].description (KvLayerDecompositionCompleteRequest). Write them in commit()/commitToResizeExport() from the buildLayerOverlays ids.",
    "card_answer": "StreamChatRequest rules at ~L1138 (add card_answer.*). Its errors stream via failedValidation, which returns SSE 200 with an error frame rather than a true 422. The ThreadController KV branch L791 does not persist the user row; ChatService::streamKvGenerator L1649-1701 does. So message.card_answer must be added in ChatService's $messageBlob and forwarded in $payload. Unknown card_id: check the UserChatHistory session_id=thread, message->kind='question_card', message->payload->card_id in the ThreadController KV branch, and return streamErrorResponse('Unknown card'). True HTTP 422 needs either a response()->json 422 or a contract tweak, so this is undecided. The clarified event's options_shown comes from that card row's payload.options ids.",
    "question_card": "QuestionCardPayload::normalize keeps card_id (string ≤26). Hydrate sites: KvGeneratorFileController L160-167 (show) and L590-597 (simpleChatHistoryForThread). selected_option_ids is derived from the next user row's message.card_answer.",
    "undone_fast": "KvAgentRunReverter::undo L93-99: after status=undone, if now-created_at ≤300s, write AgentIntentEvent kind=undone_fast {run_id,age_s,source}. mode comes from the decision event with that run_id, else 'off'. The mode enum needs 'off' too.",
    "tests_infra": "phpunit.xml uses sqlite :memory: and must be overridden with DB_CONNECTION=pgsql DB_DATABASE=frnd_kv_p0_test (per lead: reuse it, only run migrate, create no DB because the disk is full). Fixtures: tests/Traits/BuildsKvCanvas + Tests\\Support\\KvCanvasFixture (TOKEN 'test-internal-token').",
    "posthog_events": "Web owns agent_intent.clarified. api-side agent_intent.decision/fast_undo would use a SendPaymentAnalyticsEventJob-style queued capture. Not yet decided whether api emits them; the service PRD has no explicit task for it."
  },
  "next_steps": "Implement in order: TASK-1 flag (+FeatureFlagService::variantForWorkspace), TASK-9 migration/model/enums, TASK-10 controller+route, TASK-3/4/5 descriptions, TASK-2 recent_runs, TASK-6/7/8 card_answer, TASK-11 undone_fast, TASK-12/13 commands, TASK-14..16 tests. Then migrate frnd_kv_p0_test, run the targeted pest + AgentCanvas suites, pint --test, mcp:verify-mirror, smoke, track update, and push.",
  "open_issues": [
    "The I3 '422 Unknown card' conflicts with StreamChatRequest's SSE-error convention, which returns 200 plus an error frame. Needs a decision: a real JSON 422 before the stream starts, or an SSE error.",
    "Non-production behaviour of intent_mode: isEnabledForWorkspace force-opens every flag outside prod. A config default is proposed.",
    "Whether api emits PostHog agent_intent.decision/fast_undo is not assigned in the api PRD."
  ]
}
```

## IntentAi

```json
{
  "status": "paused before implementation; no code changes made",
  "tasks_done": [],
  "commits": "none. The worktree is clean (`git status` shows nothing), so no wip commit was needed and nothing was pushed.",
  "files_touched": [],
  "decisions_reached": {
    "I5_route": "IntentApi confirmed: `POST {API_INTERNAL_URL}/api/internal/agent-intent-events` (the /api/internal RequireInternalToken group, not /api/v1/internal). Responses: 202 {data:{id}}, 401, 404, 422. thread_id is a required string; run_id and latency_ms may be null. api checks `payload` only as an opaque object of at most 32 KB, with no key whitelist.",
    "I5_contract_addition_proposed": "Add a compact inventory snapshot as `payload.canvas` on `decision` events, trimmed to stay under 32 KB, so the golden export can replay a turn. IntentApi accepted it, but the contract file is not edited yet. This is a proposed contract edit.",
    "export_jsonl_shape": "One line per decision event, agreed with IntentApi: {id, surface, mode, prompt, payload, outcome: accepted|clarified|undone_fast, clarified: {option_ids, purpose}|null, created_at, thread_id, run_id, latency_ms}.",
    "fence_nonce": "Already exists in `app/utils/prompt_fence.py`, which `kv_canvas_state` and `canvas_context_prompt` already import from. Import it from there; nothing needs to move. `chat_agent/project_context_prompt.py` has its own duplicate.",
    "ulid": "There is no ULID library in the venv; `python-ulid` is not installed and the user said not to reinstall. The repo has only `app/utils/ulid_shape.is_valid_ulid`, which checks the format but cannot create one. Plan: write a small Crockford-base32 ULID helper next to it (48-bit ms timestamp + 80 random bits from `secrets`), so no new dependency.",
    "structured_output": "Follow `edit_intent.py`: `agent.arun`, then RunStatus.error means None and non-model content means unparsed, which also gives None. On OpenAI set `model.strict_output=False`, as scorecard does: strict json_schema can't represent the open `params: dict`, and agno's model_validate does the real check. If the provider is deepseek, set `use_json_mode=True`, as social_listening does. Local `.env` has no INTERNAL_MODEL_PROVIDER, so the code default `deepseek` applies, and `vision=True` switches to openai gpt-6-luna. Resolver tier is conversation with provider-default effort.",
    "describe_layers_allowlist": "Mirror api's `TrustedAssetHost` rule in Python: exact host or real subdomain, plus path-style `/<bucket>/` on the S3 endpoint. Trusted host = `{S3_BUCKET_NAME}.s3.{S3_REGION}.amazonaws.com` (`.env`: bucket frnd, region ap-southeast-3) plus AWS_URL/AWS_ENDPOINT, like `scorecard/stimulus.allowed_stimulus_hosts`. https only. Anything else gets 422. Mount on a new router at `/ai/kv-canvas` in main.py. Auth via `app.agents._internal_auth.verify_internal`.",
    "events_client": "`app/utils/internal_api` (internal_base, internal_headers, verify_internal_tls) plus httpx.AsyncClient with a 2 s timeout. Run it fire-and-forget with asyncio.create_task and log errors without raising.",
    "kv_surface_tool_shapes": "Build arguments to match `kv_canvas_tools.py`: update_kv_layers edits[{layer_id, targets{board_ids, size_ids, include_sizes}, set{text?, style?, rect{x,y,w,h,rotation}?, visible?, z?}}]; add_kv_layer targets, layer{type, text?, style?, image{source, url?}}, placement{anchor, margin, width}; remove_kv_layers layer_ids and targets; undo_kv_agent_run target_run_id. Empty targets are refused (TARGETS_REQUIRED_ERROR).",
    "live_write_execution": "Call the `_recorded` tool callables returned by `make_kv_canvas_tools` directly, so the ledger, FR-37b guard and turn_closed gate stay unchanged. Then emit started/completed ToolCallEvent chips labelled via TOOL_NAME_ENUM. Then run a short tool-free reply agent on the conversation tier with the fenced tool results, apply `canvas_ledger.footnote`, and emit KvAgentRunEvent if `has_run_writes`.",
    "cards": "Reuse `_which_layer_card` (purpose layer; option id `layer_id@board_id`) and `_target_card_from_inventory` (purpose targets). Add `card_id: str | None = None` to QuestionCardEvent and set it at every emit site, including the gated `present_question_card` path in `_agno_chat_stream`.",
    "eval_assets": "The old harness depends on /tmp files: `kv_v6_base.png` and `kv_v7_base.png` (2 MB each), `kv_crafter_config.json`, and the KV_EVAL_REAL_RUNS export for G18. The committed runner needs these as fixtures, or must skip/flag `base_image`, `crafter_role` and `real_runs` when they are absent. The disk is nearly full, so I did not plan to copy the 4 MB of PNGs into the repo without asking. The golden file is referenced only in docs (the P0 eval md, the P0 track and the intent PRD), so it can move to `evals/golden/kv_canvas/p0.json` once those references are updated."
  },
  "next_steps_when_resumed": [
    "TASK-1/2/4: `canvas_intent/{schema,surface,thresholds,validator}.py` (no kv_generator import).",
    "TASK-3: `canvas_intent/resolver.py`, using the structured-output notes above.",
    "TASK-6: request schema changes (intent_mode, CardAnswer, RecentRun).",
    "TASK-9: ULID helper and `card_id` on QuestionCardEvent at every emit site.",
    "TASK-10: `app/tools/agent_intent_events.py`, plus the mismatch_refused hook in `kv_canvas_tools` (the factory needs an optional on_mismatch callback, or the stream reads `ledger.refused`).",
    "TASK-5/7/8: KvCanvasIntentSurface and the `_run_chat_mode` wiring.",
    "TASK-11: describe-layers router.",
    "TASK-12/13/14: evals/surface_runner, the golden move, the export script and the intent seed.",
    "TASK-15/16: the targeted tests, then ruff on changed files, pytest, the eval runs, the track update and the push."
  ],
  "verification": "None run; no code was written.",
  "open_issues": [
    "Where to keep the eval image/crafter fixtures, given disk pressure.",
    "The contract edit for the I5 `payload.canvas` snapshot has to go into the contract file, as I am proposing above."
  ]
}
```

## IntentWeb

```json
{
  "service": "web",
  "worktree": "web/.worktrees/kv-agentic-canvas-intent",
  "branch": "feature/daffa/vc-kv-agentic-canvas-intent (pushed, 472e5a2bf..f88722c92)",
  "tasks": {
    "TASK-1": "4e0a6a256 — kv_question_card frame `card_id`; ChatMessageMeta.questionCard `cardId?`/`selectedOptionIds?`; card-shown dedupe key `question:<card_id>` when present, else the old label+option-ids key; hydrate maps payload `card_id`/`selected_option_ids` and sets `selectedId` from selected_option_ids[0] so the card shows as picked after reload",
    "TASK-2": "4e0a6a256 — new exported `KvCardAnswer {cardId, optionIds, purpose}`; `KvSendOptions.cardAnswer?`; body gets `card_answer {card_id, option_ids, purpose, surface:'kv_canvas'}` only when given (otherwise undefined, so JSON leaves it out); when a cardAnswer is given, send() first marks the card with the same cardId as answered (selectedId + selectedOptionIds), using a module helper `markCardAnswered`, so it renders picked at once",
    "TASK-3": "f45e6ceeb — KvChat onPick: builds cardAnswer only when qc.cardId exists (purpose falls back to 'direction' for a card that has a cardId but no purpose) and passes it in both the motion and non-motion send options; cards without a cardId send exactly what they sent before (label only)",
    "TASK-4": "4e5d18b80 — src/lib/analytics/agent-intent-events.ts `trackAgentIntentClarified({surface, purpose, option_count, option_index, file_id, card_id})` sends `agent_intent.clarified` through a module-local safeCapture copied from kv-agent-events.ts (every analytics module has its own copy; there is no shared export), with no text fields; fired from onPick next to trackKvAssistantCardEngaged, only when the card has a cardId and fileId is set",
    "docs": "f88722c92 — service PRD tasks ticked, track tasks ticked + session log `### 2026-10-19 — daffa (frndos-implement)`"
  },
  "files": [
    "src/hooks/useKvStream.ts",
    "src/components/studio/kv-generator/KvChat.tsx",
    "src/lib/analytics/agent-intent-events.ts (new)",
    "docs/prd/kv-agentic-canvas-intent.md",
    "docs/tracks/kv-agentic-canvas-intent.track.md"
  ],
  "verification": {
    "tsc": "`npx tsc --noEmit -p .` error count: baseline 0 before changes, 0 after",
    "eslint": "`npx eslint` on the 3 changed files: 0 errors, 1 warning (KvChat.tsx L2829 `onClearBoxes` unused). That line is untouched and the warning was there before.",
    "prettier": "`npx prettier --check` on the 3 files: clean",
    "tests": "`bun test` on useKvStream{,.selection,.agentRun,.resizeMarker,.motionPlan}.test.ts + KvChat.{questionCard,agentRun,nextMove}.test.tsx + KvChat.{pickers,surface}.contract.test.ts: 61 pass / 0 fail"
  },
  "manual_check_for_lead": "Flag `live`, file with several logo layers, send 'Kecilkan logonya' and a which-layer card appears. Click an option: (1) the card shows the pick at once; (2) in DevTools Network, the POST /v1/threads/{id}/stream body has `card_answer {card_id:<26-char>, option_ids:[<id>], purpose:'layer', surface:'kv_canvas'}` and `message`=the option label; (3) PostHog debugger shows `agent_intent.clarified` (no label/prompt fields) next to `kv_generator` card_engaged. Reload: the card still shows the same option picked (needs api hydrate `selected_option_ids`). Open an old thread with cards that have no card_id: picking still works and the body has no `card_answer`.",
  "contract_deviations": "none. Web-side notes: (a) a card with card_id but no purpose sends purpose 'direction' (I3 enum allows it); (b) on reload, selectedId is taken from selected_option_ids[0], so single-pick rendering works with no QuestionCard change.",
  "open_issues": [
    "Craft multi-select / Generate-selected paths (direction cards in Craft) still send label-only with no card_answer. The service PRD covers onPick only; ai-service cards with purpose `direction` in Craft go through onGenerateSelected.",
    "Reload-answered state depends on api deriving `selected_option_ids` (I2); not exercised end-to-end here."
  ]
}
```
