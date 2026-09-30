# Client Lane Multi-Item Approval — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one approval round freeze N items (KV boards, resize tiles, motion clips; one item for deck/plan), serve them frozen on the public `/s/{token}` resolver, accept pins on any item of the round, and record round-level (Phase 1) or item-level (Phase 2-ready) decisions, all additive to the P0a contract.

**Architecture:** A new `approval_items` table (one row per frozen item, `snapshot` jsonb = the KV payload item as rendered) hangs off `approvals`; `approvals.subject_version_*` stays and is written with the first item. `KvSharePayloadService` gets a public per-phase resolver (`itemsFor`, `resolvePhase`) that both the live view-link payload and the approval freeze use, so the frozen id is the id the page renders. `ApprovalService` freezes before the row lock, writes items in the round transaction, and resolves item statuses (round-level cascade, or per-item policy + aggregate). The public resolver, comments, pins and agency presenter read the round's item set instead of one version id.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL (jsonb, `split_part`), Pest 3.

**Spec:** docs/superpowers/specs/2026-09-30-client-lane-multi-item-approval-design.md

### Contract deviations

**None.** The fixed cross-repo contract (items 1–9 in the brief) is implemented as given. Clarifications the contract left open, decided here and written into the PRD's additive notes in Task 0 (web must not depend on any of them beyond what is stated):

- Deck/plan items created by a NEW round are labelled `Deck · v{round}` / `Plan · v{round}`; backfilled items are labelled `v{round}` (contract 7). The label difference is also what lets the backfill's `down()` tell a backfilled row from a live one (see Task 1).
- A board with no name is labelled `{Phase} · Untitled board`. Every label is truncated to ≤ 160 chars (`Str::limit(…, 157)` → `...` suffix).
- For `kv_file`, sending BOTH `kv_phases` and `kv_ready_item_id` fails validation on the `kv_ready_item_id` key (standard 422 `errors`), as does sending neither.
- `kv_ready_item_id` (legacy) now freezes the item AS RENDERED (board chain tip / newest motion render / resize row) — the spec's "rendered id" rule applied to the one-item path. A legacy id whose item does not render (e.g. a resize tile still generating) is a 422 on `kv_ready_item_id` ("That item is not ready to share yet.").
- Superseding a pending round (a new `request()`) sets the old round's items `not_relevant`, same as withdraw.
- Item-level decisions under `policy = required`: the same rule as the round runs per item (only named approvers count; any `changes_required` settles the item; otherwise it settles once every named approver decided on that item). Advisory decisions never settle an item.
- A round-level resolving decision overwrites EVERY item's status with the round outcome (contract 4, literal), including items an earlier item-level decision had settled.
- A round with zero `approval_items` rows (pre-backfill / factory-made) behaves as a one-version round keyed on `subject_version_id` for comments and pins (`Approval::itemVersionIds()` fallback).

## Global Constraints

- **Repo + shell:** every command runs from the api repo root. Agent shells reset cwd, so prefix every shell call with `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && `. All paths below are relative to that root unless absolute.
- **Branch:** all work on `feature/daffa/vc-client-lane-multi-item` (created in Task 0 from latest `develop`). Never commit on `develop`.
- **api/AGENTS.md rule 1:** "DO NOT MAKE OR RUN ANY TESTS WITHOUT USER PERMISSION." **GRANTED by Daffa 2026-09-30** for exactly the Pest files named in this plan, run only against the scratch DB (`frnd_testing`) with the isolation checks below — do not ask again; anything beyond that still needs asking. Original instruction: Before Task 1 Step 1, ask Daffa (AskUserQuestion) for one explicit approval covering "write and run the Pest files named in this plan against the scratch Postgres DB". Do not write or run a test before that yes.
- **api/AGENTS.md rule 2:** commit messages carry NO `Co-Authored-By` / "Generated with Claude Code" trailer. Format `<type>(api): <description>`.
- **Test DB isolation (never the dev DB `frnd`):** before every test run:
  1. `ls bootstrap/cache/config.php 2>/dev/null` must print nothing; if it prints a path run `php artisan config:clear`.
  2. If `bootstrap/cache/routes-v7.php` exists, move it aside: `mv bootstrap/cache/routes-v7.php /private/tmp/claude-501/routes-v7.php.bak`. Never restore it (a stale route cache 405s every new route); tell Daffa it was moved.
  3. Pick the scratch DB: `psql -lqt | cut -d'|' -f1 | grep -E 'frnd_test'`. As of 2026-09-30 both `frnd_test` and `frnd_testing` exist; the commands below use `frnd_testing` — substitute `frnd_test` if `frnd_testing` is missing. `tests/TestCase.php` refuses any DB whose name lacks a `test` token.
  4. Run form (always FILE PATHS, never `--filter`; one Pest process at a time; never `php artisan test`):
     `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest <file> --compact`
- **The full Feature suite is known-broken on fresh migrate for unrelated reasons.** Only run the files this plan names. If `migrate:fresh` itself fails in the pre-flight (Task 1 Step 1), STOP and report — do not fix unrelated migrations.
- **Data migrations:** run with `TELESCOPE_ENABLED=false` (Telescope OOMs data migrations). The dev DB `frnd` is migrated only in Task 9, only after asking Daffa.
- **Never `git stash`** (lesson: a popped stale stash corrupted files). Compare baselines with a worktree if ever needed.
- **Tests written from reasoning are often vacuous.** Every test step is followed by (a) a run that must FAIL for the stated reason, (b) the implementation, (c) a PASS run, and (d) a **mutation check**: break the named line, run, watch the named test fail, restore. If a test passes against the mutation, the test is wrong — fix the test, not the mutation. Where an expected value comes from real code (display labels, dimensions, payload fields), the plan says so; if the assertion fails on UNCHANGED production code, dump the actual value, confirm it is right by reading the code, and correct the expectation — never the service.
- **Public write throttle** (`public-share-link-write` = 10/min per IP): keep ≤ 9 public POSTs per test.
- **Postgres-only SQL** (`split_part`, jsonb): these tests cannot run on SQLite.
- **Gates at every commit:** `php -l` on each touched PHP file; `vendor/bin/pint --test <touched files>` (fix with `vendor/bin/pint <files>`).
- Line numbers cite `develop` as read on 2026-09-30. Earlier tasks shift them — re-read each file before editing and anchor edits on the quoted code, not the number.

## Review Focus

Input classes / failure modes most likely to bite real users that the happy-path tests would not cover. Each has a test placed in the owning task.

1. **Oversized or multibyte labels.** Board names come from the Yjs canvas (unbounded); a 300-char board name would make `approval_items.label varchar(160)` throw `22001` and 500 the whole "Send for approval". → Task 3 test *"labels never overflow the column, whatever the board or tile is called"*.
2. **Items with no image.** Layer-composed (PSD) resize tiles finish `done` with `image_url = NULL`; motion clips have no image at all. Freezing must not fail and the agency thumbnail must be `null`, not a broken URL. → Task 3 test *"a layer-composed resize tile (no image) freezes with a null image"* and Task 7 test *"GET v1/approvals lists each round's items with thumbnails…"*.
3. **Rounds with zero item rows** (created before the backfill ran, or by `ApprovalFactory`). An empty version set would make `split_part(...) IN ()` a SQL syntax error (500 on every comment load) and reject every pin. → Task 5 test *"a round with no item rows (pre-backfill) still pins against its subject version"*.
4. **jsonb round-trip of snapshots.** Postgres reorders jsonb object keys and the array cast turns `{}` into `[]`; the frozen document must still equal, by value, what the client saw at request time (including nested overlay payloads). → Task 6 test *"the KV document is frozen…"* (asserts `toEqual` against the pre-request `itemsFor()` output with an overlay present).
5. **Advisory decisions under `required`.** A forwarded-link guest who is not a named approver must never settle an item (Phase 2 would otherwise let anyone approve items one by one). → Task 4 test *"an advisory decision never settles an item"*.

Resolved (Daffa, 2026-09-30): resize item `version_id` is the resize ROW id, stable across regenerations, so version membership alone would carry round-1 tile pins into round 2. Pins therefore belong to their round: `comments()` and `validatePins()` also require the root pin's `created_at >= approval.created_at` — Task 5 test *"a pin from an earlier round does not carry into the next round, even on an unchanged tile"*.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `docs/prd/client-lane-p0a/api.md` | Modify | Additive contract notes for multi-item rounds (Task 0) |
| `database/migrations/2026_09_30_120000_create_approval_items_table.php` | Create | `approval_items` table + status CHECK |
| `database/migrations/2026_09_30_120100_add_approval_item_id_to_approval_decisions.php` | Create | `approval_decisions.approval_item_id` nullable FK, null on delete |
| `database/migrations/2026_09_30_120200_backfill_approval_items.php` | Create | One item per existing round; reversible |
| `app/Models/ApprovalItem.php` | Create | Item model (`isPending`, `thumbnailUrl`) |
| `app/Models/Approval.php` | Modify | `items()` relation, `itemVersionIds()` |
| `app/Models/ApprovalDecision.php` | Modify | `approval_item_id` fillable + `item()` |
| `database/factories/ApprovalItemFactory.php` | Create | Factory for items |
| `tests/Support/ClientLaneFixtures.php` | Create | Shared KV/plan/round seeders for the new tests |
| `app/Services/Studio/KvSharePayloadService.php` | Modify | Public `itemsFor()` + `resolvePhase()`; `build()` delegates |
| `app/Services/Approval/FrozenItem.php` | Create | Value object: one item about to be frozen (phase, type, id, label, snapshot) |
| `app/Exceptions/Approval/NothingReadyException.php` | Create | `422 nothing_ready` |
| `app/Exceptions/Approval/TooManyItemsException.php` | Create | `422 too_many_items` (carries `max`) |
| `app/Exceptions/Approval/InvalidItemException.php` | Create | `422 invalid_item` |
| `app/Services/Approval/ApprovalService.php` | Modify | Multi-item freeze, item statuses, aggregate, pin membership |
| `app/Http/Controllers/Api/PublicShareLinkController.php` | Modify | C-1 `items` + frozen KV document; C-3 `item_id`; C-4 membership |
| `app/Http/Resources/Approval/ApprovalPresenter.php` | Modify | Public `items()`, agency `items`, decision `item_id` |
| `app/Http/Controllers/Api/Approval/ApprovalController.php` | Modify | `kv_phases` validation, coded 422s, eager-load items |
| `app/Services/Approval/ApprovalNotifier.php` | Modify | `versionLabel()` public + item count; decided-mail item count |
| `app/Mail/ApprovalDecidedMail.php` | Modify | `itemCount` |
| `resources/views/emails/client-lane/approval-decided.blade.php` | Modify | Pin footnote across items |
| `tests/Feature/Approval/ApprovalItemsMigrationTest.php` | Create | Schema, FKs, backfill up/down |
| `tests/Feature/Approval/KvSharePayloadItemsForTest.php` | Create | Extraction characterisation + `itemsFor` |
| `tests/Feature/Approval/ApprovalRequestItemsTest.php` | Create | Freeze, rendered ids, caps, legacy, deck/plan, link union |
| `tests/Feature/Approval/ApprovalDecideItemsTest.php` | Create | Round/item decisions, aggregate, withdraw, invalid_item |
| `tests/Feature/Approval/ApprovalPinsMembershipTest.php` | Create | Comments/pins across items |
| `tests/Feature/Approval/PublicShareLinkItemsTest.php` | Create | C-1 items + frozen document + 404 |
| `tests/Feature/Approval/ApprovalControllerItemsTest.php` | Create | C-9 store/index |
| `tests/Feature/Approval/ApprovalNotifierLabelTest.php` | Create | Labels + decided mail |
| `docs/tracks/client-lane-multi-item.track.md` | Create | Track file (Task 9) |

---

### Task 0: Branch + contract PRD update

**Files:**
- Modify: `docs/prd/client-lane-p0a/api.md` (insert after line 151, the last bullet of "### Additive notes (post-freeze, non-breaking — api PR #539 review round 1, 2026-09-18)", before `## Scope` at line 153)

**Interfaces:**
- Consumes: nothing.
- Produces: the additive contract text the web plan copies byte-identically into `web/docs/prd/client-lane-p0a/web.md` (the web plan edits its own copy; this plan edits only the api copy).

- [ ] **Step 1: Confirm a clean tree and cut the branch**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && git status --short
```
Expected: no output. If anything is listed, stop and ask Daffa (do not stash).

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && git fetch origin && git checkout develop && git pull --rebase origin develop && git checkout -b feature/daffa/vc-client-lane-multi-item
```

- [ ] **Step 2: Check migration timestamps are still free**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && ls database/migrations | tail -5
```
Expected: the newest file sorts before `2026_09_30_120000_…`. If develop gained a later migration, bump all three new migration timestamps in this plan to sort after it (keep their relative order) and use the new names everywhere below.

- [ ] **Step 3: Insert the additive notes**

Insert this block after line 151 of `docs/prd/client-lane-p0a/api.md` (blank line before and after):

```markdown
### Additive notes (multi-item approval rounds — spec `docs/superpowers/specs/2026-09-30-client-lane-multi-item-approval-design.md`, 2026-09-30)

Additive only; nothing documented above changes meaning. Byte-identical in `api.md` and `web.md`.

- **Round items.** A round freezes 1..50 items. `ApprovalItem = { "id": "<ulid>", "phase": "sketch | craft | resize | motion | deck | plan", "label": "…", "version_id": "…", "status": "pending | approved | approved_with_changes | changes_required | not_relevant", "snapshot": {…} | null }`. For KV, `snapshot` is exactly the payload item as rendered at request time — board `{ id, kind: "board", name, image_url, aspect_ratio, is_master, overlays }`, resize `{ id, kind: "resize", platform_id, platform_label, width, height, image_url, overlays, source_overlays, source_width, source_height }`, motion `{ id, kind: "motion", video_url, ratio, width, height, duration_ms }` — and `version_id` = that item's `id` (the board's chain TIP, the NEWEST render of the motion's project + ratio, the resize ROW id). `snapshot` is `null` for deck/plan items and for rounds that existed before this change. Items are ordered by phase (sketch, craft, resize, motion), then payload order. Labels: board `"{Sketch|Craft} · {board name}"` (`Untitled board` when unnamed), resize `"Resize · {platform_label} · {w}×{h}"`, motion `"Motion · {ratio} · {w}×{h}"`, deck `"Deck · v{round}"`, plan `"Plan · v{round}"`, pre-existing rounds `"v{round}"`; at most 160 chars (longer ones end in `...`). Labels are display text — never parse them.
- **C-1** gains a top-level `"items": [ApprovalItem]` (sibling of `version`); `[]` for a `view` link and whenever `approval` is `null`. `version` keeps its shape: `label = "v{round}"`, `id` = the first item's `version_id`. For `type = kv_file`, when the round has items and every item has a `snapshot`, `document` is built from the snapshots — `{ "name", "brand_slug", "phases": [ { "phase", "items": [snapshot, …] } ] }`, canonical phase order, only phases that hold items — so edits or unmarks after the request never change the approval page. Otherwise (`view` link, withdrawn round, pre-existing round) `document` is the live payload as before.
- **C-3** request gains optional `"item_id": "<ApprovalItem.id>"`. An id that is not an item of the current round, or `item_id` together with `outcome = deferred`, → `422 { "code": "invalid_item", "message": "…" }`. Without `item_id` (all Phase 1 web sends) the round resolves exactly as before and every item takes the round's resolved status. With `item_id`, the policy rule runs per item (under `required` only named approvers count; advisory decisions never settle an item) and the round resolves once every item is settled: `changes_required` if any item is, else `approved_with_changes` if any item is, else `approved`. Withdrawing or superseding a round sets its items `not_relevant`. Every decision object (C-1, C-3, C-9) carries `"item_id": "<ulid>" | null`.
- **C-3 pins / C-4 comments.** "This round's version" becomes "any of this round's item `version_id`s": `GET …/comments` returns roots whose anchor version segment is in that set, plus their replies; `POST …/comments` refuses a new root outside the set with `422 { "code": "invalid_anchor", "message": "That element is not in this round." }`; decision `pins` follow the same rule. Anchor format unchanged, `{phase}:{version_id}:{part}`; a resize pin's part is `tile.{resize row id}` (the api validates only the version segment).
- **C-9** `POST v1/approvals` gains `"kv_phases": ["sketch" | "craft" | "resize" | "motion", …]` (at least one, distinct). For `kv_file` exactly one of `kv_phases` / `kv_ready_item_id` is required (neither, or both → `422` on `kv_ready_item_id`); both are prohibited for other subject types. `kv_ready_item_id` freezes a one-item round of that item as rendered. `422 { "code": "nothing_ready", "message": "…" }` when the selected phases hold no ready item; `422 { "code": "too_many_items", "max": 50, "message": "…" }` above 50 items. The reused-or-minted `comment` link's `phases` become the union of its phases and the round's phases. The agency approval shape (store response and `GET v1/approvals`) gains `"items": [ { "id", "phase", "label", "version_id", "status", "thumbnail_url": "…" | null } ]` — `thumbnail_url` is the snapshot's `image_url` (`null` for motion, deck, plan, and a layer-composed resize tile).
- **Mail / inbox** version label: `v{round}` for one item, `v{round} · {n} items` for more. The decided mail's pin line counts the decision's pins across all items ("{p} pins left across {n} items.").
```

- [ ] **Step 4: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && git add docs/prd/client-lane-p0a/api.md && git commit -m "docs(api): client-lane contract — additive notes for multi-item approval rounds"
```

- [ ] **Step 5: Flag for Jeff**

Tell Daffa the contract diff (this commit, and the identical web one) needs Jeff's review per spec §8. Implementation continues (the change is additive); the PR is not opened until Jeff acks.

---

### Task 1: Schema, models, factory, backfill, test fixtures

**Files:**
- Create: `database/migrations/2026_09_30_120000_create_approval_items_table.php`
- Create: `database/migrations/2026_09_30_120100_add_approval_item_id_to_approval_decisions.php`
- Create: `database/migrations/2026_09_30_120200_backfill_approval_items.php`
- Create: `app/Models/ApprovalItem.php`
- Modify: `app/Models/Approval.php` (docblock 31-51, relations after `decisions()` at 134-137)
- Modify: `app/Models/ApprovalDecision.php` (docblock 23-37, `$fillable` 69-83, relations after `approval()` 96-99)
- Create: `database/factories/ApprovalItemFactory.php`
- Create: `tests/Support/ClientLaneFixtures.php`
- Test: `tests/Feature/Approval/ApprovalItemsMigrationTest.php`

**Interfaces:**
- Consumes: `approvals`, `approval_decisions`, `kv_generations` tables.
- Produces:
  - `App\Models\ApprovalItem` — `const UPDATED_AT = null`, `PHASES`, `approval(): BelongsTo`, `isPending(): bool`, `thumbnailUrl(): ?string`.
  - `Approval::items(): HasMany` (ordered by `position`), `Approval::itemVersionIds(): array` (non-empty list of strings).
  - `ApprovalDecision::item(): BelongsTo`, fillable `approval_item_id`.
  - `Tests\Support\ClientLaneFixtures::kvFile(): array{workspace, user, brand, file}`, `::board(StudioFile, User, string $mode = 'craft', string $name = 'Hero board', string $imageUrl = 'https://cdn.test/board-1.png'): KvGeneration`, `::iterate(StudioFile, User, KvGeneration $tip, string $imageUrl): KvGeneration`, `::resizeTile(StudioFile, User, KvGeneration $parent, string $platformId = 'instagram-story', int $width = 1080, int $height = 1920, ?string $imageUrl = 'https://cdn.test/tile-1.png', ?string $name = null): KvResizeExport`, `::motionExport(StudioFile, User, KvGeneration $board, string $ratio = 'instagram-story', string $url = 'https://cdn.test/motion-1.mp4'): KvMotionExport`, `::reExport(KvMotionExport, string $url): KvMotionExport`, `::markReady(string $type, string $id, User): ShareReadyItem`, `::roundWithItems(list<string> $versionIds, array $attrs = []): Approval`, `::plan(): array{user, plan}`.

