# KV Agentic Canvas P1.1 — Concept Boards — Frozen Contracts (C1–C12)

Date: 2026-10-23. Source: `frnd/docs/prd/kv-agentic-canvas-p1-1.md` (approved 2026-10-23). These shapes extend the P1 contracts (`docs/superpowers/plans/2026-10-22-kv-agentic-canvas-p1-structure-contracts.md`, S1–S18, R1–R12). Changing one requires editing this file first.

Branch in every repo: `feature/daffa/vc-kv-agentic-canvas-p1-1`. Worktree: `<repo>/.worktrees/kv-agentic-canvas-p1-1`.

Build order: api → ai-service → web (no collab change).

---

## C1 — `concept_boards` capability registry entry (api + ai-service) [extends S4, FR-1]

### api

`App\Services\Studio\AgentCanvas\Capabilities\ConceptBoards` implements `KvCanvasCapability`. Registered in `KvCanvasCapabilityRegistry::CAPABILITIES`.

- `name()`: `'concept_boards'`.
- `cost()`: `'plan'`.
- `proposeSteps(array $params)`: validates directions (≤4, each ≤500 chars, ≤3 suggestions per direction, ≤3 extra_directions); builds steps with `capability: "concept_boards"`. No `board_id` parameter (unlike `VariantBoards` which calls `boardOrFail`).
- `estimate(...)`: identical to `VariantBoards` — `LLMHelper::estimateImageCredits` per step (R2 formula).
- `execute(...)`: computes centres via `KvBoardPlacement::nextFreeCenters`, writes `add_board` placeholders, dispatches `RenderKvVariantJob` per step with `source_board_id: null`.
- `revert(...)`: identical to `VariantBoards::revert`.
- `cardKind()`: `'plan_card'` (reuses the P1 plan card).

`KvAgentPlan` model gains: `CAPABILITY_CONCEPTS = 'concept_boards'` (alongside existing `CAPABILITY_VARIANTS = 'variant_boards'` and `CAPABILITY_SIZES = 'add_sizes'`, at `app/Models/KvAgentPlan.php` line ~33).

### ai-service

`KV_CANVAS_CAPABILITIES` gains a `concept_boards` entry (`KvCanvasCapabilityEntry`). `make_kv_structure_tools` mounts `propose_kv_concepts` when `'propose_kv_concepts'` is in `agent_canvas.tools`.

## C2 — Plan route body for `capability: "concept_boards"` (api) [extends R1, FR-2/FR-3/FR-7]

`POST v1/mcp/tools/kv/canvas/{fileId}/plans` with `capability: "concept_boards"`:

```jsonc
{ "capability": "concept_boards",
  "params": {
    "directions": [
      { "direction": "...", "suggestions": [{"label": "...", "direction": "..."}] }  // ≤3 suggestions
    ],  // ≤4 directions
    "extra_directions": [{"label": "...", "direction": "..."}],  // ≤3
    "aspect_ratio": "1:1"  // required; must be a valid ratio string (C5)
  }
}
```

No `board_id` parameter. api creates one step per direction:

```jsonc
{ "id": "step_<ulid>", "capability": "concept_boards",
  "params": { "direction": "...", "suggestions": [...] },
  "estimate": { "credits_min": 3, "credits_max": 5, "seconds": 70 } }
```

The plan row's `options` jsonb gains `aspect_ratio: string` and `extra_directions: [{label, direction}]`. No `copy_layers` key (there is no source board).

**Generalisation of `KvAgentPlanService`:**

- `MAX_VARIANTS` (4) at `KvAgentPlanService.php` line 24 applies to both variants and concepts (P1.1 does NOT rename it; the name is misleading but the value is shared).
- `new_` step templates (`new_0`, `new_1`, ...) for rows added on Go work for concept steps: shape validation is `direction ≤ 500 chars` (no `board_id` required). The plan's `options.copy_layers` check is skipped when `capability === 'concept_boards'`.
- `transition()` validates `aspect_ratio` in `plan_action.options.aspect_ratio` when capability is `concept_boards`. The value must pass C5 validation.

