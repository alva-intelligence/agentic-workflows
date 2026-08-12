# askFRND → KV Studio handoff for generated images

**Date:** 2026-08-12
**Author:** daffa
**Services:** web, api
**Status:** approved

## Problem

askFRND can generate images. When it does, the conversation is a dead end for
that image: the only affordances are a lightbox, a download, and more chat
turns. Everything the product offers for *working on* a key visual — overlays,
text, shapes, resize, motion, export — lives in KV Studio, and there is no path
from the chat image to that surface. The user has to download the file and
re-upload it through KV Studio's upload-base entry point.

The pieces to close this gap already exist:

| Piece | Where |
|---|---|
| Image URL, public and permanent | `ai-service/app/tools/generate_image.py:483` uploads with `file_permission="public"` |
| "Import an existing image as a KV base" | `importKvGenerationFromUpload` → `POST v1/studio/kv-generator/files/{id}/generations/import-from-upload` |
| KV file creation from outside the studio | `createKvFile({ brand_id })`, already called from `KvConceptsArtifact` |
| An insertion point inside the rendered answer | `MarkdownRenderer` `img:` override (`web/src/components/base/MarkdownRenderer.tsx:309`) |
| Per-message "this turn generated an image" signal | `message.image_model` (`useChatStore.ts:201`, rehydrated in `convertApiMessages.ts:95`) |

Nothing here needs a new pipeline. What is missing is the affordance and the
brand plumbing around it.

## Scope

A card rendered directly beneath every AI-generated image in askFRND that
creates a KV file, imports that image as the Craft base, and lands the user on
the canvas. One API validation rule relaxes. No new endpoint, no new feature
flag, no ai-service change.

Out of scope: generated *video* (a Motion handoff is a separate feature),
importing into an existing KV file, and naming the new file from the prompt.

## Decisions and why

### The card follows the `GeneratedFileCard` pattern

askFRND already has three inline-card idioms, and they are not
interchangeable:

| Component | Reads as |
|---|---|
| `GeneratedFileCard` | "here is a result you can take out of this chat" |
| `DeckLinkPreview` | "here is a thing you cannot see inline, so here's a thumbnail" |
| `AgentToolCard` | "the system is doing / did something" |

This feature is the first category, so it copies that component's shape:
`max-w-[420px] rounded-xl border border-white/10 bg-white/5 px-4 py-3`, a
`size-10 rounded-lg` icon tile, title over subtitle, trailing affordance icon,
`hover:bg-white/[0.08]`.

`AgentToolCard`'s pill is deliberately **not** used: in askFRND that shape means
"system activity", so wearing it as a button would misread as status rather than
an action. `DeckLinkPreview`'s thumbnail is redundant here — the image sits
directly above the card. Copy is English, matching every other UI string in the
surface (`"Tap to download"`): **"Edit in KV Studio"** with the subtitle
*"Use this image as a key visual base"*.

### The card sits under the image, not at the end of the bubble

Generated images arrive as markdown `![alt](url)` **mid-prose** — there is text
before the image and text after it. "Under the image" and "at the end of the
message" are therefore different places, and only the former stays unambiguous
when one answer contains two images.

`MarkdownRenderer` gains one optional prop:

```ts
imageFooter?: (src: string, alt?: string) => React.ReactNode
```

It is called after each non-video `<img>`. `MarkdownRenderer` learns nothing
about KV Studio; `ChatMessage` supplies the slot and owns the decision. Two
images in one message therefore yield two cards, each carrying its own image —
a consequence of the hook point, and the correct behaviour.

New files:

| File | Role |
|---|---|
| `web/src/components/chat/KvHandoffCard.tsx` | the card: idle / loading / error states, owns the click orchestration |
| `web/src/components/chat/KvHandoffBrandPicker.tsx` | brand picker, rendered inline in the chat panel (phrasing content only) |

The card has three states. **Idle** is the resting card. **Loading** disables the
card and swaps the trailing icon for a spinner while the brand resolves and the
two calls run. **Error** replaces the subtitle with the failure reason and turns
the trailing affordance into a retry.