- [ ] **Step 1: Pre-flight — prove the scratch DB migrates**

Ask Daffa for the test permission (Global Constraints, AGENTS.md rule 1) first. Then:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && ls bootstrap/cache/config.php bootstrap/cache/routes-v7.php 2>/dev/null; psql -lqt | cut -d'|' -f1 | grep -E 'frnd_test'
```
Expected: no cache files listed (handle per Global Constraints if any), and `frnd_testing` (or `frnd_test`) listed.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/KvGenerationModelTest.php --compact
```
Expected: PASS. If it fails inside `migrate:fresh`, STOP and report (unrelated breakage).

- [ ] **Step 2: Write the fixtures class**

Create `tests/Support/ClientLaneFixtures.php`:

```php
<?php

namespace Tests\Support;

use App\Enums\KvResizeExportStatus;
use App\Models\Approval;
use App\Models\ApprovalItem;
use App\Models\Brand;
use App\Models\CampaignPlan;
use App\Models\KvGeneration;
use App\Models\KvMotionExport;
use App\Models\KvMotionProject;
use App\Models\KvResizeExport;
use App\Models\ShareReadyItem;
use App\Models\StudioFile;
use App\Models\Tool;
use App\Models\User;
use App\Models\Workspace;
use App\Services\Studio\KvReadyToShareService;

/**
 * Seeds for the client-lane multi-item approval tests
 * (docs/superpowers/specs/2026-09-30-client-lane-multi-item-approval-design.md).
 *
 * A class, not global test functions: several test files use these, and
 * Pest loads every file of a run into one process — two files declaring
 * the same global function is a fatal redeclare.
 */
final class ClientLaneFixtures
{
    /** @return array{workspace: Workspace, user: User, brand: Brand, file: StudioFile} */
    public static function kvFile(): array
    {
        $workspace = Workspace::factory()->create(['type' => 'organization']);
        $user = User::factory()->create();
        $user->update(['current_workspace_id' => $workspace->id]);
        $user->workspaces()->attach($workspace->id);

        $brand = Brand::factory()->create(['workspace_id' => $workspace->id]);
        $tool = Tool::query()->where('slug', 'kv-generator')->first()
            ?? Tool::factory()->create(['slug' => 'kv-generator']);

        $file = StudioFile::factory()->create([
            'workspace_id' => $workspace->id,
            'brand_id' => $brand->id,
            'tool_id' => $tool->id,
            'created_by' => $user->id,
            'last_edited_by' => $user->id,
            'name' => 'Ramadan hero KV',
            'metadata' => null,
        ]);

        return ['workspace' => $workspace, 'user' => $user, 'brand' => $brand, 'file' => $file];
    }

    /** A generation registered as its own artboard on the file's canvas (first one becomes master). */
    public static function board(
        StudioFile $file,
        User $user,
        string $mode = 'craft',
        string $name = 'Hero board',
        string $imageUrl = 'https://cdn.test/board-1.png',
    ): KvGeneration {
        $generation = KvGeneration::factory()->create([
            'studio_file_id' => $file->id,
            'mode' => $mode,
            'image_url' => $imageUrl,
            'created_by' => $user->id,
            'metadata' => ['aspect_ratio' => '16:9', 'width' => 1672, 'height' => 941],
        ]);

        $file->refresh();
        $metadata = $file->metadata ?? [];
        $metadata['kv_canvas']['schema_version'] = 1;
        $metadata['kv_canvas']['artboards'][$generation->id] = [
            'x' => 0,
            'y' => 0,
            'name' => $name,
            'version_ids' => [],
        ];
        $metadata['kv_canvas']['master_generation_id'] ??= $generation->id;
        $file->forceFill(['metadata' => $metadata])->save();
        $file->refresh();

        return $generation;
    }

    /** A craft iteration: rekeys the artboard onto a new tip, old tip joins `version_ids`. */
    public static function iterate(StudioFile $file, User $user, KvGeneration $tip, string $imageUrl): KvGeneration
    {
        $next = KvGeneration::factory()->create([
            'studio_file_id' => $file->id,
            'parent_generation_id' => $tip->id,
            'version_number' => $tip->version_number + 1,
            'mode' => $tip->mode,
            'image_url' => $imageUrl,
            'created_by' => $user->id,
            'metadata' => $tip->metadata,
        ]);

        $file->refresh();
        $metadata = $file->metadata;
        $artboard = $metadata['kv_canvas']['artboards'][$tip->id];
        unset($metadata['kv_canvas']['artboards'][$tip->id]);
        $artboard['version_ids'] = [...($artboard['version_ids'] ?? []), $tip->id];
        $metadata['kv_canvas']['artboards'][$next->id] = $artboard;
        if (($metadata['kv_canvas']['master_generation_id'] ?? null) === $tip->id) {
            $metadata['kv_canvas']['master_generation_id'] = $next->id;
        }
        $file->forceFill(['metadata' => $metadata])->save();
        $file->refresh();

        return $next;
    }

    /** A finished (`done`) resize tile; pass `$imageUrl = null` for a layer-composed (PSD) tile. */
    public static function resizeTile(
        StudioFile $file,
        User $user,
        KvGeneration $parent,
        string $platformId = 'instagram-story',
        int $width = 1080,
        int $height = 1920,
        ?string $imageUrl = 'https://cdn.test/tile-1.png',
        ?string $name = null,
    ): KvResizeExport {
        return KvResizeExport::factory()->create([
            'studio_file_id' => $file->id,
            'parent_generation_id' => $parent->id,
            'created_by' => $user->id,
            'platform_id' => $platformId,
            'name' => $name,
            'width' => $width,
            'height' => $height,
            'status' => KvResizeExportStatus::Done,
            'image_url' => $imageUrl,
            'overlays' => null,
        ]);
    }

    public static function motionExport(
        StudioFile $file,
        User $user,
        KvGeneration $board,
        string $ratio = 'instagram-story',
        string $url = 'https://cdn.test/motion-1.mp4',
    ): KvMotionExport {
        $project = KvMotionProject::query()->create([
            'studio_file_id' => $file->id,
            'board_generation_id' => $board->id,
            'created_by' => $user->id,
            'name' => 'Ramadan cutdown',
            'snapshot' => [],
            'timeline' => [],
            'duration_ms' => 8000,
            'fps' => 30,
        ]);

        return KvMotionExport::query()->create([
            'kv_motion_project_id' => $project->id,
            'ratio' => $ratio,
            'url' => $url,
            'width' => 1080,
            'height' => 1920,
            'duration_ms' => 8000,
        ]);
    }

    /** A newer render of the same project + ratio (created a minute later so it sorts newest). */
    public static function reExport(KvMotionExport $export, string $url): KvMotionExport
    {
        $newer = KvMotionExport::query()->create([
            'kv_motion_project_id' => $export->kv_motion_project_id,
            'ratio' => $export->ratio,
            'url' => $url,
            'width' => $export->width,
            'height' => $export->height,
            'duration_ms' => $export->duration_ms,
        ]);
        $newer->forceFill(['created_at' => now()->addMinute()])->save();

        return $newer;
    }

    public static function markReady(string $markableType, string $markableId, User $user): ShareReadyItem
    {
        return app(KvReadyToShareService::class)->mark($markableType, $markableId, $user);
    }

    /**
     * A deck round (ApprovalFactory default subject) with one item per
     * version id, in order.
     *
     * @param  list<string>  $versionIds
     * @param  array<string, mixed>  $attrs  extra Approval attributes
     */
    public static function roundWithItems(array $versionIds, array $attrs = []): Approval
    {
        $approval = Approval::factory()->create(array_merge([
            'subject_version_type' => Approval::VERSION_DECK,
            'subject_version_id' => $versionIds[0],
        ], $attrs));

        foreach ($versionIds as $position => $versionId) {
            ApprovalItem::factory()->create([
                'approval_id' => $approval->id,
                'position' => $position,
                'phase' => 'deck',
                'version_type' => Approval::VERSION_DECK,
                'version_id' => $versionId,
                'label' => 'Item '.($position + 1),
            ]);
        }

        return $approval->refresh();
    }

    /** @return array{user: User, plan: CampaignPlan} */
    public static function plan(): array
    {
        $workspace = Workspace::factory()->create(['type' => 'organization']);
        $user = User::factory()->create();
        $brand = Brand::factory()->create(['workspace_id' => $workspace->id]);
        $plan = CampaignPlan::factory()->create(['brand_id' => $brand->id, 'created_by' => $user->id]);

        return ['user' => $user, 'plan' => $plan];
    }
}
```

- [ ] **Step 3: Write the failing test**

Create `tests/Feature/Approval/ApprovalItemsMigrationTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Models\Approval;
use App\Models\ApprovalDecision;
use App\Models\ApprovalItem;
use Illuminate\Database\QueryException;
use Tests\Support\ClientLaneFixtures;

// `require`, not `require_once`: each call re-evaluates the file and hands
// back a fresh migration instance.
function clBackfillMigration(): object
{
    return require database_path('migrations/2026_09_30_120200_backfill_approval_items.php');
}

test('the backfill writes one item per existing round, phase derived from the version type', function () {
    $kv = ClientLaneFixtures::kvFile();
    $sketch = ClientLaneFixtures::board($kv['file'], $kv['user'], 'sketch', 'Moodboard');
    $craft = ClientLaneFixtures::board($kv['file'], $kv['user'], 'craft', 'Hero board');
    $onFile = [
        'subject_type' => 'kv_file',
        'subject_id' => $kv['file']->id,
        'workspace_id' => $kv['workspace']->id,
        'brand_id' => $kv['brand']->id,
    ];

    $deck = Approval::factory()->create(['status' => 'approved', 'subject_version_type' => 'deck_version', 'subject_version_id' => '812']);
    $plan = Approval::factory()->create(['status' => 'changes_required', 'subject_version_type' => 'fingerprint', 'subject_version_id' => str_repeat('a', 64)]);
    $sketchRound = Approval::factory()->create([...$onFile, 'round' => 1, 'status' => 'not_relevant', 'subject_version_type' => 'kv_generation', 'subject_version_id' => $sketch->id]);
    $craftRound = Approval::factory()->create([...$onFile, 'round' => 2, 'status' => 'approved_with_changes', 'subject_version_type' => 'kv_generation', 'subject_version_id' => $craft->id]);
    $resizeRound = Approval::factory()->create([...$onFile, 'round' => 3, 'status' => 'not_relevant', 'subject_version_type' => 'kv_resize_export', 'subject_version_id' => '01jresizeresizeresizeresiz']);
    $motionRound = Approval::factory()->create([...$onFile, 'round' => 4, 'status' => 'pending', 'subject_version_type' => 'kv_motion_export', 'subject_version_id' => '01jmotionmotionmotionmotio']);

    clBackfillMigration()->up();
    clBackfillMigration()->up(); // idempotent

    $byRound = ApprovalItem::query()->get()->keyBy('approval_id');
    expect($byRound)->toHaveCount(6);

    $shape = fn (Approval $round): array => $byRound[$round->id]->only(['position', 'phase', 'version_type', 'version_id', 'label', 'snapshot', 'status']);

    expect($shape($deck))->toBe(['position' => 0, 'phase' => 'deck', 'version_type' => 'deck_version', 'version_id' => '812', 'label' => 'v1', 'snapshot' => null, 'status' => 'approved'])
        ->and($shape($plan))->toBe(['position' => 0, 'phase' => 'plan', 'version_type' => 'fingerprint', 'version_id' => str_repeat('a', 64), 'label' => 'v1', 'snapshot' => null, 'status' => 'changes_required'])
        ->and($shape($sketchRound)['phase'])->toBe('sketch')
        ->and($shape($craftRound))->toBe(['position' => 0, 'phase' => 'craft', 'version_type' => 'kv_generation', 'version_id' => $craft->id, 'label' => 'v2', 'snapshot' => null, 'status' => 'approved_with_changes'])
        ->and($shape($resizeRound)['phase'])->toBe('resize')
        ->and($shape($motionRound)['phase'])->toBe('motion')
        ->and($shape($motionRound)['status'])->toBe('pending');

    expect($byRound[$deck->id]->created_at->equalTo($deck->fresh()->created_at))->toBeTrue();
});

test('down() removes only what the backfill wrote, and up() restores it', function () {
    $legacy = Approval::factory()->create(['subject_version_id' => '900']);
    clBackfillMigration()->up();

    // A live deck round created after deploy: same shape except its label.
    $live = Approval::factory()->create(['subject_version_id' => '901']);
    ApprovalItem::factory()->create([
        'approval_id' => $live->id,
        'position' => 0,
        'phase' => 'deck',
        'version_type' => 'deck_version',
        'version_id' => '901',
        'label' => 'Deck · v1',
        'snapshot' => null,
        'created_at' => $live->created_at,
    ]);

    clBackfillMigration()->down();

    expect(ApprovalItem::query()->where('approval_id', $legacy->id)->exists())->toBeFalse()
        ->and(ApprovalItem::query()->where('approval_id', $live->id)->exists())->toBeTrue();

    clBackfillMigration()->up();

    expect(ApprovalItem::query()->where('approval_id', $legacy->id)->count())->toBe(1)
        ->and(ApprovalItem::query()->where('approval_id', $live->id)->count())->toBe(1);
});

test('items cascade with their round and a decision outlives its item', function () {
    $round = ClientLaneFixtures::roundWithItems(['101', '102']);
    $item = $round->items()->first();
    $decision = ApprovalDecision::factory()->create(['approval_id' => $round->id, 'approval_item_id' => $item->id]);

    $item->delete();
    expect($decision->fresh()->approval_item_id)->toBeNull();

    $round->delete();
    expect(ApprovalItem::query()->where('approval_id', $round->id)->count())->toBe(0);
});

test('itemVersionIds() lists the round items in order and falls back to subject_version_id', function () {
    $round = ClientLaneFixtures::roundWithItems(['103', '101', '102']);
    expect($round->itemVersionIds())->toBe(['103', '101', '102']);

    $bare = Approval::factory()->create(['subject_version_id' => '555']);
    expect($bare->itemVersionIds())->toBe(['555']);
});

test('an item status outside the five is refused by the database', function () {
    $round = ClientLaneFixtures::roundWithItems(['101']);

    expect(fn () => ApprovalItem::factory()->create(['approval_id' => $round->id, 'position' => 1, 'status' => 'deferred']))
        ->toThrow(QueryException::class);
});
```

- [ ] **Step 4: Run it — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalItemsMigrationTest.php --compact
```
Expected: FAIL — `Class "App\Models\ApprovalItem" not found` (and the migration file missing).

- [ ] **Step 5: Create the migrations**

`database/migrations/2026_09_30_120000_create_approval_items_table.php`:

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Client lane — multi-item approval rounds (spec 2026-09-30 §4.1).
 *
 * One row per item frozen into an approval round. `version_id` is the id the
 * decision page RENDERS (board chain tip, newest motion render, resize row),
 * `snapshot` the payload item as rendered at request time (null for
 * deck/plan and for backfilled rounds). Immutable except `status`.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('approval_items', function (Blueprint $table) {
            $table->ulid('id')->primary();
            $table->foreignUlid('approval_id')->constrained('approvals')->cascadeOnDelete();
            $table->unsignedSmallInteger('position');
            $table->string('phase', 16);
            $table->string('version_type', 32);
            $table->string('version_id', 64);
            $table->string('label', 160);
            $table->jsonb('snapshot')->nullable();
            $table->string('status', 32);
            $table->timestampTz('created_at')->useCurrent();

            $table->unique(['approval_id', 'position']);
            $table->index('version_id');
        });

        if (DB::getDriverName() === 'pgsql') {
            DB::statement(
                'ALTER TABLE approval_items ADD CONSTRAINT approval_items_status_check '
                ."CHECK (status IN ('pending', 'approved', 'approved_with_changes', 'changes_required', 'not_relevant'))"
            );
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('approval_items');
    }
};
```

`database/migrations/2026_09_30_120100_add_approval_item_id_to_approval_decisions.php`:

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Client lane — multi-item approval rounds (spec 2026-09-30 §4.2).
 *
 * NULL = a decision on the whole round (all Phase 1 decisions); set = a
 * decision on one item (Phase 2). Null on delete: a decision is audit
 * history and outlives its item.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('approval_decisions', function (Blueprint $table) {
            $table->foreignUlid('approval_item_id')->nullable()->constrained('approval_items')->nullOnDelete();
        });
    }

    public function down(): void
    {
        Schema::table('approval_decisions', function (Blueprint $table) {
            $table->dropConstrainedForeignId('approval_item_id');
        });
    }
};
```

`database/migrations/2026_09_30_120200_backfill_approval_items.php`:

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * Client lane — multi-item approval rounds (spec 2026-09-30 §8.3).
 *
 * One `approval_items` row per round that predates the table, copied from
 * `approvals.subject_version_*`: phase derived from the version type
 * (a `kv_generation` is `sketch` when its generation's mode says so, else
 * `craft`), label `v{round}`, no snapshot, status = the round's status.
 * Idempotent. Run with TELESCOPE_ENABLED=false.
 */
return new class extends Migration
{
    public function up(): void
    {
        DB::table('approvals')->chunkById(200, function ($rounds): void {
            foreach ($rounds as $round) {
                if (DB::table('approval_items')->where('approval_id', $round->id)->exists()) {
                    continue;
                }

                DB::table('approval_items')->insert([
                    'id' => strtolower((string) Str::ulid()),
                    'approval_id' => $round->id,
                    'position' => 0,
                    'phase' => $this->phaseFor($round),
                    'version_type' => $round->subject_version_type,
                    'version_id' => $round->subject_version_id,
                    'label' => 'v'.$round->round,
                    'snapshot' => null,
                    'status' => $round->status,
                    // Copied verbatim: down() recognises a backfilled row by it.
                    'created_at' => $round->created_at,
                ]);
            }
        });
    }

    /**
     * Only what this backfill could have written: no snapshot, position 0,
     * the round's own `created_at`, and the bare `v{round}` label. A live
     * deck/plan item created in the same second as its round is labelled
     * `Deck · v{n}` / `Plan · v{n}`, and a live KV item always has a
     * snapshot, so neither matches.
     */
    public function down(): void
    {
        DB::table('approval_items')
            ->whereNull('snapshot')
            ->where('position', 0)
            ->whereExists(function ($query): void {
                $query->selectRaw('1')
                    ->from('approvals')
                    ->whereColumn('approvals.id', 'approval_items.approval_id')
                    ->whereColumn('approvals.created_at', 'approval_items.created_at')
                    ->whereRaw("approval_items.label = 'v' || approvals.round::text");
            })
            ->delete();
    }

    private function phaseFor(object $round): string
    {
        return match ((string) $round->subject_version_type) {
            'deck_version' => 'deck',
            'fingerprint' => 'plan',
            'kv_resize_export' => 'resize',
            'kv_motion_export' => 'motion',
            'kv_generation' => DB::table('kv_generations')->where('id', $round->subject_version_id)->value('mode') === 'sketch'
                ? 'sketch'
                : 'craft',
            default => match ((string) $round->subject_type) {
                'deck' => 'deck',
                'campaign' => 'plan',
                default => 'craft',
            },
        };
    }
};
```