**Errors:**

- 422 `invalid_params`: >4 directions, >3 suggestions, >3 extra, direction > 500 chars, missing or invalid `aspect_ratio`.
- 422 `nothing_to_propose`: zero directions.

## C3 — Plan view additions (api -> web) [extends R3, FR-5]

`GET v1/studio/files/{file}/agent/plans/{plan}` response for a concept plan:

```jsonc
{ "id", "status", "goal", "capability": "concept_boards",
  "source_board": null,
  "steps": [ { "id", "capability": "concept_boards", "params": { "direction", "suggestions" }, "estimate", "done": false } ],
  "options": { "aspect_ratio": "1:1", "extra_directions": [ {"label", "direction"} ] },
  "estimate": { "credits_min", "credits_max", "seconds" },
  "accepted_steps": null, "step_overrides": null,
  "run_id": null, "expires_at", "created_at",
  "balance": 1240 }
```

Key differences from a variant plan view:
- `source_board: null` (no source).
- `options.aspect_ratio` instead of `options.copy_layers`.
- No `options.copy_layers`.

## C4 — `propose_kv_concepts` ai-service tool [extends S12, FR-2/FR-4]

`app/tools/kv_plan_tools.py` gains `propose_kv_concepts`:

```python
CONCEPTS_TOOL = "propose_kv_concepts"
PLAN_PROPOSAL_TOOLS = frozenset({VARIANTS_TOOL, SIZES_TOOL, CONCEPTS_TOOL})
```

Tool args (no `board_id`, no `file_id` — file comes from the turn context):

```python
{ "directions": [{"direction": str, "suggestions": [{"label": str, "direction": str}]}],  # ≤4
  "extra_directions": [{"label": str, "direction": str}],  # ≤3
  "aspect_ratio": str  # required
}
```

The tool calls `POST v1/mcp/tools/kv/canvas/{fileId}/plans` with `capability: "concept_boards"`. Uses `stop_after_tool_call` + post-hook. `plan_pending` is claimed before the await (the `propose_deck_plan` pattern). Every other write in that turn is refused (P1 FR-11 unchanged).

After a successful proposal, emits NDJSON `{event: "kv_plan_card", plan_id, card_id}` and ends the turn (R4 frame).

>4 directions are clamped to 4 by the tool before calling api, with `clamped: true` in the response and "maximum is 4" in the reply text.

## C5 — Allowed aspect ratios and Go validation (api) [extends R5, FR-6]

On Go, `plan_action.options.aspect_ratio` is sent for concept plans. Validation:

- `aspect_ratio` must be one of the **KV generate flow presets**: `['16:9', '9:16', '1:1']` (from `KvVariantRenderer::ASPECT_RATIOS` at line 44, and `KvToolController::ASPECT_RATIOS` at line 41).
- **Resolved (open issue 1):** allowed set stays `16:9`, `9:16`, `1:1` (no code change); default = ratio the user named, else `1:1`.

The api validates the aspect ratio both on proposal (C2) and on Go transition. An invalid ratio is 422 `invalid_params`.

## C6 — Concept execution and placement (api) [extends R6/R7, FR-8/FR-9/FR-10]

On Go for a concept plan:

1. `assertAffordable(estimate.credits_max of accepted steps)`.
2. Placement: `KvBoardPlacement::nextFreeCenters`.
   - On an **empty canvas** (zero visible boards): the first board is at `(0, 0)`; the rest are side by side.
   - On a **non-empty canvas**: the row starts after the last visible board (the existing `nextFreeCenters` behaviour from P1 S6).
3. One `add_board` placeholder per accepted direction (stamped `agent_run_id`, name from `KvBoardLabel::deriveVariantName(direction)`). Placeholders use the plan's `options.aspect_ratio` for their visual dimensions.
4. Dispatch `RenderKvVariantJob` per step with the **no-source branch**.

### No-source branch in `KvVariantRenderer` [FR-9]

`KvVariantRenderer::renderLocked` (line 90) currently hard-requires `$source !== null` at line 112:

```php
if ($step === null || $file === null || $source === null || ...) {
    $this->fail($runId, $planStepId, 'The source board or its file is gone.');
    return;
}
```

The no-source branch adds an alternative path when `$op['source_board_id']` is null (concept boards):

- **Skip source lookup**: `$source` is not fetched.
- **`baseGeneration`**: `null`. `KvGeneratePayloadBuilder::build` already accepts `?array $baseGeneration = null` (line 27). When null, `base_generation` is null in the payload and `brand_logo_stamp` is null (line 62–64), which is the existing cold-start path.
- **`aspect_ratio`**: from `$plan->options['aspect_ratio']` instead of `self::aspectOf($source)`.
- **`parent_generation_id`**: NOT set on the persisted generation (line 147 currently hardcodes `$source->id`; the no-source branch skips this).
- **No layer copy**: the `land()` method skips `overlaysForVariant` when there is no source (no `copy_layers` option exists on concept plans).
- **Brand knowledge**: honoured via `KvGeneratePayloadBuilder` as today. Logo compositing follows the cold-start path: `brand_logo_stamp` is null when `baseGeneration` is null, so ai-service composites the logo.
- **Failure path**: unchanged (`hide_board`, `render_failed`).

### Generation metadata for concept boards

```php
$ready['metadata'] = [
    'agent_run_id' => $run->id,
    'plan_step_id' => $planStepId,
    'direction' => $direction,
    // NO 'source_board_id' key
    // NO 'parent_generation_id'
];
```

## C7 — Run view items for concept boards (api -> web) [extends R8, FR-15]

Concept board items reuse the P1 run view shape: `kind: "board"`, states `queued -> generating -> done / failed`. No `source_board_id` in the item (concept boards have no source). The item carries `board_id`, `name`, `image_url` (when done), `credits` (when settled).

## C8 — Undo for concept boards (api) [extends R11, FR-16]

Identical to variant undo (S9 / R11):
- Untouched concept board: `hide_board`.
- Edited concept board: kept, reported as `changed_after_run`.
- Queued/running render: hide placeholder, late result not placed (`run.status == "undone"` check).
- Credits already spent are not refunded.

## C9 — MCP twin `ProposeKvConceptsTool` (api) [FR-14]

`app/Mcp/Tools/ProposeKvConceptsTool.php`:

```php
class ProposeKvConceptsTool extends KvPlanProposalTool
{
    public const FIXED_ARGS = ['capability' => KvAgentPlan::CAPABILITY_CONCEPTS];
}
```

Follows the D1 pattern from `ProposeKvVariantsTool` (line 10) and `ProposeKvSizesTool` (line 10). The twin fills `capability: "concept_boards"` on the shared `KvCanvasPlanToolController` route. `php artisan mcp:verify-mirror` passes.

## C10 — `CanvasIntent.Action` gains `concept_boards` (ai-service) [extends S16, FR-12/FR-13]

`app/agents/canvas_intent/schema.py`:

```python
Action = Literal[
    # existing
    "resize", "move", "rotate", "hide", "show", "restack", "text", "style",
    "add", "remove", "undo", "pixel_edit", "brainstorm", "other",
    # P1
    "duplicate", "variant", "add_sizes", "rename_board", "arrange", "hide_board", "show_board",
    # P1.1
    "concept_boards",
]
```

### Resolver rules

| Input | Canvas state | Resolved action |
|-------|-------------|----------------|
| "generate 3 different ideas about X" / "buat 3 ide berbeda tentang X" | any | `concept_boards` (count=3, brief=X) |
| "generate 3 variants of V2" / "buat 3 varian dari V2" | any | `variant` (unchanged, R12) |
| "duplicate V2 and change the background" | any | `variant` (unchanged, R12) |
| "generate N ideas ..." | **empty canvas** | always `concept_boards` |
| "generate N ideas / new ideas ..." (no board named) | **non-empty canvas** | clarifying card (C10.1) |
| "generate 3 new ideas from scratch" | non-empty canvas | `concept_boards` (explicit, no card) |
| "generate N ideas of V2" | non-empty canvas | `variant` (board named) |

