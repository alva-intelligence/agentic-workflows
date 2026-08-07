# KV Resize — resize any variant, not just the latest

**Date:** 2026-08-07
**Services:** api, web
**Status:** implemented

## Problem

Selecting an older variant on the KV canvas and running a resize failed with a red
toast: *"A newer generation exists. Refresh and try again."* (HTTP 409).

This breaks non-linear editing. A user who generates ten variants should be able to
pin any one of them and resize it. Pinning variant 3 and resizing it is a normal
act, not a stale write.

## Root cause

`KvResizeExportController` resolved "the latest generation" by `version_number` and
treated that as the only legal target, in **three** places:

| Line | Method | Effect |
|---|---|---|
| 83 | `store()` | 409 unless the named parent was the latest generation |
| 39 | `index()` | Listed the latest generation's exports, ignoring the parent the client asked about |
| 291 | `downloadZip()` | Zipped the latest generation's exports |

Plus `stream()`, which emitted every export row for the file regardless of parent.

The 409 came from the original April 2026 resize spec, which predates the
non-linear board model. That spec's validation rule reads: *"`parent_generation_id`
must belong to `studio_file_id` and be the latest generation."*

The write-side 409 was the visible bug. The read-side had a second, quieter one:
because `index()` ignored the requested parent while the React Query cache keyed on
it, pinning variant 3 listed **variant 5's** tiles under variant 3's cache key.

### What was already correct

- **Data model.** `kv_resize_exports` is unique on `(parent_generation_id, platform_id)`.
  Several variants can each own a full set of exports with no collision. Nothing had
  to change here.
- **Web.** `KvGeneratorLayout` already resolves `viewedGeneration` (pinned board,
  else latest) and sends it as `parent_generation_id`. `KvResizeCanvas` already
  sources from `source.id`. The React Query key already included the parent.
- **Motion** has no equivalent guard. Resize was the only holdout.

## Design

The parent generation is an **input, not a lookup**. The caller names the generation
it is acting on and the API obeys. `KvGeneration::where('studio_file_id', …)->firstOrFail()`
— parent must belong to this file — is the real boundary; the "must be latest" check
layered on top protected nothing, because exports are keyed per parent and can never
overwrite each other.

### API

| Endpoint | Before | After |
|---|---|---|
| `POST /resize-exports` | 409 unless parent is latest | Creates for whatever parent is named |
| `GET /resize-exports` | Rows for latest | Rows for `?parent_generation_id=…`, falling back to latest |
| `GET /resize-exports/stream` | Every row for the file | Named parent's rows only; termination check scoped to match |
| `GET /resize-exports/download-zip` | Latest's done rows | Named parent's done rows |

A private `resolveParent()` centralises the lookup: it validates the requested id
against the file (so the param can't become a cross-file read primitive) and falls
back to latest when the caller doesn't name one.

Two deliberate exceptions:

- **`failStaleExports()` stays file-wide.** It is a self-heal watchdog for exports
  whose completion callback never landed (D18). Scoping it to one parent would
  strand another variant's orphaned spinners until someone opened that exact variant.
- **`regenerate` / `updateOverlays` / `destroy` are unchanged.** They address a row
  by id and were already parent-agnostic.

### Web

- `listResizeExports(fileId, parentGenerationId?)` passes the param.
- `connectResizeStream(fileId, parentGenerationId, onUpdate)` passes the param **and**
  drops any event whose `parent_generation_id` doesn't match. Server-side scoping is
  the fix; the client check is a guard against a connection outliving a variant switch.
- `useResizeExports` threads its existing `parentGenerationId` into both.

No component changes — the UI layer was already per-variant.

## Consequences

**Resizing v3 after already resizing v5 charges credits again.** `firstOrCreate` keys
on `(parent_generation_id, platform_id)`, so those are distinct rows. This is correct
— it is a separate render of different source pixels — but a user hopping between
variants can spend more than they might expect.

**No new storage growth.** Per-variant export rows already accumulated; they were
simply unreadable once a newer generation existed. This change makes them visible.

## Testing

api (`KvResizeExportControllerTest`, `KvResizeExportStreamTest`):

- Creating exports for an older generation when a newer one exists returns 202.
- A `parent_generation_id` from another file is rejected (404) — on both write and read.
- Two generations hold independent exports for the same platform id.
- `index` returns the requested generation's rows, not the latest's.
- `stream` emits only the watched generation's rows.

Two pre-existing problems in the same file were fixed because they masked real
coverage:

- The `beforeEach` never granted credits, so **every** POST assertion failed at the
  `check.credits:1` gate with a 400 before reaching the controller.
- `it('soft-deletes an export')` asserted `trashed()` against a `destroy()` that was
  changed to `forceDelete()` by the resize-cancel work. It now asserts hard deletion,
  matching the controller's own comment.

web (`api.test.ts`, `resize-stream.test.ts`, `useResizeExports.test.ts`):

- The list request carries `parent_generation_id`, and omits it when not given.
- The stream URL is scoped, and a foreign-parent event is dropped.
- `useResizeExports` fetches the generation it is showing.

## Not done

- **No analytics change.** `trackKvResizeRequested` already emits
  `parent_generation_id`. Adding an `is_latest_generation` boolean would make
  adoption of non-linear resize directly measurable — worth considering separately.
- **No UI indicator** of which variant a resize batch targets. Considered and
  deferred; the chat already shows an "Editing {board}" chip.