- [ ] **Step 6: Create the model and factory**

`app/Models/ApprovalItem.php`:

```php
<?php

declare(strict_types=1);

namespace App\Models;

// craftsman-ignore: PHP002 — Eloquent models are not final in this codebase.

use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Carbon;

/**
 * One item frozen into an approval round (client lane multi-item spec §4.1).
 *
 * `version_id` is the id the decision page renders; pins anchor to it
 * (`{phase}:{version_id}:{part}`). `snapshot` is the KV payload item as
 * rendered at request time — null for deck/plan and backfilled rounds.
 * Immutable except `status`; no `updated_at`.
 *
 * @property string $id
 * @property string $approval_id
 * @property int $position
 * @property string $phase
 * @property string $version_type
 * @property string $version_id
 * @property string $label
 * @property array<string, mixed>|null $snapshot
 * @property string $status
 * @property Carbon|null $created_at
 */
class ApprovalItem extends Model
{
    use HasFactory, HasUlids;

    public const UPDATED_AT = null;

    protected $table = 'approval_items';

    /** @var list<string> */
    public const PHASES = ['sketch', 'craft', 'resize', 'motion', 'deck', 'plan'];

    protected $fillable = [
        'approval_id',
        'position',
        'phase',
        'version_type',
        'version_id',
        'label',
        'snapshot',
        'status',
    ];

    protected function casts(): array
    {
        return [
            'position' => 'integer',
            'snapshot' => 'array',
            'created_at' => 'datetime',
        ];
    }

    public function approval(): BelongsTo
    {
        return $this->belongsTo(Approval::class);
    }

    public function isPending(): bool
    {
        return $this->status === Approval::STATUS_PENDING;
    }

    /**
     * The still the agency list shows: the snapshot's `image_url`. Null for
     * motion (a clip has no still), deck/plan (no snapshot), and a
     * layer-composed resize tile (its `image_url` is null by design).
     */
    public function thumbnailUrl(): ?string
    {
        $snapshot = $this->snapshot;
        if (! is_array($snapshot) || ($snapshot['kind'] ?? null) === 'motion') {
            return null;
        }

        $url = $snapshot['image_url'] ?? null;

        return is_string($url) && $url !== '' ? $url : null;
    }
}
```

`database/factories/ApprovalItemFactory.php`:

```php
<?php

namespace Database\Factories;

use App\Models\Approval;
use App\Models\ApprovalItem;
use Illuminate\Database\Eloquent\Factories\Factory;

/**
 * @extends Factory<ApprovalItem>
 */
class ApprovalItemFactory extends Factory
{
    protected $model = ApprovalItem::class;

    public function definition(): array
    {
        return [
            'approval_id' => Approval::factory(),
            'position' => 0,
            'phase' => 'deck',
            'version_type' => Approval::VERSION_DECK,
            'version_id' => (string) $this->faker->numberBetween(1, 999),
            'label' => 'v1',
            'snapshot' => null,
            'status' => Approval::STATUS_PENDING,
        ];
    }
}
```

- [ ] **Step 7: Extend `Approval` and `ApprovalDecision`**

In `app/Models/Approval.php`, add to the class docblock after line 50 (`resolved_by_decision_id`):

```php
 * @property-read \Illuminate\Database\Eloquent\Collection<int, ApprovalItem> $items
```

After `decisions()` (lines 134-137) add:

```php
    /** The frozen items, in display order (multi-item spec §4.1). */
    public function items(): HasMany
    {
        return $this->hasMany(ApprovalItem::class)->orderBy('position');
    }

    /**
     * Every version id this round froze, in display order — what a pin's
     * `{phase}:{version}:{part}` version segment must be one of. A round
     * with no item rows (created before `approval_items` existed and not
     * yet backfilled, or seeded by a factory) falls back to its own
     * `subject_version_id`, so a membership check never runs against an
     * empty set (an empty SQL `IN ()` is a syntax error).
     *
     * @return non-empty-list<string>
     */
    public function itemVersionIds(): array
    {
        $ids = $this->relationLoaded('items')
            ? $this->items->pluck('version_id')->all()
            : $this->items()->pluck('version_id')->all();

        $ids = array_values(array_unique(array_map('strval', $ids)));

        return $ids !== [] ? $ids : [(string) $this->subject_version_id];
    }
```

In `app/Models/ApprovalDecision.php`: add `* @property string|null $approval_item_id` after line 24 (`approval_id`); add `'approval_item_id',` to `$fillable` after `'approval_id',` (line 70); after `approval()` (lines 96-99) add:

```php
    /** The item this decision is about; null = the whole round (Phase 1). */
    public function item(): BelongsTo
    {
        return $this->belongsTo(ApprovalItem::class, 'approval_item_id');
    }
```

- [ ] **Step 8: Run — expect PASS**

Same command as Step 4. Expected: 5 passed.

- [ ] **Step 9: Mutation check**

1. In the backfill `phaseFor()`, change `'kv_generation' => … === 'sketch' ? 'sketch' : 'craft'` to always `'craft'` → run → *"the backfill writes one item per round…"* must FAIL on the sketch assertion. Restore.
2. In `down()`, delete the `whereRaw("approval_items.label = …")` line → *"down() removes only what the backfill wrote…"* must FAIL (the live item is deleted). Restore.
3. In `itemVersionIds()`, return `$ids` without the fallback → *"itemVersionIds()…"* must FAIL. Restore.
4. In migration 2 replace `->nullOnDelete()` with nothing, then `migrate:fresh` happens automatically on the next run → *"items cascade…"* must FAIL with a FK violation. Restore.

Re-run Step 4's command: all pass.

- [ ] **Step 10: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && for f in app/Models/ApprovalItem.php app/Models/Approval.php app/Models/ApprovalDecision.php database/factories/ApprovalItemFactory.php database/migrations/2026_09_30_120000_create_approval_items_table.php database/migrations/2026_09_30_120100_add_approval_item_id_to_approval_decisions.php database/migrations/2026_09_30_120200_backfill_approval_items.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/ApprovalItemsMigrationTest.php; do php -l "$f"; done && vendor/bin/pint --test app/Models/ApprovalItem.php app/Models/Approval.php app/Models/ApprovalDecision.php database/factories/ApprovalItemFactory.php database/migrations/2026_09_30_1201*.php database/migrations/2026_09_30_120000_create_approval_items_table.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/ApprovalItemsMigrationTest.php
```

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && git add app/Models/ApprovalItem.php app/Models/Approval.php app/Models/ApprovalDecision.php database/factories/ApprovalItemFactory.php database/migrations/2026_09_30_120000_create_approval_items_table.php database/migrations/2026_09_30_120100_add_approval_item_id_to_approval_decisions.php database/migrations/2026_09_30_120200_backfill_approval_items.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/ApprovalItemsMigrationTest.php && git commit -m "feat(api): approval_items table, decision item FK and backfill for multi-item rounds"
```

---

### Task 2: Extract `KvSharePayloadService::itemsFor()` (view links unchanged)

**Files:**
- Modify: `app/Services/Studio/KvSharePayloadService.php` (`build()` 46-91)
- Test: `tests/Feature/Approval/KvSharePayloadItemsForTest.php`

**Interfaces:**
- Consumes: `KvReadyToShareService::rawMarkedGenerationIds/ResizeIds/MotionIds`, private `resolveBoards/resolveResizeTiles/resolveMotionClips`, `Tests\Support\ClientLaneFixtures` (Task 1).
- Produces:
  - `KvSharePayloadService::itemsFor(StudioFile $file, array $phases): array` — `array<string, list<array<string, mixed>>>`, keys = requested phases in canonical `PHASES` order (each present, possibly `[]`), values = payload items exactly as `build()` renders them.
  - `KvSharePayloadService::resolvePhase(StudioFile $file, string $phase, array $rawIds): array` — payload items for raw marked ids (board chain → tip, motion → newest render, resize → usable rows).

- [ ] **Step 1: Write the characterisation test + the new-API tests**

Create `tests/Feature/Approval/KvSharePayloadItemsForTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Services\Sharing\ShareLinkService;
use App\Services\Studio\KvSharePayloadService;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];

    $this->board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $this->tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $this->board);
    $this->clip = ClientLaneFixtures::motionExport($this->file, $this->user, $this->board);
    ClientLaneFixtures::markReady('kv_generation', $this->board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $this->tile->id, $this->user);
    ClientLaneFixtures::markReady('kv_motion_export', $this->clip->id, $this->user);

    $this->service = app(KvSharePayloadService::class);

    // Derived from the resolvers in KvSharePayloadService (resolveBoards
    // 102-119, resolveMotionClips 186-201, resolveResizeTiles 278-305). If the
    // characterisation test fails on the UNCHANGED service, fix these values
    // from the actual output — never the service.
    $this->expected = [
        'craft' => [[
            'id' => $this->board->id,
            'kind' => 'board',
            'name' => 'Hero board',
            'image_url' => 'https://cdn.test/board-1.png',
            'aspect_ratio' => '16:9',
            'is_master' => true,
            'overlays' => [],
        ]],
        'resize' => [[
            'id' => $this->tile->id,
            'kind' => 'resize',
            'platform_id' => 'instagram-story',
            'platform_label' => $this->tile->displayLabel(),
            'width' => 1080,
            'height' => 1920,
            'image_url' => 'https://cdn.test/tile-1.png',
            'overlays' => null,
            'source_overlays' => [],
            'source_width' => 1672,
            'source_height' => 941,
        ]],
        'motion' => [[
            'id' => $this->clip->id,
            'kind' => 'motion',
            'video_url' => 'https://cdn.test/motion-1.mp4',
            'ratio' => 'instagram-story',
            'width' => 1080,
            'height' => 1920,
            'duration_ms' => 8000,
        ]],
    ];
});

test('build() output is unchanged by the extraction (characterisation: green before AND after)', function () {
    $link = app(ShareLinkService::class)->create(
        $this->file,
        $this->user,
        ['motion', 'sketch', 'resize', 'craft'],
        workspaceId: (string) $this->file->workspace_id,
    );

    expect($this->service->build($this->file, $link, 'garuda'))->toBe([
        'name' => 'Ramadan hero KV',
        'brand_slug' => 'garuda',
        'phases' => [
            ['phase' => 'sketch', 'items' => []],
            ['phase' => 'craft', 'items' => $this->expected['craft']],
            ['phase' => 'resize', 'items' => $this->expected['resize']],
            ['phase' => 'motion', 'items' => $this->expected['motion']],
        ],
    ]);
});

test('itemsFor() resolves only the requested phases, canonical order, empty phases kept', function () {
    $items = $this->service->itemsFor($this->file, ['motion', 'sketch', 'craft']);

    expect(array_keys($items))->toBe(['sketch', 'craft', 'motion'])
        ->and($items['sketch'])->toBe([])
        ->and($items['craft'])->toBe($this->expected['craft'])
        ->and($items['motion'])->toBe($this->expected['motion']);
});

test('resolvePhase() maps a raw marked id to what the page renders', function () {
    $tip = ClientLaneFixtures::iterate($this->file, $this->user, $this->board, 'https://cdn.test/board-2.png');
    $newest = ClientLaneFixtures::reExport($this->clip, 'https://cdn.test/motion-2.mp4');

    $boards = $this->service->resolvePhase($this->file, 'craft', [$this->board->id]);
    $clips = $this->service->resolvePhase($this->file, 'motion', [$this->clip->id]);

    expect(array_column($boards, 'id'))->toBe([$tip->id])
        ->and($boards[0]['image_url'])->toBe('https://cdn.test/board-2.png')
        ->and(array_column($clips, 'id'))->toBe([$newest->id]);
});
```

- [ ] **Step 2: Run — expect the characterisation test to PASS and the other two to FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/KvSharePayloadItemsForTest.php --compact
```
Expected: `build() output is unchanged…` PASSES on the untouched service (if it fails, correct `$this->expected` per the comment, re-run until green — this pins today's behaviour). The other two FAIL with `Call to undefined method App\Services\Studio\KvSharePayloadService::itemsFor()` / `resolvePhase()`.

- [ ] **Step 3: Extract**

In `app/Services/Studio/KvSharePayloadService.php` replace the body of `build()` (lines 55-91, from `public function build(` through its closing brace) with:

```php
    public function build(StudioFile $file, ShareLink $link, string $brandSlug = ''): array
    {
        $phases = [];

        foreach ($this->itemsFor($file, $link->phaseList()) as $phase => $items) {
            $phases[] = ['phase' => $phase, 'items' => $items];
        }

        return [
            'name' => $file->name,
            'brand_slug' => $brandSlug,
            'phases' => $phases,
        ];
    }

    /**
     * The ready items of each requested phase, exactly as a guest page
     * renders them — the one resolver behind both the live view-link payload
     * ({@see build()}) and an approval round's freeze
     * (ApprovalService::request(), client lane multi-item spec §5.1).
     *
     * Iterates the canonical order rather than `$phases` so Sketch → Craft →
     * Resize → Motion holds regardless of how the phases were ticked. Every
     * requested phase is present, even with zero items (see PHASE SHAPE on
     * the class).
     *
     * @param  array<int, string>  $phases
     * @return array<string, array<int, array<string, mixed>>>
     */
    public function itemsFor(StudioFile $file, array $phases): array
    {
        $out = [];

        foreach (self::PHASES as $phase) {
            if (! in_array($phase, $phases, true)) {
                continue;
            }

            // match over a ternary: sketch/craft share one resolver, but resize
            // and motion each have their own, so a two-way branch would send
            // motion ids to the wrong table.
            $ids = match ($phase) {
                'resize' => $this->readyToShare->rawMarkedResizeIds($file),
                'motion' => $this->readyToShare->rawMarkedMotionIds($file),
                default => $this->readyToShare->rawMarkedGenerationIds($file, $phase),
            };

            $out[$phase] = $this->resolvePhase($file, $phase, $ids);
        }

        return $out;
    }

    /**
     * Payload items for raw marked ids of one phase: a board id resolves to
     * its chain tip, a motion export to the newest render of its (project,
     * ratio), a resize id to its row when usable. Public for the legacy
     * one-item approval path (`kv_ready_item_id`), which resolves a single
     * marked id rather than a whole phase.
     *
     * @param  array<int, string>  $rawIds
     * @return array<int, array<string, mixed>>
     */
    public function resolvePhase(StudioFile $file, string $phase, array $rawIds): array
    {
        return match ($phase) {
            'resize' => $this->resolveResizeTiles($file, $rawIds),
            'motion' => $this->resolveMotionClips($file, $rawIds),
            default => $this->resolveBoards($file, $rawIds),
        };
    }
```

Keep the existing `@return` docblock above `build()` (lines 46-54) as is.

- [ ] **Step 4: Run — expect PASS (3 passed), then the existing KV share suite as regression**

Same command as Step 2. Then:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/KvShareLinkTest.php --compact
```
Expected: same pass count as on develop (run it once on develop first if unsure; a pre-existing failure there is not yours — note it in the track file).

- [ ] **Step 5: Mutation check**

1. In `itemsFor()`, iterate `foreach ($phases as $phase)` instead of `self::PHASES` → run → both `build() output…` and `itemsFor() resolves…` must FAIL (order). Restore.
2. In `itemsFor()`, add `if ($ids === []) { continue; }` before `$out[$phase] = …` → `build()…` must FAIL (sketch phase disappears). Restore.

- [ ] **Step 6: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && php -l app/Services/Studio/KvSharePayloadService.php && php -l tests/Feature/Approval/KvSharePayloadItemsForTest.php && vendor/bin/pint --test app/Services/Studio/KvSharePayloadService.php tests/Feature/Approval/KvSharePayloadItemsForTest.php && git add app/Services/Studio/KvSharePayloadService.php tests/Feature/Approval/KvSharePayloadItemsForTest.php && git commit -m "refactor(api): expose per-phase KV share payload resolution as itemsFor/resolvePhase"
```

---

### Task 3: `ApprovalService::request()` freezes N items

**Files:**
- Create: `app/Services/Approval/FrozenItem.php`
- Create: `app/Exceptions/Approval/NothingReadyException.php`
- Create: `app/Exceptions/Approval/TooManyItemsException.php`
- Modify: `app/Services/Approval/ApprovalService.php` (imports 9-37, const 64-65, constructor 67-72, `request()` 107-261, `freezeVersion()` 623-644, `resolveKvVersion()` 646-690, `reuseOrMintCommentLink()` 692-734)
- Modify: `tests/Support/ClientLaneFixtures.php` (add `requestKv`)
- Test: `tests/Feature/Approval/ApprovalRequestItemsTest.php`

**Interfaces:**
- Consumes: `KvSharePayloadService::itemsFor()`, `::resolvePhase()`, `::PHASES` (Task 2); `ApprovalItem`, `Approval::items()` (Task 1).
- Produces:
  - `ApprovalService::MAX_ITEMS = 50`.
  - `ApprovalService::request(ApprovalSubject $subject, User $requester, array $approverEmails = [], ?string $message = null, ?string $kvReadyItemId = null, bool $send = true, bool $notify = true, bool $mintLink = true, ?array $kvPhases = null): array` — same return shape; `approval->items` relation is set.
  - `App\Services\Approval\FrozenItem` (final readonly): `__construct(string $phase, string $versionType, string $versionId, string $label, ?array $snapshot)`, `static fromKvPayload(string $phase, array $item): self`, `toRow(int $position): array`, `static clip(string $label): string`, `LABEL_MAX = 160`.
  - `NothingReadyException` (`CODE = 'nothing_ready'`), `TooManyItemsException` (`CODE = 'too_many_items'`, `public readonly int $max`).
  - private `ApprovalService::setItemStatuses(Approval $approval, string $status): void` (used again in Task 4).
  - `ClientLaneFixtures::requestKv(StudioFile $file, User $user, array $phases): array`.

- [ ] **Step 1: Add the fixture helper**

In `tests/Support/ClientLaneFixtures.php` add imports `use App\Services\Approval\ApprovalService;` and `use App\Services\Approval\ApprovalSubject;`, and this method:

```php
    /**
     * Open a KV round over the given phases (no mail, link minted/reused).
     *
     * @param  list<string>  $phases
     * @return array{approval: Approval, share_link: \App\Models\ShareLink|null, approvers: array<int, mixed>}
     */
    public static function requestKv(StudioFile $file, User $user, array $phases): array
    {
        return app(ApprovalService::class)->request(
            ApprovalSubject::from($file),
            $user,
            notify: false,
            kvPhases: $phases,
        );
    }
```

- [ ] **Step 2: Write the failing test**

Create `tests/Feature/Approval/ApprovalRequestItemsTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Enums\KvResizeExportStatus;
use App\Exceptions\Approval\NothingReadyException;
use App\Exceptions\Approval\TooManyItemsException;
use App\Models\Approval;
use App\Models\Deck\Deck;
use App\Models\Deck\DeckVersion;
use App\Models\KvResizeExport;
use App\Models\ShareLink;
use App\Services\Approval\ApprovalService;
use App\Services\Approval\ApprovalSubject;
use App\Services\Deck\DeckCollabWriter;
use App\Services\Sharing\ShareLinkService;
use App\Services\Studio\KvReadyToShareService;
use App\Services\Studio\KvSharePayloadService;
use Illuminate\Validation\ValidationException;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];
});