### Clarifying card (C10.1) [FR-12]

On a **non-empty canvas with no board named**, when the intent could be either `concept_boards` or `variant`, the validator shows a clarifying card:

- Surface: `kv_canvas`, purpose: `clarify_intent` (new, or reuse existing `purpose: "targets"`).
- Text: "Do you want new ideas from scratch, or variants of <active board name>?"
- Options: `["New ideas", "Variants of <board name>"]`.
- The answer routes to `concept_boards` (calls `propose_kv_concepts`) or `variant_boards` (calls `propose_kv_variants` with the active board as source).

The card uses the existing question card mechanism (`card_answer` channel). The `card_answer.purpose` may be `clarify_intent` or reuse `targets` with a distinct option format.

### Golden cases [FR-13]

>=3 EN + >=3 ID cases in `evals/golden/kv_canvas/` for `concept_boards`:
- Empty canvas + "generate 3 different ideas about Ramadan".
- Non-empty canvas + "generate 3 new ideas" with no board named (clarifying card).
- Explicit "from scratch" on non-empty canvas (direct concept).
- Count > 4 (clamp to 4).
- Boundary: "copy V2 but change X" stays `variant` (R12 unchanged).
- "Generate 3 variants of V2" stays `variant`.

Scoring: correct action + correct count + correct routing. Pass threshold >= 90%.

## C11 — Web plan card `concept_boards` branch [extends S17, FR-5/FR-6]

`KvPlanCard` gains a `concept_boards` branch. Differences from `variant_boards`:

| Aspect | `variant_boards` | `concept_boards` |
|--------|-----------------|-----------------|
| Title | "N variants of <board>" | "N new ideas" |
| Source board display | Yes | No |
| "Copy layers" toggle | Yes (default on) | No |
| Aspect-ratio picker | No | Yes (dropdown/radio) |
| Row labels | "variant" / "varian" | "idea" / "ide" |
| "Add" button text | "Add variant" | "Add idea" |
| Suggestion chips | Yes | Yes |
| Estimate, Go/Cancel | Same | Same |
| Terminal states | Same | Same |

### Aspect-ratio picker

