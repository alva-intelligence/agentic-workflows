# askFRND → open the KV file the chat already created

**Date:** 2026-08-13
**Author:** daffa
**Services:** web (phase 1), ai-service (phase 2, separate)
**Status:** approved

## Problem

When askFRND generates a key visual through its own `generate_key_visual` tool, the KV file
**already exists in Studio**. The only way into it is a line of prose the model writes at the end of
its answer:

> 📁 File: **frndGlow-Asia-Skin-KV** (rasio 16:9) · 2 versi 🔗 Buka di Studio: `frndGlow-Asia-Skin-KV`

That block is model-authored text, not a component — the string "Buka di Studio" appears nowhere in
the codebase. It is therefore inconsistent turn to turn, unclickable in any reliable way, and
invisible to the analytics that measure whether anyone goes from chat into Studio.

Meanwhile the sibling feature ([2026-08-12 handoff](2026-08-12-askfrnd-kv-handoff-design.md)) put a
real "Edit in KV Studio" card under generated images — but it does **not** appear on these turns, and
it must not be reused as-is here. Verified 2026-08-13 against live data:

| Turn produced by | `image_model` | Card today |
|---|---|---|
| `generate_image` tool | set (`gpt-image-2`, `gemini-2.5-flash-image-preview`) | "Edit in KV Studio" renders |
| `generate_key_visual` tool | **NULL** | nothing renders |

`isKvHandoffEligible` requires `imageModel`, so KV-tool turns fall through. Dropping that gate to make
the existing card appear would be the wrong fix: that card **creates** a file, so it would file a
second, duplicate KV for one the chat had just saved.

## Scope

Phase 1, web only: on a turn whose tool results contain a KV file, render an **"Open in KV Studio"**
card under the generated image, routing to the file that already exists.

Phase 2, separate and later: change the ai-service prompt so the model stops writing the file block.

Out of scope: `list_key_visuals` / `get_key_visual` results (those turns render no image, so there is
no footer slot to hang a card on), and the generated-files gallery.

## Decisions and why

### No api and no ai-service change in phase 1

Everything needed is already on the wire. `KvToolController::generate` returns
`studio_file_id`, `brand_id`, and `file_url`
(`api/app/Http/Controllers/Api/ModelContextProtocol/KvToolController.php:466-470`). `ToolUsageData.tool_result`
is typed with `[key: string]: any` (`web/src/store/useChatStore.ts:114`), so web already receives all of
it, and `convertApiMessages.ts:53` maps `tool_result` back on rehydration — **the card survives a page
reload**, which a model-authored text block also does but a live-only signal would not.

### Open always wins over create

`ChatMessage`'s existing `renderImageFooter` picks the card:

```
KV tool file present in this turn  → <KvOpenInStudioCard>   (route to it)
otherwise                          → <KvHandoffCard>        (create from the image)
```

One branch, and it is the rule that makes a duplicate structurally impossible — including if
`image_model` ever starts being set on KV-tool turns too, which would otherwise silently make both
cards eligible at once.

### Route from `brand_id` + `studio_file_id`, never from `file_url`

`file_url` is absolute, built from `config('app.frontend_url')`
(`KvToolController.php:511-514`). Using it as an `href` forces a full page load, and if that config
value differs from the origin the user is on, it navigates them to a different host. The card builds
the same route the handoff already uses and calls `router.push`.

### The card has no error state

Click → navigate. No measure, no create, no import, no brand picker, no retry. If the file was deleted
from Studio in the meantime the user lands on a 404 in KV Studio rather than seeing an error in the
chat. Checking existence first would add a request and a busy state to defend against a rare case;
the 404 is the honest outcome and the cheaper one. **Deliberate** — do not "improve" this into a
pre-flight check without a reason from real usage.

### No brand picker, ever

The brand is not resolved or guessed here — it comes from the tool result, which is the brand the file
was actually created under. The four-way resolution and the picker in the sibling feature exist only
because *creating* a file has to choose a brand. Opening one does not.

## Components

| Unit | Responsibility | Depends on |
|---|---|---|
| `selectKvToolFile(toolUsages)` | pure: find the KV file this turn produced → `{ fileId, brandId, fileName } \| null` | nothing (no React, no DOM) |

### How the selector recognises the right result

Match on the **result shape**, not on a tool display name — display names are prose and change without
notice. `generate` is distinguishable from its siblings by construction
(`KvToolController.php:463-472`, `:68-84`, `:99-108`):