test('a round freezes every ready item of the selected phases, as rendered', function () {
    $board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $story = ClientLaneFixtures::resizeTile($this->file, $this->user, $board, 'instagram-story', 1080, 1920, 'https://cdn.test/tile-story.png');
    $feed = ClientLaneFixtures::resizeTile($this->file, $this->user, $board, 'instagram-post', 1080, 1080, 'https://cdn.test/tile-feed.png');
    $clip = ClientLaneFixtures::motionExport($this->file, $this->user, $board);
    ClientLaneFixtures::markReady('kv_generation', $board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $story->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $feed->id, $this->user);
    ClientLaneFixtures::markReady('kv_motion_export', $clip->id, $this->user);

    $rendered = app(KvSharePayloadService::class)->itemsFor($this->file, ['craft', 'resize', 'motion']);

    $approval = ClientLaneFixtures::requestKv($this->file, $this->user, ['motion', 'resize', 'craft'])['approval'];
    $items = $approval->items()->get();

    expect($items->pluck('position')->all())->toBe([0, 1, 2, 3])
        ->and($items->pluck('phase')->all())->toBe(['craft', 'resize', 'resize', 'motion'])
        ->and($items->pluck('version_type')->all())->toBe(['kv_generation', 'kv_resize_export', 'kv_resize_export', 'kv_motion_export'])
        ->and($items->pluck('status')->unique()->values()->all())->toBe(['pending']);

    expect($items[0]->version_id)->toBe($board->id)
        ->and($items[0]->label)->toBe('Craft · Hero board')
        ->and($items[0]->snapshot)->toEqual($rendered['craft'][0]);

    // Intra-phase order follows the ready-to-share pluck (no ORDER BY): assert as a set.
    expect($items->where('phase', 'resize')->pluck('version_id')->all())->toEqualCanonicalizing([$story->id, $feed->id]);
    expect($items->firstWhere('version_id', $story->id)->label)->toBe('Resize · '.$story->displayLabel().' · 1080×1920');

    expect($items[3]->version_id)->toBe($clip->id)
        ->and($items[3]->label)->toBe('Motion · instagram-story · 1080×1920')
        ->and($items[3]->snapshot)->toEqual($rendered['motion'][0]);

    expect($approval->subject_version_type)->toBe('kv_generation')
        ->and($approval->subject_version_id)->toBe($board->id)
        ->and($approval->relationLoaded('items'))->toBeTrue();
});

test('the frozen id is the id the page renders: board tip, newest motion render, resize row', function () {
    $old = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board', 'https://cdn.test/board-v1.png');
    ClientLaneFixtures::markReady('kv_generation', $old->id, $this->user);
    $tip = ClientLaneFixtures::iterate($this->file, $this->user, $old, 'https://cdn.test/board-v2.png');

    $firstRender = ClientLaneFixtures::motionExport($this->file, $this->user, $tip);
    ClientLaneFixtures::markReady('kv_motion_export', $firstRender->id, $this->user);
    $newest = ClientLaneFixtures::reExport($firstRender, 'https://cdn.test/motion-2.mp4');

    $tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $tip);
    ClientLaneFixtures::markReady('kv_resize_export', $tile->id, $this->user);
    $tile->forceFill(['image_url' => 'https://cdn.test/tile-regenerated.png'])->save();

    $items = ClientLaneFixtures::requestKv($this->file, $this->user, ['craft', 'resize', 'motion'])['approval']
        ->items()->get()->keyBy('phase');

    expect($items['craft']->version_id)->toBe($tip->id)
        ->and($items['craft']->snapshot['image_url'])->toBe('https://cdn.test/board-v2.png')
        ->and($items['motion']->version_id)->toBe($newest->id)
        ->and($items['motion']->snapshot['video_url'])->toBe('https://cdn.test/motion-2.mp4')
        ->and($items['resize']->version_id)->toBe($tile->id)
        ->and($items['resize']->snapshot['image_url'])->toBe('https://cdn.test/tile-regenerated.png');
});

test('a selection with nothing ready is refused before anything is written', function () {
    $board = ClientLaneFixtures::board($this->file, $this->user);
    ClientLaneFixtures::markReady('kv_generation', $board->id, $this->user);

    expect(fn () => ClientLaneFixtures::requestKv($this->file, $this->user, ['sketch', 'motion']))
        ->toThrow(NothingReadyException::class);

    expect(Approval::query()->count())->toBe(0)
        ->and(ShareLink::query()->where('role', ShareLink::ROLE_COMMENT)->count())->toBe(0);
});

test('fifty items is accepted, fifty-one is refused with the cap', function () {
    $board = ClientLaneFixtures::board($this->file, $this->user);
    $tiles = KvResizeExport::factory()->count(50)->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $board->id,
        'created_by' => $this->user->id,
        'status' => KvResizeExportStatus::Done,
        'image_url' => 'https://cdn.test/tile.png',
    ]);
    app(KvReadyToShareService::class)->markAll('kv_resize_export', $tiles->pluck('id')->all(), $this->user);

    expect(ClientLaneFixtures::requestKv($this->file, $this->user, ['resize'])['approval']->items()->count())->toBe(50);

    $extra = ClientLaneFixtures::resizeTile($this->file, $this->user, $board);
    ClientLaneFixtures::markReady('kv_resize_export', $extra->id, $this->user);

    expect(fn () => ClientLaneFixtures::requestKv($this->file, $this->user, ['resize']))
        ->toThrow(function (TooManyItemsException $e) {
            expect($e->max)->toBe(50);
        });

    expect(Approval::query()->count())->toBe(1);
});

test('kv_ready_item_id still works and freezes a one-item round of what the page renders', function () {
    $old = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $mark = ClientLaneFixtures::markReady('kv_generation', $old->id, $this->user);
    $tip = ClientLaneFixtures::iterate($this->file, $this->user, $old, 'https://cdn.test/board-v2.png');

    $service = app(ApprovalService::class);
    $byMarkable = $service->request(ApprovalSubject::from($this->file), $this->user, kvReadyItemId: $old->id, notify: false)['approval'];
    $items = $byMarkable->items()->get();

    expect($items)->toHaveCount(1)
        ->and($items[0]->phase)->toBe('craft')
        ->and($items[0]->version_id)->toBe($tip->id)
        ->and($byMarkable->subject_version_id)->toBe($tip->id);

    // The share_ready_items ROW id is accepted too.
    $byRow = $service->request(ApprovalSubject::from($this->file), $this->user, kvReadyItemId: $mark->id, notify: false)['approval'];
    expect($byRow->items()->value('version_id'))->toBe($tip->id);
});

test('kv_ready_item_id naming an item that does not render is refused', function () {
    $board = ClientLaneFixtures::board($this->file, $this->user);
    $rendering = KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $board->id,
        'created_by' => $this->user->id,
    ]); // factory default status = pending: still generating
    ClientLaneFixtures::markReady('kv_resize_export', $rendering->id, $this->user);

    expect(fn () => app(ApprovalService::class)->request(ApprovalSubject::from($this->file), $this->user, kvReadyItemId: $rendering->id, notify: false))
        ->toThrow(ValidationException::class);

    expect(Approval::query()->count())->toBe(0);
});

test('a plan round holds exactly one plan item', function () {
    $fx = ClientLaneFixtures::plan();

    $approval = app(ApprovalService::class)->request(ApprovalSubject::from($fx['plan']), $fx['user'], notify: false, mintLink: false)['approval'];

    expect($approval->items()->sole()->only(['position', 'phase', 'version_type', 'version_id', 'label', 'snapshot', 'status']))->toBe([
        'position' => 0,
        'phase' => 'plan',
        'version_type' => 'fingerprint',
        'version_id' => ApprovalService::fingerprintPlan($fx['plan']),
        'label' => 'Plan · v1',
        'snapshot' => null,
        'status' => 'pending',
    ]);
});

test('a deck round holds exactly one deck item pointing at the frozen deck version', function () {
    // Deck first, mock second: anything that touches DeckCollabWriter while
    // the deck is created must hit the real service, not a strict mock.
    $deck = Deck::factory()->create([
        'workspace_id' => $this->kv['workspace']->id,
        'brand_id' => $this->kv['brand']->id,
        'created_by' => $this->user->id,
    ]);
    // No hocuspocus in tests: hand request() a live document.
    $this->mock(DeckCollabWriter::class, function ($mock) {
        $mock->shouldReceive('liveDocumentResolved')->andReturn([
            'document' => ['slides' => []],
            'source' => 'snapshot',
            'pending_count' => 0,
        ]);
    });

    $approval = app(ApprovalService::class)->request(ApprovalSubject::from($deck), $this->user, notify: false)['approval'];
    $item = $approval->items()->sole();

    expect($item->phase)->toBe('deck')
        ->and($item->version_type)->toBe('deck_version')
        ->and($item->version_id)->toBe((string) DeckVersion::query()->where('deck_id', $deck->id)->value('id'))
        ->and($item->label)->toBe('Deck · v1')
        ->and($item->snapshot)->toBeNull();
});

test("a reused comment link gains the round's phases without losing its own", function () {
    $board = ClientLaneFixtures::board($this->file, $this->user);
    $tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $board);
    ClientLaneFixtures::markReady('kv_generation', $board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $tile->id, $this->user);
    $link = app(ShareLinkService::class)->create(
        $this->file,
        $this->user,
        ['sketch'],
        role: ShareLink::ROLE_COMMENT,
        workspaceId: (string) $this->file->workspace_id,
    );

    $result = ClientLaneFixtures::requestKv($this->file, $this->user, ['craft', 'resize']);

    expect($result['share_link']->id)->toBe($link->id)
        ->and($link->fresh()->phaseList())->toBe(['sketch', 'craft', 'resize']);
});

test('a new round supersedes the open one and retires its items', function () {
    $board = ClientLaneFixtures::board($this->file, $this->user);
    ClientLaneFixtures::markReady('kv_generation', $board->id, $this->user);

    $first = ClientLaneFixtures::requestKv($this->file, $this->user, ['craft'])['approval'];
    $second = ClientLaneFixtures::requestKv($this->file, $this->user, ['craft'])['approval'];

    expect($first->fresh()->status)->toBe('not_relevant')
        ->and($first->items()->pluck('status')->all())->toBe(['not_relevant'])
        ->and($second->round)->toBe(2)
        ->and($second->items()->pluck('status')->all())->toBe(['pending'])
        ->and($second->share_link_id)->toBe($first->share_link_id);
});

// Review Focus 1
test('labels never overflow the column, whatever the board or tile is called', function () {
    $board = ClientLaneFixtures::board($this->file, $this->user, 'craft', str_repeat('Kampanye Ramadan ', 20)); // 340 chars
    $tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $board, name: str_repeat('ポスター', 30)); // 120 multibyte chars (column max)
    ClientLaneFixtures::markReady('kv_generation', $board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $tile->id, $this->user);

    $items = ClientLaneFixtures::requestKv($this->file, $this->user, ['craft', 'resize'])['approval']->items()->get();

    foreach ($items as $item) {
        expect(mb_strlen($item->label))->toBeLessThanOrEqual(160);
    }
    expect($items[0]->label)->toStartWith('Craft · Kampanye Ramadan')->toEndWith('...')
        ->and($items[1]->label)->toStartWith('Resize · ポスター');
});

// Review Focus 2
test('a layer-composed resize tile (no image) freezes with a null image', function () {
    $board = ClientLaneFixtures::board($this->file, $this->user);
    $tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $board, imageUrl: null);
    ClientLaneFixtures::markReady('kv_resize_export', $tile->id, $this->user);

    $item = ClientLaneFixtures::requestKv($this->file, $this->user, ['resize'])['approval']->items()->sole();

    expect($item->snapshot)->toHaveKey('image_url')
        ->and($item->snapshot['image_url'])->toBeNull()
        ->and($item->version_id)->toBe($tile->id);
});
```

- [ ] **Step 3: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalRequestItemsTest.php --compact
```
Expected: FAIL — `Unknown named parameter $kvPhases` (and class-not-found for the two exceptions).

- [ ] **Step 4: Create the value object and exceptions**

`app/Services/Approval/FrozenItem.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval;

use App\Models\Approval;
use Illuminate\Support\Str;

/**
 * One item about to be frozen into an approval round (client lane
 * multi-item spec §4.1): which phase it belongs to, the version it pins,
 * the display label and — for KV — the payload item exactly as the
 * decision page renders it.
 */
final readonly class FrozenItem
{
    public const LABEL_MAX = 160;

    /**
     * @param  array<string, mixed>|null  $snapshot
     */
    public function __construct(
        public string $phase,
        public string $versionType,
        public string $versionId,
        public string $label,
        public ?array $snapshot,
    ) {}

    /**
     * Map one `KvSharePayloadService` item. The frozen `versionId` is the
     * payload item's own `id` — the board tip, the newest motion render, the
     * resize row — so it always matches what the page renders.
     *
     * @param  array<string, mixed>  $item
     */
    public static function fromKvPayload(string $phase, array $item): self
    {
        $id = (string) $item['id'];

        return match ($item['kind'] ?? null) {
            'resize' => new self(
                'resize',
                Approval::VERSION_KV_RESIZE_EXPORT,
                $id,
                self::clip(sprintf('Resize · %s · %d×%d', (string) ($item['platform_label'] ?? ''), (int) ($item['width'] ?? 0), (int) ($item['height'] ?? 0))),
                $item,
            ),
            'motion' => new self(
                'motion',
                Approval::VERSION_KV_MOTION_EXPORT,
                $id,
                self::clip(sprintf('Motion · %s · %d×%d', (string) ($item['ratio'] ?? ''), (int) ($item['width'] ?? 0), (int) ($item['height'] ?? 0))),
                $item,
            ),
            default => new self(
                $phase,
                Approval::VERSION_KV_GENERATION,
                $id,
                self::clip(ucfirst($phase).' · '.(trim((string) ($item['name'] ?? '')) !== '' ? (string) $item['name'] : 'Untitled board')),
                $item,
            ),
        };
    }

    /** @return array<string, mixed> an `approval_items` row minus `approval_id` */
    public function toRow(int $position): array
    {
        return [
            'position' => $position,
            'phase' => $this->phase,
            'version_type' => $this->versionType,
            'version_id' => $this->versionId,
            'label' => $this->label,
            'snapshot' => $this->snapshot,
            'status' => Approval::STATUS_PENDING,
        ];
    }

    /** ≤ 160 chars (`approval_items.label`); board names are unbounded canvas text. */
    public static function clip(string $label): string
    {
        return Str::limit($label, self::LABEL_MAX - 3);
    }
}
```

`app/Exceptions/Approval/NothingReadyException.php`:

```php
<?php

declare(strict_types=1);

namespace App\Exceptions\Approval;

use RuntimeException;

/**
 * The stages picked for a KV round hold no item that is marked ready to
 * share and renders — `422 { code: "nothing_ready" }` (multi-item spec §5.1).
 */
final class NothingReadyException extends RuntimeException
{
    public const CODE = 'nothing_ready';

    public function __construct()
    {
        parent::__construct('Nothing in the selected stages is marked ready to share yet.');
    }
}
```

`app/Exceptions/Approval/TooManyItemsException.php`:

```php
<?php

declare(strict_types=1);

namespace App\Exceptions\Approval;

use RuntimeException;

/**
 * A KV round would freeze more than the cap — `422 { code: "too_many_items",
 * max }` (multi-item spec §3, §5.1).
 */
final class TooManyItemsException extends RuntimeException
{
    public const CODE = 'too_many_items';

    public function __construct(public readonly int $max)
    {
        parent::__construct("A round can hold at most {$max} items. Pick fewer stages or unmark some items.");
    }
}
```

- [ ] **Step 5: Change `ApprovalService`**

5a. Imports (lines 9-37) — add, keeping alphabetical order:

```php
use App\Exceptions\Approval\NothingReadyException;
use App\Exceptions\Approval\TooManyItemsException;
use App\Models\ApprovalItem;
use App\Services\Studio\KvSharePayloadService;
```

5b. After `public const MAX_DEFERRAL_DAYS = 14;` (line 65) add:

```php

    /** Most items one round may freeze (multi-item spec §3). */
    public const MAX_ITEMS = 50;
```

5c. Constructor (lines 67-72) becomes:

```php
    public function __construct(
        private readonly ShareLinkService $shareLinks,
        private readonly ClientLaneService $lanes,
        private readonly DeckCollabWriter $collab,
        private readonly ApprovalNotifier $notifier,
        private readonly KvSharePayloadService $kvPayload,
    ) {}
```

5d. In the `request()` docblock (lines 107-130) add after the `$mintLink` param lines:

```php
     * @param  list<string>|null  $kvPhases  KV only: freeze every ready item of
     *                                       these phases (multi-item spec §5.1);
     *                                       `$kvReadyItemId` is the legacy
     *                                       one-item form
```
and add `     * @throws NothingReadyException` and `     * @throws TooManyItemsException` to the `@throws` list.

5e. Signature (lines 131-140): add a last parameter `?array $kvPhases = null,` after `bool $mintLink = true,`.

5f. After the deck prefetch (ends line 158 `: null;`) insert:

```php

        // KV items are resolved OUTSIDE the transaction too (multi-item spec
        // §5.1 step 1): the payload resolver walks board chains, resize rows
        // and motion renders, none of which needs the round lock, and a
        // `nothing_ready` / `too_many_items` refusal writes nothing.
        $kvItems = $subject->model instanceof StudioFile
            ? $this->freezeKvItems($subject->model, $kvPhases, $kvReadyItemId)
            : null;
```

5g. In the `DB::transaction(function () use (…)` list (line 162) replace `$kvReadyItemId` with `$kvItems`.

5h. The supersede block (lines 180-185) becomes:

```php
                if ($previous !== null && $previous->isPending()) {
                    $previous->forceFill([
                        'status' => Approval::STATUS_NOT_RELEVANT,
                        'resolved_at' => now(),
                    ])->save();
                    $this->setItemStatuses($previous, Approval::STATUS_NOT_RELEVANT);
                }
```

5i. Replace lines 187-189 (`[$versionType, $versionId, $kvPhase] = …` and `$link = …`) with:

```php
                $items = $this->freezeItems($subject, $round, $requester, $kvItems, $liveDeckDocument);
                $first = $items[0];

                $link = $mintLink ? $this->reuseOrMintCommentLink($subject, $requester, self::kvPhasesOf($items)) : null;
```

5j. In `Approval::create([…])` replace lines 215-216 with:

```php
                    // Kept for compatibility (spec §4.4): the FIRST item.
                    'subject_version_type' => $first->versionType,
                    'subject_version_id' => $first->versionId,
```

5k. After the `Approval::create([…]);` statement (ends line 221) insert:

```php

                $approval->setRelation('items', $approval->items()->createMany(array_map(
                    static fn (FrozenItem $item, int $position): array => $item->toRow($position),
                    $items,
                    array_keys($items),
                )));
```

5l. Replace `freezeVersion()` and `resolveKvVersion()` (lines 623-690, docblocks included) with:

```php
    /**
     * The items this round freezes: a deck or plan is always one item; KV
     * items were resolved before the lock by {@see freezeKvItems()}.
     *
     * @param  list<FrozenItem>|null  $kvItems
     * @param  array<string, mixed>|null  $liveDeckDocument  pre-fetched deck document (M-1), ignored for non-deck subjects
     * @return non-empty-list<FrozenItem>
     */
    private function freezeItems(ApprovalSubject $subject, int $round, User $requester, ?array $kvItems, ?array $liveDeckDocument = null): array
    {
        $model = $subject->model;

        if ($model instanceof Deck) {
            $version = $this->freezeDeckVersion($model, $round, $requester, $liveDeckDocument);

            return [new FrozenItem('deck', Approval::VERSION_DECK, (string) $version->id, 'Deck · v'.$round, null)];
        }

        if ($model instanceof CampaignPlan) {
            return [new FrozenItem('plan', Approval::VERSION_FINGERPRINT, self::fingerprintPlan($model), 'Plan · v'.$round, null)];
        }

        if ($model instanceof StudioFile && $kvItems !== null && $kvItems !== []) {
            return $kvItems;
        }

        throw ValidationException::withMessages(['subject_type' => 'Unsupported subject.']);
    }

    /**
     * Every ready item of `$phases` as the page renders it, or — legacy —
     * the one item `$readyItemId` names.
     *
     * @param  list<string>|null  $phases
     * @return non-empty-list<FrozenItem>
     *
     * @throws NothingReadyException
     * @throws TooManyItemsException
     * @throws ValidationException bad legacy `kv_ready_item_id`
     */
    private function freezeKvItems(StudioFile $file, ?array $phases, ?string $readyItemId): array
    {
        if ($phases !== null && $phases !== []) {
            $byPhase = $this->kvPayload->itemsFor($file, array_values(array_unique($phases)));
        } else {
            [$phase, $rawId] = $this->resolveLegacyReadyItem($file, $readyItemId);
            $byPhase = [$phase => $this->kvPayload->resolvePhase($file, $phase, [$rawId])];
            if ($byPhase[$phase] === []) {
                throw ValidationException::withMessages(['kv_ready_item_id' => 'That item is not ready to share yet.']);
            }
        }

        $items = [];
        foreach ($byPhase as $phase => $payloadItems) {
            foreach ($payloadItems as $payloadItem) {
                $items[] = FrozenItem::fromKvPayload((string) $phase, $payloadItem);
            }
        }

        if ($items === []) {
            throw new NothingReadyException;
        }
        if (count($items) > self::MAX_ITEMS) {
            throw new TooManyItemsException(self::MAX_ITEMS);
        }

        return $items;
    }

    /**
     * The `ShareReadyItem` a legacy `kv_ready_item_id` names, checked to sit
     * on this file: its phase and the raw marked id the payload resolver
     * takes. Web only ever sees markable ids (readyToShareMap on the studio
     * file), never share_ready_items row ids — accept either; ULIDs make the
     * markable lookup unambiguous.
     *
     * @return array{0: string, 1: string} phase, raw marked id
     *
     * @throws ValidationException
     */
    private function resolveLegacyReadyItem(StudioFile $file, ?string $readyItemId): array
    {
        if ($readyItemId === null) {
            throw ValidationException::withMessages(['kv_ready_item_id' => 'Pick the item to send for approval.']);
        }

        $item = ShareReadyItem::query()->find($readyItemId)
            ?? ShareReadyItem::query()->where('markable_id', $readyItemId)->first();
        if ($item === null) {
            throw ValidationException::withMessages(['kv_ready_item_id' => 'That item is not marked ready to share.']);
        }

        $phase = match ($item->markable_type) {
            KvReadyToShareService::MARKABLE_KV_GENERATION => KvGeneration::query()
                ->whereKey($item->markable_id)
                ->where('studio_file_id', $file->id)
                ->value('mode'),
            KvReadyToShareService::MARKABLE_KV_RESIZE_EXPORT => KvResizeExport::query()
                ->whereKey($item->markable_id)
                ->where('studio_file_id', $file->id)
                ->exists() ? 'resize' : null,
            KvReadyToShareService::MARKABLE_KV_MOTION_EXPORT => KvMotionExport::query()
                ->whereKey($item->markable_id)
                ->whereHas('project', fn ($q) => $q->where('studio_file_id', $file->id))
                ->exists() ? 'motion' : null,
            default => null,
        };

        if ($phase === null) {
            throw ValidationException::withMessages(['kv_ready_item_id' => 'That item does not belong to this file.']);
        }

        $phase = $phase instanceof \BackedEnum ? (string) $phase->value : (string) $phase;

        if (! in_array($phase, KvSharePayloadService::PHASES, true)) {
            throw ValidationException::withMessages(['kv_ready_item_id' => 'That item is not ready to share yet.']);
        }

        return [$phase, (string) $item->markable_id];
    }

    /**
     * KV phases the round's items live in, canonical order; [] for deck/plan.
     *
     * @param  list<FrozenItem>  $items
     * @return list<string>
     */
    private static function kvPhasesOf(array $items): array
    {
        $phases = array_map(static fn (FrozenItem $item): string => $item->phase, $items);

        return array_values(array_intersect(KvSharePayloadService::PHASES, $phases));
    }

    /** Stamp every item of the round with one status (round-level close, withdraw, supersede). */
    private function setItemStatuses(Approval $approval, string $status): void
    {
        ApprovalItem::query()->where('approval_id', $approval->id)->update(['status' => $status]);
    }
```

5m. `reuseOrMintCommentLink()` (lines 692-734): docblock sentence "For KV the link must expose the phase the chosen item lives in, so a reused link gains that phase when missing." becomes "For KV the link must expose every phase the round's items live in, so a reused link gains the missing ones (union, existing order first)."; add `     * @param  list<string>  $kvPhases` above `@throws`. Signature becomes `private function reuseOrMintCommentLink(ApprovalSubject $subject, User $requester, array $kvPhases): ShareLink`. Replace the reuse branch (lines 709-716) with:

```php
        if ($existing !== null) {
            $union = array_values(array_unique([...$existing->phaseList(), ...$kvPhases]));
            if ($union !== $existing->phaseList()) {
                $existing->phases = $union;
                $existing->save();
            }

            return $existing;
        }
```

and in the `create(` call replace `phases: $kvPhase !== null ? [$kvPhase] : [],` with `phases: $kvPhases,`.

- [ ] **Step 6: Run — expect PASS (11 passed)**

Same command as Step 3.

- [ ] **Step 7: Mutation check**

1. In `freezeKvItems()` delete the `count($items) > self::MAX_ITEMS` block → *"fifty items is accepted…"* must FAIL. Restore.
2. In `freezeKvItems()` legacy branch pass `[(string) $readyItemId]` instead of `[$rawId]` to `resolvePhase()` → *"kv_ready_item_id still works…"* must FAIL on the by-row request (a `share_ready_items` row id is not a generation id, so nothing renders → 422). Restore.
2b. Temporarily, in `freezeKvItems()` after building `$items`, overwrite the craft item's id with the raw marked id: `$items[0] = new FrozenItem($items[0]->phase, $items[0]->versionType, (string) app(KvReadyToShareService::class)->rawMarkedGenerationIds($file, 'craft')[0], $items[0]->label, $items[0]->snapshot);` → *"the frozen id is the id the page renders…"* must FAIL (old board id instead of the tip). Remove the line.
3. In `FrozenItem::clip()` return `$label` unchanged → *"labels never overflow…"* must FAIL (QueryException 22001 on the insert). Restore.
4. In `reuseOrMintCommentLink()` set `$union = $kvPhases;` → *"a reused comment link gains…"* must FAIL. Restore.
5. Remove `$this->setItemStatuses($previous, …)` from the supersede block → *"a new round supersedes…"* must FAIL. Restore.

Re-run: all pass.

- [ ] **Step 8: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && for f in app/Services/Approval/FrozenItem.php app/Exceptions/Approval/NothingReadyException.php app/Exceptions/Approval/TooManyItemsException.php app/Services/Approval/ApprovalService.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/ApprovalRequestItemsTest.php; do php -l "$f"; done && vendor/bin/pint --test app/Services/Approval/FrozenItem.php app/Exceptions/Approval/NothingReadyException.php app/Exceptions/Approval/TooManyItemsException.php app/Services/Approval/ApprovalService.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/ApprovalRequestItemsTest.php
```

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && git add app/Services/Approval/FrozenItem.php app/Exceptions/Approval/NothingReadyException.php app/Exceptions/Approval/TooManyItemsException.php app/Services/Approval/ApprovalService.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/ApprovalRequestItemsTest.php && git commit -m "feat(api): freeze multi-item approval rounds from selected KV phases"
```

---

### Task 4: Item statuses — round vs item decisions, aggregate, withdraw, C-3 `item_id`

**Files:**
- Create: `app/Exceptions/Approval/InvalidItemException.php`
- Modify: `app/Services/Approval/ApprovalService.php` (`decide()` 267-366, `resolve()` 368-438, `withdraw()` 444-461, `close()` 807-814; imports)
- Modify: `app/Http/Controllers/Api/PublicShareLinkController.php` (`decision()` validation 130-147, try/catch 169-175; imports 9-10)
- Modify: `app/Http/Resources/Approval/ApprovalPresenter.php` (`decision()` 103-121)
- Test: `tests/Feature/Approval/ApprovalDecideItemsTest.php`

**Interfaces:**
- Consumes: `ApprovalItem`, `Approval::items()` (Task 1); `setItemStatuses()` (Task 3); `ClientLaneFixtures::roundWithItems()`, `::requestKv()`.
- Produces:
  - `decide()` accepts `$input['item_id'] ?? null`; decision rows carry `approval_item_id`.
  - `public static ApprovalService::aggregateStatus(array $statuses): string`.
  - private `outcomeFor(Approval, Collection): ?array`, `resolveItems(Approval): void`, `itemFor(Approval, mixed, string): ?ApprovalItem`; `close(Approval, string, ApprovalDecision, bool $cascadeItems = true)`.
  - `InvalidItemException` (`CODE = 'invalid_item'`).
  - Presenter decision gains `'item_id' => string|null`.

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Approval/ApprovalDecideItemsTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Exceptions\Approval\InvalidItemException;
use App\Models\Approval;
use App\Models\ApprovalDecision;
use App\Models\User;
use App\Services\Approval\ApprovalActor;
use App\Services\Approval\ApprovalService;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    $this->approvals = app(ApprovalService::class);
    $this->guest = ApprovalActor::guest('Bayu', 'bayu@brand.test');
});

test('a round-level decision resolves the round and every item with it', function () {
    $round = ClientLaneFixtures::roundWithItems(['101', '102', '103']);

    $decision = $this->approvals->decide($round, $this->guest, ['outcome' => 'changes_required', 'note' => 'Logo too small'], notify: false);

    expect($decision->approval_item_id)->toBeNull()
        ->and($round->fresh()->status)->toBe('changes_required')
        ->and($round->items()->pluck('status')->all())->toBe(['changes_required', 'changes_required', 'changes_required']);
});

test('an item-level decision settles that item only while others stay open', function () {
    $round = ClientLaneFixtures::roundWithItems(['101', '102', '103']);
    $items = $round->items()->get();

    $decision = $this->approvals->decide($round, $this->guest, ['outcome' => 'approved', 'item_id' => $items[1]->id], notify: false);

    expect($decision->approval_item_id)->toBe($items[1]->id)
        ->and($round->fresh()->status)->toBe('pending')
        ->and($round->items()->pluck('status')->all())->toBe(['pending', 'approved', 'pending']);
});

test('the round resolves once every item is settled, aggregating the outcomes', function (array $outcomes, string $expected) {
    $round = ClientLaneFixtures::roundWithItems(['101', '102', '103']);
    $items = $round->items()->get();

    $last = null;
    foreach ($outcomes as $i => $outcome) {
        $last = $this->approvals->decide($round->fresh(), $this->guest, ['outcome' => $outcome, 'note' => 'n', 'item_id' => $items[$i]->id], notify: false);
    }

    $fresh = $round->fresh();
    expect($fresh->status)->toBe($expected)
        ->and($fresh->resolved_by_decision_id)->toBe($last->id)
        ->and($round->items()->pluck('status')->all())->toBe($outcomes);
})->with([
    'all approved' => [['approved', 'approved', 'approved'], 'approved'],
    'one approved with changes' => [['approved', 'approved_with_changes', 'approved'], 'approved_with_changes'],
    'one changes required' => [['approved', 'changes_required', 'approved'], 'changes_required'],
    'changes required beats approved with changes' => [['approved_with_changes', 'changes_required', 'approved_with_changes'], 'changes_required'],
]);

test('deferral stays round-level: item_id with deferred is refused', function () {
    $round = ClientLaneFixtures::roundWithItems(['101', '102']);
    $item = $round->items()->first();

    expect(fn () => $this->approvals->decide($round, $this->guest, [
        'outcome' => 'deferred',
        'deferred_until' => now()->addDays(3)->toDateString(),
        'item_id' => $item->id,
    ], notify: false))->toThrow(InvalidItemException::class);

    expect(ApprovalDecision::query()->count())->toBe(0);
});

test('an item of another round is refused', function () {
    $round = ClientLaneFixtures::roundWithItems(['101']);
    $other = ClientLaneFixtures::roundWithItems(['201']);

    expect(fn () => $this->approvals->decide($round, $this->guest, ['outcome' => 'approved', 'item_id' => $other->items()->value('id')], notify: false))
        ->toThrow(InvalidItemException::class);
});

test('withdrawing retires every item', function () {
    $round = ClientLaneFixtures::roundWithItems(['101', '102']);

    $this->approvals->withdraw($round);

    expect($round->items()->pluck('status')->all())->toBe(['not_relevant', 'not_relevant']);
});

test('under required policy an item settles only once every named approver decided on it', function () {
    $dina = User::factory()->create();
    $bayu = User::factory()->create();
    $row = fn (User $u): array => ['user_id' => (string) $u->id, 'lane_link_id' => null, 'email' => (string) $u->email, 'name' => (string) $u->name];
    $round = ClientLaneFixtures::roundWithItems(['101', '102'], [
        'policy' => Approval::POLICY_REQUIRED,
        'approvers' => [$row($dina), $row($bayu)],
    ]);
    $first = $round->items()->first();

    $this->approvals->decide($round, ApprovalActor::user($dina), ['outcome' => 'approved', 'item_id' => $first->id], notify: false);
    expect($first->fresh()->status)->toBe('pending');

    $this->approvals->decide($round->fresh(), ApprovalActor::user($bayu), ['outcome' => 'approved', 'item_id' => $first->id], notify: false);
    expect($first->fresh()->status)->toBe('approved')
        ->and($round->fresh()->status)->toBe('pending');
});

// Review Focus 5
test('an advisory decision never settles an item', function () {
    $dina = User::factory()->create();
    $round = ClientLaneFixtures::roundWithItems(['101'], [
        'policy' => Approval::POLICY_REQUIRED,
        'approvers' => [['user_id' => (string) $dina->id, 'lane_link_id' => null, 'email' => (string) $dina->email, 'name' => (string) $dina->name]],
    ]);
    $item = $round->items()->first();

    $decision = $this->approvals->decide($round, $this->guest, ['outcome' => 'approved', 'item_id' => $item->id], notify: false);

    expect($decision->advisory)->toBeTrue()
        ->and($item->fresh()->status)->toBe('pending')
        ->and($round->fresh()->status)->toBe('pending');
});