### Gating

Every condition must hold for the card to render:

| Condition | Source |
|---|---|
| `message.sender === "ai"` and `message.image_model` is set | `useChatStore`; survives reload via `convertApiMessages` |
| Not a video | the existing `isVideo` branch in the `img:` override |
| MIME ∈ `image/png,image/jpeg,image/webp,image/gif` | `getMimeTypeFromUrl`; anything else the API rejects, so no card |
| `useMajorFeatureFlag(MAJOR_FEATURE_FLAGS.KV_GENERATOR)` | `web/src/lib/featureFlags` |
| At least one brand where `hasBrandPillarAccess(id, "brand.studio")` | `usePermissions` |

`message.image_model` is used rather than the URL heuristic in
`GeneratedFiles.tsx` (`url.includes("amazonaws.com") || alt.includes("image")`),
which would also fire on web-search images and brand assets.

No new feature flag. Per the `frndos-feature-flags` rule — *skip the flag for
additions to an already-flagged surface* — this inherits `show-askfrnd` and is
additionally gated by `show-kv-generator` because it links into that surface.

### Brand resolution covers both askFRND contexts

askFRND is reachable at workspace level (no brand selected, so not brand-aware)
and inside brand-aware pages. KV Studio routes require `/brands/{id}/...`, so
the brand must be resolved in both:

1. **URL brand** — `getUrlBrandId(pathname)` (`web/src/hooks/useUrlBrandId.ts:18`),
   the brand-aware page case.
2. **`thread.origin_brand_id`** — a chat started from a brand page keeps its
   origin brand (`ThreadItem`, `response.ts:187`), so this still resolves after
   a reload or when the panel is reopened from the thread list.
3. **Brand picker** — workspace level. Lists brands from `useWorkspaceBrands`
   filtered by `hasBrandPillarAccess(id, "brand.studio")` **and**
   `canReadForBrand("brand.studio.kv_generator", id)` — the first alone falls back
   to workspace-level `canRead` for users whose permissions are not tower-shaped.
   Skipped when exactly one brand is accessible; the card does not render when
   none is.

   Rendered **inline in the chat panel**, directly under the card, styled like the
   genUI `choice_chips` it sits beside — not as a modal. A modal covered the whole
   app to ask one question and pulled the user out of the answer they were reading,
   and an uncapped list grew past the viewport in a workspace with dozens of brands.
   Inline means every element must be phrasing content (`span`/`button`/`input`),
   because the card renders inside a markdown `<p>`. Above 6 brands the list gets a
   search box; the list height is capped and scrolls.

   It only *looks* like genUI. A real `choice_chips` click calls `send()` and posts a
   message to the model; this one invokes a client-side callback, because the handoff
   is entirely client-side and the model never learns the card was clicked.

### Landing in Craft

`canvas_mode: "craft"`. "Continue editing this image" means polishing an
existing base, which is what Craft is for, and the craft-requires-base rule is
satisfied because the imported image *is* the base. Sketch would treat a
finished image as a starting sketch — a step backwards. The mode is sent
explicitly rather than relying on the server default (`"sketch"`), so the
behaviour does not silently change if that default moves.

### Web orchestrates with the two calls that already exist

```
click → card enters loading
      → resolve brand (picker only if needed)
      → createKvFile({ brand_id })
      → measure natural w/h: new Image() (plain load, no crossOrigin)
      → importKvGenerationFromUpload(fileId, {
          image_url, mime_type, width, height, canvas_mode: "craft"
        })
      → router.push(`/brands/${brandId}/studio/kv-generator/${fileId}`)
```

Failure at any stage keeps the user **in the chat** with an inline error and a
retry on the card — the context needed to try again is still on screen. If the
measurement step fails (the `Image` load errors, or reports zero dimensions),
the import is **not** attempted: `width`/`height` remain required server-side and
guessing them would silently mis-set `craft_supported`. A KV
file created before a failed import is indistinguishable from one created by the
"New KV" button, so it is left alone rather than rolled back; adding a delete
call from the chat would introduce another failure path without removing the
class.