| Tool | `data` | Distinctive keys |
|---|---|---|
| `generate_key_visual` | **object** | `status: "processing"`, **`file_name`**, `studio_file_id`, `brand_id`, `file_url` |
| `list_key_visuals` | **array** | per row: `name`, `studio_file_id` |
| `get_key_visual` | object | `name` (not `file_name`), `id`, no `status` |

So the rule is: `data` is a non-array object carrying **both `studio_file_id` and `file_name`**.
`file_name` is the discriminator — the other two use `name`. A turn that lists and then generates
therefore yields exactly one match, and it is the file the turn produced.

**One thing the plan must settle empirically, not by assumption:** whether `tool_result` reaches web as
the raw `{ data: {...} }` envelope or already unwrapped by ai-service. The typed fields on
`ToolUsageData.tool_result` (`file_url`, `filename`) sit at the top level, which suggests unwrapping,
but that is inference. The selector should read `result.data ?? result` and the plan's first step should
print a real `tool_result` from a live KV turn to confirm which it is.

`status: "processing"` is expected and not a reason to withhold the card: the api returns 202 before the
new version renders, but the **file** exists from that moment, so opening it is valid immediately.
| `KvOpenInStudioCard` | presentation + one `router.push` | the selector's output, `usePermissions`, the feature flag |
| `ChatMessage.renderImageFooter` (modify) | choose which card | both cards |

The selector carries all the judgment (which tool, which result shape, what counts as present) and is
testable without rendering anything — the same split the sibling feature used for `kvHandoff.ts`, and
the reason its logic could be verified exhaustively in milliseconds.

## Data flow

```
generate_key_visual (ai-service)
  → POST mcp/tools/kv/generate (api)  → { studio_file_id, brand_id, file_url, message }
  → tool_result relayed verbatim through api's chat stream
  → web: message.toolUsages[].tool_result        (and on reload, convertApiMessages.ts:53)
  → selectKvToolFile(...)                        → { fileId, brandId, fileName }
  → renderImageFooter → <KvOpenInStudioCard>     → router.push(/brands/{brandId}/studio/kv-generator/{fileId})
```

## Gating

Every condition must hold, or nothing renders:

- `useMajorFeatureFlag(MAJOR_FEATURE_FLAGS.KV_GENERATOR)` — same flag as the sibling feature, no new one
- the turn's tool results contain a KV file
- the user can read that brand: `hasBrandPillarAccess(brandId, "brand.studio")` **and**
  `canReadForBrand("brand.studio.kv_generator", brandId)` — both, for the reason the sibling feature
  learned the hard way: `canReadForBrand` alone falls back to workspace-level `canRead` when
  `permissions.tower` is not an array

Fail closed. A user who cannot open the brand sees no card rather than a card that 403s.

## Analytics

One event, flat `askfrnd_*` per the repo convention (all 20+ askFRND events are flat snake_case):

| Event | Properties |
|---|---|
| `askfrnd_kv_open_clicked` | `file_id`, `conversation_id` |

No attempt/success/failure triple — there is nothing between the click and the navigation that can
fail, so a funnel would have two legs that are always equal.

## Testing

- **Selector**, exhaustively and without a DOM: no tool usages; unrelated tools; a KV result missing
  `brand_id`; a `tool_result` that is a plain string rather than an object; a `list_key_visuals` result
  (array) alongside a `generate` result, asserting the generate one wins; a `get_key_visual` result
  (`name`, no `file_name`) asserting it is ignored; and both envelope shapes, `{data:{…}}` and unwrapped.
- **Card**: renders title and file name; click routes to the right path; fires the event once.
- **The branch in `ChatMessage`** — the one that matters: a turn with BOTH a KV tool result and
  `image_model` set must render the open-card, not the create-card. This is the duplicate guard, and
  it is the test that would catch a future refactor collapsing the two cards.
- Runner is `bunx vitest run <path>`, not `bun test` — these files need `vi.*`.

## Risks

**A turn with two images and one file.** Observed data says KV turns render exactly one image, so the
footer fires once. If a two-version turn ever renders two, the same card appears under both, pointing
at the same file. Repetition, not incorrectness — accepted for v1 rather than threading an index
through the render-prop for a case that does not occur.

**Phase 2 is model behaviour, not code.** Prompting the model to stop writing the file block will not
be perfectly deterministic. That is why phase 1 ships first and stands on its own: if the model keeps
writing the block, the result is redundant, not broken.