test('the public decision endpoint answers invalid_item and echoes item_id', function () {
    $kv = ClientLaneFixtures::kvFile();
    $board = ClientLaneFixtures::board($kv['file'], $kv['user']);
    ClientLaneFixtures::markReady('kv_generation', $board->id, $kv['user']);
    $result = ClientLaneFixtures::requestKv($kv['file'], $kv['user'], ['craft']);
    $token = $result['share_link']->token;
    $guest = ['guest_name' => 'Bayu', 'guest_email' => 'bayu@brand.test'];

    $this->postJson("/api/public/share-links/{$token}/decision", ['outcome' => 'approved', 'item_id' => '01jzzzzzzzzzzzzzzzzzzzzzzz', ...$guest])
        ->assertStatus(422)
        ->assertJson(['code' => 'invalid_item']);

    $itemId = $result['approval']->items()->value('id');
    $this->postJson("/api/public/share-links/{$token}/decision", ['outcome' => 'approved', 'item_id' => $itemId, ...$guest])
        ->assertCreated()
        ->assertJsonPath('data.decision.item_id', $itemId)
        ->assertJsonPath('data.approval.status', 'approved');
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalDecideItemsTest.php --compact
```
Expected: FAIL — `Class "App\Exceptions\Approval\InvalidItemException" not found`; the round-level test fails on item statuses still `pending`.

- [ ] **Step 3: Create the exception**

`app/Exceptions/Approval/InvalidItemException.php`:

```php
<?php

declare(strict_types=1);

namespace App\Exceptions\Approval;

use RuntimeException;

/**
 * A decision named an item that is not in the current round, or tried to
 * defer a single item (deferral is round-level) — `422 { code:
 * "invalid_item" }` (multi-item spec §5.4).
 */
final class InvalidItemException extends RuntimeException
{
    public const CODE = 'invalid_item';

    public function __construct(string $message = 'That item is not in this round.')
    {
        parent::__construct($message);
    }
}
```

- [ ] **Step 4: Change `ApprovalService`**

4a. Imports: add `use App\Exceptions\Approval\InvalidItemException;` and `use Illuminate\Support\Collection;`.

4b. `decide()` docblock (line 270): the `@param array{…}` becomes `array{outcome: string, note?: string|null, pins?: list<string>|null, deferred_until?: string|null, item_id?: string|null}  $input`; add `     * @throws InvalidItemException item_id not in this round, or with `deferred``.

4c. Inside the transaction, replace line 325 (`$pins = $this->validatePins(…);`) with:

```php
            $item = $this->itemFor($locked, $input['item_id'] ?? null, $outcome);

            $pins = $this->validatePins($locked, $actor, $input['pins'] ?? []);
```

and in `ApprovalDecision::create([…])` add after `'approval_id' => $locked->id,`:

```php
                'approval_item_id' => $item?->id,
```

4d. Replace `resolve()` (lines 368-438, docblock included) with:

```php
    /**
     * FR-3, on an approval already locked by the caller. `$closer` forces
     * the round shut with that decision (agency sign-off).
     *
     * Multi-item (spec §4.3): item-level decisions (`approval_item_id` set)
     * settle their item by the same policy rule, and close the round once
     * every item is settled ({@see resolveItems()}). Round-level decisions
     * (`approval_item_id` NULL — all of Phase 1) resolve the round exactly as
     * before, and closing stamps every item with the round's status.
     */
    public function resolve(Approval $approval, ?ApprovalDecision $closer = null): void
    {
        if ($approval->isTerminal()) {
            return;
        }

        if ($closer !== null) {
            $this->close($approval, $closer->outcome, $closer);

            return;
        }

        $this->resolveItems($approval);
        if ($approval->isTerminal()) {
            return;
        }

        $counting = $approval->decisions()
            ->where('advisory', false)
            ->whereNull('approval_item_id')
            ->whereIn('outcome', ApprovalDecision::RESOLVING_OUTCOMES)
            ->orderBy('id')
            ->get();

        $result = $this->outcomeFor($approval, $counting);
        if ($result !== null) {
            $this->close($approval, $result[0], $result[1]);
        }
    }

    /**
     * Round status from settled item statuses (spec §4.3): any
     * `changes_required` wins, then any `approved_with_changes`, else
     * `approved`.
     *
     * @param  list<string>  $statuses
     */
    public static function aggregateStatus(array $statuses): string
    {
        if (in_array(Approval::STATUS_CHANGES_REQUIRED, $statuses, true)) {
            return Approval::STATUS_CHANGES_REQUIRED;
        }
        if (in_array(Approval::STATUS_APPROVED_WITH_CHANGES, $statuses, true)) {
            return Approval::STATUS_APPROVED_WITH_CHANGES;
        }

        return Approval::STATUS_APPROVED;
    }
```

(`orderBy('id')` after the relation's own `orderBy('decided_at')` breaks same-second ties by ULID, which is monotonic.)

4e. Add these private methods in the Internals section (after `isAdvisory()`, line 746):

```php
    /**
     * The FR-3 policy rule over one set of counting decisions (ordered by
     * decided_at, id): optional → the first one; required → any
     * changes_required immediately, else once every named approver decided
     * (approved_with_changes if any said so). Null = still waiting.
     *
     * @param  Collection<int, ApprovalDecision>  $counting
     * @return array{0: string, 1: ApprovalDecision}|null status, closing decision
     */
    private function outcomeFor(Approval $approval, Collection $counting): ?array
    {
        if ($counting->isEmpty()) {
            return null;
        }

        if ($approval->policy === Approval::POLICY_OPTIONAL) {
            /** @var ApprovalDecision $first */
            $first = $counting->first();

            return [$first->outcome, $first];
        }

        if ($approval->policy !== Approval::POLICY_REQUIRED) {
            return null;
        }

        /** @var ApprovalDecision|null $veto */
        $veto = $counting->first(fn (ApprovalDecision $d) => $d->outcome === ApprovalDecision::OUTCOME_CHANGES_REQUIRED);
        if ($veto !== null) {
            return [Approval::STATUS_CHANGES_REQUIRED, $veto];
        }

        // Latest counting decision per named approver.
        $latestByApprover = [];
        foreach ($counting as $decision) {
            $latestByApprover[(string) $decision->actor_user_id] = $decision;
        }

        foreach ($approval->approverUserIds() as $userId) {
            if (! isset($latestByApprover[$userId])) {
                return null; // still waiting on someone
            }
        }

        /** @var ApprovalDecision|null $withChanges */
        $withChanges = collect($latestByApprover)->first(
            fn (ApprovalDecision $d) => $d->outcome === ApprovalDecision::OUTCOME_APPROVED_WITH_CHANGES
        );
        /** @var ApprovalDecision $last */
        $last = collect($latestByApprover)->sortBy(fn (ApprovalDecision $d) => $d->decided_at)->last();

        return [
            $withChanges !== null ? Approval::STATUS_APPROVED_WITH_CHANGES : Approval::STATUS_APPROVED,
            $withChanges ?? $last,
        ];
    }

    /**
     * Settle each still-pending item from its own counting item-level
     * decisions, then close the round with the aggregate once none is
     * pending. Items keep their own statuses (no cascade).
     */
    private function resolveItems(Approval $approval): void
    {
        $decisions = $approval->decisions()
            ->where('advisory', false)
            ->whereNotNull('approval_item_id')
            ->whereIn('outcome', ApprovalDecision::RESOLVING_OUTCOMES)
            ->orderBy('id')
            ->get();

        if ($decisions->isEmpty()) {
            return;
        }

        $byItem = $decisions->groupBy('approval_item_id');
        $items = ApprovalItem::query()->where('approval_id', $approval->id)->orderBy('position')->get();
        if ($items->isEmpty()) {
            return;
        }

        foreach ($items as $item) {
            if (! $item->isPending()) {
                continue;
            }
            $result = $this->outcomeFor($approval, $byItem->get($item->id, collect()));
            if ($result !== null) {
                $item->forceFill(['status' => $result[0]])->save();
            }
        }

        if ($items->contains(fn (ApprovalItem $item): bool => $item->isPending())) {
            return;
        }

        /** @var ApprovalDecision $last */
        $last = $decisions->last();
        $this->close(
            $approval,
            self::aggregateStatus($items->pluck('status')->all()),
            $last,
            cascadeItems: false,
        );
    }

    /**
     * The item a decision names, checked to belong to this round. Deferral
     * is round-level only (spec §4.3).
     *
     * @throws InvalidItemException
     */
    private function itemFor(Approval $approval, mixed $itemId, string $outcome): ?ApprovalItem
    {
        if ($itemId === null || $itemId === '') {
            return null;
        }

        if ($outcome === ApprovalDecision::OUTCOME_DEFERRED) {
            throw new InvalidItemException('Only the whole round can be deferred.');
        }

        $item = ApprovalItem::query()
            ->where('approval_id', $approval->id)
            ->whereKey((string) $itemId)
            ->first();

        if ($item === null) {
            throw new InvalidItemException;
        }

        return $item;
    }
```

4f. `close()` (lines 807-814) becomes:

```php
    /**
     * @param  bool  $cascadeItems  true for a round-level close (every item
     *                              takes the round's status); false when the
     *                              items already settled themselves
     */
    private function close(Approval $approval, string $status, ApprovalDecision $decision, bool $cascadeItems = true): void
    {
        $approval->forceFill([
            'status' => $status,
            'resolved_at' => now(),
            'resolved_by_decision_id' => $decision->id,
        ])->save();

        if ($cascadeItems) {
            $this->setItemStatuses($approval, $status);
        }
    }
```

4g. `withdraw()`: after the `$locked->forceFill([...])->save();` (line 457) insert:

```php
            $this->setItemStatuses($locked, Approval::STATUS_NOT_RELEVANT);
```

- [ ] **Step 5: Wire C-3 + presenter**

In `app/Http/Controllers/Api/PublicShareLinkController.php`:
- Imports: add `use App\Exceptions\Approval\InvalidItemException;` after line 9.
- In `decision()` validation, after the `'deferred_until' => [ … ],` block (ends line 145) add:

```php
            // Multi-item C-3: an item of the current round; anything else is
            // `422 invalid_item` from the service (not a validation error), so
            // only the shape is checked here.
            'item_id' => ['nullable', 'string', 'max:64'],
```

- In the `try { … }` around `decide()` (lines 169-175) add a catch after the `ApprovalRoundClosedException` catch:

```php
        } catch (InvalidItemException $e) {
            return $this->error(422, InvalidItemException::CODE, $e->getMessage());
```

In `app/Http/Resources/Approval/ApprovalPresenter.php` `decision()` add after `'id' => $decision->id,` (line 106):

```php
            // Multi-item (spec §5.5): null = a decision on the whole round.
            'item_id' => $decision->approval_item_id,
```

- [ ] **Step 6: Run — expect PASS (12 passed incl. the 4 dataset rows)**

Same command as Step 2. Then re-run Task 3's file as regression:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalRequestItemsTest.php --compact
```

- [ ] **Step 7: Mutation check**

1. In `resolve()` delete `->whereNull('approval_item_id')` → *"an item-level decision settles that item only…"* must FAIL (round closes on the first item decision). Restore.
2. In `aggregateStatus()` swap the two `if` blocks → dataset *"changes required beats approved with changes"* must FAIL. Restore.
3. In `resolveItems()` delete `->where('advisory', false)` → *"an advisory decision never settles an item"* must FAIL. Restore.
4. In `close()` default `$cascadeItems = false` → *"a round-level decision resolves the round and every item…"* must FAIL. Restore.
5. In `itemFor()` delete the deferred branch → *"deferral stays round-level…"* must FAIL. Restore.

- [ ] **Step 8: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && for f in app/Exceptions/Approval/InvalidItemException.php app/Services/Approval/ApprovalService.php app/Http/Controllers/Api/PublicShareLinkController.php app/Http/Resources/Approval/ApprovalPresenter.php tests/Feature/Approval/ApprovalDecideItemsTest.php; do php -l "$f"; done && vendor/bin/pint --test app/Exceptions/Approval/InvalidItemException.php app/Services/Approval/ApprovalService.php app/Http/Controllers/Api/PublicShareLinkController.php app/Http/Resources/Approval/ApprovalPresenter.php tests/Feature/Approval/ApprovalDecideItemsTest.php
```

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && git add app/Exceptions/Approval/InvalidItemException.php app/Services/Approval/ApprovalService.php app/Http/Controllers/Api/PublicShareLinkController.php app/Http/Resources/Approval/ApprovalPresenter.php tests/Feature/Approval/ApprovalDecideItemsTest.php && git commit -m "feat(api): per-item approval statuses, item-level decisions and aggregate resolution"
```

---

### Task 5: Pins and comments accept any item of the round

**Files:**
- Modify: `app/Services/Approval/ApprovalService.php` (`validatePins()` 748-805)
- Modify: `app/Http/Controllers/Api/PublicShareLinkController.php` (`comments()` 208-236, `storeComment()` 300-313)
- Test: `tests/Feature/Approval/ApprovalPinsMembershipTest.php`

**Interfaces:**
- Consumes: `Approval::itemVersionIds()` (Task 1), `ClientLaneFixtures::requestKv/iterate/board/resizeTile/markReady`.
- Produces: C-4 `GET`/`POST …/comments` and C-3 `pins` keyed on the round's version-id set; `invalid_anchor` message "That element is not in this round.".

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Approval/ApprovalPinsMembershipTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Models\Approval;
use App\Models\Comment;
use App\Models\ShareLink;
use App\Services\Sharing\ShareLinkService;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];
    $this->board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $this->tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $this->board);
    ClientLaneFixtures::markReady('kv_generation', $this->board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $this->tile->id, $this->user);

    $result = ClientLaneFixtures::requestKv($this->file, $this->user, ['craft', 'resize']);
    $this->token = $result['share_link']->token;
    $this->guest = ['guest_name' => 'Bayu', 'guest_email' => 'bayu@brand.test'];
    $this->boardAnchor = "craft:{$this->board->id}:board";
    $this->tileAnchor = "resize:{$this->tile->id}:tile.{$this->tile->id}";
});

test('a client can pin any item of the round, and nothing outside it', function () {
    $this->postJson("/api/public/share-links/{$this->token}/comments", [
        'body' => 'Logo too tight to the edge',
        'anchor' => ['kind' => 'pin', 'id' => $this->tileAnchor, 'x' => 0.4, 'y' => 0.6],
        ...$this->guest,
    ])->assertCreated();

    $other = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Alt board');
    $this->postJson("/api/public/share-links/{$this->token}/comments", [
        'body' => 'And this one?',
        'anchor' => ['kind' => 'pin', 'id' => "craft:{$other->id}:board", 'x' => 0.5, 'y' => 0.5],
        ...$this->guest,
    ])->assertStatus(422)->assertExactJson(['code' => 'invalid_anchor', 'message' => 'That element is not in this round.']);
});

test('comments list roots on every item of the round plus their replies', function () {
    $onBoard = $this->postJson("/api/public/share-links/{$this->token}/comments", [
        'body' => 'Warmer please',
        'anchor' => ['kind' => 'pin', 'id' => $this->boardAnchor, 'x' => 0.2, 'y' => 0.3],
        ...$this->guest,
    ])->assertCreated()->json('data.id');
    $onTile = $this->postJson("/api/public/share-links/{$this->token}/comments", [
        'body' => 'Crop the head less',
        'anchor' => ['kind' => 'pin', 'id' => $this->tileAnchor, 'x' => 0.5, 'y' => 0.1],
        ...$this->guest,
    ])->assertCreated()->json('data.id');
    $reply = $this->postJson("/api/public/share-links/{$this->token}/comments", [
        'body' => 'Agreed',
        'parent_id' => $onTile,
        ...$this->guest,
    ])->assertCreated()->json('data.id');

    $other = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Alt board');
    // Written directly on purpose: the store endpoint would refuse it.
    $outside = Comment::query()->create([
        'commentable_type' => 'kv_file',
        'commentable_id' => $this->file->id,
        'anchor' => ['kind' => 'pin', 'id' => "craft:{$other->id}:board", 'x' => 0.5, 'y' => 0.5],
        'body' => 'Not in this round',
        'guest_name' => 'Bayu',
        'guest_email' => 'bayu@brand.test',
        'internal_only' => false,
    ])->id;

    $ids = $this->getJson("/api/public/share-links/{$this->token}/comments")->assertOk()->json('data.*.id');

    expect($ids)->toEqualCanonicalizing([$onBoard, $onTile, $reply])
        ->and($ids)->not->toContain($outside);
});

test('decision pins may sit on any item of the round and nowhere else', function () {
    $onTile = $this->postJson("/api/public/share-links/{$this->token}/comments", [
        'body' => 'Crop the head less',
        'anchor' => ['kind' => 'pin', 'id' => $this->tileAnchor, 'x' => 0.5, 'y' => 0.1],
        ...$this->guest,
    ])->assertCreated()->json('data.id');

    $other = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Alt board');
    $outside = Comment::query()->create([
        'commentable_type' => 'kv_file',
        'commentable_id' => $this->file->id,
        'anchor' => ['kind' => 'pin', 'id' => "craft:{$other->id}:board", 'x' => 0.5, 'y' => 0.5],
        'body' => 'Not in this round',
        'guest_name' => 'Bayu',
        'guest_email' => 'bayu@brand.test',
        'internal_only' => false,
    ])->id;

    $this->postJson("/api/public/share-links/{$this->token}/decision", [
        'outcome' => 'changes_required', 'note' => 'See pins', 'pins' => [$onTile, $outside], ...$this->guest,
    ])->assertStatus(422)->assertJsonValidationErrors('pins');

    $this->postJson("/api/public/share-links/{$this->token}/decision", [
        'outcome' => 'changes_required', 'note' => 'See pins', 'pins' => [$onTile], ...$this->guest,
    ])->assertCreated()->assertJsonPath('data.decision.pins', [$onTile]);
});

test('after a new round, a pin on the superseded board version is refused', function () {
    $tip = ClientLaneFixtures::iterate($this->file, $this->user, $this->board, 'https://cdn.test/board-v2.png');
    ClientLaneFixtures::requestKv($this->file, $this->user, ['craft', 'resize']); // round 2, same comment link

    $this->postJson("/api/public/share-links/{$this->token}/comments", [
        'body' => 'Old version',
        'anchor' => ['kind' => 'pin', 'id' => $this->boardAnchor, 'x' => 0.1, 'y' => 0.1],
        ...$this->guest,
    ])->assertStatus(422)->assertJson(['code' => 'invalid_anchor']);

    $this->postJson("/api/public/share-links/{$this->token}/comments", [
        'body' => 'New version',
        'anchor' => ['kind' => 'pin', 'id' => "craft:{$tip->id}:board", 'x' => 0.1, 'y' => 0.1],
        ...$this->guest,
    ])->assertCreated();
});

// Decision 2026-09-30 (Daffa): pins belong to the round they were placed in.
// A resize tile keeps its row id across rounds, so without this a round-1 pin
// would reappear on the regenerated tile in round 2.
test('a pin from an earlier round does not carry into the next round, even on an unchanged tile', function () {
    $old = $this->postJson("/api/public/share-links/{$this->token}/comments", [
        'body' => 'Crop the head less',
        'anchor' => ['kind' => 'pin', 'id' => $this->tileAnchor, 'x' => 0.5, 'y' => 0.1],
        ...$this->guest,
    ])->assertCreated()->json('data.id');

    // Timestamps are second-precision: move past round 1 before round 2 opens.
    $this->travel(1)->minutes();
    ClientLaneFixtures::requestKv($this->file, $this->user, ['craft', 'resize']); // round 2, same tile row id
    $this->travel(1)->minutes();

    $new = $this->postJson("/api/public/share-links/{$this->token}/comments", [
        'body' => 'Better, nudge it up',
        'anchor' => ['kind' => 'pin', 'id' => $this->tileAnchor, 'x' => 0.5, 'y' => 0.2],
        ...$this->guest,
    ])->assertCreated()->json('data.id');

    expect($this->getJson("/api/public/share-links/{$this->token}/comments")->assertOk()->json('data.*.id'))
        ->toBe([$new]);

    $this->postJson("/api/public/share-links/{$this->token}/decision", [
        'outcome' => 'changes_required', 'note' => 'See pins', 'pins' => [$old], ...$this->guest,
    ])->assertStatus(422)->assertJsonValidationErrors('pins');
});

// Review Focus 3
test('a round with no item rows (pre-backfill) still pins against its subject version', function () {
    $fx = ClientLaneFixtures::kvFile();
    $board = ClientLaneFixtures::board($fx['file'], $fx['user']);
    $link = app(ShareLinkService::class)->create(
        $fx['file'],
        $fx['user'],
        ['craft'],
        role: ShareLink::ROLE_COMMENT,
        workspaceId: (string) $fx['file']->workspace_id,
    );
    Approval::factory()->create([
        'subject_type' => 'kv_file',
        'subject_id' => $fx['file']->id,
        'workspace_id' => $fx['file']->workspace_id,
        'brand_id' => $fx['file']->brand_id,
        'subject_version_type' => 'kv_generation',
        'subject_version_id' => $board->id,
        'share_link_id' => $link->id,
    ]);

    $id = $this->postJson("/api/public/share-links/{$link->token}/comments", [
        'body' => 'Pinned on a legacy round',
        'anchor' => ['kind' => 'pin', 'id' => "craft:{$board->id}:board", 'x' => 0.3, 'y' => 0.3],
        ...$this->guest,
    ])->assertCreated()->json('data.id');

    expect($this->getJson("/api/public/share-links/{$link->token}/comments")->assertOk()->json('data.*.id'))
        ->toBe([$id]);
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalPinsMembershipTest.php --compact
```
Expected: FAIL — pinning the tile (item 2) returns 422 "That element is not on the current version." (only the first item's version is accepted today); the comments test misses `$onTile`/`$reply`.

- [ ] **Step 3: Implement**

3a. `ApprovalService::validatePins()` — docblock first line becomes "Every pin must be a comment on this subject, by this actor, anchored to one of THIS round's item versions (`{stage}:{version}:{part}`) — C-3, multi-item spec §5.3." Before the `foreach ($rows as $comment)` loop (line 771) add:

```php
        $versionIds = $approval->itemVersionIds();
```

and replace lines 789-793 with:

```php
            $anchorId = (string) (($comment->anchor ?? [])['id'] ?? '');
            $segments = explode(':', $anchorId);
            if (count($segments) < 2 || ! in_array($segments[1], $versionIds, true)) {
                continue;
            }
            // Pins belong to the round they were placed in (decision
            // 2026-09-30): a resize tile keeps its row id across rounds, so
            // version membership alone would let a round-1 pin back in.
            if ($comment->created_at !== null && $comment->created_at->lt($approval->created_at)) {
                continue;
            }
```

Change the error message on line 800 to `'One or more pins are not yours or not in this round.'`.

3b. `PublicShareLinkController::comments()` — replace lines 208-236 (from `$versionId = …` through the closing `})` of the outer `where`) with:

```php
        // Every version this round froze (multi-item spec §5.3); a round with
        // no item rows falls back to its own version, never an empty set.
        $versionIds = $approval->itemVersionIds();
        $in = implode(', ', array_fill(0, count($versionIds), '?'));

        // SECURITY (client lane P0a review #2): this is an UNAUTHENTICATED
        // surface — a lane code proves the mailbox, never workspace
        // membership. Reading the lane's `User` in here as `visibleTo`'s
        // member check would let a client who is LATER invited as a
        // workspace member (nothing revokes their lane on invite) unlock
        // `internal_only` threads by lane code alone. Always read as a
        // non-member.
        //
        // Anchors whose `{stage}:{version}:{part}` version segment is one of
        // THIS round's item versions AND that were placed during this round
        // (pins belong to their round — decision 2026-09-30; a resize tile
        // keeps its row id across rounds), plus replies to those roots.
        $roundStart = $approval->created_at;
        $rows = Comment::query()
            ->where('commentable_type', $subject->type)
            ->where('commentable_id', (string) $subject->model->getKey())
            ->visibleTo(null, $subject->model)
            ->where(function ($q) use ($versionIds, $in, $roundStart) {
                $q->where(function ($root) use ($versionIds, $in, $roundStart) {
                    $root->whereRaw("split_part(anchor->>'id', ':', 2) IN ({$in})", $versionIds)
                        ->where('created_at', '>=', $roundStart);
                })
                    ->orWhere(function ($reply) use ($versionIds, $in, $roundStart) {
                        $reply->whereNotNull('parent_id')
                            ->whereExists(function ($sub) use ($versionIds, $in, $roundStart) {
                                $sub->selectRaw('1')
                                    ->from('comments as roots')
                                    ->whereColumn('roots.id', 'comments.parent_id')
                                    ->whereNull('roots.deleted_at')
                                    ->whereRaw("split_part(roots.anchor->>'id', ':', 2) IN ({$in})", $versionIds)
                                    ->where('roots.created_at', '>=', $roundStart);
                            });
                    });
            })