- Presets: the KV generate flow set (`16:9`, `9:16`, `1:1`; default `1:1`).
- Default: the ratio the user named in their message (e.g. "IG story" -> `9:16`), else `1:1` (the code's existing fallback, pending open issue 1).
- Stored in local state; sent as `plan_action.options.aspect_ratio` on Go.

### Placeholder aspect

On an empty canvas, concept board placeholders use the plan's `options.aspect_ratio` for their visual dimensions. The run view carries no `source_board_id`, so the existing R10 source-board-aspect fallback does not apply. The plan view's `options.aspect_ratio` is the source.

### PostHog events [extends S17]

Extend existing events with `capability: "concept_boards"`:
- `kv_agent.plan_shown` — gains `capability`.
- `kv_agent.plan_confirmed` — gains `capability`, `aspect_ratio`. No `copy_layers`.
- `kv_agent.plan_cancelled` — gains `capability`.
- `kv_agent.plan_expired` — gains `capability`.
- Add `kv_agent.concept_done` / `concept_failed` mirroring `variant_done` / `variant_failed`.

## C12 — `PROPOSAL_TOOLS` and `agent_canvas.tools` (api + ai-service)

### api

`KvAgentCanvasTurn::PROPOSAL_TOOLS` (line 37) gains `'propose_kv_concepts'`:

```php
public const PROPOSAL_TOOLS = ['propose_kv_variants', 'propose_kv_sizes', 'propose_kv_concepts'];
```

`agent_canvas.tools` lists `propose_kv_concepts` on structure-flagged turns (alongside `propose_kv_variants` and `propose_kv_sizes`), except an accepted Go turn which lists `run_kv_plan_step`.

### ai-service

`PLAN_PROPOSAL_TOOLS` (line 43 of `kv_plan_tools.py`) gains `CONCEPTS_TOOL`:

```python
CONCEPTS_TOOL = "propose_kv_concepts"
PLAN_PROPOSAL_TOOLS = frozenset({VARIANTS_TOOL, SIZES_TOOL, CONCEPTS_TOOL})
```

`TOOL_NAME_ENUM` / label map gains: `"propose_kv_concepts": "Proposing Concepts"`. `TOOL_ICONS` gains an appropriate icon (lightbulb or `key_visual`).

---

## Shared names

| Name | Kind | Service |
|------|------|---------|
| `concept_boards` | Capability name, `KvAgentPlan::CAPABILITY_CONCEPTS` | api, ai-service, web |
| `propose_kv_concepts` | Tool name (ai-service tool + api MCP twin) | api, ai-service |
| `ProposeKvConceptsTool` | MCP twin class | api |
| `ConceptBoards` | Capability class | api |
| `options.aspect_ratio` | Plan options field (jsonb, no migration) | api, web |
| `concept_boards` | `CanvasIntent.Action` value | ai-service |
| `kv_agent.concept_done` / `concept_failed` | PostHog events | web |
| Clarifying card ("From scratch or variants?") | Question card | ai-service, web |

## Open issues / deviations

1. **`4:5` is NOT in the allowed aspect ratios.** The PRD says "default = the ratio the user named, else 4:5" and lists "e.g. 4:5, 1:1, 9:16, 16:9". But the code only has `['16:9', '9:16', '1:1']` (at `KvVariantRenderer::ASPECT_RATIOS` line 44, `KvToolController::ASPECT_RATIOS` line 41, and `KvArtboardRatio` type). Options:
   - (a) Add `4:5` (and possibly `5:4`) to the allowed set across all three lists. This touches the existing KV generate flow.
   - (b) Default to `1:1` instead of `4:5` and keep the existing 3 presets.
   - (c) Expand the set for concept boards only (api validation per capability).
   - **RESOLVED 2026-10-23 (daffa): (b)** — keep the existing 3 presets, default `1:1`. No ASPECT_RATIOS / KvArtboardRatio change; the KV render path (ai-service aspect card `service.py:3323`, image-model size mapping) has no 4:5.

2. **Wireframe waived.** User decision 2026-10-23. No new wireframe is created; the P1 plan card wireframe (`web/src/wireframes/kv-agent-structure-cards/`) is reused with the changes described in C11. This is an explicit deviation from the wireframe gate.

3. **`KvVariantRenderer` hard-requires a source board** at line 112: `$source === null` causes `$this->fail(...)`. The no-source branch (C6) must split the `renderLocked` method before this check. The split point is after `$plan` and `$step` are loaded (line 106–107) and before `$source` is fetched (line 109).

4. **`parent_generation_id` is hardcoded** at line 147: `$ready['parent_generation_id'] = $source->id`. The no-source branch skips this line entirely. The persisted generation has no `parent_generation_id`.

5. **`land()` assumes `copy_layers` key in plan options** at line 161: `(bool) ($plan->options['copy_layers'] ?? true)`. For concept plans, `copy_layers` is absent from `options`; the `?? true` default would copy non-existent layers (a no-op, since there is no source). The no-source branch should pass `copyLayers: false` explicitly.

6. **Concept-mode (sketch) is out of scope.** The Craft gate in `KvAgentCanvasTurn::forTurn` (line 53: `if ($canvasMode !== 'craft' || $mode !== 'chat')`) and `KvGeneratePayloadBuilder::build` (line 39: `'canvas_mode' => 'craft'`) are unchanged.

7. **TOOL_NAME_ENUM** for plan tools is in a local label map in `app/agents/kv_generator/service.py` (line ~3260), not the global `app/utils/enum.py`. The new `propose_kv_concepts` label should be added to the same local map.

8. **KvAgentPlan model path.** The model is at `app/Models/KvAgentPlan.php` (NOT `app/Models/Studio/`). The new constant `CAPABILITY_CONCEPTS` goes there.