A dedicated atomic api endpoint was rejected: both the create and the import
paths already exist and are exercised by other features, so a third path buys
only orphan-file avoidance at the cost of a new endpoint, request, service
method, and tests.

## API change

`api/app/Http/Requests/Studio/ImportKvGenerationFromUploadRequest.php`:

```diff
- 'size' => ['required', 'integer', 'min:1', 'max:20971520'],
+ 'size' => ['sometimes', 'nullable', 'integer', 'min:1', 'max:20971520'],
```

This is forced, not convenient. The S3 bucket serving these assets returns no
CORS headers — `<img src>` works in no-cors mode but `fetch()` fails before any
HTTP exchange, as documented in `web/src/lib/studio/kv/downloadFile.ts:7`. So a
browser can read an image's natural dimensions but *cannot* read its byte
length.

Relaxing it is safe because `size` drives no logic: `persistImportFromUpload`
(`KvGenerationService.php:149`) only writes it into `$metadata`. `width` and
`height` stay required — those feed `KvAspectRatio::isSupported`, which sets
`craft_supported` and the extreme-ratio block, and they *are* measurable client
side.

## Analytics

Per `frndos-analytics-events` ("if a user can do it, it gets an event"):

| Event | Properties |
|---|---|
| `askfrnd_kv_handoff_clicked` | `brand_resolution`: `url` \| `thread` \| `single` \| `picker`, `image_model`, `conversation_id` |
| `askfrnd_kv_handoff_succeeded` | `brand_resolution`, `conversation_id`, `file_id` |
| `askfrnd_kv_handoff_failed` | `stage`: `create` \| `measure` \| `import`, `reason`, `conversation_id` |

Three events, not two: attempt / success / failure. Without the success event the
conversion rate has to be inferred as clicked minus failed, which over-counts —
a user who closes the tab mid-handoff never reports either outcome.

`brand_resolution` carries **four** values, not three. A workspace-level user with
exactly one accessible brand is auto-resolved with no picker shown, and labelling
that `picker` would make the metric lie.

The `frndos-analytics-events` agent runs before this is called done. It did, and
it caught two things this spec had right and the web plan had drifted from: these
event names are flat `askfrnd_*` like every other askFRND event, and the funnel
needs its success leg.

## Testing

`bun test` (bunfig preloads jest-dom); the repo has no type gate, so any `tsc`
comparison is against a baseline worktree.

Web:
- card does not render when `image_model` is absent
- card does not render for a markdown video
- card does not render for a MIME outside the allowed set
- card does not render when the KV flag is off, or when no brand grants
  `brand.studio`
- brand resolution prefers URL, then `origin_brand_id`, then the picker; picker
  is skipped for a single accessible brand
- orchestration, services mocked: success navigates to the new file; a failed
  import does not navigate and surfaces the error

Assertions use `within(document.body)` rather than RTL's `screen`, which is
broken under bun in this repo. Tests reference components by real paths, not
`@/` aliases, so a rename fails loudly instead of silently skipping.

api:
- import succeeds with `size` omitted and stores `size: null` in metadata
- `width`/`height` remain required

## Risks

**`TrustedAssetHost` in staging/prod.** `import-from-upload` rejects any
`image_url` whose host is not `S3_OVERLAY_HOST_PATTERN` or a subdomain of it.
Locally that variable is unset, which `TrustedAssetHost::matches` treats as
permissive, so local testing cannot detect a mismatch. `AWS_BUCKET=frnd` and
ai-service uploads to the same bucket, so this is very likely fine — but it must
be confirmed with arhen against the deployed value before release. A mismatch
surfaces as a 422 on the import step, which the card's error state already
handles without stranding the user.

**Canvas tainting on export.** The no-CORS bucket means a canvas reading this
image can be tainted. This is not a new regression — it is identical to any
base imported through the existing upload path today, and `/api/kv/flatten-image`
exists as the server-side workaround. It stays on the e2e checklist rather than
being designed around.