```

(The `->orderBy('created_at')->with(…)->get();` lines that follow stay.)

3c. `storeComment()` — replace the anchor block (lines 300-313) with:

```php
        // A NEW pin (root anchor) must sit on one of THIS round's items —
        // never a stale or future version (client lane P0a review M-7,
        // multi-item spec §5.3). Replies inherit their root's anchor and
        // never carry their own (C-4).
        if (isset($validated['anchor']) && empty($validated['parent_id'])) {
            $approval = $this->currentApproval($link);
            if ($approval === null) {
                return $this->error(422, 'invalid_anchor', 'There is no open round to pin this to.');
            }
            $anchorId = (string) $validated['anchor']['id'];
            if (
                preg_match('/^[a-z-]+:([^:]+):/', $anchorId, $match) !== 1
                || ! in_array($match[1], $approval->itemVersionIds(), true)
            ) {
                return $this->error(422, 'invalid_anchor', 'That element is not in this round.');
            }
        }
```

- [ ] **Step 4: Run — expect PASS (6 passed)**, then Task 4's file as regression (its HTTP test uses the decision route).

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalPinsMembershipTest.php --compact
```

- [ ] **Step 5: Mutation check**

1. In `storeComment()` replace `$approval->itemVersionIds()` with `[(string) $approval->subject_version_id]` → *"a client can pin any item…"* must FAIL (tile pin 422). Restore.
2. In `comments()` drop the reply `orWhere` branch → *"comments list roots… plus their replies"* must FAIL. Restore.
3. In `validatePins()` replace `$versionIds` with `[$approval->subject_version_id]` → *"decision pins may sit on any item…"* must FAIL (valid tile pin rejected). Restore.
4. In `Approval::itemVersionIds()` drop the fallback (return `$ids`) → *"a round with no item rows…"* must FAIL (SQL error on `IN ()` or 422). Restore.
5. In `comments()` drop the root `->where('created_at', '>=', $roundStart)` → *"a pin from an earlier round does not carry…"* must FAIL (the list contains `$old`). Restore. Then drop the `created_at->lt(...)` guard in `validatePins()` → the same test must FAIL on the decision (201 instead of 422). Restore.

- [ ] **Step 6: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && php -l app/Services/Approval/ApprovalService.php && php -l app/Http/Controllers/Api/PublicShareLinkController.php && php -l tests/Feature/Approval/ApprovalPinsMembershipTest.php && vendor/bin/pint --test app/Services/Approval/ApprovalService.php app/Http/Controllers/Api/PublicShareLinkController.php tests/Feature/Approval/ApprovalPinsMembershipTest.php && git add app/Services/Approval/ApprovalService.php app/Http/Controllers/Api/PublicShareLinkController.php tests/Feature/Approval/ApprovalPinsMembershipTest.php && git commit -m "feat(api): accept pins and comments on any item of an approval round"
```

---

### Task 6: C-1 `items` and the frozen KV document

**Files:**
- Modify: `app/Http/Resources/Approval/ApprovalPresenter.php` (add `items()`; imports 7-10)
- Modify: `app/Http/Controllers/Api/PublicShareLinkController.php` (`show()` data array 96-99, `document()` 432-466)
- Test: `tests/Feature/Approval/PublicShareLinkItemsTest.php`

**Interfaces:**
- Consumes: `Approval::items()`, `ApprovalItem` (Task 1), `KvSharePayloadService::PHASES` / `build()` (Task 2), `ClientLaneFixtures`.
- Produces:
  - `ApprovalPresenter::items(Approval $approval): array` → `list<array{id: string, phase: string, label: string, version_id: string, status: string, snapshot: array|null}>`.
  - C-1 `data.items`; KV `data.document` from snapshots when every item has one.
  - private `PublicShareLinkController::frozenKvDocument(StudioFile $file, Approval $approval, string $brandSlug): ?array`.

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Approval/PublicShareLinkItemsTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Models\Approval;
use App\Models\ApprovalItem;
use App\Models\ShareLink;
use App\Services\Sharing\ShareLinkService;
use App\Services\Studio\KvReadyToShareService;
use App\Services\Studio\KvSharePayloadService;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];
    $this->board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    // An overlay with a nested payload: the part a jsonb round-trip reorders.
    $this->file->forceFill(['overlays' => [[
        'id' => 'ov-logo',
        'type' => 'image',
        'x' => 0.1, 'y' => 0.2, 'width' => 0.3, 'height' => 0.4,
        'rotation' => 0, 'z' => 0,
        'board_generation_id' => $this->board->id,
        'payload' => ['type' => 'image', 'asset_url' => 'https://cdn.test/logo.png', 'fit' => 'contain'],
    ]]])->save();
    $this->tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $this->board);
    ClientLaneFixtures::markReady('kv_generation', $this->board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $this->tile->id, $this->user);
});

test('C-1 lists the round items and keeps version pointing at the first one', function () {
    $rendered = app(KvSharePayloadService::class)->itemsFor($this->file, ['craft', 'resize']);
    $result = ClientLaneFixtures::requestKv($this->file, $this->user, ['craft', 'resize']);
    $items = $result['approval']->items()->get();

    $data = $this->getJson("/api/public/share-links/{$result['share_link']->token}")->assertOk()->json('data');

    expect($data['items'])->toHaveCount(2);
    foreach ($data['items'] as $i => $item) {
        expect(array_keys($item))->toBe(['id', 'phase', 'label', 'version_id', 'status', 'snapshot'])
            ->and($item['id'])->toBe($items[$i]->id)
            ->and($item['version_id'])->toBe($items[$i]->version_id)
            ->and($item['status'])->toBe('pending');
    }
    expect($data['items'][0]['phase'])->toBe('craft')
        ->and($data['items'][0]['label'])->toBe('Craft · Hero board')
        ->and($data['items'][0]['snapshot'])->toEqual($rendered['craft'][0])
        ->and($data['items'][1]['snapshot'])->toEqual($rendered['resize'][0])
        ->and($data['version'])->toMatchArray(['type' => 'kv_generation', 'id' => $this->board->id, 'label' => 'v1']);
});

// Review Focus 4
test('the KV document is frozen: editing or unmarking after the request changes nothing on the approval page', function () {
    $rendered = app(KvSharePayloadService::class)->itemsFor($this->file, ['craft', 'resize']);
    $result = ClientLaneFixtures::requestKv($this->file, $this->user, ['craft', 'resize']);
    $viewLink = app(ShareLinkService::class)->create($this->file, $this->user, ['craft', 'resize'], workspaceId: (string) $this->file->workspace_id);

    $this->board->forceFill(['image_url' => 'https://cdn.test/board-EDITED.png'])->save();
    app(KvReadyToShareService::class)->unmark('kv_resize_export', $this->tile->id);

    $document = $this->getJson("/api/public/share-links/{$result['share_link']->token}")->assertOk()->json('data.document');

    expect($document)->toEqual([
        'name' => 'Ramadan hero KV',
        'brand_slug' => $this->kv['brand']->slug,
        'phases' => [
            ['phase' => 'craft', 'items' => [$rendered['craft'][0]]],
            ['phase' => 'resize', 'items' => [$rendered['resize'][0]]],
        ],
    ]);
    expect($document['phases'][0]['items'][0]['overlays'][0]['payload']['asset_url'])->toBe('https://cdn.test/logo.png');

    $live = $this->getJson("/api/public/share-links/{$viewLink->token}")->assertOk()->json('data');
    expect($live['items'])->toBe([])
        ->and($live['document']['phases'][0]['items'][0]['image_url'])->toBe('https://cdn.test/board-EDITED.png')
        ->and($live['document']['phases'][1]['items'])->toBe([]);
});

test('a round without snapshots (backfilled) keeps the live payload', function () {
    $link = app(ShareLinkService::class)->create($this->file, $this->user, ['craft'], role: ShareLink::ROLE_COMMENT, workspaceId: (string) $this->file->workspace_id);
    $round = Approval::factory()->create([
        'subject_type' => 'kv_file',
        'subject_id' => $this->file->id,
        'workspace_id' => $this->file->workspace_id,
        'brand_id' => $this->file->brand_id,
        'subject_version_type' => 'kv_generation',
        'subject_version_id' => $this->board->id,
        'share_link_id' => $link->id,
    ]);
    ApprovalItem::factory()->create([
        'approval_id' => $round->id,
        'phase' => 'craft',
        'version_type' => 'kv_generation',
        'version_id' => $this->board->id,
        'label' => 'v1',
        'snapshot' => null,
    ]);
    $this->board->forceFill(['image_url' => 'https://cdn.test/board-EDITED.png'])->save();

    $data = $this->getJson("/api/public/share-links/{$link->token}")->assertOk()->json('data');

    expect($data['items'])->toHaveCount(1)
        ->and($data['items'][0]['snapshot'])->toBeNull()
        ->and($data['document']['phases'][0]['items'][0]['image_url'])->toBe('https://cdn.test/board-EDITED.png');
});

test('dead links still answer the byte-identical 404', function () {
    $unknown = $this->getJson('/api/public/share-links/definitely-not-a-token')->assertNotFound();
    expect($unknown->getContent())->toBe('{"message":"Not found."}');

    $result = ClientLaneFixtures::requestKv($this->file, $this->user, ['craft']);
    $result['share_link']->forceFill(['revoked_at' => now()])->save();

    $revoked = $this->getJson("/api/public/share-links/{$result['share_link']->token}")->assertNotFound();
    expect($revoked->getContent())->toBe('{"message":"Not found."}');
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/PublicShareLinkItemsTest.php --compact
```
Expected: FAIL — `Undefined array key "items"` in the first three tests; the 404 test passes already (it guards the byte-identical body against regression).

- [ ] **Step 3: Presenter `items()`**

In `app/Http/Resources/Approval/ApprovalPresenter.php` add `use App\Models\ApprovalItem;` to the imports and this method after `decision()`:

```php
    /**
     * The round's frozen items for the public resolver (C-1, multi-item
     * spec §5.2). `snapshot` is the KV payload item as rendered at request
     * time; null for deck/plan and backfilled rounds.
     *
     * @return list<array{id: string, phase: string, label: string, version_id: string, status: string, snapshot: array<string, mixed>|null}>
     */
    public static function items(Approval $approval): array
    {
        $approval->loadMissing('items');

        return $approval->items
            ->map(fn (ApprovalItem $item): array => [
                'id' => $item->id,
                'phase' => $item->phase,
                'label' => $item->label,
                'version_id' => (string) $item->version_id,
                'status' => $item->status,
                'snapshot' => $item->snapshot,
            ])
            ->values()
            ->all();
    }
```

- [ ] **Step 4: Controller**

4a. In `show()`, after the `'version' => …` entry (ends line 98) add:

```php
            // Multi-item (spec §5.2): the frozen set; [] for a view link / no round.
            'items' => $approval !== null ? ApprovalPresenter::items($approval) : [],
```

4b. In `document()`, the docblock line ` *   kv_file  → the curated `KvSharePayloadService` payload for this link` becomes:

```php
 *   kv_file  → the round's frozen item snapshots when every item has one
 *              (multi-item spec §5.2), else the live
 *              `KvSharePayloadService` payload for this link
```

and replace the KV branch (lines 453-455) with:

```php
        if ($model instanceof StudioFile) {
            $frozen = $approval !== null
                ? $this->frozenKvDocument($model, $approval, (string) ($brandSlug ?? ''))
                : null;

            return $frozen ?? $this->kvPayload->build($model, $link, (string) ($brandSlug ?? ''));
        }
```

4c. Add after `document()`:

```php
    /**
     * The KV payload rebuilt from the round's snapshots — same shape as
     * `KvSharePayloadService::build()` (`{name, brand_slug, phases}`),
     * canonical phase order, only phases that hold items — so an item edited
     * or unmarked after the request never changes the approval page. Null
     * when any item has no snapshot (a backfilled round): the caller falls
     * back to the live payload.
     *
     * @return array<string, mixed>|null
     */
    private function frozenKvDocument(StudioFile $file, Approval $approval, string $brandSlug): ?array
    {
        $approval->loadMissing('items');
        $items = $approval->items;

        if ($items->isEmpty() || $items->contains(fn ($item): bool => $item->snapshot === null)) {
            return null;
        }

        $phases = [];
        foreach (KvSharePayloadService::PHASES as $phase) {
            $snapshots = $items->where('phase', $phase)->sortBy('position')->pluck('snapshot')->values()->all();
            if ($snapshots !== []) {
                $phases[] = ['phase' => $phase, 'items' => $snapshots];
            }
        }

        return [
            'name' => $file->name,
            'brand_slug' => $brandSlug,
            'phases' => $phases,
        ];
    }
```

- [ ] **Step 5: Run — expect PASS (4 passed)**

Same command as Step 2.

- [ ] **Step 6: Mutation check**

1. In `document()` always return `$this->kvPayload->build(…)` → *"the KV document is frozen…"* must FAIL (edited image appears). Restore.
2. In `frozenKvDocument()` delete the `$items->contains(… === null)` guard → *"a round without snapshots…"* must FAIL (document phases become `[[null]]`/wrong). Restore.
3. In `show()` set `'items' => []` unconditionally → *"C-1 lists the round items…"* must FAIL. Restore.

- [ ] **Step 7: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && php -l app/Http/Resources/Approval/ApprovalPresenter.php && php -l app/Http/Controllers/Api/PublicShareLinkController.php && php -l tests/Feature/Approval/PublicShareLinkItemsTest.php && vendor/bin/pint --test app/Http/Resources/Approval/ApprovalPresenter.php app/Http/Controllers/Api/PublicShareLinkController.php tests/Feature/Approval/PublicShareLinkItemsTest.php && git add app/Http/Resources/Approval/ApprovalPresenter.php app/Http/Controllers/Api/PublicShareLinkController.php tests/Feature/Approval/PublicShareLinkItemsTest.php && git commit -m "feat(api): serve approval round items and a frozen KV document on the share-link resolver"
```

---

### Task 7: C-9 — `kv_phases` on store, `items` on the agency shape

**Files:**
- Modify: `app/Http/Controllers/Api/Approval/ApprovalController.php` (imports 9-25, `index()` 57-61, `store()` 74-119)
- Modify: `app/Http/Resources/Approval/ApprovalPresenter.php` (`approval()` 27-100; add `agencyItems()`)
- Test: `tests/Feature/Approval/ApprovalControllerItemsTest.php`

**Interfaces:**
- Consumes: `ApprovalService::request(…, kvPhases:)`, `NothingReadyException`, `TooManyItemsException` (Task 3), `ApprovalItem::thumbnailUrl()` (Task 1), presenter decision `item_id` (Task 4), `KvSharePayloadService::PHASES`.
- Produces: `POST v1/approvals` accepts `kv_phases`; coded 422s `nothing_ready`, `too_many_items` (+`max`); agency approval shape gains `items: list<{id, phase, label, version_id, status, thumbnail_url}>`; `ApprovalPresenter::agencyItems(Approval $approval): array`.

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Approval/ApprovalControllerItemsTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Enums\KvResizeExportStatus;
use App\Models\Brand;
use App\Models\KvResizeExport;
use App\Models\Role;
use App\Models\StudioFile;
use App\Models\Tool;
use App\Models\User;
use App\Models\Workspace;
use App\Services\Approval\ApprovalActor;
use App\Services\Approval\ApprovalService;
use App\Services\Studio\KvReadyToShareService;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Str;
use Tests\Support\ClientLaneFixtures;

// Same auth setup as tests/Feature/Studio/KvShareLinkTest.php (see its
// comment): ONE `owner` role with scope `internal` clears both the
// scope_role middleware and the studio file policy.
beforeEach(function () {
    Mail::fake();

    $this->workspace = Workspace::factory()->create(['type' => 'organization']);
    $this->user = User::factory()->create();
    $this->user->update(['current_workspace_id' => $this->workspace->id]);
    $this->user->workspaces()->attach($this->workspace->id);

    $ownerRole = Role::firstOrCreate(['slug' => 'owner'], ['name' => 'Owner']);
    $ownerRole->forceFill(['type' => 'workspace', 'scope' => 'internal'])->save();
    $this->user->roles()->attach($ownerRole->id, ['workspace_id' => $this->workspace->id]);

    $this->brand = Brand::factory()->create(['workspace_id' => $this->workspace->id]);
    $tool = Tool::query()->where('slug', 'kv-generator')->first() ?? Tool::factory()->create(['slug' => 'kv-generator']);
    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => $this->brand->id,
        'tool_id' => $tool->id,
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
        'metadata' => null,
    ]);
    $this->actingAs($this->user, 'api');
});

test('POST v1/approvals freezes the selected stages and returns the items', function () {
    $board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $clip = ClientLaneFixtures::motionExport($this->file, $this->user, $board);
    ClientLaneFixtures::markReady('kv_generation', $board->id, $this->user);
    ClientLaneFixtures::markReady('kv_motion_export', $clip->id, $this->user);

    $items = $this->postJson('/api/v1/approvals', [
        'subject_type' => 'kv_file',
        'subject_id' => $this->file->id,
        'kv_phases' => ['craft', 'motion'],
    ])->assertCreated()->json('data.approval.items');

    expect($items)->toHaveCount(2)
        ->and(array_keys($items[0]))->toBe(['id', 'phase', 'label', 'version_id', 'status', 'thumbnail_url'])
        ->and($items[0])->toMatchArray(['phase' => 'craft', 'label' => 'Craft · Hero board', 'status' => 'pending', 'thumbnail_url' => 'https://cdn.test/board-1.png'])
        ->and($items[1])->toMatchArray(['phase' => 'motion', 'status' => 'pending', 'thumbnail_url' => null]);
});

test('kv_file needs exactly one of kv_phases or kv_ready_item_id, and kv_phases is KV-only', function () {
    $base = ['subject_type' => 'kv_file', 'subject_id' => $this->file->id];

    $this->postJson('/api/v1/approvals', $base)
        ->assertUnprocessable()->assertJsonValidationErrors('kv_ready_item_id');
    $this->postJson('/api/v1/approvals', [...$base, 'kv_phases' => ['craft'], 'kv_ready_item_id' => str_repeat('a', 26)])
        ->assertUnprocessable()->assertJsonValidationErrors('kv_ready_item_id');
    $this->postJson('/api/v1/approvals', [...$base, 'kv_phases' => []])
        ->assertUnprocessable()->assertJsonValidationErrors('kv_phases');
    $this->postJson('/api/v1/approvals', [...$base, 'kv_phases' => ['storyboard']])
        ->assertUnprocessable()->assertJsonValidationErrors('kv_phases.0');
    $this->postJson('/api/v1/approvals', [...$base, 'kv_phases' => ['craft', 'craft']])
        ->assertUnprocessable()->assertJsonValidationErrors('kv_phases.0');
    $this->postJson('/api/v1/approvals', ['subject_type' => 'deck', 'subject_id' => strtolower((string) Str::ulid()), 'kv_phases' => ['craft']])
        ->assertUnprocessable()->assertJsonValidationErrors('kv_phases');
});

test('nothing ready and too many items come back as coded 422s', function () {
    $this->postJson('/api/v1/approvals', ['subject_type' => 'kv_file', 'subject_id' => $this->file->id, 'kv_phases' => ['sketch']])
        ->assertStatus(422)
        ->assertJson(['code' => 'nothing_ready']);

    $board = ClientLaneFixtures::board($this->file, $this->user);
    $tiles = KvResizeExport::factory()->count(51)->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $board->id,
        'created_by' => $this->user->id,
        'status' => KvResizeExportStatus::Done,
        'image_url' => 'https://cdn.test/tile.png',
    ]);
    app(KvReadyToShareService::class)->markAll('kv_resize_export', $tiles->pluck('id')->all(), $this->user);

    $this->postJson('/api/v1/approvals', ['subject_type' => 'kv_file', 'subject_id' => $this->file->id, 'kv_phases' => ['resize']])
        ->assertStatus(422)
        ->assertJson(['code' => 'too_many_items', 'max' => 50]);
});

// Review Focus 2
test("GET v1/approvals lists each round's items with thumbnails and decisions with item_id", function () {
    $board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $psdTile = ClientLaneFixtures::resizeTile($this->file, $this->user, $board, imageUrl: null);
    $clip = ClientLaneFixtures::motionExport($this->file, $this->user, $board);
    ClientLaneFixtures::markReady('kv_generation', $board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $psdTile->id, $this->user);
    ClientLaneFixtures::markReady('kv_motion_export', $clip->id, $this->user);

    $approval = ClientLaneFixtures::requestKv($this->file, $this->user, ['craft', 'resize', 'motion'])['approval'];
    app(ApprovalService::class)->decide($approval, ApprovalActor::guest('Bayu', 'bayu@brand.test'), ['outcome' => 'approved'], notify: false);

    $round = $this->getJson("/api/v1/approvals?subject_type=kv_file&subject_id={$this->file->id}")->assertOk()->json('data.0');

    expect(array_column($round['items'], 'phase'))->toBe(['craft', 'resize', 'motion'])
        ->and(array_column($round['items'], 'thumbnail_url'))->toBe(['https://cdn.test/board-1.png', null, null])
        ->and(array_column($round['items'], 'status'))->toBe(['approved', 'approved', 'approved'])
        ->and($round['decisions'][0]['item_id'])->toBeNull();
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalControllerItemsTest.php --compact
```
Expected: FAIL — the store test gets `422` with `errors.kv_ready_item_id` (kv_phases unknown to validation); the index test has no `items` key. If ANY test fails with 401/403 instead, the auth setup drifted from `KvShareLinkTest.php` — re-copy its `beforeEach` (lines 24-59) rather than changing the controller.

- [ ] **Step 3: Presenter agency items**

In `ApprovalPresenter::approval()`: change line 29 to

```php
        $approval->loadMissing($agency ? ['decisions.actor:id,name', 'items'] : ['decisions.actor:id,name']);
```

inside `if ($agency) { … }` (lines 92-97) add `$out['items'] = self::agencyItems($approval);` after `$out['created_at'] = …;`, and add this method after `items()`:

```php
    /**
     * The round's items for the agency sheet / status block (C-9,
     * multi-item spec §5.5): no snapshot, just the still to show.
     *
     * @return list<array{id: string, phase: string, label: string, version_id: string, status: string, thumbnail_url: string|null}>
     */
    public static function agencyItems(Approval $approval): array
    {
        $approval->loadMissing('items');

        return $approval->items
            ->map(fn (ApprovalItem $item): array => [
                'id' => $item->id,
                'phase' => $item->phase,
                'label' => $item->label,
                'version_id' => $item->version_id,
                'status' => $item->status,
                'thumbnail_url' => $item->thumbnailUrl(),
            ])
            ->values()
            ->all();
    }
```

Update the class docblock sentence "C-9 adds `subject_type`, `subject_id`, `share_link_id` on top" to "C-9 adds `subject_type`, `subject_id`, `share_link_id`, `created_at` and `items` on top".

- [ ] **Step 4: Controller**

4a. Imports: add

```php
use App\Exceptions\Approval\NothingReadyException;
use App\Exceptions\Approval\TooManyItemsException;
use App\Services\Studio\KvSharePayloadService;
```

4b. `index()` line 59: `->with('decisions.actor:id,name')` becomes `->with(['decisions.actor:id,name', 'items'])`.

4c. `store()` validation: replace the `'kv_ready_item_id' => [ … ],` entry (lines 80-84) with:

```php
            // KV: exactly one of `kv_phases` (multi-item spec §5.1) or the
            // legacy `kv_ready_item_id`; both prohibited for other subjects.
            'kv_ready_item_id' => [
                Rule::requiredIf(fn () => $request->input('subject_type') === 'kv_file' && $request->input('kv_phases') === null),
                Rule::prohibitedIf(fn () => $request->input('subject_type') !== 'kv_file' || $request->input('kv_phases') !== null),
                'nullable', 'string', 'size:26',
            ],
            'kv_phases' => [
                Rule::prohibitedIf(fn () => $request->input('subject_type') !== 'kv_file'),
                'nullable', 'array', 'min:1',
            ],
            'kv_phases.*' => ['string', 'distinct', Rule::in(KvSharePayloadService::PHASES)],
```

4d. The `request(` call (lines 96-102) gains a named argument after `$validated['kv_ready_item_id'] ?? null,`:

```php
                kvPhases: $validated['kv_phases'] ?? null,
```

4e. Add catches after the `RoundConflictException` catch (line 118):

```php
        } catch (NothingReadyException $e) {
            return response()->json([
                'code' => NothingReadyException::CODE,
                'message' => $e->getMessage(),
            ], 422);
        } catch (TooManyItemsException $e) {
            return response()->json([
                'code' => TooManyItemsException::CODE,
                'max' => $e->max,
                'message' => $e->getMessage(),
            ], 422);
```

- [ ] **Step 5: Run — expect PASS (4 passed)**

Same command as Step 2.

- [ ] **Step 6: Mutation check**

1. Remove `'distinct'` from `kv_phases.*` → the duplicate-phase assertion in *"kv_file needs exactly one…"* must FAIL. Restore.
2. In `ApprovalItem::thumbnailUrl()` replace `$snapshot['image_url'] ?? null` with `$snapshot['image_url'] ?? $snapshot['video_url'] ?? 'about:blank'` and delete the motion guard → *"GET v1/approvals lists…"* must FAIL (motion and the layer-composed tile get non-null thumbnails). Restore.
3. Delete the `TooManyItemsException` catch → *"nothing ready and too many items…"* must FAIL with a 500. Restore.

- [ ] **Step 7: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && php -l app/Http/Controllers/Api/Approval/ApprovalController.php && php -l app/Http/Resources/Approval/ApprovalPresenter.php && php -l tests/Feature/Approval/ApprovalControllerItemsTest.php && vendor/bin/pint --test app/Http/Controllers/Api/Approval/ApprovalController.php app/Http/Resources/Approval/ApprovalPresenter.php tests/Feature/Approval/ApprovalControllerItemsTest.php && git add app/Http/Controllers/Api/Approval/ApprovalController.php app/Http/Resources/Approval/ApprovalPresenter.php tests/Feature/Approval/ApprovalControllerItemsTest.php && git commit -m "feat(api): request approval by KV phases and list round items for the agency"
```

---

### Task 8: Notifier and mail labels

**Files:**
- Modify: `app/Services/Approval/ApprovalNotifier.php` (`decided()` 88-129, `versionLabel()` 210-213)
- Modify: `app/Mail/ApprovalDecidedMail.php` (constructor 20-29)
- Modify: `resources/views/emails/client-lane/approval-decided.blade.php` (line 12)
- Test: `tests/Feature/Approval/ApprovalNotifierLabelTest.php`

**Interfaces:**
- Consumes: `Approval::items()` (Task 1), `ApprovalService::decide()` (Task 4), `ClientLaneFixtures::roundWithItems()`.
- Produces: `public ApprovalNotifier::versionLabel(Approval $approval): string`; `ApprovalDecidedMail::$itemCount` (`public int $itemCount = 1`, last constructor param). `ApprovalRequestMail` is unchanged — it receives the new label string through `versionLabel`.

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Approval/ApprovalNotifierLabelTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Mail\ApprovalDecidedMail;
use App\Models\Approval;
use App\Models\Comment;
use App\Services\Approval\ApprovalActor;
use App\Services\Approval\ApprovalNotifier;
use App\Services\Approval\ApprovalService;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

test('the version label names the item count only when there is more than one', function () {
    $notifier = app(ApprovalNotifier::class);

    expect($notifier->versionLabel(ClientLaneFixtures::roundWithItems(['101'], ['round' => 2])))->toBe('v2')
        ->and($notifier->versionLabel(ClientLaneFixtures::roundWithItems(['101', '102', '103'], ['round' => 2])))->toBe('v2 · 3 items')
        ->and($notifier->versionLabel(Approval::factory()->create(['round' => 4])))->toBe('v4');
});

test('the decided mail carries the multi-item label and the total pin count', function () {
    Mail::fake();
    $round = ClientLaneFixtures::roundWithItems(['101', '102', '103']);
    $pins = collect(['101', '103'])->map(fn (string $version) => Comment::query()->create([
        'commentable_type' => $round->subject_type,
        'commentable_id' => $round->subject_id,
        'anchor' => ['kind' => 'pin', 'id' => "deck-canvas:{$version}:slide-1", 'x' => 0.5, 'y' => 0.5],
        'body' => 'Fix this',
        'guest_name' => 'Bayu',
        'guest_email' => 'bayu@brand.test',
        'internal_only' => false,
    ])->id)->all();

    app(ApprovalService::class)->decide(
        $round,
        ApprovalActor::guest('Bayu', 'bayu@brand.test'),
        ['outcome' => 'changes_required', 'note' => 'See pins', 'pins' => $pins],
    );

    Mail::assertQueued(ApprovalDecidedMail::class, fn (ApprovalDecidedMail $mail): bool => $mail->versionLabel === 'v1 · 3 items'
        && $mail->pinCount === 2
        && $mail->itemCount === 3);
});

test('the decided mail says where the pins are', function () {
    $args = [
        'headline' => 'Bayu requested changes',
        'title' => 'Ramadan hero KV',
        'brandName' => 'Garuda',
        'note' => null,
        'pinCount' => 2,
        'editorUrl' => 'https://app.test/x',
    ];

    (new ApprovalDecidedMail(...$args, versionLabel: 'v1 · 3 items', itemCount: 3))
        ->assertSeeInHtml('2 pins left across 3 items.');
    (new ApprovalDecidedMail(...$args, versionLabel: 'v1', itemCount: 1))
        ->assertSeeInHtml('2 pins left on this version.');
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalNotifierLabelTest.php --compact
```
Expected: FAIL — `Call to private method App\Services\Approval\ApprovalNotifier::versionLabel()`; `Unknown named parameter $itemCount`.

- [ ] **Step 3: Implement**

3a. `ApprovalNotifier::versionLabel()` (lines 210-213) becomes (public, moved above `mailApprovers()` is optional — keep it where it is):

```php
    /**
     * `v{round}`, or `v{round} · {n} items` for a multi-item round (spec
     * §5.6) — flows into both mails' subjects/headers and the inbox label.
     */
    public function versionLabel(Approval $approval): string
    {
        $count = $approval->items()->count();

        return $count > 1 ? "v{$approval->round} · {$count} items" : 'v'.$approval->round;
    }
```

3b. In `decided()`, the `new ApprovalDecidedMail(…)` call (lines 117-125) gains, after `editorUrl: …,`:

```php
                itemCount: max(1, $approval->items()->count()),
```

3c. `ApprovalDecidedMail` constructor: after `public string $editorUrl,` add

```php
        /** Items in the round; >1 switches the pin line to "across {n} items". */
        public int $itemCount = 1,
```

3d. `resources/views/emails/client-lane/approval-decided.blade.php` line 12 becomes (one line — Blade directives must not wrap):

```blade
@section('footnote', $pinCount > 0 ? "{$pinCount} " . ($pinCount === 1 ? 'pin' : 'pins') . ($itemCount > 1 ? " left across {$itemCount} items." : ' left on this version.') : ($itemCount > 1 ? "No pins across {$itemCount} items." : 'No pins on this version.'))
```

- [ ] **Step 4: Run — expect PASS (3 passed)**

Same command as Step 2.

- [ ] **Step 5: Mutation check**

1. In `versionLabel()` change `$count > 1` to `$count > 0` → *"the version label names the item count…"* must FAIL on the one-item case. Restore.
2. Remove `itemCount: …` from `decided()` → *"the decided mail carries…"* must FAIL (`itemCount` stays 1). Restore.
3. In the blade swap the two footnote strings → *"the decided mail says where the pins are"* must FAIL. Restore.

- [ ] **Step 6: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && php -l app/Services/Approval/ApprovalNotifier.php && php -l app/Mail/ApprovalDecidedMail.php && php -l tests/Feature/Approval/ApprovalNotifierLabelTest.php && vendor/bin/pint --test app/Services/Approval/ApprovalNotifier.php app/Mail/ApprovalDecidedMail.php tests/Feature/Approval/ApprovalNotifierLabelTest.php && git add app/Services/Approval/ApprovalNotifier.php app/Mail/ApprovalDecidedMail.php resources/views/emails/client-lane/approval-decided.blade.php tests/Feature/Approval/ApprovalNotifierLabelTest.php && git commit -m "feat(api): multi-item version label and pin count in approval mail and inbox"
```

---

### Task 9: Final gates + track file

**Files:**
- Create: `docs/tracks/client-lane-multi-item.track.md`

**Interfaces:**
- Consumes: everything above.
- Produces: a green branch ready for review, and the track file.

- [ ] **Step 1: Static gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && git diff --name-only develop...HEAD -- '*.php' | xargs -n1 php -l && vendor/bin/pint --test $(git diff --name-only develop...HEAD -- '*.php')
```
Expected: `No syntax errors` for every file; pint passes.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && php artisan route:list --path=approvals && php artisan route:list --path=public/share-links
```
Expected: `approvals.index|store|withdraw|resend` and the four `public/share-links/{token}…` routes, unchanged.

- [ ] **Step 2: Run every new test file in one process, then the touched legacy suites**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && ls bootstrap/cache/config.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalItemsMigrationTest.php tests/Feature/Approval/KvSharePayloadItemsForTest.php tests/Feature/Approval/ApprovalRequestItemsTest.php tests/Feature/Approval/ApprovalDecideItemsTest.php tests/Feature/Approval/ApprovalPinsMembershipTest.php tests/Feature/Approval/PublicShareLinkItemsTest.php tests/Feature/Approval/ApprovalControllerItemsTest.php tests/Feature/Approval/ApprovalNotifierLabelTest.php --compact
```
Expected: all pass (≈ 45 tests).

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/KvShareLinkTest.php --compact && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/CampaignPlan/CampaignPlanCrudTest.php --compact && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Unit/CampaignPlan/PlanApprovalTest.php --compact
```
Expected: same results as on `develop` (plan approvals now also write one `plan` item through `request()`; any NEW failure here is yours).

- [ ] **Step 3: Dev DB migration (ask first)**

Ask Daffa (AskUserQuestion) whether to migrate the dev DB `frnd` now. Only on yes:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && TELESCOPE_ENABLED=false php artisan migrate && psql -d frnd -c "select count(*) as rounds, (select count(*) from approval_items) as items from approvals"
```
Expected: `rounds = items` (one backfilled item per pre-existing round).

- [ ] **Step 4: Write the track file**

Create `docs/tracks/client-lane-multi-item.track.md`:

```markdown
---
prd: client-lane-multi-item-approval
parent_prd: docs/superpowers/specs/2026-09-30-client-lane-multi-item-approval-design.md
service: api
branch: feature/daffa/vc-client-lane-multi-item
pr_url: null
status: in_progress
---

# Track — Client Lane multi-item approval rounds (api)

Plan: `docs/superpowers/plans/2026-09-30-client-lane-multi-item-api.md` (workspace root).
Contract: additive notes in `docs/prd/client-lane-p0a/api.md` (identical copy in web) — awaiting Jeff's review.
Tests: `DB_CONNECTION=pgsql DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest <file>` — file paths only, one process at a time.

## Status

| Item | Status |
|------|--------|
| Wireframe | n/a (api) |
| PRD | spec approved in chat 2026-09-30; contract notes pending Jeff |
| Service PRD | additive contract notes committed |
| Implementation | completed (api) |
| PR | not_submitted |

## Task Checklist

- [x] TASK-0: Branch + additive contract notes (C-1, C-3, C-4/5, C-9, mail)
- [x] TASK-1: `approval_items` + `approval_decisions.approval_item_id` + backfill (reversible) + model/factory/fixtures
- [x] TASK-2: `KvSharePayloadService::itemsFor()` / `resolvePhase()` extraction (view links byte-identical)
- [x] TASK-3: `request()` freezes N items (`kv_phases`, legacy `kv_ready_item_id`, deck/plan one item, `nothing_ready`, `too_many_items`, link phase union, supersede retires items)
- [x] TASK-4: item statuses — round cascade, item-level decisions + aggregate, withdraw, C-3 `item_id` / `invalid_item`
- [x] TASK-5: pins + comments across the round's item versions
- [x] TASK-6: C-1 `items` + frozen KV document from snapshots
- [x] TASK-7: C-9 `kv_phases` validation, coded 422s, agency `items` with thumbnails
- [x] TASK-8: `v{round} · {n} items` label + decided-mail pin count
- [x] TASK-9: gates + this file

## Session Log

### 2026-09-30 — daffa (plan executor)
- Implemented TASK-0 … TASK-9 per the plan; all new Approval test files green on the scratch DB.
- Known consequence (by design, flagged for review): resize `version_id` is the stable row id, so round-1 pins on a tile also list in round 2.
- Next: Jeff's review of the contract notes; web branch consumes the contract; manual smoke (1 craft board + 3 resize tiles, phone + laptop).
```

Fill the Session Log line with the real pass counts and anything that deviated from the plan (including pre-existing failures observed in Step 2).

- [ ] **Step 5: Restore the route cache if it was moved, then commit**

If Global Constraints step 2 moved `bootstrap/cache/routes-v7.php`, do NOT restore a stale route cache (it 405s new routes); leave it deleted and tell Daffa.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && git add docs/tracks/client-lane-multi-item.track.md && git commit -m "docs(api): track file for client-lane multi-item approval rounds" && git log --oneline develop..HEAD
```
Expected: 10 commits (Task 0 … Task 9). Do not push or open a PR — Daffa pushes manually after Jeff acks the contract.

---

## Spec coverage (self-review)

| Spec | Task |
|---|---|
| §4.1 `approval_items` table, indexes, CHECK | 1 |
| §4.2 `approval_decisions.approval_item_id` | 1 |
| §4.3 status semantics (round cascade, per-item + aggregate, policy/deferral round-level) | 4 |
| §4.4 `subject_version_*` = first item; deck/plan one item | 3 |
| §5.1 `kv_phases`, legacy id, `nothing_ready`, `too_many_items`, freeze before lock, link phase union, `itemsFor` extraction | 2, 3, 7 |
| §5.2 C-1 `items`, `version` unchanged, frozen KV document, `can_decide` unchanged | 6 |
| §5.3 comments/pins/storeComment membership, anchor format | 5 |
| §5.4 C-3 `item_id` | 4 |
| §5.5 agency `items` + `thumbnail_url`, decisions `item_id` | 4, 7 |
| §5.6 version label + decided-mail pin count | 8 |
| §8 migrations 1–3, reversible backfill, `TELESCOPE_ENABLED=false`, contract-first commit | 0, 1, 9 |
| §9 api tests (freeze, rendered ids, caps, legacy, round/item decisions incl. four aggregates, pins in/out, round 2, C-1 shape, frozen document, comments across items, anchor validation, byte-identical 404, backfill up/down) | 1–8 |
| §6, §7 (web, analytics) | web plan — not api |
