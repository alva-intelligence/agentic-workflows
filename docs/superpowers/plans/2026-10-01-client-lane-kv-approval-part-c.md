# Client Lane KV Approval Requests — Part C (Comments dock, client comments, Team only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In KV's agency Comments dock, the team can see which threads a client wrote in, filter to them or to Team-only threads, and choose per post whether the client sees it. A new team thread on an artboard the client is reviewing starts Team only. Client pins get a yellow face ring. On the client page, agency replies the viewer has not seen yet are marked New.

**Architecture:** The api already labels authors (`Comment::toArray` adds `author.guest` / `author.external`, and `CommentPosted::broadcastWith` does the same). Task 1 pins that with a Pest test. On web, the flag reaches `CommentAuthor.external` through the three mappers (REST `mapComment`, realtime `normalizeWireComment`, public `publicThreads`), and `internalOnly` reaches the KV post. All the rules are pure helpers: `commentVisibility.ts` (client thread, per-thread visibility) and `pendingArtboards.ts` (which anchors sit on an artboard pending in an open request). The UI pieces take these as **opt-in props**: `CommentSidePanel.clientLane`, `CommentThread.visibility` / `newCommentIds`, `CommentThreadPopover.visibility` / `draftVisibility`, and `CommentPinOverlay.markClientFaces`. Only `KvGeneratorLayout` passes them, through `useKvClientVisibility`, and only while `show-client-lane` is on. The deck dock (`AnchoredComments`) passes none, so it is unchanged, and Task 6 has a regression test for that. The client page adds `useNewAgencyReplies`, which keeps the reply ids seen per token in `localStorage`, plus a "New" chip in `CommentThread`.

**Tech Stack:** Laravel 13 / Pest (api); Next.js 16, React 19, TypeScript, Tailwind 3.4, TanStack Query v5, `@base-ui/react` (frndOS v2) + frndOS v1 `Label`/`Avatar`, PostHog (`posthog-js`), `bun test` + Testing Library (web).

**Spec:** `docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md`. This plan implements §6.2 (Part C) under §11. Part A is already on the branch (fast mode, untested), and this plan reads its code. Parts B and D are out of scope.

## Global Constraints

- **Worktrees:** web `/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item` and api `/Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item`. Both are on branch `feature/daffa/vc-client-lane-multi-item`, which is unpushed, so keep working on it. Agent shells reset cwd, so every command `cd`s into the literal path. Base tips when this plan was written: web `752323bba`, api `646f2b29a`.
- **Git:** use `/usr/bin/git` and `/usr/bin/grep` (an rtk hook rewrites plain `git`/`grep`). The shell is zsh, so put file lists in arrays (`F=(a b); npx eslint "${F[@]}"`). **Never push. Never `git stash`.** If a tree is dirty at the start, stop and ask Daffa.
  - **Web commits:** `<type>(web): …`, ending with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - **Api commits:** `<type>(api): …` with **no** Co-Authored-By line.
- **Api tests:** api/AGENTS.md forbids making or running tests without Daffa's permission. Task 0 asks **once** for the named files. Run only on the scratch DB `frnd_testing`, one file at a time:
  `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest <file> --compact`.
  Never use the dev DB `frnd`. A `bootstrap/cache/config.php` or `routes-v7.php` takes over the DB connection, so Task 0 checks for them. Run `vendor/bin/pint --format agent <files>` before each api commit.
- **Web tests:**
  - Run `bun test <file>`, ONE file per invocation. Never a directory, never `bunx vitest`.
  - Query with `within(document.body)`, never `screen`.
  - **Never `vi.mock` a module.** Spy on the edges instead: `vi.spyOn(axiosInstance, …)` (`import axiosInstance from "@/services/axios"`), `vi.spyOn(axiosPublic, …)`, `vi.spyOn(posthog, "capture")` (`import posthog from "posthog-js"`), `vi.spyOn(Storage.prototype, …)`. Restore every spy in `afterEach(() => vi.restoreAllMocks())`.
  - bun has no `vi.waitFor`, `vi.hoisted` or `vi.mocked`. Use RTL `waitFor` and cast mocks.
  - Keep every test file under ~45 KB.
  - Anything that renders `CommentComposer` (and so `CommentThread` replies, the dock and the popover) needs a `QueryClientProvider`. Create the client with `useState` in a wrapper component, never per render.
  - jsdom has no `Range.getBoundingClientRect`. Stub it on `Range.prototype` inside `try/finally` around every `user.type` into the mention editor (helper given in Task 6).
  - `useAnchoredComments` calls `useAuth()`, which throws without a provider. Wrap with `<AuthContext.Provider value={{ user: null } as never}>`.
- **Mutation check:** after a new test passes, break the rule exactly as the step says, watch the NAMED test fail, restore it, and watch it pass. Every test or mutation step is marked **(test)** in its title. Daffa may execute in fast mode, skipping those steps; the code steps must still be complete without them.
- **Type gate:** `npx tsc --noEmit -p .` has a baseline of **895** errors (re-measured in Task 0). Every touched file must have **0** errors, except `KvGeneratorLayout.tsx`, which keeps its **1** pre-existing error and gains none (per-file counts in Task 0). `npx eslint <touched files>` must be clean. Run `bunx prettier --write <touched files>` before each web commit.
- **frndOS UI (spec §11):** before any UI task, read `web/.agents/skills/frndos-ui/SKILL.md`, `frndos-components-v2/SKILL.md`, `frndos-design-foundations/SKILL.md` (§Appearance, Daylight rules) and `frndos-rules/SKILL.md`.
  - **Priority:** v2 → v1 → base → new v2 (with a story, an export and a skill row). This plan needs **no new v2 component**.
  - **Component map** (§11.2): the Client and Team-only labels and the client-page "New" marker are v1 `Label`. The reply visibility toggle is v2 `Button` (text, tiny, `leftIcon` eye or lock). The Client pill uses the dock's existing `PillTabs`. The Visibility group uses the dock's existing `Dropdown` + `FilterCheckbox`. Faces are v1 `Avatar`.
- **No v1/v2 mix in a new file.** v1 `Label` is used only through a new v1-only wrapper, `src/components/comments/CommentChips.tsx`. The toggle file imports only v2.
  - Ruling: the existing dock files (`CommentSidePanel`, `CommentThread`, `CommentPinOverlay`) already import both generations from before §11. They stay as they are, without a refactor. This plan adds no new direct v1 import to a file that imports v2.
- **Tokens only on every line this plan writes:**
  - text: `text-text-inverse*`, `text-textXs` / `text-textXsMedium` / `text-textSm`, `font-geist`;
  - shape and surface: `rounded-*`, `bg-white/5|10|15`, `border-white/10`;
  - colour: palette yellow (`ring-yellow-400`) for the client accent, matching `Label variant="alert" dark`.
  Never `text-[Npx]`, `rounded-[Npx]`, `px-[Npx]`, `text-white`, `text-gray-*`, or a new dark hex. Existing arbitrary values on untouched lines stay. The agency dock must read right in **Midnight, Aurora and Daylight**. `/s/` stays dark-scoped.
- **Deck unchanged:** the dock, thread, popover and pin overlay are shared with decks (`AnchoredComments`), pitches and research surfaces. Every new behaviour is opt-in. Without the new props, the markup and callback arities are byte-for-byte today's (regression tests in Tasks 5, 6, 7, 8). On the client page, the "New" marker is gated to `kv_file` (spec D-2: decks and plans untouched).
- **Analytics** goes through typed helpers in `src/lib/analytics/client-lane-events.ts` (spec §11.1), never an inline `posthog.capture`. The events are named exactly as spec §6.2: `comments.client_filter_used`, `comments.reply_visibility_toggled`, `comments.team_only_thread_created`. Each gets a row in the Lark taxonomy (Task 11).
- **Flag:** the agency side is behind `show-client-lane`. `KvGeneratorLayout` already reads it as `clientLaneOn`. Do not add a new named import from `@/lib/featureFlags`; that module is widely mocked.

## Review Focus

These are five inputs the spec implies but its happy path does not exercise, most likely to bite first. Each has a named test in its owning task.

1. **Resize-tile anchors are lower-cased.** `slugPart` lower-cases the part segment, so a tile pin's anchor reads `tile.01jabc…` while the approval's `subject_key` reads `resize:01JABC…`. A case-sensitive match silently never defaults to Team only on Resize. → Task 3, `pendingArtboards` test "matches a resize tile pin whose slugged part is lower-case".
2. **The Client filter is active when the last client thread leaves scope** (deleted, or the stage tab changed). If the pill hides while selected, the dock shows an empty list with no visible way out of the filter. → Task 6, "keeps the Client pill while it is the active filter, even with no client thread left".
3. **The approval-requests query resolves after the draft composer opened**, or the artboard becomes pending mid-draft. The default must follow the data until the reviewer touches the toggle, and never override a choice they made. → Task 7, "starts Team only when the pending state arrives after the draft opened" and "keeps the reviewer's choice when the default changes".
4. **A reply on a Team-only thread.** The api hides every reply under an internal root, so a "Client sees this" toggle there would lie. The reply must post `internal_only: true`, with a static Team-only hint and no toggle. → Task 6, "keeps replies on a Team only thread team only, with no toggle".
5. **Client page `localStorage` blocked or corrupt.** Blocked storage must not mark every agency reply New on every visit; corrupt JSON reads as "nothing seen". → Task 10, `seenReplies` tests "reads null when storage is blocked" and "treats corrupt storage as nothing seen".

---

## File Structure

### api — `/Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item`

| File | Status | Responsibility |
|---|---|---|
| `tests/Feature/Comment/KvCommentAuthorFlagsTest.php` | create | Pins that the agency KV comment listing, store and broadcast carry `author.guest` / `author.external` and `internal_only` |
| `app/Models/Comment.php` | modify **only if** Task 1's test fails | `toArray()` author flags (already present at lines 164–186 when this plan was written) |
| `docs/tracks/client-lane-multi-item.track.md` | modify | Part C line + permission record |

### web — `/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item`

| File | Status | Responsibility |
|---|---|---|
| `src/types/comments/index.ts` | modify | `CommentAuthor.external?` |
| `src/services/query.ts` | modify | `CommentServerJson.author` gains `id: string \| null`, `guest?` and `external?`; `mapComment` sets `external` and gives a guest the id `guest:{name}` |
| `src/lib/deck/reverb.ts` | modify | `WireCommentPayload.author` gains `guest?` and `external?` |
| `src/hooks/comments/useAnchoredComments.ts` | modify | `normalizeWireComment` sets `external` and the guest id; `PostAnchoredCommentInput.internalOnly` is forwarded |
| `src/hooks/comments/useKvFileComments.visibility.test.tsx` | create | Mapper flags + `internal_only` on the KV post |
| `src/lib/client-lane/commentThreads.ts` (+ test) | modify | Public page keeps `external` |
| `src/components/comments/commentVisibility.ts` (+ test) | create | `PostVisibility`, `ThreadVisibility`, `isClientComment`, `isClientThread`, `threadVisibility` |
| `src/lib/client-lane/pendingArtboards.ts` (+ test) | create | `pendingArtboards`, `isPendingSpec`, `isPendingAnchor`, `requestThreadIds` |
| `src/lib/analytics/client-lane-events.ts` | modify | The three `comments.*` helpers |
| `src/components/comments/CommentChips.tsx` | create | v1-only `ClientChip`, `TeamOnlyChip`, `NewChip` |
| `src/components/comments/CommentVisibilityToggle.tsx` (+ test) | create | v2 "Client sees this / Team only" toggle + `TeamOnlyHint` |
| `src/components/comments/CommentComposer.tsx` (+ new hint test) | modify | `hintText` widens to `ReactNode` |
| `src/components/comments/CommentThread.tsx` | modify | `visibility` (dashed card, reply marker, reply toggle, `onReply` 4th arg) and `newCommentIds` (New chip, collapsed count) |
| `src/components/comments/CommentThread.visibility.test.tsx` | create | Thread tests incl. no-opt-in regression |
| `src/components/comments/CommentSidePanel.tsx` | modify | `clientLane` opt-in: Client label + pill, Visibility › Team only, Team-only label, visibility to threads, `onReply` 5th arg |
| `src/components/comments/CommentSidePanel.clientLane.test.tsx` | create | Dock tests incl. deck regression |
| `src/components/comments/CommentThreadPopover.tsx` (+ new test) | modify | `visibility` pass-through, `draftVisibility` root toggle, team-only-thread event |
| `src/components/comments/CommentPinOverlay.tsx` (+ new test) | modify | `threadParticipants` keeps `external`; `markClientFaces` yellow ring |
| `src/hooks/comments/useKvClientVisibility.ts` (+ test) | create | KV: requests → pending artboards → `requestThreadIds` |
| `src/components/studio/kv-generator/KvGeneratorLayout.tsx` | modify | Wires the opt-in props (flag-gated) and posts `internalOnly` |
| `src/lib/client-lane/seenReplies.ts` (+ test) | create | Seen reply ids per token in `localStorage`; agency reply ids; new ids |
| `src/components/client-lane/useNewAgencyReplies.ts` (+ test) | create | Per-visit frozen "new" set; persists seen ids |
| `src/components/client-lane/PinList.tsx` | modify | `newCommentIds` → `CommentThread` |
| `src/components/client-lane/DecisionPage.tsx` (+ existing test) | modify | Computes and passes New ids (KV only) |
| `docs/tracks/client-lane-multi-item.track.md` | modify | Part C section |

---

### Task 0: Pre-flight — api permission, branches, baselines

**Files:** none changed.

**Interfaces:**
- Consumes: nothing.
- Produces: Daffa's single api test permission (recorded in Task 11), the web baselines (whole-project tsc count + per-file counts for the touched files), and clean trees.

- [ ] **Step 1: Ask for the one api test permission**

Use AskUserQuestion with exactly one question, options "Yes, approved" / "No":

> "api/AGENTS.md says no tests without your permission. Part C (docs/superpowers/plans/2026-10-01-client-lane-kv-approval-part-c.md) needs ONE approval to create and run tests/Feature/Comment/KvCommentAuthorFlagsTest.php on the scratch DB `frnd_testing` only (never `frnd`). It pins that the agency KV comment endpoint already returns `author.guest` / `author.external` and `internal_only`. Approve?"

On anything but "Yes, approved": skip Task 1 Steps 2–5 (write no api test). Record "api author flags: unverified, permission declined" in Task 11 and continue with web.

- [ ] **Step 2: Confirm both branches and clean trees**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git branch --show-current && /usr/bin/git status --short && /usr/bin/git log --oneline -1
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && /usr/bin/git branch --show-current && /usr/bin/git status --short && /usr/bin/git log --oneline -1
```

Expected for both: `feature/daffa/vc-client-lane-multi-item` and no status lines. The tips are `752323bba` (web) and `646f2b29a` (api), or later. If either tree is dirty, stop and ask Daffa.

- [ ] **Step 3: api caches and scratch DB**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/; psql -lqt | cut -d'|' -f1 | /usr/bin/grep -E 'frnd_test'
```

Expected: `bootstrap/cache/` lists only `.gitignore`, `packages.php` and `services.php`, and `frnd_testing` is listed.
- If `config.php` or `routes-v7.php` is present, run `php artisan config:clear && php artisan route:clear` in this worktree.
- If `frnd_testing` is missing, STOP and ask Daffa. Do not create databases.

- [ ] **Step 4: Web baselines**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "src/components/comments/|src/services/query.ts|src/lib/deck/reverb.ts|src/hooks/comments/|src/lib/client-lane/|src/components/client-lane/|src/types/comments/|src/lib/analytics/client-lane-events.ts|KvGeneratorLayout.tsx"
```

Expected: `895`, then exactly one line, in `KvGeneratorLayout.tsx` (the known pre-existing error). Write both numbers down for Task 11. A different count means the baseline moved, so record the new numbers and use them.

- [ ] **Step 5: Existing suites that this plan touches (test)**

Run each on its own and note the pass counts. A pre-existing failure is recorded, not fixed.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/CommentSidePanel.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/CommentThread.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/CommentComposer.drop.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/commentThreads.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/DecisionPage.test.tsx
```

---

### Task 1: api — the KV comment listing carries the client author flags

The spec asks for a check: does the agency comment serialisation carry `guest` / `external`, and if not, add it. When this plan was written, it already did:
- `app/Models/Comment.php:164-186`: `toArray()` gives a guest `{id: null, name, guest: true}` and a lane actor `author.external = true`;
- `app/Events/CommentPosted.php:63-70`: the broadcast does the same.

`CommentController::listComments` (`response()->json(['data' => $rows])`) and `createComment` (`$comment->load('author:id,name,avatar')`) both go through `toArray()`. No test pins any of this, so this task adds a characterisation test. The presenter changes only if that test fails.

**Files:**
- Create: `tests/Feature/Comment/KvCommentAuthorFlagsTest.php`
- Modify (only if Step 3 fails on a flag): `app/Models/Comment.php` (`toArray`)

**Interfaces:**
- Consumes: routes `GET|POST /api/v1/brands/{brand_id}/studio-files/{file}/comments` (`indexForKvFile`, `storeForKvFile`), `ClientLaneLink::factory()`, `CommentPosted`.
- Produces: the wire contract Task 2's mapper reads.
  - Guest: `author: {id: null, name: string, guest: true}`.
  - Lane client: `author: {id, name, avatar, external: true}`.
  - Member: `author: {id, name, avatar}`.
  - Every row: `internal_only: bool`.

- [ ] **Step 1: Write the test (test)**

Create `tests/Feature/Comment/KvCommentAuthorFlagsTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Events\CommentPosted;
use App\Models\Brand;
use App\Models\ClientLaneLink;
use App\Models\Comment;
use App\Models\Role;
use App\Models\StudioFile;
use App\Models\Tool;
use App\Models\User;
use App\Models\Workspace;

/**
 * Client lane Part C (spec 2026-10-01 §6.2): the agency's KV comment endpoints
 * say who is a client, so the Comments dock can label client threads and ring
 * client pins. A guest comes back as `{id: null, name, guest: true}`, a lane
 * client with `external: true`, a member with neither. Characterises
 * Comment::toArray (REST) and CommentPosted::broadcastWith (realtime).
 */
beforeEach(function () {
    $this->workspace = Workspace::factory()->create(['type' => 'organization']);

    $this->user = User::factory()->create(['name' => 'Ana']);
    $this->user->update(['current_workspace_id' => $this->workspace->id]);
    $this->user->workspaces()->attach($this->workspace->id);

    // Same single owner role KvShareLinkTest uses: `owner` slug clears
    // hasFullWorkspaceAccess (CheckPermissions + the `comment` gate), scope
    // `internal` clears CheckRoleScope. forceFill because `scope` is not
    // fillable.
    $ownerRole = Role::firstOrCreate(['slug' => 'owner'], ['name' => 'Owner']);
    $ownerRole->forceFill(['type' => 'workspace', 'scope' => 'internal'])->save();
    $this->user->roles()->attach($ownerRole->id, ['workspace_id' => $this->workspace->id]);

    $this->brand = Brand::factory()->create(['workspace_id' => $this->workspace->id]);
    $tool = Tool::query()->where('slug', 'kv-generator')->first()
        ?? Tool::factory()->create(['slug' => 'kv-generator']);
    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => $this->brand->id,
        'tool_id' => $tool->id,
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
    ]);

    $this->url = "/api/v1/brands/{$this->brand->id}/studio-files/{$this->file->id}/comments";
    $this->actingAs($this->user, 'api');
});

/** A root pin on the file. Unique name: Pest loads every file into one process. */
function kvAuthorFlagsComment(StudioFile $file, array $attrs): Comment
{
    return Comment::query()->create(array_merge([
        'commentable_type' => 'kv_file',
        'commentable_id' => $file->id,
        'anchor' => ['kind' => 'pin', 'id' => 'craft:g1:board.g1', 'x' => 0.5, 'y' => 0.5],
        'body' => 'Logo smaller',
        'mentions' => [],
    ], $attrs));
}

function kvAuthorFlagsLaneClient(object $test): array
{
    $client = User::factory()->create(['name' => 'Bayu']);
    $lane = ClientLaneLink::factory()->create([
        'workspace_id' => $test->workspace->id,
        'brand_id' => $test->brand->id,
        'user_id' => $client->id,
    ]);

    return [$client, $lane];
}

it('marks a guest pin as a guest with no user id and no email', function () {
    kvAuthorFlagsComment($this->file, [
        'author_id' => null,
        'guest_name' => 'Dina',
        'guest_email' => 'dina@brand.test',
    ]);

    $row = $this->getJson($this->url.'?include_resolved=1')->assertOk()->json('data.0');

    expect($row['author'])->toBe(['id' => null, 'name' => 'Dina', 'guest' => true])
        ->and($row)->not->toHaveKey('guest_email');
});

it('marks a lane client as external and keeps their user shape', function () {
    [$client, $lane] = kvAuthorFlagsLaneClient($this);
    kvAuthorFlagsComment($this->file, ['author_id' => $client->id, 'lane_link_id' => $lane->id]);

    $author = $this->getJson($this->url.'?include_resolved=1')->assertOk()->json('data.0.author');

    expect($author['id'])->toBe((string) $client->id)
        ->and($author['name'])->toBe('Bayu')
        ->and($author['external'])->toBeTrue()
        ->and($author)->not->toHaveKey('guest');
});

it('leaves a team member without either flag', function () {
    kvAuthorFlagsComment($this->file, ['author_id' => $this->user->id]);

    $author = $this->getJson($this->url.'?include_resolved=1')->assertOk()->json('data.0.author');

    expect($author)->not->toHaveKey('external')
        ->and($author)->not->toHaveKey('guest');
});

it('stores a team-only post and lists it back to the team', function () {
    $this->postJson($this->url, [
        'body' => 'Internal: swap the logo before Dina looks',
        'anchor' => ['kind' => 'pin', 'id' => 'craft:g1:board.g1', 'x' => 0.2, 'y' => 0.3],
        'internal_only' => true,
    ])->assertCreated()->assertJsonPath('data.internal_only', true);

    $this->getJson($this->url.'?include_resolved=1')
        ->assertOk()
        ->assertJsonPath('data.0.internal_only', true);
});

it('broadcasts the same author flags', function () {
    [$client, $lane] = kvAuthorFlagsLaneClient($this);
    $laneComment = kvAuthorFlagsComment($this->file, ['author_id' => $client->id, 'lane_link_id' => $lane->id]);
    $guestComment = kvAuthorFlagsComment($this->file, [
        'author_id' => null,
        'guest_name' => 'Dina',
        'guest_email' => 'dina@brand.test',
    ]);

    expect((new CommentPosted($laneComment->load('author')))->broadcastWith()['author']['external'])->toBeTrue()
        ->and((new CommentPosted($guestComment))->broadcastWith()['author'])
        ->toBe(['id' => null, 'name' => 'Dina', 'guest' => true]);
});
```

- [ ] **Step 2: Format**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && vendor/bin/pint --format agent tests/Feature/Comment/KvCommentAuthorFlagsTest.php
```

- [ ] **Step 3: Run it (test)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Comment/KvCommentAuthorFlagsTest.php --compact
```

Expected: 5 passed, because the presenter already exists.
- A **403** on the HTTP tests is a setup gap, not a product bug. Compare the `beforeEach` with `tests/Feature/Studio/KvShareLinkTest.php:24-59` and fix the setup only.
- If the **guest / external assertions** fail, the presenter is missing. Add it to `app/Models/Comment.php` (replace the whole `toArray` method) and re-run:

```php
    /**
     * Author shape for guests and lane actors (client lane P0a, C-4) so every
     * existing comment UI renders a guest without a code change:
     *   guest      → `{ id: null, name: guest_name, guest: true }`
     *   lane actor → the user's normal shape plus `external: true`
     *
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        $array = parent::toArray();

        if ($this->isGuestAuthored()) {
            $array['author'] = [
                'id' => null,
                'name' => $this->guest_name ?: 'Guest',
                'guest' => true,
            ];
        } elseif ($this->lane_link_id !== null && isset($array['author']) && is_array($array['author'])) {
            $array['author']['external'] = true;
        }

        return $array;
    }
```

- [ ] **Step 4: Mutation check (test)**

In `app/Models/Comment.php`, comment out the line `$array['author']['external'] = true;`. Re-run Step 3. Expected: "marks a lane client as external and keeps their user shape" FAILS. Restore the line, re-run, and expect 5 passed. Check that `/usr/bin/git diff app/Models/Comment.php` is empty (unless Step 3 added the presenter).

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && vendor/bin/pint --format agent tests/Feature/Comment/KvCommentAuthorFlagsTest.php && /usr/bin/git add tests/Feature/Comment/KvCommentAuthorFlagsTest.php app/Models/Comment.php && /usr/bin/git commit -m "test(api): KV comment listing, store and broadcast carry the client author flags"
```

---

### Task 2: web — `external` on every author, `internalOnly` on the KV post

**Files:**
- Modify: `src/types/comments/index.ts` (`CommentAuthor`, lines 91–95)
- Modify: `src/services/query.ts` (`CommentServerJson.author` ~5318–5323; `mapComment` author ~5609–5619)
- Modify: `src/lib/deck/reverb.ts` (`WireCommentPayload.author`, line 384)
- Modify: `src/hooks/comments/useAnchoredComments.ts` (`normalizeWireComment` author ~95–99; `PostAnchoredCommentInput` ~245–254; post `mutationFn` ~464–471)
- Modify: `src/lib/client-lane/commentThreads.ts` (`toAuthor`)
- Modify: `src/lib/client-lane/commentThreads.test.ts`
- Create: `src/hooks/comments/useKvFileComments.visibility.test.tsx`

**Interfaces:**
- Consumes: Task 1's wire contract.
- Produces:
  - `CommentAuthor.external?: true` — present only when the author is a guest or lane client, absent otherwise, so existing `toEqual` author assertions still hold.
  - A guest author's `id` is `guest:{name}` in the agency mappers, as on the public page.
  - `PostAnchoredCommentInput.internalOnly?: boolean` — forwarded to `service.post` → `postKvFileComment` → `internal_only`. When omitted, the key is `undefined`, which axios drops.

- [ ] **Step 1: Write the failing tests (test)**

Append to `src/lib/client-lane/commentThreads.test.ts` (inside the `describe`):

```ts
  it("flags guests and lane clients as external, members not at all", () => {
    const lane = pinComment("p4", "craft:g1:board.g1", "2026-09-30T10:00:00.000Z", {
      author: { id: "u7", name: "Bayu", external: true },
    });
    const threads = publicThreads([root, reply, lane]);
    expect(threads.get("p1")?.parent.author.external).toBe(true);
    expect(threads.get("p4")?.parent.author).toEqual({
      id: "u7",
      name: "Bayu",
      external: true,
    });
    expect(threads.get("p1")?.replies[0].author).not.toHaveProperty("external");
  });
```

Create `src/hooks/comments/useKvFileComments.visibility.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import { useState, type ReactNode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { AuthContext } from "@/context/AuthContext";
import axiosInstance from "@/services/axios";

import { useKvFileComments } from "./useKvFileComments";

const AT = "2026-10-01T08:00:00.000Z";
const row = (id: string, author: Record<string, unknown> | null, over = {}) => ({
  id,
  commentable_type: "kv_file",
  commentable_id: "f1",
  anchor: { kind: "pin", id: "craft:g1:board.g1", x: 0.5, y: 0.5 },
  parent_id: null,
  author,
  body: `Note ${id}`,
  mentions: [],
  internal_only: false,
  resolved_at: null,
  resolved_by_id: null,
  created_at: AT,
  updated_at: AT,
  ...over,
});

const LIST = [
  row("g", { id: null, name: "Dina", guest: true }),
  row("l", { id: "u7", name: "Bayu", avatar: null, external: true }),
  row("m", { id: "u1", name: "Ana", avatar: null }),
];

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return (
    <AuthContext.Provider value={{ user: null } as never}>
      <QueryClientProvider client={client}>{children}</QueryClientProvider>
    </AuthContext.Provider>
  );
}

function stubApi() {
  vi.spyOn(axiosInstance, "get").mockImplementation((async () => ({
    data: { data: LIST },
  })) as never);
  return vi.spyOn(axiosInstance, "post").mockImplementation((async (
    _url: string,
    input: Record<string, unknown>
  ) => ({
    data: {
      data: row("new", { id: "u1", name: "Ana" }, {
        parent_id: input.parent_id ?? null,
        internal_only: input.internal_only === true,
      }),
    },
  })) as never);
}

afterEach(() => vi.restoreAllMocks());

describe("useKvFileComments — client lane", () => {
  it("flags guest and lane-client authors external and gives each guest an id", async () => {
    stubApi();
    const { result } = renderHook(() => useKvFileComments("b1", "f1"), {
      wrapper: Wrapper,
    });
    await waitFor(() => expect(result.current.threads).toHaveLength(3));
    const byId = new Map(result.current.threads.map((t) => [t.parent.id, t]));
    expect(byId.get("g")?.parent.author).toMatchObject({
      id: "guest:Dina",
      name: "Dina",
      external: true,
    });
    expect(byId.get("l")?.parent.author).toMatchObject({ id: "u7", external: true });
    expect(byId.get("m")?.parent.author).not.toHaveProperty("external");
  });

  it("posts internal_only on a team-only reply", async () => {
    const post = stubApi();
    const { result } = renderHook(() => useKvFileComments("b1", "f1"), {
      wrapper: Wrapper,
    });
    await waitFor(() => expect(result.current.threads).toHaveLength(3));
    await act(async () => {
      await result.current.reply("m", { body: "Team note", internalOnly: true });
    });
    expect(post).toHaveBeenCalledWith(
      "v1/brands/b1/studio-files/f1/comments",
      expect.objectContaining({ parent_id: "m", internal_only: true })
    );
  });

  it("leaves internal_only unset when the caller did not choose", async () => {
    const post = stubApi();
    const { result } = renderHook(() => useKvFileComments("b1", "f1"), {
      wrapper: Wrapper,
    });
    await waitFor(() => expect(result.current.threads).toHaveLength(3));
    await act(async () => {
      await result.current.reply("m", { body: "Plain reply" });
    });
    const body = (post.mock.calls[0] as unknown[])[1] as Record<string, unknown>;
    expect(body.internal_only).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run them to see them fail (test)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/commentThreads.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/hooks/comments/useKvFileComments.visibility.test.tsx
```

Expected:
- `commentThreads`: "flags guests and lane clients…" FAILS (`external` is undefined).
- Hook: "flags guest and lane-client authors…" FAILS (id `null` / no `external`), and "posts internal_only…" FAILS (no `internal_only`).
- "leaves internal_only unset" passes already, which is correct.

If the hook suite errors on mount with a Pusher/Reverb exception instead, `useCommentsChannel` is not inert in jsdom. Report it, and keep only the `commentThreads` tests plus a direct test of `postKvFileComment` (`vi.spyOn(axiosInstance, "post")`, call `postKvFileComment("b1", "f1", { body: "x", internalOnly: true })`, assert `internal_only: true`).

- [ ] **Step 3: Implement**

`src/types/comments/index.ts` — replace `CommentAuthor`:

```ts
export interface CommentAuthor {
  id: string;
  name: string;
  avatarUrl?: string;
  /**
   * Written by someone outside the workspace: a guest on a share link or a
   * client on their lane (api `author.guest` / `author.external`, client lane
   * C-4). Set ONLY when true, so every existing author shape stays as it was.
   */
  external?: boolean;
}
```

`src/services/query.ts` — in `CommentServerJson`, replace the `author` member:

```ts
  author: {
    /** `null` for a guest (client lane C-4): they have no `users` row. */
    id: string | null;
    name: string;
    avatar?: string;
    avatar_url?: string;
    /** A share-link guest (client lane C-4). */
    guest?: boolean;
    /** A client acting on their lane (client lane C-4). */
    external?: boolean;
  } | null;
```

In `mapComment`, replace the `author: c.author ? { … } : UNKNOWN_COMMENT_AUTHOR,` expression:

```ts
    author: c.author
      ? {
          // A guest has no user id. Each gets `guest:{name}`, as the public
          // page does (lib/client-lane/commentThreads.ts): a blank id merges
          // every guest into one face, one author filter row and one pin.
          id: c.author.id ?? `guest:${c.author.name}`,
          name: c.author.name,
          // The api eager-loads `author:id,name,avatar` and User has no
          // `avatar_url` accessor, so reading `avatar_url` alone silently
          // yielded undefined for every comment ever posted — which is why
          // threads rendered grey initials for people who do have a photo.
          // `avatar_url` kept as a fallback in case a serializer adds it.
          avatarUrl: c.author.avatar ?? c.author.avatar_url,
          // Client lane Part C: the dock's Client label, pill and pin ring.
          ...(c.author.guest || c.author.external ? { external: true } : {}),
        }
      : UNKNOWN_COMMENT_AUTHOR,
```

`src/lib/deck/reverb.ts` — in `WireCommentPayload`, replace the `author?` line:

```ts
  author?: {
    id: string | null;
    name: string;
    avatar_url?: string;
    /** Client lane C-4 — mirrors the REST author shape. */
    guest?: boolean;
    external?: boolean;
  } | null;
```

`src/hooks/comments/useAnchoredComments.ts` — in `normalizeWireComment`, replace the `author: { … },` block:

```ts
    author: {
      id:
        payload.author?.id ??
        payload.author_id ??
        // A guest (client lane C-4) has neither id — same `guest:{name}` key
        // the REST mapper uses, so a live insert and a refetch agree.
        (payload.author?.guest ? `guest:${payload.author.name}` : ""),
      name: payload.author?.name ?? "Unknown",
      avatarUrl: payload.author?.avatar_url,
      ...(payload.author?.guest || payload.author?.external
        ? { external: true }
        : {}),
    },
```

In `PostAnchoredCommentInput`, add after `parentId?: string;`:

```ts
  /**
   * Client lane Part C: `true` posts Team only (`internal_only`), which the
   * api hides from the client. Omit for today's default.
   */
  internalOnly?: boolean;
```

In the post mutation's `mutationFn`, add `internalOnly: input.internalOnly,` after `parentId: input.parentId,`:

```ts
    mutationFn: (input: PostAnchoredCommentInput) =>
      service.post(scopeId as string, {
        body: input.body,
        mentions: input.mentions ?? [],
        attachments: input.attachments,
        anchor: input.anchor,
        parentId: input.parentId,
        internalOnly: input.internalOnly,
      }),
```

`src/lib/client-lane/commentThreads.ts` — replace `toAuthor`:

```ts
function toAuthor(author: PublicComment["author"]): CommentAuthor {
  const name = author?.name ?? "Guest";
  return {
    id: author?.id ?? `guest:${name}`,
    name,
    ...(author?.avatar ? { avatarUrl: author.avatar } : {}),
    // The client's own side (guest or lane): their replies are never "new".
    ...(author?.guest || author?.external ? { external: true } : {}),
  };
}
```

- [ ] **Step 4: Run them to see them pass (test)**

Re-run the two Step 2 commands. Expected: all pass, including the four existing `commentThreads` tests.

- [ ] **Step 5: Mutation check (test)**

- Remove `internalOnly: input.internalOnly,` from the `mutationFn` → "posts internal_only on a team-only reply" FAILS. Restore.
- Remove the `...(c.author.guest || c.author.external …)` spread in `mapComment` → "flags guest and lane-client authors external…" FAILS. Restore. Both pass again.

- [ ] **Step 6: Gates + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/types/comments/index.ts src/services/query.ts src/lib/deck/reverb.ts src/hooks/comments/useAnchoredComments.ts src/hooks/comments/useKvFileComments.visibility.test.tsx src/lib/client-lane/commentThreads.ts src/lib/client-lane/commentThreads.test.ts) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "src/types/comments/|src/services/query.ts|src/lib/deck/reverb.ts|src/hooks/comments/|src/lib/client-lane/commentThreads"; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
```

Expected: the touched-file grep prints nothing, and the count is ≤ the baseline. If `id: string | null` surfaces errors elsewhere in `query.ts` (another reader of `CommentServerJson.author.id`), coalesce there the same way: `?? \`guest:${…name}\``.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/types/comments/index.ts src/services/query.ts src/lib/deck/reverb.ts src/hooks/comments/useAnchoredComments.ts src/hooks/comments/useKvFileComments.visibility.test.tsx src/lib/client-lane/commentThreads.ts src/lib/client-lane/commentThreads.test.ts && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): comments know which authors are clients; KV posts can be team only

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: web — visibility rules (pure)

**Files:**
- Create: `src/components/comments/commentVisibility.ts`
- Create: `src/components/comments/commentVisibility.test.ts`
- Create: `src/lib/client-lane/pendingArtboards.ts`
- Create: `src/lib/client-lane/pendingArtboards.test.ts`

**Interfaces:**
- Consumes: `CommentAuthor.external` (Task 2); `AgencyRequest` (`@/services/client-lane`); `anchorPart` / `anchorVersion` (`@/lib/comments/anchorCodec`).
- Produces:

```ts
// src/components/comments/commentVisibility.ts
export interface PostVisibility { internalOnly: boolean }
export interface ThreadVisibility { teamOnly: boolean; replyToggle: boolean }
export function isClientComment(c: Pick<Comment, "author">): boolean;
export function isClientThread(t: CommentThread): boolean;
export function threadVisibility(t: CommentThread, requestThreadIds?: ReadonlySet<string>): ThreadVisibility;

// src/lib/client-lane/pendingArtboards.ts
export interface PendingArtboards {
  boardVersionIds: ReadonlySet<string>;
  resizeRowIds: ReadonlySet<string>;   // lower-cased
  motionProjectIds: ReadonlySet<string>; // lower-cased
}
export const NO_PENDING_ARTBOARDS: PendingArtboards;
export function pendingArtboards(requests: readonly AgencyRequest[]): PendingArtboards;
export function isPendingSpec(spec: { version: string | null; part: string | null }, p: PendingArtboards): boolean;
export function isPendingAnchor(anchor: CommentAnchor | null | undefined, p: PendingArtboards): boolean;
export function requestThreadIds(threads: readonly CommentThread[], p: PendingArtboards): Set<string>;
```

**Rulings (spec §6.2 leaves these open):**
- **Board match.** A board pin's anchor carries the generation it was placed on (`KvGeneratorLayout.handleSubmitDraft` stamps the clicked board's tip). The approval's `subject_key` is the chain's FIRST generation (D-8), which an anchor never carries. So a board matches on the approval's `version_id`: the version the client is reviewing. A note on a newer iteration made after sending is not on what the client sees, so it keeps today's default.
- **Resize and motion** match on the part's row/project id, lower-cased (Review Focus 1).
- **"Open request"** = request `status === "pending"`. **"Pending approval"** = `status === "pending"` and not superseded.
- **Reply toggle** shows where the client can read the thread: they wrote in it, or its artboard is pending in an open request. It never shows on a Team-only root, because replies there inherit invisibility (`Comment::scopeVisibleTo` hides replies under an internal root).

- [ ] **Step 1: Write the failing tests (test)**

`src/components/comments/commentVisibility.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import type { Comment, CommentThread } from "@/types/comments";

import {
  isClientThread,
  threadVisibility,
} from "./commentVisibility";

const AT = "2026-10-01T08:00:00.000Z";
function comment(id: string, over: Partial<Comment> = {}): Comment {
  return {
    id,
    commentableType: "kv_file",
    commentableId: "f1",
    anchor: { kind: "pin", id: "craft:g1:board.g1", x: 0.5, y: 0.5 },
    parentId: null,
    author: { id: "u1", name: "Ana" },
    body: `Note ${id}`,
    mentions: [],
    internalOnly: false,
    resolvedAt: null,
    resolvedById: null,
    createdAt: AT,
    updatedAt: AT,
    ...over,
  };
}
const DINA = { id: "guest:Dina", name: "Dina", external: true };

describe("isClientThread", () => {
  it("is true when the client wrote the root or any reply", () => {
    expect(isClientThread({ parent: comment("a", { author: DINA }), replies: [] })).toBe(true);
    expect(
      isClientThread({
        parent: comment("b"),
        replies: [comment("r", { parentId: "b", author: DINA })],
      })
    ).toBe(true);
    expect(isClientThread({ parent: comment("c"), replies: [] })).toBe(false);
  });
});

describe("threadVisibility", () => {
  const team: CommentThread = { parent: comment("t"), replies: [] };
  const client: CommentThread = { parent: comment("c", { author: DINA }), replies: [] };
  const internal: CommentThread = { parent: comment("i", { internalOnly: true }), replies: [] };

  it("offers the reply toggle on a client thread", () => {
    expect(threadVisibility(client)).toEqual({ teamOnly: false, replyToggle: true });
  });

  it("offers it on a team thread whose artboard the client is reviewing", () => {
    expect(threadVisibility(team, new Set(["t"]))).toEqual({
      teamOnly: false,
      replyToggle: true,
    });
    expect(threadVisibility(team)).toEqual({ teamOnly: false, replyToggle: false });
  });

  it("never offers it on a Team only root, even on a reviewed artboard", () => {
    expect(threadVisibility(internal, new Set(["i"]))).toEqual({
      teamOnly: true,
      replyToggle: false,
    });
  });
});
```

`src/lib/client-lane/pendingArtboards.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { buildPinAnchor } from "@/lib/comments/anchorCodec";
import type {
  AgencyRequest,
  AgencyRequestApproval,
} from "@/services/client-lane";
import type { CommentThread } from "@/types/comments";

import {
  NO_PENDING_ARTBOARDS,
  isPendingAnchor,
  isPendingSpec,
  pendingArtboards,
  requestThreadIds,
} from "./pendingArtboards";

function approval(over: Partial<AgencyRequestApproval>): AgencyRequestApproval {
  return {
    id: "a1",
    subject_key: "board:G0",
    phase: "craft",
    label: "Craft · Hero board",
    round: 1,
    version_id: "G1",
    thumbnail_url: null,
    status: "pending",
    superseded_by_request_number: null,
    pin_count: 0,
    decisions: [],
    ...over,
  };
}

function request(over: Partial<AgencyRequest>): AgencyRequest {
  return {
    id: "q1",
    number: 1,
    status: "pending",
    policy: "optional",
    message: null,
    sent_at: "2026-10-01T08:00:00.000Z",
    decide_by: null,
    deferred_until: null,
    deferred_note: null,
    resolved_at: null,
    created_at: "2026-10-01T08:00:00.000Z",
    share_url: "https://frnd.test/s/tok",
    share_link_active: true,
    counts: {
      approved: 0,
      approved_with_changes: 0,
      changes_required: 0,
      pending: 1,
      superseded: 0,
    },
    approvers: [],
    approvals: [],
    ...over,
  };
}

const OPEN = request({
  approvals: [
    approval({ id: "a1", subject_key: "board:G0", version_id: "G1" }),
    approval({
      id: "a2",
      subject_key: "resize:01JABCDROW",
      phase: "resize",
      version_id: "01JABCDROW",
    }),
    approval({
      id: "a3",
      subject_key: "motion:01JMOTIONPRJ:9:16",
      phase: "motion",
      version_id: "EXP9",
    }),
    approval({ id: "a4", subject_key: "board:H0", version_id: "H1", status: "approved" }),
    approval({
      id: "a5",
      subject_key: "board:K0",
      version_id: "K1",
      status: "not_relevant",
      superseded_by_request_number: 2,
    }),
  ],
});
const CLOSED = request({
  id: "q0",
  number: 0,
  status: "approved",
  approvals: [approval({ id: "z", subject_key: "board:Z0", version_id: "Z1", status: "approved" })],
});

describe("pendingArtboards", () => {
  it("collects only pending, unsuperseded artboards of open requests", () => {
    const p = pendingArtboards([OPEN, CLOSED]);
    expect([...p.boardVersionIds]).toEqual(["G1"]);
    expect([...p.resizeRowIds]).toEqual(["01jabcdrow"]);
    expect([...p.motionProjectIds]).toEqual(["01jmotionprj"]);
  });

  it("is empty with no requests", () => {
    expect(pendingArtboards([])).toEqual(NO_PENDING_ARTBOARDS);
  });
});

describe("isPendingAnchor / isPendingSpec", () => {
  const p = pendingArtboards([OPEN]);

  it("matches a board pin on the version the client is reviewing, and only that version", () => {
    const onSent = buildPinAnchor({ stage: "craft", version: "G1", part: "board.G1" }, 0.5, 0.5);
    const onNewer = buildPinAnchor({ stage: "craft", version: "G2", part: "board.G2" }, 0.5, 0.5);
    expect(isPendingAnchor(onSent, p)).toBe(true);
    expect(isPendingAnchor(onNewer, p)).toBe(false);
  });

  it("matches a resize tile pin whose slugged part is lower-case", () => {
    const anchor = buildPinAnchor(
      { stage: "resize", version: "G1", part: "tile.01JABCDROW" },
      0.2,
      0.2
    );
    expect(anchor.id).toBe("resize:G1:tile.01jabcdrow");
    expect(isPendingAnchor(anchor, p)).toBe(true);
  });

  it("matches a draft's raw, unslugged tile part", () => {
    expect(isPendingSpec({ version: "G1", part: "tile.01JABCDROW" }, p)).toBe(true);
    expect(isPendingSpec({ version: "G1", part: "tile.__master__" }, p)).toBe(false);
  });

  it("matches a motion part by project id", () => {
    expect(isPendingSpec({ version: "X", part: "motion.01JMOTIONPRJ" }, p)).toBe(true);
  });

  it("never matches an approved, superseded, closed or foreign anchor", () => {
    expect(isPendingSpec({ version: "H1", part: "board.H1" }, p)).toBe(false);
    expect(isPendingSpec({ version: "K1", part: "board.K1" }, p)).toBe(false);
    expect(isPendingSpec({ version: "Z1", part: "board.Z1" }, p)).toBe(false);
    expect(isPendingAnchor({ kind: "widget", id: "w1" }, p)).toBe(false);
    expect(isPendingAnchor(null, p)).toBe(false);
  });
});

describe("requestThreadIds", () => {
  it("lists the root ids anchored on a pending artboard", () => {
    const thread = (id: string, version: string, part: string): CommentThread =>
      ({
        parent: {
          id,
          anchor: buildPinAnchor({ stage: "craft", version, part }, 0.5, 0.5),
        },
        replies: [],
      }) as unknown as CommentThread;
    const ids = requestThreadIds(
      [thread("t1", "G1", "board.G1"), thread("t2", "G2", "board.G2")],
      pendingArtboards([OPEN])
    );
    expect([...ids]).toEqual(["t1"]);
  });
});
```

- [ ] **Step 2: Run them to see them fail (test)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/commentVisibility.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/pendingArtboards.test.ts
```

Expected: both FAIL with "Cannot find module".

- [ ] **Step 3: Implement**

`src/components/comments/commentVisibility.ts`:

```ts
/**
 * Who can read a comment, for the client lane (spec 2026-10-01 §6.2). Pure —
 * the dock, the thread card and the canvas popover all ask the same
 * questions, so the answers live once, here.
 *
 * Hosts that never opt in (decks, pitches, research surfaces) never call
 * these, and their comment UI is unchanged.
 */
import type { Comment, CommentThread } from "@/types/comments";

/** What a post says about who may read it. Absent = today's default. */
export interface PostVisibility {
  /** `true` posts Team only — the api's `internal_only`. */
  internalOnly: boolean;
}

/** How one thread behaves for a host that opted into the client lane. */
export interface ThreadVisibility {
  /**
   * The root is `internal_only`. The card is dashed, and replies stay team
   * only: the api hides every reply under an internal root
   * (`Comment::scopeVisibleTo`), so a "Client sees this" choice there would
   * be a lie.
   */
  teamOnly: boolean;
  /** Offer "Client sees this / Team only" on the reply composer. */
  replyToggle: boolean;
}

/** Written by a guest or a lane client (api `author.guest` / `.external`). */
export function isClientComment(c: Pick<Comment, "author">): boolean {
  return c.author.external === true;
}

/** A thread the client is part of: they wrote the root or any reply. */
export function isClientThread(t: CommentThread): boolean {
  return [t.parent, ...t.replies].some(isClientComment);
}

/**
 * The toggle shows where the client can read the thread: they wrote in it,
 * or its artboard is pending in an open approval request
 * (`requestThreadIds`, from `lib/client-lane/pendingArtboards`). Default
 * stays "Client sees this" — today's behaviour.
 */
export function threadVisibility(
  t: CommentThread,
  requestThreadIds?: ReadonlySet<string>
): ThreadVisibility {
  const teamOnly = t.parent.internalOnly === true;
  return {
    teamOnly,
    replyToggle:
      !teamOnly &&
      (isClientThread(t) || (requestThreadIds?.has(t.parent.id) ?? false)),
  };
}
```

`src/lib/client-lane/pendingArtboards.ts`:

```ts
/**
 * Which comment anchors sit on an artboard the client is reviewing right now
 * — pending in an open approval request (spec 2026-10-01 §6.2: a new team
 * thread there starts Team only; replies offer the visibility toggle). Pure.
 *
 * Matching, per artboard kind (subject_key, spec §4.2):
 * - board  (`board:{first gen}`) → the approval's `version_id` against the
 *   anchor's VERSION. An anchor never carries the chain's first generation;
 *   it carries the generation it was placed on — so a note on a newer
 *   iteration (not what the client sees) keeps today's default.
 * - resize (`resize:{row}`) → the anchor's PART `tile.{row}`.
 * - motion (`motion:{project}:{ratio}`) → the anchor's PART `motion.{project}`.
 *
 * Parts are compared LOWER-CASED: `slugPart` lower-cases every stored part
 * (anchorCodec), while ULIDs in `subject_key` are upper-case.
 */
import { anchorPart, anchorVersion } from "@/lib/comments/anchorCodec";
import type { AgencyRequest } from "@/services/client-lane";
import type { CommentAnchor, CommentThread } from "@/types/comments";

export interface PendingArtboards {
  /** `version_id` of pending Sketch / Craft approvals. */
  boardVersionIds: ReadonlySet<string>;
  /** Resize export row ids, lower-cased. */
  resizeRowIds: ReadonlySet<string>;
  /** Motion project ids, lower-cased. */
  motionProjectIds: ReadonlySet<string>;
}

export const NO_PENDING_ARTBOARDS: PendingArtboards = {
  boardVersionIds: new Set(),
  resizeRowIds: new Set(),
  motionProjectIds: new Set(),
};

export function pendingArtboards(
  requests: readonly AgencyRequest[]
): PendingArtboards {
  const board = new Set<string>();
  const resize = new Set<string>();
  const motion = new Set<string>();
  for (const r of requests) {
    if (r.status !== "pending") continue;
    for (const a of r.approvals) {
      if (a.status !== "pending" || a.superseded_by_request_number !== null) {
        continue;
      }
      const [kind, id] = a.subject_key.split(":");
      if (!id) continue;
      if (kind === "board") board.add(a.version_id);
      else if (kind === "resize") resize.add(id.toLowerCase());
      else if (kind === "motion") motion.add(id.toLowerCase());
    }
  }
  return {
    boardVersionIds: board,
    resizeRowIds: resize,
    motionProjectIds: motion,
  };
}

/** A version + part (an anchor's, or a draft's before it is encoded). */
export function isPendingSpec(
  spec: { version: string | null; part: string | null },
  p: PendingArtboards
): boolean {
  const part = spec.part?.toLowerCase() ?? "";
  if (part.startsWith("tile.")) {
    return p.resizeRowIds.has(part.slice("tile.".length));
  }
  if (part.startsWith("motion.")) {
    return p.motionProjectIds.has(part.slice("motion.".length));
  }
  return spec.version !== null && p.boardVersionIds.has(spec.version);
}

export function isPendingAnchor(
  anchor: CommentAnchor | null | undefined,
  p: PendingArtboards
): boolean {
  const part = anchorPart(anchor);
  if (part === null) return false;
  return isPendingSpec({ version: anchorVersion(anchor), part }, p);
}

/** Root ids of the threads anchored on a pending artboard. */
export function requestThreadIds(
  threads: readonly CommentThread[],
  p: PendingArtboards
): Set<string> {
  const out = new Set<string>();
  for (const t of threads) {
    if (isPendingAnchor(t.parent.anchor, p)) out.add(t.parent.id);
  }
  return out;
}
```

- [ ] **Step 4: Run them to see them pass (test)**

Re-run both Step 2 commands. Expected: all pass.

- [ ] **Step 5: Mutation check (test)**

- In `isPendingSpec`, change `const part = spec.part?.toLowerCase() ?? "";` to `const part = spec.part ?? "";` → "matches a draft's raw, unslugged tile part" FAILS. Restore.
- In `threadVisibility`, drop `!teamOnly &&` → "never offers it on a Team only root…" FAILS. Restore.
- In `pendingArtboards`, drop `|| a.superseded_by_request_number !== null` → "never matches an approved, superseded…" FAILS. Restore.

- [ ] **Step 6: Gates + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/comments/commentVisibility.ts src/components/comments/commentVisibility.test.ts src/lib/client-lane/pendingArtboards.ts src/lib/client-lane/pendingArtboards.test.ts) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "commentVisibility|pendingArtboards"
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/comments/commentVisibility.ts src/components/comments/commentVisibility.test.ts src/lib/client-lane/pendingArtboards.ts src/lib/client-lane/pendingArtboards.test.ts && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): client-lane visibility rules — client threads and artboards under review

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: web — analytics helpers, chips, the visibility toggle, a ReactNode hint slot

Load `.agents/skills/frndos-ui/SKILL.md` → `frndos-components-v2` (Button), `frndos-components` (Label), `frndos-design-foundations` (§Appearance) and `.agents/skills/frndos-analytics-events/SKILL.md` first.

**Files:**
- Modify: `src/lib/analytics/client-lane-events.ts` (append a section at the end)
- Create: `src/components/comments/CommentChips.tsx`
- Create: `src/components/comments/CommentVisibilityToggle.tsx`
- Create: `src/components/comments/CommentVisibilityToggle.test.tsx`
- Modify: `src/components/comments/CommentComposer.tsx` (`hintText` prop type, line 54)
- Create: `src/components/comments/CommentComposer.hint.test.tsx`

**Interfaces:**
- Consumes: `PostVisibility` (Task 3) — type only.
- Produces:

```ts
// client-lane-events.ts
export type CommentsClientFilter = "client" | "team_only";
export type CommentVisibilityTarget = "client" | "team";
export type CommentComposerKind = "reply" | "root";
export const trackCommentsClientFilterUsed: (p: { filter: CommentsClientFilter }) => void;          // "comments.client_filter_used"
export const trackCommentsReplyVisibilityToggled: (p: { to: CommentVisibilityTarget; composer: CommentComposerKind }) => void; // "comments.reply_visibility_toggled"
export const trackCommentsTeamOnlyThreadCreated: (p: { defaulted: boolean }) => void;              // "comments.team_only_thread_created"

// CommentChips.tsx (v1 only)
export function ClientChip(): JSX.Element;   // yellow "Client"
export function TeamOnlyChip(): JSX.Element; // grey "Team only"
export function NewChip(): JSX.Element;      // "New" (client page)

// CommentVisibilityToggle.tsx (v2 only)
export function CommentVisibilityToggle(props: { teamOnly: boolean; onChange: (teamOnly: boolean) => void; composer: CommentComposerKind }): JSX.Element;
export function TeamOnlyHint(): JSX.Element; // static lock + "Team only"

// CommentComposer
hintText?: ReactNode; // was string — every existing string caller still compiles
```

**Rulings:**
- **Toggle label.** The visible label names the current state ("Client sees this" / "Team only"), and `title` says what a click does. There is no `aria-pressed` with a changing name, because a toggle whose name flips under `aria-pressed` reads as two different controls.
- **Grey "Team only" chip.** v1 `Label` has no grey that works in all three modes: `translucent` uses `text-gray-100`, which disappears in Daylight. So it is `variant="translucent"` (`bg-white/15` flips in Daylight) with `!text-text-inverse-subtle`.
- **"New" chip.** It is `variant="neutral"` (white chip, dark ink) and appears only on the dark-scoped `/s/` page. Yellow means "pending" there and green means "approved" (`statusTone.ts`), so neither is used.
- **Event home.** These `comments.*` events live in `client-lane-events.ts` because spec §11.1 names that module for all Part C analytics. The names are exactly spec §6.2's.

- [ ] **Step 1: Write the failing tests (test)**

`src/components/comments/CommentVisibilityToggle.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { fireEvent, render, within } from "@testing-library/react";
import posthog from "posthog-js";
import { afterEach, describe, expect, it, vi } from "vitest";

import { CommentVisibilityToggle } from "./CommentVisibilityToggle";

const body = () => within(document.body);
afterEach(() => vi.restoreAllMocks());

describe("CommentVisibilityToggle", () => {
  it("names who will see the post and flips it, without bubbling", () => {
    const capture = vi.spyOn(posthog, "capture").mockImplementation(() => undefined as never);
    const onChange = vi.fn();
    const outer = vi.fn();
    const { rerender } = render(
      <div onClick={outer}>
        <CommentVisibilityToggle teamOnly={false} onChange={onChange} composer="reply" />
      </div>
    );

    fireEvent.click(body().getByRole("button", { name: "Client sees this" }));
    expect(onChange).toHaveBeenCalledWith(true);
    expect(outer).not.toHaveBeenCalled();
    expect(capture).toHaveBeenCalledWith(
      "comments.reply_visibility_toggled",
      expect.objectContaining({ to: "team", composer: "reply" })
    );

    rerender(
      <div onClick={outer}>
        <CommentVisibilityToggle teamOnly onChange={onChange} composer="root" />
      </div>
    );
    fireEvent.click(body().getByRole("button", { name: "Team only" }));
    expect(onChange).toHaveBeenLastCalledWith(false);
    expect(capture).toHaveBeenLastCalledWith(
      "comments.reply_visibility_toggled",
      expect.objectContaining({ to: "client", composer: "root" })
    );
  });
});
```

`src/components/comments/CommentComposer.hint.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, within } from "@testing-library/react";
import { useState, type ReactNode } from "react";
import { describe, expect, it, vi } from "vitest";

import CommentComposer from "./CommentComposer";

const body = () => within(document.body);

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

describe("CommentComposer hint slot", () => {
  it("hosts a control in place of the keyboard hint", () => {
    render(
      <CommentComposer
        compact
        onSubmit={vi.fn()}
        mentionCandidates={[]}
        hintText={<button type="button">Client sees this</button>}
      />,
      { wrapper: Wrapper }
    );
    expect(body().getByRole("button", { name: "Client sees this" })).toBeInTheDocument();
    expect(body().queryByText(/to reply/)).not.toBeInTheDocument();
  });

  it("keeps the default keyboard hint when no hint is given", () => {
    render(<CommentComposer compact onSubmit={vi.fn()} mentionCandidates={[]} />, {
      wrapper: Wrapper,
    });
    expect(body().getByText("⏎ to reply · Shift+Enter for new line")).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run them to see them fail (test)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/CommentVisibilityToggle.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/CommentComposer.hint.test.tsx
```

Expected:
- Toggle: FAIL ("Cannot find module").
- Composer: may already PASS at runtime, because `string` is only a type. Its job is the regression, and Step 4's tsc is the real gate for the widened type.

- [ ] **Step 3: Implement**

Append to `src/lib/analytics/client-lane-events.ts`:

```ts
/* ── Agency comments dock (spec 2026-10-01 §6.2, Part C) ──────────────── */

/**
 * A client-lane filter switched ON in the KV Comments dock: the Client pill
 * or Filter › Visibility › Team only. Fired on activation, not on clearing.
 */
export type CommentsClientFilter = "client" | "team_only";

export const trackCommentsClientFilterUsed = (props: {
  filter: CommentsClientFilter;
}) => safeCapture("comments.client_filter_used", props);

/** Who will read the post after the toggle. */
export type CommentVisibilityTarget = "client" | "team";

/** The composer the toggle sits in. */
export type CommentComposerKind = "reply" | "root";

export const trackCommentsReplyVisibilityToggled = (props: {
  to: CommentVisibilityTarget;
  composer: CommentComposerKind;
}) => safeCapture("comments.reply_visibility_toggled", props);

/**
 * A new root thread posted Team only. `defaulted` = the reviewer left the
 * default (the artboard was pending in an open request) rather than choosing.
 */
export const trackCommentsTeamOnlyThreadCreated = (props: {
  defaulted: boolean;
}) => safeCapture("comments.team_only_thread_created", props);
```

`src/components/comments/CommentChips.tsx`:

```tsx
/**
 * The comment surfaces' small status chips (spec 2026-10-01 §11.2: v1
 * `Label`). Kept in this v1-only file so the files that compose them with
 * v2 controls never import a second component generation directly.
 *
 * `size="small"` untouched: the token scale's smallest text is `textXs`, and
 * the dock's older "Artboard deleted" chip shrinks below it with arbitrary
 * values this plan does not copy.
 */
import { Label } from "@/components/frndos/Label";

/** A thread the client is part of. Yellow, as the client's pin ring. */
export function ClientChip() {
  return (
    <Label size="small" variant="alert" dark className="shrink-0">
      Client
    </Label>
  );
}

/**
 * A thread only the team can read. `translucent` is the one glass fill that
 * flips in Daylight (`bg-white/15`); its own `text-gray-100` does not, so the
 * ink comes from the inverse token.
 */
export function TeamOnlyChip() {
  return (
    <Label
      size="small"
      variant="translucent"
      className="shrink-0 !text-text-inverse-subtle"
    >
      Team only
    </Label>
  );
}

/** An agency reply this viewer has not seen yet (client page, dark scope). */
export function NewChip() {
  return (
    <Label size="small" variant="neutral" className="shrink-0">
      New
    </Label>
  );
}
```

`src/components/comments/CommentVisibilityToggle.tsx`:

```tsx
"use client";

import { EyeIcon, LockSimpleIcon } from "@phosphor-icons/react";

import { Button } from "@/components/frndos/v2";
import {
  trackCommentsReplyVisibilityToggled,
  type CommentComposerKind,
} from "@/lib/analytics/client-lane-events";

/**
 * "Client sees this" / "Team only" — who a comment will be visible to (spec
 * 2026-10-01 §6.2). Lives in `CommentComposer`'s hint slot, so it sits where
 * the keyboard hint was and costs the composer no height.
 *
 * The label names the CURRENT state; `title` says what a click does. Team
 * only posts `internal_only: true`, which the api hides from the client.
 */
export function CommentVisibilityToggle({
  teamOnly,
  onChange,
  composer,
}: {
  teamOnly: boolean;
  onChange: (teamOnly: boolean) => void;
  composer: CommentComposerKind;
}) {
  return (
    <Button
      type="button"
      variant="text"
      size="tiny"
      leftIcon={
        teamOnly ? (
          <LockSimpleIcon size={12} aria-hidden />
        ) : (
          <EyeIcon size={12} aria-hidden />
        )
      }
      title={
        teamOnly
          ? "Only your team will see this. Click to let the client see it."
          : "The client will see this. Click to keep it to your team."
      }
      onClick={(e) => {
        // Inside a clickable thread card, and over a canvas that turns
        // clicks into pins — the toggle is neither.
        e.stopPropagation();
        const next = !teamOnly;
        trackCommentsReplyVisibilityToggled({
          to: next ? "team" : "client",
          composer,
        });
        onChange(next);
      }}
    >
      {teamOnly ? "Team only" : "Client sees this"}
    </Button>
  );
}

/** A reply under a Team-only root: no choice to make, just say so. */
export function TeamOnlyHint() {
  return (
    <span className="flex items-center gap-1 font-geist text-textXs text-text-inverse-subtlest">
      <LockSimpleIcon size={12} aria-hidden />
      Team only
    </span>
  );
}
```

`src/components/comments/CommentComposer.tsx`:
- Change the import line `import { useCallback, useEffect, useMemo, useRef, useState } from "react";` to `import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";`.
- Replace the `hintText` prop:

```ts
  /**
   * Overrides the keyboard-hint caption underneath the box. Same
   * `compact`-isn't-"is a reply" issue as `placeholder` — the default
   * "⏎ to reply" is wrong for a composer that isn't a reply.
   *
   * A node, not only text: the client lane's "Client sees this / Team only"
   * toggle lives in this slot (spec 2026-10-01 §6.2).
   */
  hintText?: ReactNode;
```

- [ ] **Step 4: Run them to see them pass (test)**

Re-run the two Step 2 commands, then `bun test src/components/comments/CommentComposer.drop.test.tsx` (regression). Expected: all pass.

- [ ] **Step 5: Mutation check (test)**

Remove `e.stopPropagation();` from the toggle's `onClick` → "names who will see the post and flips it, without bubbling" FAILS. Restore.

- [ ] **Step 6: Gates + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/lib/analytics/client-lane-events.ts src/components/comments/CommentChips.tsx src/components/comments/CommentVisibilityToggle.tsx src/components/comments/CommentVisibilityToggle.test.tsx src/components/comments/CommentComposer.tsx src/components/comments/CommentComposer.hint.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "client-lane-events|CommentChips|CommentVisibilityToggle|CommentComposer"
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/lib/analytics/client-lane-events.ts src/components/comments/CommentChips.tsx src/components/comments/CommentVisibilityToggle.tsx src/components/comments/CommentVisibilityToggle.test.tsx src/components/comments/CommentComposer.tsx src/components/comments/CommentComposer.hint.test.tsx && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): comment visibility toggle, client and team-only chips, comments.* events

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: web — `CommentThread`: Team-only styling, reply toggle, New marker

Load `frndos-ui` → `frndos-design-foundations` (§Appearance) first.

**Files:**
- Modify: `src/components/comments/CommentThread.tsx`
- Create: `src/components/comments/CommentThread.visibility.test.tsx`

**Interfaces:**
- Consumes:
  - `PostVisibility` and `ThreadVisibility` (Task 3);
  - `CommentVisibilityToggle`, `TeamOnlyHint` and `NewChip` (Task 4);
  - `Comment.internalOnly`.
- Produces (on `CommentThreadProps`):

```ts
onReply?: (body: string, mentions: string[], attachments?: CommentAttachment[], visibility?: PostVisibility) => Promise<void> | void;
/** Omit → exactly today's thread; onReply receives THREE arguments. */
visibility?: ThreadVisibility;
/** Client page: agency reply ids not yet seen → "New" + "· n new" on the collapsed toggle. */
newCommentIds?: ReadonlySet<string>;
```

When `visibility` is set, `onReply` receives a 4th argument:
- `{ internalOnly: true }` on a Team-only root;
- `{ internalOnly: <toggle> }` when `replyToggle` is set;
- `{ internalOnly: false }` otherwise.

- [ ] **Step 1: Write the failing tests (test)**

`src/components/comments/CommentThread.visibility.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState, type ReactNode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { Comment, CommentThread as Thread } from "@/types/comments";

import CommentThread from "./CommentThread";

const body = () => within(document.body);
const AT = "2026-10-01T08:00:00.000Z";
afterEach(() => vi.restoreAllMocks());

function comment(id: string, over: Partial<Comment> = {}): Comment {
  return {
    id,
    commentableType: "kv_file",
    commentableId: "f1",
    anchor: { kind: "pin", id: "craft:g1:board.g1", x: 0.5, y: 0.5 },
    parentId: null,
    author: { id: "u1", name: "Ana" },
    body: `Note ${id}`,
    mentions: [],
    internalOnly: false,
    resolvedAt: null,
    resolvedById: null,
    createdAt: AT,
    updatedAt: AT,
    ...over,
  };
}

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

/** jsdom has no Range layout; the mention editor measures the caret. */
async function typeReply(user: ReturnType<typeof userEvent.setup>, text: string) {
  const proto = Range.prototype as unknown as { getBoundingClientRect?: () => DOMRect };
  const had = proto.getBoundingClientRect;
  proto.getBoundingClientRect = () =>
    ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;
  try {
    await user.type(body().getByRole("textbox", { name: /Write a reply/ }), text);
  } finally {
    proto.getBoundingClientRect = had;
  }
}

const withTeamReply: Thread = {
  parent: comment("p"),
  replies: [comment("r1", { parentId: "p", internalOnly: true, body: "Budget note" })],
};

describe("CommentThread — client lane opt-in", () => {
  it("marks a team-only reply where 'edited' sits", () => {
    render(<CommentThread thread={withTeamReply} visibility={{ teamOnly: false, replyToggle: true }} />, {
      wrapper: Wrapper,
    });
    fireEvent.click(body().getByRole("button", { name: "1 reply" }));
    expect(body().getByText("team only")).toBeInTheDocument();
  });

  it("dashes a Team only thread's card", () => {
    const { container } = render(
      <CommentThread
        thread={{ parent: comment("i", { internalOnly: true }), replies: [] }}
        visibility={{ teamOnly: true, replyToggle: false }}
      />,
      { wrapper: Wrapper }
    );
    expect(container.querySelector(".border-dashed")).not.toBeNull();
  });

  it("posts the toggle's choice as the fourth argument", async () => {
    const onReply = vi.fn();
    const user = userEvent.setup();
    render(
      <CommentThread
        thread={{ parent: comment("p"), replies: [] }}
        visibility={{ teamOnly: false, replyToggle: true }}
        onReply={onReply}
      />,
      { wrapper: Wrapper }
    );
    await user.click(body().getByRole("button", { name: "Reply" }));
    await user.click(body().getByRole("button", { name: "Client sees this" }));
    await typeReply(user, "Internal only{Enter}");
    await waitFor(() =>
      expect(onReply).toHaveBeenCalledWith("Internal only", [], undefined, { internalOnly: true })
    );
  });

  it("marks new replies and counts them on the collapsed toggle", () => {
    render(
      <CommentThread
        thread={{
          parent: comment("p"),
          replies: [comment("r1", { parentId: "p" }), comment("r2", { parentId: "p" })],
        }}
        newCommentIds={new Set(["r2"])}
      />,
      { wrapper: Wrapper }
    );
    fireEvent.click(body().getByRole("button", { name: "2 replies · 1 new" }));
    expect(body().getAllByText("New")).toHaveLength(1);
  });
});

describe("CommentThread — without the opt-in (decks, task sheet, client page)", () => {
  it("calls onReply with exactly three arguments and shows no toggle or marker", async () => {
    const onReply = vi.fn();
    const user = userEvent.setup();
    const { container } = render(<CommentThread thread={withTeamReply} onReply={onReply} />, {
      wrapper: Wrapper,
    });
    fireEvent.click(body().getByRole("button", { name: "1 reply" }));
    expect(body().queryByText("team only")).not.toBeInTheDocument();
    expect(container.querySelector(".border-dashed")).toBeNull();

    await user.click(body().getByRole("button", { name: "Reply" }));
    expect(body().queryByRole("button", { name: "Client sees this" })).not.toBeInTheDocument();
    await typeReply(user, "Plain{Enter}");
    await waitFor(() => expect(onReply).toHaveBeenCalledTimes(1));
    expect((onReply.mock.calls[0] as unknown[]).length).toBe(3);
  });
});
```

- [ ] **Step 2: Run them to see them fail (test)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/CommentThread.visibility.test.tsx
```

Expected:
- FAIL: the first four tests (no marker, no dashed card, no toggle button, toggle name "2 replies").
- PASS already: the regression test.

- [ ] **Step 3: Implement**

In `src/components/comments/CommentThread.tsx`:

(a) Imports: change the phosphor import to add `LockSimpleIcon`, and add:

```ts
import {
  CaretDownIcon,
  CheckCircle,
  Circle,
  DotsThree,
  LockSimpleIcon,
  SmileyIcon,
} from "@phosphor-icons/react";
import type { PostVisibility, ThreadVisibility } from "./commentVisibility";
import { CommentVisibilityToggle, TeamOnlyHint } from "./CommentVisibilityToggle";
import { NewChip } from "./CommentChips";
```

(b) In `CommentThreadProps`, replace the `onReply?` member and add the two props after `onEdit?`:

```ts
  onReply?: (
    body: string,
    mentions: string[],
    attachments?: CommentAttachment[],
    /** Only when the host passed `visibility` (client lane). */
    visibility?: PostVisibility
  ) => Promise<void> | void;
```

```ts
  /**
   * Client lane (spec 2026-10-01 §6.2), opt-in. Omit — as decks, the task
   * sheet and the client page do — and the thread is exactly as before:
   * no dashed card, no reply marker, no toggle, and `onReply` gets three
   * arguments.
   */
  visibility?: ThreadVisibility;
  /**
   * Client page: agency replies this viewer has not seen yet. Each gets a
   * "New" chip, and the collapsed reply toggle says how many are new — the
   * list starts collapsed, so a marker inside it alone would go unseen.
   */
  newCommentIds?: ReadonlySet<string>;
```

(c) `CommentRow`: add two props to its destructure and its prop type:

```ts
  isNew = false,
  teamOnlyMark = false,
```

```ts
  /** Client page: an agency reply this viewer has not seen yet. */
  isNew?: boolean;
  /** A Team-only reply on a thread the client can read (client lane). */
  teamOnlyMark?: boolean;
```

In its header, insert right after the `{comment.editedAt && ( … )}` block:

```tsx
          {teamOnlyMark && (
            <span
              className="flex shrink-0 items-center gap-0.5 font-geist text-textXs text-text-inverse-subtlest"
              title="Only your team sees this reply"
            >
              <LockSimpleIcon size={10} aria-hidden />
              team only
            </span>
          )}
          {isNew && <NewChip />}
```

(d) In `CommentThread`'s destructure add `visibility,` and `newCommentIds,`. After `const showsResolved = …;` add:

```ts
  // Client lane: what the reply composer's toggle currently says. Resets
  // after each post, so the next reply starts at the default again.
  const [replyTeamOnly, setReplyTeamOnly] = useState(false);
  const newReplies = newCommentIds
    ? thread.replies.filter((r) => newCommentIds.has(r.id)).length
    : 0;
```

(e) The card `className`: replace

```ts
          : "border-border-default bg-surface-default") +
```

with

```ts
          : "border-border-default bg-surface-default") +
        // Team only (client lane): dashed, so "the client cannot see this"
        // reads at a glance without another label on the card.
        (visibility?.teamOnly ? " border-dashed" : "") +
```

(f) The parent `CommentRow` gets `isNew={newCommentIds?.has(thread.parent.id) ?? false}`. Each reply `CommentRow` gets:

```tsx
                isNew={newCommentIds?.has(reply.id) ?? false}
                // Only on a thread the client can read — under a Team-only
                // root every reply is team only, and the dashed card says so.
                teamOnlyMark={
                  Boolean(visibility) && !visibility?.teamOnly && reply.internalOnly
                }
```

(g) The collapsed toggle text: replace

```tsx
          {repliesOpen
            ? "Hide replies"
            : `${thread.replies.length} ${
                thread.replies.length === 1 ? "reply" : "replies"
              }`}
```

with

```tsx
          {repliesOpen
            ? "Hide replies"
            : `${thread.replies.length} ${
                thread.replies.length === 1 ? "reply" : "replies"
              }${newReplies > 0 ? ` · ${newReplies} new` : ""}`}
```

(h) The reply `CommentComposer`: add a `hintText` prop and replace `onSubmit`:

```tsx
          <CommentComposer
            compact
            submitLabel="Reply"
            mentionCandidates={mentionCandidates}
            allowAttachments={allowAttachments}
            hintText={
              visibility?.teamOnly ? (
                <TeamOnlyHint />
              ) : visibility?.replyToggle ? (
                <CommentVisibilityToggle
                  teamOnly={replyTeamOnly}
                  onChange={setReplyTeamOnly}
                  composer="reply"
                />
              ) : undefined
            }
            onSubmit={async (body, mentions, attachments) => {
              try {
                if (visibility) {
                  await onReply?.(body, mentions, attachments, {
                    internalOnly:
                      visibility.teamOnly ||
                      (visibility.replyToggle && replyTeamOnly),
                  });
                } else {
                  // No opt-in: exactly today's three-argument call.
                  await onReply?.(body, mentions, attachments);
                }
                // Reveal it: a reply that lands into a collapsed list looks
                // like it failed to send.
                setRepliesOpen(true);
                setReplyOpen(false);
                setReplyTeamOnly(false);
              } catch {
                // The hook already toasts the failure; keep the composer
                // open so the reply text is not lost.
              }
            }}
          />
```

- [ ] **Step 4: Run them to see them pass (test)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/CommentThread.visibility.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/CommentThread.test.tsx
```

Expected: all pass. The second suite should match its Task 0 count.

- [ ] **Step 5: Mutation check (test)**

- Replace the `if (visibility) {…} else {…}` with only the 4-argument call → "calls onReply with exactly three arguments…" FAILS. Restore.
- Remove the `${newReplies > 0 ? …}` suffix → "marks new replies and counts them…" FAILS. Restore.

- [ ] **Step 6: Gates + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/comments/CommentThread.tsx src/components/comments/CommentThread.visibility.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "src/components/comments/|src/components/client-lane/PinList"
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/comments/CommentThread.tsx src/components/comments/CommentThread.visibility.test.tsx && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): comment threads show team-only posts, offer the reply visibility toggle, mark new replies

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: web — `CommentSidePanel`: Client label and pill, Visibility › Team only

Load `frndos-ui` → `frndos-components` (Label, PillTabs, Dropdown) and `frndos-design-foundations` first.

**Files:**
- Modify: `src/components/comments/CommentSidePanel.tsx`
- Create: `src/components/comments/CommentSidePanel.clientLane.test.tsx`

**Interfaces:**
- Consumes:
  - `isClientThread`, `threadVisibility`, `PostVisibility` (Task 3);
  - `ClientChip`, `TeamOnlyChip` (Task 4);
  - `trackCommentsClientFilterUsed` (Task 4);
  - `CommentThread.visibility` (Task 5).
- Produces:

```ts
export type CommentPanelFilter = "all" | "client" | "unresolved" | "resolved" | "mine";
// CommentSidePanelProps
onReply: (threadId: string, body: string, mentions: string[], attachments?: CommentAttachment[], visibility?: PostVisibility) => Promise<void> | void;
/** Omit (the deck dock) → nothing changes; onReply keeps receiving FOUR arguments. */
clientLane?: { requestThreadIds?: ReadonlySet<string> };
```

**Behaviour (with `clientLane`):**
- **Client pill.** It comes second in the row (`All · Client {n} · Open · Done · @me`), and `n` = threads with any client comment. It renders while `n > 0` **or** while it is the active filter (Review Focus 2).
- **Visibility group.** It is the first group in the Filter dropdown and holds one item, `Team only` (the root is `internal_only`). It combines with the other extras, counts in `activeExtras`, and is cleared by "Clear filters".
- **Anchor row.** Client threads get `ClientChip`, and Team-only roots get `TeamOnlyChip`. Both sit in the slot where `Artboard deleted` sits.
- **Threads** get `visibility={threadVisibility(thread, clientLane.requestThreadIds)}`.
- **Analytics.** `comments.client_filter_used` fires when the Client pill or Team only is switched on.

- [ ] **Step 1: Write the failing tests (test)**

`src/components/comments/CommentSidePanel.clientLane.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { useState } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { Comment, CommentThread } from "@/types/comments";

import CommentSidePanel, {
  type CommentPanelFilter,
  type CommentSidePanelProps,
} from "./CommentSidePanel";

const body = () => within(document.body);
const AT = "2026-10-01T08:00:00.000Z";
afterEach(() => vi.restoreAllMocks());

function comment(id: string, over: Partial<Comment> = {}): Comment {
  return {
    id,
    commentableType: "kv_file",
    commentableId: "f1",
    anchor: { kind: "pin", id: "craft:g1:board.g1", x: 0.5, y: 0.5 },
    parentId: null,
    author: { id: "u1", name: "Ana" },
    body: `Note ${id}`,
    mentions: [],
    internalOnly: false,
    resolvedAt: null,
    resolvedById: null,
    createdAt: AT,
    updatedAt: AT,
    ...over,
  };
}
const DINA = { id: "guest:Dina", name: "Dina", external: true };
const CLIENT: CommentThread = { parent: comment("c1", { author: DINA, body: "Logo smaller please" }), replies: [] };
const TEAM: CommentThread = { parent: comment("t1", { body: "Swap the font" }), replies: [] };
const INTERNAL: CommentThread = {
  parent: comment("i1", { body: "Internal: budget", internalOnly: true }),
  replies: [],
};

function Harness({
  initialFilter,
  ...props
}: Partial<CommentSidePanelProps> & { initialFilter?: CommentPanelFilter }) {
  const [filter, setFilter] = useState<CommentPanelFilter>(initialFilter ?? "all");
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return (
    <QueryClientProvider client={client}>
      <CommentSidePanel
        threads={[]}
        selectedThreadId={null}
        onSelect={() => {}}
        pinsVisible
        onTogglePins={() => {}}
        onClose={() => {}}
        onReply={() => {}}
        onResolveToggle={() => {}}
        renderAnchorLabel={() => "Craft · v1 · Board 1"}
        mentionCandidates={[]}
        {...props}
        activeFilter={filter}
        onFilterChange={setFilter}
      />
    </QueryClientProvider>
  );
}

/** The `<li>` (anchor row + card) holding a thread's body text. */
const rowOf = (text: string) => body().getByText(text).closest("li") as HTMLElement;
const pillTexts = () =>
  body()
    .getAllByRole("button")
    .map((b) => b.textContent ?? "");

/** jsdom has no Range layout; the mention editor measures the caret. */
async function typeReply(user: ReturnType<typeof userEvent.setup>, row: HTMLElement, text: string) {
  const proto = Range.prototype as unknown as { getBoundingClientRect?: () => DOMRect };
  const had = proto.getBoundingClientRect;
  proto.getBoundingClientRect = () =>
    ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;
  try {
    await user.type(within(row).getByRole("textbox", { name: /Write a reply/ }), text);
  } finally {
    proto.getBoundingClientRect = had;
  }
}

describe("CommentSidePanel — client lane", () => {
  it("labels a client thread and counts it in a Client pill, second in the row", () => {
    render(<Harness clientLane={{}} threads={[CLIENT, TEAM]} />);
    const texts = pillTexts();
    const all = texts.findIndex((t) => t.startsWith("All"));
    const client = texts.findIndex((t) => t.startsWith("Client"));
    const open = texts.findIndex((t) => t.startsWith("Open"));
    expect(texts[client]).toBe("Client1");
    expect(all).toBeLessThan(client);
    expect(client).toBeLessThan(open);
    expect(within(rowOf("Logo smaller please")).getByText("Client")).toBeInTheDocument();
    expect(within(rowOf("Swap the font")).queryByText("Client")).not.toBeInTheDocument();
  });

  it("filters to client threads and records the filter", () => {
    const capture = vi.spyOn(posthog, "capture").mockImplementation(() => undefined as never);
    render(<Harness clientLane={{}} threads={[CLIENT, TEAM]} />);
    fireEvent.click(body().getByRole("button", { name: /^Client/ }));
    expect(body().getByText("Logo smaller please")).toBeInTheDocument();
    expect(body().queryByText("Swap the font")).not.toBeInTheDocument();
    expect(capture).toHaveBeenCalledWith(
      "comments.client_filter_used",
      expect.objectContaining({ filter: "client" })
    );
  });

  it("hides the Client pill when the file has no client comments", () => {
    render(<Harness clientLane={{}} threads={[TEAM]} />);
    expect(body().queryByRole("button", { name: /^Client/ })).not.toBeInTheDocument();
  });

  it("keeps the Client pill while it is the active filter, even with no client thread left", () => {
    render(<Harness clientLane={{}} initialFilter="client" threads={[TEAM]} />);
    expect(body().getByRole("button", { name: /^Client/ })).toBeInTheDocument();
    fireEvent.click(body().getByRole("button", { name: /^All/ }));
    expect(body().getByText("Swap the font")).toBeInTheDocument();
  });

  it("narrows to Team only threads from Filter › Visibility and styles them", () => {
    const capture = vi.spyOn(posthog, "capture").mockImplementation(() => undefined as never);
    render(<Harness clientLane={{}} threads={[TEAM, INTERNAL]} />);
    const internalRow = rowOf("Internal: budget");
    expect(within(internalRow).getByText("Team only")).toBeInTheDocument();
    expect(internalRow.querySelector(".border-dashed")).not.toBeNull();
    expect(rowOf("Swap the font").querySelector(".border-dashed")).toBeNull();

    fireEvent.click(body().getByRole("button", { name: "More filters" }));
    expect(body().getByText("Visibility")).toBeInTheDocument();
    fireEvent.click(body().getByRole("button", { name: "Team only" }));
    expect(body().queryByText("Swap the font")).not.toBeInTheDocument();
    expect(body().getByText("Internal: budget")).toBeInTheDocument();
    expect(capture).toHaveBeenCalledWith(
      "comments.client_filter_used",
      expect.objectContaining({ filter: "team_only" })
    );
  });

  it("replies 'Client sees this' by default on a client thread, Team only when toggled", async () => {
    const onReply = vi.fn();
    const user = userEvent.setup();
    render(<Harness clientLane={{}} threads={[CLIENT]} onReply={onReply} />);
    const row = rowOf("Logo smaller please");

    await user.click(within(row).getByRole("button", { name: "Reply" }));
    await typeReply(user, row, "On it{Enter}");
    await waitFor(() =>
      expect(onReply).toHaveBeenCalledWith("c1", "On it", [], undefined, { internalOnly: false })
    );

    await user.click(within(row).getByRole("button", { name: "Reply" }));
    await user.click(within(row).getByRole("button", { name: "Client sees this" }));
    await typeReply(user, row, "Ask Budi first{Enter}");
    await waitFor(() =>
      expect(onReply).toHaveBeenLastCalledWith("c1", "Ask Budi first", [], undefined, {
        internalOnly: true,
      })
    );
  });

  it("offers the toggle on a team thread only while its artboard is under review", async () => {
    const user = userEvent.setup();
    const { unmount } = render(
      <Harness clientLane={{ requestThreadIds: new Set(["t1"]) }} threads={[TEAM]} />
    );
    await user.click(within(rowOf("Swap the font")).getByRole("button", { name: "Reply" }));
    expect(body().getByRole("button", { name: "Client sees this" })).toBeInTheDocument();
    unmount();

    render(<Harness clientLane={{}} threads={[TEAM]} />);
    await user.click(within(rowOf("Swap the font")).getByRole("button", { name: "Reply" }));
    expect(body().queryByRole("button", { name: "Client sees this" })).not.toBeInTheDocument();
  });

  it("keeps replies on a Team only thread team only, with no toggle", async () => {
    const onReply = vi.fn();
    const user = userEvent.setup();
    render(
      <Harness
        clientLane={{ requestThreadIds: new Set(["i1"]) }}
        threads={[INTERNAL]}
        onReply={onReply}
      />
    );
    const row = rowOf("Internal: budget");
    await user.click(within(row).getByRole("button", { name: "Reply" }));
    expect(within(row).queryByRole("button", { name: "Client sees this" })).not.toBeInTheDocument();
    await typeReply(user, row, "Agreed{Enter}");
    await waitFor(() =>
      expect(onReply).toHaveBeenCalledWith("i1", "Agreed", [], undefined, { internalOnly: true })
    );
  });
});

describe("CommentSidePanel — without clientLane (the deck dock)", () => {
  it("adds no pill, label, filter group or toggle, and replies with four arguments", async () => {
    const onReply = vi.fn();
    const user = userEvent.setup();
    render(<Harness threads={[CLIENT, INTERNAL]} onReply={onReply} />);

    expect(body().queryByRole("button", { name: /^Client/ })).not.toBeInTheDocument();
    expect(within(rowOf("Logo smaller please")).queryByText("Client")).not.toBeInTheDocument();
    expect(within(rowOf("Internal: budget")).queryByText("Team only")).not.toBeInTheDocument();
    expect(rowOf("Internal: budget").querySelector(".border-dashed")).toBeNull();

    fireEvent.click(body().getByRole("button", { name: "More filters" }));
    expect(body().queryByText("Visibility")).not.toBeInTheDocument();
    fireEvent.keyDown(document.body, { key: "Escape" });

    const row = rowOf("Logo smaller please");
    await user.click(within(row).getByRole("button", { name: "Reply" }));
    expect(within(row).queryByRole("button", { name: "Client sees this" })).not.toBeInTheDocument();
    await typeReply(user, row, "Noted{Enter}");
    await waitFor(() => expect(onReply).toHaveBeenCalledTimes(1));
    expect(onReply.mock.calls[0]).toEqual(["c1", "Noted", [], undefined]);
  });
});
```

- [ ] **Step 2: Run them to see them fail (test)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/CommentSidePanel.clientLane.test.tsx
```

Expected: every client-lane test FAILS (no pill, label or group, and `clientLane` is an unknown prop at type level only). The deck regression test passes already.

- [ ] **Step 3: Implement**

In `src/components/comments/CommentSidePanel.tsx`:

(a) Imports, below `import CommentThread from "./CommentThread";`:

```ts
import { ClientChip, TeamOnlyChip } from "./CommentChips";
import {
  isClientThread,
  threadVisibility,
  type PostVisibility,
} from "./commentVisibility";
import { trackCommentsClientFilterUsed } from "@/lib/analytics/client-lane-events";
```

(b) Replace the filter type and add the client pill constant below `FILTERS`:

```ts
export type CommentPanelFilter =
  | "all"
  | "client"
  | "unresolved"
  | "resolved"
  | "mine";
```

```ts
/**
 * Client lane (spec 2026-10-01 §6.2): second in the row, and only on hosts
 * that opt in — `All · Client {n} · Open · Done · @me`.
 */
const CLIENT_FILTER: { value: CommentPanelFilter; label: string } = {
  value: "client",
  label: "Client",
};
```

(c) In `CommentSidePanelProps`, replace `onReply` and add `clientLane` after `floating?`:

```ts
  onReply: (
    threadId: string,
    body: string,
    mentions: string[],
    attachments?: CommentAttachment[],
    /** Only when `clientLane` is set: who the reply is for. */
    visibility?: PostVisibility
  ) => Promise<void> | void;
```

```ts
  /**
   * Client lane, KV (spec 2026-10-01 §6.2). Omit — as the deck dock does —
   * and nothing here changes: no Client pill or label, no Visibility filter,
   * no Team-only styling, no reply toggle, and `onReply` keeps receiving four
   * arguments.
   */
  clientLane?: {
    /**
     * Root ids whose artboard is pending in an open approval request: the
     * client is reviewing it now, so replies there offer the visibility
     * toggle even before the client has written.
     */
    requestThreadIds?: ReadonlySet<string>;
  };
```

(d) Destructure `clientLane,` (after `floating = false,`). Replace the `activeExtras` block with:

```ts
  const [teamOnly, setTeamOnly] = useState(false);

  const authors = useMemo(() => threadAuthors(threads), [threads]);
  const activeExtras =
    (withAttachments ? 1 : 0) +
    (authorIds.length > 0 ? 1 : 0) +
    (teamOnly ? 1 : 0);

  const clientCount = useMemo(
    () => (clientLane ? threads.filter(isClientThread).length : 0),
    [clientLane, threads]
  );
  // Rendered while it is SELECTED too: if the last client thread leaves
  // scope, a hidden active pill would leave an empty list with no way out.
  const showClientPill =
    Boolean(clientLane) && (clientCount > 0 || activeFilter === "client");
  const pillFilters = showClientPill
    ? [FILTERS[0], CLIENT_FILTER, ...FILTERS.slice(1)]
    : FILTERS;
```

(Delete the original `const authors = …` and `const activeExtras = …` lines this replaces.)

(e) In `byStatus`, add as the first branch:

```ts
    if (activeFilter === "client") return threads.filter(isClientThread);
```

(f) In `visible`, after the `withAttachments` filter add:

```ts
    if (teamOnly) out = out.filter((t) => t.parent.internalOnly);
```

and add `teamOnly` to its dependency array: `[byStatus, query, withAttachments, authorIds, teamOnly]`.

(g) `resetFilters`: add `setTeamOnly(false);`.

(h) `PillTabs` `tabs`: replace `FILTERS.map((f) => {` with `pillFilters.map((f) => {`. Replace the `count` expression and `onClick` with:

```ts
                const count =
                  f.value === "all"
                    ? counts.all
                    : f.value === "client"
                      ? clientCount
                      : f.value === "unresolved"
                        ? counts.unresolved
                        : f.value === "resolved"
                          ? counts.resolved
                          : undefined;
                return {
                  label: f.label,
                  active: activeFilter === f.value,
                  onClick: () => {
                    if (f.value === "client" && activeFilter !== "client") {
                      trackCommentsClientFilterUsed({ filter: "client" });
                    }
                    onFilterChange(f.value);
                  },
```

(the `badge:` member stays as it is).

(i) `Dropdown.Content`: insert as its FIRST child, before the Attachment group:

```tsx
              {clientLane && (
                <div className="flex flex-col">
                  <div className="px-2 pb-0.5 pt-2 font-geist text-textXsMedium text-text-inverse-subtlest">
                    Visibility
                  </div>
                  <button
                    type="button"
                    aria-pressed={teamOnly}
                    onClick={() => {
                      if (!teamOnly) {
                        trackCommentsClientFilterUsed({ filter: "team_only" });
                      }
                      setTeamOnly((v) => !v);
                    }}
                    className="flex w-full items-center justify-between rounded-xl p-2 text-left font-geist text-textSm text-text-inverse-subtle transition-colors hover:bg-white/5 hover:text-text-inverse"
                  >
                    Team only
                    <FilterCheckbox checked={teamOnly} />
                  </button>
                </div>
              )}
```

(j) The anchor row: insert right after `<span className="min-w-0 truncate">{renderAnchorLabel(thread)}</span>`:

```tsx
                {/* Client lane: who can read this thread, in the slot the
                    deleted-artboard chip uses. */}
                {clientLane && isClientThread(thread) && <ClientChip />}
                {clientLane && thread.parent.internalOnly && <TeamOnlyChip />}
```

(k) The `CommentThread` element: add the `visibility` prop and replace `onReply`:

```tsx
                  visibility={
                    clientLane
                      ? threadVisibility(thread, clientLane.requestThreadIds)
                      : undefined
                  }
                  onReply={(body, mentions, attachments, visibility) =>
                    clientLane
                      ? onReply(
                          thread.parent.id,
                          body,
                          mentions,
                          attachments,
                          visibility
                        )
                      : // No opt-in: exactly today's four-argument call.
                        onReply(thread.parent.id, body, mentions, attachments)
                  }
```

- [ ] **Step 4: Run them to see them pass (test)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/CommentSidePanel.clientLane.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/CommentSidePanel.test.tsx
```

Expected: all pass. The second suite should match its Task 0 count.

If the dropdown's Escape in the regression test does not close it, delete that `fireEvent.keyDown` line: the open menu does not cover the thread rows in jsdom.

- [ ] **Step 5: Mutation check (test)**

- Change `showClientPill` to `Boolean(clientLane) && clientCount > 0` → "keeps the Client pill while it is the active filter…" FAILS. Restore.
- In (k), call the 5-argument form unconditionally → "adds no pill, label, filter group or toggle, and replies with four arguments" FAILS. Restore.

- [ ] **Step 6: Gates + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/comments/CommentSidePanel.tsx src/components/comments/CommentSidePanel.clientLane.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "src/components/comments/|AnchoredComments"
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/comments/CommentSidePanel.tsx src/components/comments/CommentSidePanel.clientLane.test.tsx && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): KV comments dock — Client label and pill, Team only filter, reply visibility (opt-in)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: web — `CommentThreadPopover`: Team-only default for new root threads

**Files:**
- Modify: `src/components/comments/CommentThreadPopover.tsx`
- Create: `src/components/comments/CommentThreadPopover.visibility.test.tsx`

**Interfaces:**
- Consumes:
  - `PostVisibility` and `ThreadVisibility` (Task 3);
  - `CommentVisibilityToggle` (Task 4);
  - `trackCommentsTeamOnlyThreadCreated` (Task 4);
  - `CommentThread.visibility` (Task 5).
- Produces (on `CommentThreadPopoverProps`):

```ts
onReply?: (body, mentions, attachments?, visibility?: PostVisibility) => …;      // passed straight to CommentThread
onSubmitDraft?: (body, mentions, attachments?, visibility?: PostVisibility) => …; // 4th arg only when draftVisibility is set
visibility?: ThreadVisibility;                              // thread mode, client lane
draftVisibility?: { defaultTeamOnly: boolean } | null;      // draft mode, client lane
```

**Behaviour:**
- With `draftVisibility`, the draft composer's hint slot shows the toggle. Its state is `choice ?? draftVisibility.defaultTeamOnly`, and `choice` stays `null` until the reviewer clicks. So data that arrives late moves the default (Review Focus 3), and a click is never overridden.
- Submit passes `{ internalOnly }`. On a Team-only post it fires `comments.team_only_thread_created { defaulted: choice === null }`.
- Without `draftVisibility`, the composer and the 3-argument `onSubmitDraft` are exactly as today.

- [ ] **Step 1: Write the failing tests (test)**

`src/components/comments/CommentThreadPopover.visibility.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { Comment } from "@/types/comments";

import CommentThreadPopover, {
  type CommentThreadPopoverProps,
} from "./CommentThreadPopover";

const body = () => within(document.body);
const AT = "2026-10-01T08:00:00.000Z";
afterEach(() => vi.restoreAllMocks());

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

const AT_RECT = { left: 10, top: 10, width: 24, height: 24 };

function popover(props: Partial<CommentThreadPopoverProps>) {
  return (
    <CommentThreadPopover at={AT_RECT} onClose={() => {}} mentionCandidates={[]} {...props} />
  );
}

async function typeInto(user: ReturnType<typeof userEvent.setup>, name: RegExp, text: string) {
  const proto = Range.prototype as unknown as { getBoundingClientRect?: () => DOMRect };
  const had = proto.getBoundingClientRect;
  proto.getBoundingClientRect = () =>
    ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;
  try {
    await user.type(body().getByRole("textbox", { name }), text);
  } finally {
    proto.getBoundingClientRect = had;
  }
}

describe("CommentThreadPopover — draft visibility", () => {
  it("starts Team only on an artboard under review and records a defaulted team-only thread", async () => {
    const capture = vi.spyOn(posthog, "capture").mockImplementation(() => undefined as never);
    const onSubmitDraft = vi.fn();
    const user = userEvent.setup();
    render(popover({ onSubmitDraft, draftVisibility: { defaultTeamOnly: true } }), { wrapper: Wrapper });
    expect(body().getByRole("button", { name: "Team only" })).toBeInTheDocument();
    await typeInto(user, /Write a comment/, "Check the crop first{Enter}");
    await waitFor(() =>
      expect(onSubmitDraft).toHaveBeenCalledWith("Check the crop first", [], undefined, {
        internalOnly: true,
      })
    );
    expect(capture).toHaveBeenCalledWith(
      "comments.team_only_thread_created",
      expect.objectContaining({ defaulted: true })
    );
  });

  it("posts for the client when the reviewer switches it, without the team-only event", async () => {
    const capture = vi.spyOn(posthog, "capture").mockImplementation(() => undefined as never);
    const onSubmitDraft = vi.fn();
    const user = userEvent.setup();
    render(popover({ onSubmitDraft, draftVisibility: { defaultTeamOnly: true } }), { wrapper: Wrapper });
    await user.click(body().getByRole("button", { name: "Team only" }));
    await typeInto(user, /Write a comment/, "Dina, is this better?{Enter}");
    await waitFor(() =>
      expect(onSubmitDraft).toHaveBeenCalledWith("Dina, is this better?", [], undefined, {
        internalOnly: false,
      })
    );
    expect(capture).not.toHaveBeenCalledWith("comments.team_only_thread_created", expect.anything());
  });

  it("starts Team only when the pending state arrives after the draft opened", () => {
    const { rerender } = render(popover({ draftVisibility: null }), { wrapper: Wrapper });
    expect(body().queryByRole("button", { name: "Team only" })).not.toBeInTheDocument();
    rerender(popover({ draftVisibility: { defaultTeamOnly: true } }));
    expect(body().getByRole("button", { name: "Team only" })).toBeInTheDocument();
  });

  it("keeps the reviewer's choice when the default changes", async () => {
    const user = userEvent.setup();
    const { rerender } = render(popover({ draftVisibility: { defaultTeamOnly: true } }), {
      wrapper: Wrapper,
    });
    await user.click(body().getByRole("button", { name: "Team only" }));
    rerender(popover({ draftVisibility: { defaultTeamOnly: true } }));
    expect(body().getByRole("button", { name: "Client sees this" })).toBeInTheDocument();
  });

  it("without draftVisibility shows no toggle and submits three arguments", async () => {
    const onSubmitDraft = vi.fn();
    const user = userEvent.setup();
    render(popover({ onSubmitDraft }), { wrapper: Wrapper });
    expect(body().queryByRole("button", { name: /Team only|Client sees this/ })).not.toBeInTheDocument();
    await typeInto(user, /Write a comment/, "Plain{Enter}");
    await waitFor(() => expect(onSubmitDraft).toHaveBeenCalledTimes(1));
    expect((onSubmitDraft.mock.calls[0] as unknown[]).length).toBe(3);
  });
});

describe("CommentThreadPopover — thread visibility", () => {
  it("passes the thread's rules through to its replies", async () => {
    const onReply = vi.fn();
    const user = userEvent.setup();
    const parent: Comment = {
      id: "i1",
      commentableType: "kv_file",
      commentableId: "f1",
      anchor: { kind: "pin", id: "craft:g1:board.g1", x: 0.5, y: 0.5 },
      parentId: null,
      author: { id: "u1", name: "Ana" },
      body: "Internal: budget",
      mentions: [],
      internalOnly: true,
      resolvedAt: null,
      resolvedById: null,
      createdAt: AT,
      updatedAt: AT,
    };
    render(
      popover({
        thread: { parent, replies: [] },
        onReply,
        visibility: { teamOnly: true, replyToggle: false },
      }),
      { wrapper: Wrapper }
    );
    await user.click(body().getByRole("button", { name: "Reply" }));
    await typeInto(user, /Write a reply/, "Agreed{Enter}");
    await waitFor(() =>
      expect(onReply).toHaveBeenCalledWith("Agreed", [], undefined, { internalOnly: true })
    );
  });
});
```

- [ ] **Step 2: Run them to see them fail (test)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/CommentThreadPopover.visibility.test.tsx
```

Expected:
- FAIL: the first four draft tests and the thread test.
- PASS already: "without draftVisibility…".

- [ ] **Step 3: Implement**

In `src/components/comments/CommentThreadPopover.tsx`:

(a) Imports:

```ts
import type { PostVisibility, ThreadVisibility } from "./commentVisibility";
import { CommentVisibilityToggle } from "./CommentVisibilityToggle";
import { trackCommentsTeamOnlyThreadCreated } from "@/lib/analytics/client-lane-events";
```

(b) Props: replace `onReply?` and `onSubmitDraft?`, and add two members after `draftDisabledReason?`:

```ts
  onReply?: (
    body: string,
    mentions: string[],
    attachments?: CommentAttachment[],
    visibility?: PostVisibility
  ) => Promise<void> | void;
  /** New-thread submit, used when `thread` is null (draft composer). The
   *  4th argument comes only when `draftVisibility` is set. */
  onSubmitDraft?: (
    body: string,
    mentions: string[],
    attachments?: CommentAttachment[],
    visibility?: PostVisibility
  ) => Promise<void> | void;
```

```ts
  /** Client lane: the open thread's rules (CommentThread `visibility`). */
  visibility?: ThreadVisibility;
  /**
   * Client lane (spec 2026-10-01 §6.2): the draft sits on an artboard the
   * client is reviewing, so the composer offers "Client sees this / Team
   * only", starting at `defaultTeamOnly`. Omit or null for today's composer.
   */
  draftVisibility?: { defaultTeamOnly: boolean } | null;
```

(c) Destructure `visibility,` and `draftVisibility,`. Right after `const ref = useRef<HTMLDivElement>(null);` add:

```ts
  // `null` until the reviewer clicks: the default follows the data (the
  // requests query can land after the draft opened), a click never moves.
  const [draftTeamOnlyChoice, setDraftTeamOnlyChoice] = useState<
    boolean | null
  >(null);
  const draftTeamOnly =
    draftTeamOnlyChoice ?? draftVisibility?.defaultTeamOnly ?? false;
```

(d) The draft `CommentComposer`: replace its `onSubmit` and add `hintText`:

```tsx
          <CommentComposer
            onSubmit={async (body, mentions, attachments) => {
              if (!draftVisibility) {
                await onSubmitDraft?.(body, mentions, attachments);
                return;
              }
              await onSubmitDraft?.(body, mentions, attachments, {
                internalOnly: draftTeamOnly,
              });
              if (draftTeamOnly) {
                trackCommentsTeamOnlyThreadCreated({
                  defaulted: draftTeamOnlyChoice === null,
                });
              }
            }}
            hintText={
              draftVisibility ? (
                <CommentVisibilityToggle
                  teamOnly={draftTeamOnly}
                  onChange={setDraftTeamOnlyChoice}
                  composer="root"
                />
              ) : undefined
            }
            mentionCandidates={mentionCandidates}
            allowAttachments
            disabled={Boolean(draftDisabledReason)}
          />
```

(e) The thread-mode `CommentThread`: add `visibility={visibility}` (its `onReply={onReply}` already forwards all four arguments).

- [ ] **Step 4: Run them to see them pass (test)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/CommentThreadPopover.visibility.test.tsx
```

Expected: all pass.

- [ ] **Step 5: Mutation check (test)**

- Change `useState<boolean | null>(null)` + `??` to a plain `useState(draftVisibility?.defaultTeamOnly ?? false)` (and use it directly) → "starts Team only when the pending state arrives after the draft opened" FAILS. Restore.
- Change `defaulted: draftTeamOnlyChoice === null` to `defaulted: false` → "starts Team only … records a defaulted team-only thread" FAILS. Restore.

- [ ] **Step 6: Gates + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/comments/CommentThreadPopover.tsx src/components/comments/CommentThreadPopover.visibility.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "src/components/comments/|AnchoredComments"
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/comments/CommentThreadPopover.tsx src/components/comments/CommentThreadPopover.visibility.test.tsx && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): new team threads on an artboard under review start Team only (opt-in)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: web — `CommentPinOverlay`: yellow ring on client faces

**Files:**
- Modify: `src/components/comments/CommentPinOverlay.tsx` (`threadParticipants` 62–77; props 79–112; faces 313–335)
- Create: `src/components/comments/CommentPinOverlay.clientFaces.test.tsx`

**Interfaces:**
- Consumes: `CommentAuthor.external` (Task 2).
- Produces:
  - `threadParticipants(thread): { id; name; avatarUrl?; external?: true }[]` (the flag only when true);
  - `CommentPinOverlayProps.markClientFaces?: boolean`. With it set, external faces get `ring-yellow-400` (2px, as the blue ring) and `data-client-face=""`.

**Ruling:** opt-in. Deck pins also carry client faces (P0a deck links), and the deck canvas must not change (spec D-2).

- [ ] **Step 1: Write the failing test (test)**

`src/components/comments/CommentPinOverlay.clientFaces.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { render } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import type { Comment, CommentThread } from "@/types/comments";

import CommentPinOverlay, { threadParticipants } from "./CommentPinOverlay";

const AT = "2026-10-01T08:00:00.000Z";
function comment(id: string, over: Partial<Comment> = {}): Comment {
  return {
    id,
    commentableType: "kv_file",
    commentableId: "f1",
    anchor: { kind: "pin", id: "craft:g1:board.g1", x: 0.5, y: 0.5 },
    parentId: null,
    author: { id: "u1", name: "Ana" },
    body: `Note ${id}`,
    mentions: [],
    internalOnly: false,
    resolvedAt: null,
    resolvedById: null,
    createdAt: AT,
    updatedAt: AT,
    ...over,
  };
}
const THREAD: CommentThread = {
  parent: comment("c1", { author: { id: "guest:Dina", name: "Dina", external: true } }),
  replies: [comment("r1", { parentId: "c1" })],
};
const item = { thread: THREAD, x: 0.5, y: 0.5, partRect: { left: 0, top: 0, width: 200, height: 200 } };

describe("CommentPinOverlay — client faces", () => {
  it("keeps the external flag on participants", () => {
    expect(threadParticipants(THREAD)).toEqual([
      { id: "guest:Dina", name: "Dina", avatarUrl: undefined, external: true },
      { id: "u1", name: "Ana", avatarUrl: undefined },
    ]);
  });

  it("rings the client's face yellow when the host opts in", () => {
    render(
      <CommentPinOverlay items={[item]} visible selectedThreadId={null} onSelect={() => {}} markClientFaces />
    );
    const faces = document.body.querySelectorAll("[data-client-face]");
    expect(faces).toHaveLength(1);
    expect(faces[0].className).toContain("ring-yellow-400");
  });

  it("draws every face in the pin's blue without the opt-in", () => {
    render(<CommentPinOverlay items={[item]} visible selectedThreadId={null} onSelect={() => {}} />);
    expect(document.body.querySelectorAll("[data-client-face]")).toHaveLength(0);
    expect(document.body.innerHTML).not.toContain("ring-yellow-400");
  });
});
```

- [ ] **Step 2: Run it to see it fail (test)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/comments/CommentPinOverlay.clientFaces.test.tsx
```

Expected:
- FAIL: "keeps the external flag…" and "rings the client's face yellow…".
- PASS already: the no-opt-in test.

- [ ] **Step 3: Implement**

`threadParticipants`: replace the return type and the `out.push` call:

```ts
export function threadParticipants(
  thread: CommentThread
): { id: string; name: string; avatarUrl?: string; external?: true }[] {
  const seen = new Set<string>();
  const out: { id: string; name: string; avatarUrl?: string; external?: true }[] = [];
  for (const c of [thread.parent, ...thread.replies]) {
    if (seen.has(c.author.id)) continue;
    seen.add(c.author.id);
    out.push({
      id: c.author.id,
      name: c.author.name,
      avatarUrl: c.author.avatarUrl,
      // Client lane: the host may ring a client's face (markClientFaces).
      ...(c.author.external ? { external: true as const } : {}),
    });
  }
  return out;
}
```

Props: add after `cameraStore?`:

```ts
  /**
   * Client lane (spec 2026-10-01 §6.2): ring a client's face in yellow, the
   * colour of the dock's Client label, so a reviewer scanning the canvas can
   * tell the client's pins from the team's. Off for every other host.
   */
  markClientFaces?: boolean;
```

Destructure `markClientFaces = false,`. In the faces `.map`, replace the `className={clsx(…)}` and add the data attribute:

```tsx
                        // Ring in the pin's own blue so overlapping circles read
                        // as separate faces rather than one smeared shape. Ink
                        // stays Avatar's dark default — the generated colours
                        // are light, and white on them fails contrast. A
                        // client's face rings yellow when the host opts in.
                        className={clsx(
                          "ring-2",
                          markClientFaces && p.external
                            ? "ring-yellow-400"
                            : "ring-[#0B81FF]",
                          i > 0 && "-ml-3"
                        )}
                        data-client-face={
                          markClientFaces && p.external ? "" : undefined
                        }
```

- [ ] **Step 4: Run it to see it pass (test)**

Re-run Step 2. Expected: 3 passed.

- [ ] **Step 5: Mutation check (test)**

Change `markClientFaces && p.external` in the className to `p.external` → "draws every face in the pin's blue without the opt-in" FAILS. Restore.

- [ ] **Step 6: Gates + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/comments/CommentPinOverlay.tsx src/components/comments/CommentPinOverlay.clientFaces.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "src/components/comments/|KvGeneratorLayout"
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/comments/CommentPinOverlay.tsx src/components/comments/CommentPinOverlay.clientFaces.test.tsx && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): client pins ring the client's face in yellow (opt-in)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: web — wire Part C into the KV editor

**Files:**
- Create: `src/hooks/comments/useKvClientVisibility.ts`
- Create: `src/hooks/comments/useKvClientVisibility.test.tsx`
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx`:
  - imports ~197–221;
  - after `approvalVersionLabelById` ~3288–3292;
  - `handleSubmitDraft` ~3671–3712;
  - pin overlay ~8712;
  - draft popover ~8731;
  - thread popover ~8752;
  - dock ~8818–8849.

**Interfaces:**
- Consumes:
  - `useApprovalRequests` (`@/services/client-lane`, Part A);
  - `pendingArtboards`, `requestThreadIds`, `isPendingSpec` (Task 3);
  - `threadVisibility`, `PostVisibility` (Task 3);
  - the opt-in props from Tasks 6–8;
  - `PostAnchoredCommentInput.internalOnly` (Task 2).
- Produces:

```ts
export interface KvClientVisibility {
  pending: PendingArtboards;
  requestThreadIds: ReadonlySet<string>;
}
/** null while the flag is off — every opt-in prop is then omitted. */
export function useKvClientVisibility(
  fileId: string | null | undefined,
  threads: readonly CommentThread[],
  enabled: boolean
): KvClientVisibility | null;
```

- [ ] **Step 1: Write the failing hook test (test)**

`src/hooks/comments/useKvClientVisibility.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { renderHook, waitFor } from "@testing-library/react";
import { useState, type ReactNode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { buildPinAnchor } from "@/lib/comments/anchorCodec";
import axiosInstance from "@/services/axios";
import type { CommentThread } from "@/types/comments";

import { useKvClientVisibility } from "./useKvClientVisibility";

afterEach(() => vi.restoreAllMocks());

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

const thread = (id: string, version: string): CommentThread =>
  ({
    parent: { id, anchor: buildPinAnchor({ stage: "craft", version, part: `board.${version}` }, 0.5, 0.5) },
    replies: [],
  }) as unknown as CommentThread;
const THREADS = [thread("t1", "G1"), thread("t2", "G2")];

const REQUESTS = [
  {
    id: "q1",
    number: 1,
    status: "pending",
    approvals: [
      { id: "a1", subject_key: "board:G0", version_id: "G1", status: "pending", superseded_by_request_number: null },
    ],
  },
];

describe("useKvClientVisibility", () => {
  it("lists the threads on artboards pending in an open request", async () => {
    vi.spyOn(axiosInstance, "get").mockImplementation((async () => ({
      data: { data: REQUESTS },
    })) as never);
    const { result } = renderHook(() => useKvClientVisibility("f1", THREADS, true), {
      wrapper: Wrapper,
    });
    await waitFor(() => expect([...(result.current?.requestThreadIds ?? [])]).toEqual(["t1"]));
  });

  it("is null and asks nothing while the flag is off", () => {
    const get = vi.spyOn(axiosInstance, "get");
    const { result } = renderHook(() => useKvClientVisibility("f1", THREADS, false), {
      wrapper: Wrapper,
    });
    expect(result.current).toBeNull();
    expect(get).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run it to see it fail (test)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/hooks/comments/useKvClientVisibility.test.tsx
```

Expected: FAIL ("Cannot find module").

- [ ] **Step 3: Implement the hook**

`src/hooks/comments/useKvClientVisibility.ts`:

```ts
"use client";

import { useMemo } from "react";

import {
  pendingArtboards,
  requestThreadIds,
  type PendingArtboards,
} from "@/lib/client-lane/pendingArtboards";
import { useApprovalRequests } from "@/services/client-lane";
import type { CommentThread } from "@/types/comments";

/**
 * What KV's comment surfaces need for the client lane (spec 2026-10-01
 * §6.2): which artboards the client is reviewing right now, and which
 * threads hang off them. Reads the same `GET v1/approval-requests` the share
 * dialog and the version labels read (same query key — one request).
 *
 * `null` while the flag is off, so the editor passes none of the opt-in
 * props and its comment UI is exactly today's.
 */
export interface KvClientVisibility {
  pending: PendingArtboards;
  requestThreadIds: ReadonlySet<string>;
}

export function useKvClientVisibility(
  fileId: string | null | undefined,
  threads: readonly CommentThread[],
  enabled: boolean
): KvClientVisibility | null {
  const requests = useApprovalRequests(enabled ? fileId : null, { enabled });
  return useMemo(() => {
    if (!enabled) return null;
    const pending = pendingArtboards(requests.data ?? []);
    return { pending, requestThreadIds: requestThreadIds(threads, pending) };
  }, [enabled, requests.data, threads]);
}
```

- [ ] **Step 4: Run it to see it pass (test)**

Re-run Step 2. Expected: 2 passed.

- [ ] **Step 5: Wire `KvGeneratorLayout.tsx`**

(a) Imports. After `import { useCommentMode } from "@/hooks/comments/useCommentMode";` add:

```ts
import { useKvClientVisibility } from "@/hooks/comments/useKvClientVisibility";
import { isPendingSpec } from "@/lib/client-lane/pendingArtboards";
import {
  threadVisibility,
  type PostVisibility,
} from "@/components/comments/commentVisibility";
```

(b) Right after the `approvalVersionLabelById` declaration (the `useApprovalVersionLabels("kv_file", liveFileId, { enabled: clientLaneOn })` call) add:

```ts
  // Client lane Part C (spec 2026-10-01 §6.2): which artboards the client is
  // reviewing now. Null while the flag is off — every opt-in comment prop
  // below is then omitted and the dock, popover and pins are today's.
  const kvClientVisibility = useKvClientVisibility(
    liveFileId,
    commentThreads,
    clientLaneOn
  );
```

(c) Replace the whole `const handleSubmitDraft = useCallback( … );` (from its declaration through the closing `);` after its dependency array) with:

```ts
  // Where a draft would post. Version comes from the board that was CLICKED,
  // not the active one. On a multi-board canvas a pin can land on a
  // neighbour, and stamping the active board's generation id would file that
  // feedback against artwork the reviewer never looked at — and hide it from
  // the board it belongs to. Tile pins keep the parent's version.
  const draftAnchorSpec = useMemo(() => {
    if (!commentContext || !commentDraft) return null;
    const part = draftPart ?? scopedCommentPart ?? commentContext.part;
    const version = part.startsWith("board.")
      ? part.slice("board.".length)
      : commentContext.version;
    return { stage: commentContext.stage, version, part };
  }, [commentContext, commentDraft, draftPart, scopedCommentPart]);

  // Client lane: a new team thread on an artboard the client is reviewing
  // right now starts Team only (the composer shows the toggle).
  const draftVisibility = useMemo(
    () =>
      kvClientVisibility &&
      draftAnchorSpec &&
      isPendingSpec(draftAnchorSpec, kvClientVisibility.pending)
        ? { defaultTeamOnly: true }
        : null,
    [kvClientVisibility, draftAnchorSpec]
  );

  const handleSubmitDraft = useCallback(
    async (
      body: string,
      mentions: string[],
      attachments?: CommentAttachment[],
      visibility?: PostVisibility
    ) => {
      if (!draftAnchorSpec || !commentDraft) return;
      await postComment({
        body,
        mentions,
        attachments,
        internalOnly: visibility?.internalOnly,
        anchor: buildPinAnchor(draftAnchorSpec, commentDraft.x, commentDraft.y),
      });
      setDraftPart(null);
      // Sticky: stays in comment mode so a whole review pass needs no
      // re-selecting of the tool (J3).
      submitCommentDraft();
    },
    [draftAnchorSpec, commentDraft, postComment, submitCommentDraft]
  );
```

(d) `<CommentPinOverlay … />`: add `markClientFaces={clientLaneOn}` after `cameraStore={canvasCameraStore}`.

(e) The draft `<CommentThreadPopover … onSubmitDraft={handleSubmitDraft} … />`: add `draftVisibility={draftVisibility}` after `onSubmitDraft={handleSubmitDraft}`.

(f) The open-thread `<CommentThreadPopover thread={openThread} … />`: add after `thread={openThread}`:

```tsx
            visibility={
              kvClientVisibility
                ? threadVisibility(openThread, kvClientVisibility.requestThreadIds)
                : undefined
            }
```

and replace its `onReply`:

```tsx
            onReply={(body, mentions, attachments, visibility) =>
              replyToComment(openThread.parent.id, {
                body,
                mentions,
                attachments,
                internalOnly: visibility?.internalOnly,
              })
            }
```

(g) `<CommentSidePanel … />`: replace its `onReply` and add `clientLane` after `floating`:

```tsx
              clientLane={
                kvClientVisibility
                  ? { requestThreadIds: kvClientVisibility.requestThreadIds }
                  : undefined
              }
```

```tsx
              onReply={(threadId, body, mentions, attachments, visibility) =>
                replyToComment(threadId, {
                  body,
                  mentions,
                  attachments,
                  internalOnly: visibility?.internalOnly,
                })
              }
```

- [ ] **Step 6: Gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/hooks/comments/useKvClientVisibility.ts src/hooks/comments/useKvClientVisibility.test.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "useKvClientVisibility|KvGeneratorLayout"; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
```

Expected:
- the grep prints only `KvGeneratorLayout.tsx`'s ONE pre-existing error (the same line as in Task 0);
- the count is ≤ the baseline;
- eslint prints no new warning in the touched lines (its existing warnings in that file are not this task's).

If `useMemo` for `draftAnchorSpec` lands above the declaration of `scopedCommentPart`, `commentContext` or `commentDraft`, tsc reports "used before its declaration". Move the block down to just above `handleSubmitDraft`'s old position. It must stay there, not higher.

- [ ] **Step 7: Mutation check (test)**

In `useKvClientVisibility`, change `if (!enabled) return null;` to nothing → "is null and asks nothing while the flag is off" FAILS. Restore.

- [ ] **Step 8: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/hooks/comments/useKvClientVisibility.ts src/hooks/comments/useKvClientVisibility.test.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): KV comments know the client — labels, Team only, yellow pins, team-only drafts on artboards under review

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: web — client page: "New" on agency replies not yet seen

**Files:**
- Create: `src/lib/client-lane/seenReplies.ts`
- Create: `src/lib/client-lane/seenReplies.test.ts`
- Create: `src/components/client-lane/useNewAgencyReplies.ts`
- Create: `src/components/client-lane/useNewAgencyReplies.test.tsx`
- Modify: `src/components/client-lane/PinList.tsx`
- Modify: `src/components/client-lane/DecisionPage.tsx` (~392 and the two `<PinList` mounts ~1234 / ~1295)
- Modify: `src/components/client-lane/DecisionPage.test.tsx` (append one test inside the "comments through the app's comment components" `describe`)

**Interfaces:**
- Consumes:
  - `CommentAuthor.external` on public threads (Task 2: the client's own guest or lane replies are external);
  - `CommentThread.newCommentIds` (Task 5).
- Produces:

```ts
// seenReplies.ts
export const SEEN_REPLIES_CAP = 500;
export function seenRepliesKey(token: string): string;            // "client-lane:seen-replies:{token}"
export function readSeenReplies(token: string): Set<string> | null; // null = storage unavailable
export function writeSeenReplies(token: string, ids: readonly string[]): void; // union, newest SEEN_REPLIES_CAP kept
export function agencyReplyIds(threads: Iterable<CommentThread>): string[];
export function newReplyIds(ids: readonly string[], seen: ReadonlySet<string> | null): Set<string>;
// useNewAgencyReplies.ts
export function useNewAgencyReplies(token: string, threads: ReadonlyMap<string, CommentThread>, enabled?: boolean): ReadonlySet<string>;
// PinList
newCommentIds?: ReadonlySet<string>;
```

**Rulings:**
- **What counts as "seen".** "Seen" = the reply was shown on this device for this token, on an earlier visit. The set is read once per visit, so a reply stays New for the rest of the visit where it first appeared. On the first visit every agency reply is New, which is literally unseen.
- **Blocked storage** means nothing is marked New, never everything on every visit. **Corrupt storage** means nothing seen.
- **Agency reply** = a reply whose author is not `external`. The client's own replies are never New.
- **KV only.** The marker is gated to `data.type === "kv_file"` (spec D-2), so decks and plans are unchanged.

- [ ] **Step 1: Write the failing tests (test)**

`src/lib/client-lane/seenReplies.test.ts`:

```ts
import { afterEach, describe, expect, it, vi } from "vitest";

import type { CommentThread } from "@/types/comments";

import {
  SEEN_REPLIES_CAP,
  agencyReplyIds,
  newReplyIds,
  readSeenReplies,
  seenRepliesKey,
  writeSeenReplies,
} from "./seenReplies";

afterEach(() => {
  vi.restoreAllMocks();
  window.localStorage.removeItem(seenRepliesKey("tok"));
});

const reply = (id: string, external = false) =>
  ({ id, author: { id: external ? "guest:Dina" : "u1", name: "x", ...(external ? { external: true } : {}) } });
const threads = [
  { parent: { id: "p1" }, replies: [reply("r1"), reply("r2", true)] },
  { parent: { id: "p2" }, replies: [reply("r3")] },
] as unknown as CommentThread[];

describe("seenReplies", () => {
  it("lists agency replies only — never roots, never the client's own", () => {
    expect(agencyReplyIds(threads)).toEqual(["r1", "r3"]);
  });

  it("round-trips through localStorage as a union", () => {
    writeSeenReplies("tok", ["r1"]);
    writeSeenReplies("tok", ["r3"]);
    expect([...(readSeenReplies("tok") ?? [])]).toEqual(["r1", "r3"]);
  });

  it("keeps only the newest ids past the cap", () => {
    const ids = Array.from({ length: SEEN_REPLIES_CAP + 5 }, (_, i) => `r${i}`);
    writeSeenReplies("tok", ids);
    const seen = readSeenReplies("tok")!;
    expect(seen.size).toBe(SEEN_REPLIES_CAP);
    expect(seen.has("r0")).toBe(false);
    expect(seen.has(`r${SEEN_REPLIES_CAP + 4}`)).toBe(true);
  });

  it("treats corrupt storage as nothing seen", () => {
    window.localStorage.setItem(seenRepliesKey("tok"), "{not json");
    expect(readSeenReplies("tok")).toEqual(new Set());
  });

  it("reads null when storage is blocked, and marks nothing new", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("blocked");
    });
    const seen = readSeenReplies("tok");
    expect(seen).toBeNull();
    expect(newReplyIds(["r1"], seen)).toEqual(new Set());
    expect(() => writeSeenReplies("tok", ["r1"])).not.toThrow();
  });

  it("marks only the unseen ids new", () => {
    expect(newReplyIds(["r1", "r3"], new Set(["r1"]))).toEqual(new Set(["r3"]));
  });
});
```

`src/components/client-lane/useNewAgencyReplies.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";

import { readSeenReplies, seenRepliesKey } from "@/lib/client-lane/seenReplies";
import type { CommentThread } from "@/types/comments";

import { useNewAgencyReplies } from "./useNewAgencyReplies";

afterEach(() => window.localStorage.removeItem(seenRepliesKey("tok")));

const THREADS = new Map([
  [
    "p1",
    {
      parent: { id: "p1", author: { id: "guest:Dina", name: "Dina", external: true } },
      replies: [{ id: "r1", author: { id: "u1", name: "Rani" } }],
    },
  ],
]) as unknown as ReadonlyMap<string, CommentThread>;

describe("useNewAgencyReplies", () => {
  it("marks an unseen agency reply new for the whole visit, and not on the next", async () => {
    const first = renderHook(() => useNewAgencyReplies("tok", THREADS));
    await waitFor(() => expect([...first.result.current]).toEqual(["r1"]));
    await waitFor(() => expect(readSeenReplies("tok")?.has("r1")).toBe(true));
    first.rerender();
    expect([...first.result.current]).toEqual(["r1"]);
    first.unmount();

    const second = renderHook(() => useNewAgencyReplies("tok", THREADS));
    await waitFor(() => expect(readSeenReplies("tok")?.has("r1")).toBe(true));
    expect([...second.result.current]).toEqual([]);
  });

  it("marks nothing when disabled (deck and plan links)", async () => {
    const { result } = renderHook(() => useNewAgencyReplies("tok", THREADS, false));
    expect([...result.current]).toEqual([]);
    expect(readSeenReplies("tok")).toEqual(new Set());
  });
});
```

Append to `src/components/client-lane/DecisionPage.test.tsx`, inside `describe("DecisionPage — comments through the app's comment components", …)`:

```tsx
  it("marks an agency reply New until this device has seen it", async () => {
    window.localStorage.removeItem("client-lane:seen-replies:tok");
    const agencyReply = pinComment("p9", "", "2026-09-30T09:30:00.000Z", {
      parent_id: "p1",
      anchor: null,
      body: "Swapped the logo",
      author: { id: "u9", name: "Rani" },
    });
    stubApi([PIN_ON_HERO, agencyReply]);
    const first = renderPage(kvRound());
    expect(
      await body().findByRole("button", { name: "1 reply · 1 new" })
    ).toBeInTheDocument();
    first.unmount();

    renderPage(kvRound());
    expect(await body().findByRole("button", { name: "1 reply" })).toBeInTheDocument();
    window.localStorage.removeItem("client-lane:seen-replies:tok");
  });
```

- [ ] **Step 2: Run them to see them fail (test)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/seenReplies.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/useNewAgencyReplies.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/DecisionPage.test.tsx
```

Expected:
- first two: FAIL ("Cannot find module");
- DecisionPage: only the new test FAILS (the toggle reads "1 reply").

- [ ] **Step 3: Implement**

`src/lib/client-lane/seenReplies.ts`:

```ts
/**
 * Which agency replies this device has already shown for one link (spec
 * 2026-10-01 §6.2 — the client page marks the rest "New"). Best-effort
 * browser state, like `storage.ts`: kept per token in `localStorage`.
 *
 * Blocked storage reads as `null` — the caller then marks NOTHING new, so a
 * private window never sees every reply flagged on every visit. Corrupt
 * storage reads as "nothing seen".
 */
import type { CommentThread } from "@/types/comments";

/** Newest ids kept per token, so the entry cannot grow without bound. */
export const SEEN_REPLIES_CAP = 500;

export function seenRepliesKey(token: string): string {
  return `client-lane:seen-replies:${token}`;
}

export function readSeenReplies(token: string): Set<string> | null {
  let raw: string | null;
  try {
    raw = window.localStorage.getItem(seenRepliesKey(token));
  } catch {
    return null;
  }
  if (!raw) return new Set();
  try {
    const parsed: unknown = JSON.parse(raw);
    return new Set(
      Array.isArray(parsed)
        ? parsed.filter((x): x is string => typeof x === "string")
        : []
    );
  } catch {
    return new Set();
  }
}

export function writeSeenReplies(token: string, ids: readonly string[]): void {
  const seen = readSeenReplies(token);
  if (seen === null) return;
  for (const id of ids) {
    // Re-insert so a re-seen id counts as newest for the cap.
    seen.delete(id);
    seen.add(id);
  }
  try {
    window.localStorage.setItem(
      seenRepliesKey(token),
      JSON.stringify([...seen].slice(-SEEN_REPLIES_CAP))
    );
  } catch {
    // Storage blocked or full — the page simply marks fewer replies new.
  }
}

/** Replies by the agency — never a root, never the client's own (external). */
export function agencyReplyIds(threads: Iterable<CommentThread>): string[] {
  const out: string[] = [];
  for (const t of threads) {
    for (const r of t.replies) {
      if (r.author.external !== true) out.push(r.id);
    }
  }
  return out;
}

export function newReplyIds(
  ids: readonly string[],
  seen: ReadonlySet<string> | null
): Set<string> {
  if (seen === null) return new Set();
  return new Set(ids.filter((id) => !seen.has(id)));
}
```

`src/components/client-lane/useNewAgencyReplies.ts`:

```ts
"use client";

import { useEffect, useMemo, useState } from "react";

import {
  agencyReplyIds,
  newReplyIds,
  readSeenReplies,
  writeSeenReplies,
} from "@/lib/client-lane/seenReplies";
import type { CommentThread } from "@/types/comments";

const NONE: ReadonlySet<string> = new Set();

/**
 * Agency replies this device had not seen before THIS visit — the client
 * page's "New" marker (spec 2026-10-01 §6.2).
 *
 * The seen set is read once per visit (in an effect: `localStorage` does not
 * exist on the server render), so a reply stays New for the whole visit it
 * first appears in, while everything shown is recorded for the next one.
 * Disabled for deck and plan links (spec D-2).
 */
export function useNewAgencyReplies(
  token: string,
  threads: ReadonlyMap<string, CommentThread>,
  enabled = true
): ReadonlySet<string> {
  // undefined = not read yet; null = storage unavailable.
  const [seenAtLoad, setSeenAtLoad] = useState<
    ReadonlySet<string> | null | undefined
  >(undefined);
  useEffect(() => {
    if (!enabled) return;
    setSeenAtLoad(readSeenReplies(token));
  }, [token, enabled]);

  const ids = useMemo(() => agencyReplyIds(threads.values()), [threads]);

  useEffect(() => {
    if (!enabled || seenAtLoad === undefined || ids.length === 0) return;
    writeSeenReplies(token, ids);
  }, [enabled, token, ids, seenAtLoad]);

  return useMemo(
    () =>
      !enabled || seenAtLoad === undefined
        ? NONE
        : newReplyIds(ids, seenAtLoad),
    [enabled, ids, seenAtLoad]
  );
}
```

`src/components/client-lane/PinList.tsx`:
- Add `newCommentIds,` to the destructure.
- Add to the props type, after `onReply?`:

```ts
  /** Agency replies this viewer has not seen yet (KV request links). */
  newCommentIds?: ReadonlySet<string>;
```

- In the `<CommentThread …>` element, add `newCommentIds={newCommentIds}`.

`src/components/client-lane/DecisionPage.tsx`:
- Import `import { useNewAgencyReplies } from "./useNewAgencyReplies";`.
- After `const threads = useMemo(() => publicThreads(comments), [comments]);` add:

```ts
  /** Agency replies this device has not seen on this link yet — "New"
   *  (spec 2026-10-01 §6.2). KV only (D-2). */
  const newReplyIds = useNewAgencyReplies(
    token,
    threads,
    data.type === "kv_file"
  );
```

- Add `newCommentIds={newReplyIds}` to BOTH `<PinList` elements (the main-column one and the one inside `FocusedArtboardPanel`).

- [ ] **Step 4: Run them to see them pass (test)**

Re-run the three Step 2 commands, then `bun test src/lib/client-lane/commentThreads.test.ts`. Expected: all pass, and DecisionPage passes at its Task 0 count + 1.

- [ ] **Step 5: Mutation check (test)**

- In `readSeenReplies`, return `new Set()` from the first `catch` instead of `null` → "reads null when storage is blocked, and marks nothing new" FAILS. Restore.
- In `useNewAgencyReplies`, replace `seenAtLoad` in the returned memo with a fresh `readSeenReplies(token)` → "marks an unseen agency reply new for the whole visit…" FAILS. Restore.

- [ ] **Step 6: Gates + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/lib/client-lane/seenReplies.ts src/lib/client-lane/seenReplies.test.ts src/components/client-lane/useNewAgencyReplies.ts src/components/client-lane/useNewAgencyReplies.test.tsx src/components/client-lane/PinList.tsx src/components/client-lane/DecisionPage.tsx src/components/client-lane/DecisionPage.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "src/lib/client-lane/|src/components/client-lane/"
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/lib/client-lane/seenReplies.ts src/lib/client-lane/seenReplies.test.ts src/components/client-lane/useNewAgencyReplies.ts src/components/client-lane/useNewAgencyReplies.test.tsx src/components/client-lane/PinList.tsx src/components/client-lane/DecisionPage.tsx src/components/client-lane/DecisionPage.test.tsx && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): client page marks agency replies New until this device has seen them

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Gates, §11.3 review, manual smoke, track files, Lark rows

**Files:**
- Modify: `web/.worktrees/client-lane-multi-item/docs/tracks/client-lane-multi-item.track.md`
- Modify: `api/.worktrees/client-lane-multi-item/docs/tracks/client-lane-multi-item.track.md`

**Interfaces:** none (verification + docs).

- [ ] **Step 1: Whole-project type count + every new suite (test)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
```

Expected: ≤ the Task 0 baseline (895). Then run each suite on its own:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && for f in src/hooks/comments/useKvFileComments.visibility.test.tsx src/lib/client-lane/commentThreads.test.ts src/components/comments/commentVisibility.test.ts src/lib/client-lane/pendingArtboards.test.ts src/components/comments/CommentVisibilityToggle.test.tsx src/components/comments/CommentComposer.hint.test.tsx src/components/comments/CommentComposer.drop.test.tsx src/components/comments/CommentThread.visibility.test.tsx src/components/comments/CommentThread.test.tsx src/components/comments/CommentSidePanel.clientLane.test.tsx src/components/comments/CommentSidePanel.test.tsx src/components/comments/CommentThreadPopover.visibility.test.tsx src/components/comments/CommentPinOverlay.clientFaces.test.tsx src/hooks/comments/useKvClientVisibility.test.tsx src/lib/client-lane/seenReplies.test.ts src/components/client-lane/useNewAgencyReplies.test.tsx src/components/client-lane/DecisionPage.test.tsx; do echo "== $f"; bun test "$f" 2>&1 | tail -3; done
```

Expected: every suite passes, and the pre-existing ones match their Task 0 counts.

- [ ] **Step 2: §11.3 review greps**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git diff 752323bba -- src | /usr/bin/grep -nE '^\+.*(-\[[0-9.]+px\]|text-white\b|text-gray-|bg-\[#|rounded-\[)'
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && for f in src/components/comments/CommentChips.tsx src/components/comments/CommentVisibilityToggle.tsx src/components/comments/commentVisibility.ts src/hooks/comments/useKvClientVisibility.ts src/lib/client-lane/pendingArtboards.ts src/lib/client-lane/seenReplies.ts src/components/client-lane/useNewAgencyReplies.ts; do v1=$(/usr/bin/grep -c '@/components/frndos/[A-Z]' "$f"); v2=$(/usr/bin/grep -c '@/components/frndos/v2' "$f"); echo "$f v1=$v1 v2=$v2"; done
```

Expected:
- First command: no output. The one allowed hit is the kept `ring-[#0B81FF]` in `CommentPinOverlay.tsx`, an unchanged value moved into a ternary. Any other hit gets fixed with a token.
- Second command: no new file shows both `v1>0` and `v2>0`.

- [ ] **Step 3: Manual smoke (Daffa) — record PASS/FAIL per line in the track file**

Run with `show-client-lane` on, on a KV file that has an open approval request (Part A) and at least one client pin.

1. **Comments dock:**
   - the client thread shows a yellow **Client** label;
   - the pill row reads `All · Client n · Open · Done · @me`;
   - clicking **Client** narrows the list;
   - Filter › **Visibility › Team only** narrows to dashed, "Team only"-labelled threads.
2. **Reply on a client thread:**
   - the hint reads **Client sees this** (eye); a click turns it to **Team only** (lock);
   - post it; the reply shows a lock and `team only`;
   - on the `/s/` request link, that reply is absent.
3. **New pin on an artboard of the open request** (canvas, comment mode):
   - the composer shows **Team only**; post it;
   - the dock shows a dashed card;
   - the `/s/` link does not show it.
4. **New pin on an artboard NOT in the request:** no toggle; the composer is exactly as before.
5. **Pins:** the client's face on a pin has a yellow ring; team faces stay blue.
6. **Client page:** reply to a client pin from the agency dock with "Client sees this", then reload the `/s/` link:
   - the reply toggle reads `1 reply · 1 new`, and expanding shows **New**;
   - reload again, and it is no longer New.
7. **Tri-mode:** repeat 1–3 in **Midnight, Aurora and Daylight** (profile menu → Theme). The labels, the toggle, the dashed border and the Visibility group must stay legible; the Team only chip text must not vanish in Daylight.
8. **Deck regression:** open a deck's comments dock. There is no Client pill, label, Visibility group or toggle, and replies post as before.
9. **Flag off:** the KV dock looks exactly as before Part C.

- [ ] **Step 4: Track files + Lark rows**

Web `docs/tracks/client-lane-multi-item.track.md`: add above `## Session Log`:

```markdown
## Part C — Comments dock, client comments, Team only (plan `docs/superpowers/plans/2026-10-01-client-lane-kv-approval-part-c.md`)

Part C base: 752323bba. Baselines (Task 0): tsc <N>; KvGeneratorLayout.tsx pre-existing errors: <n>.

- [ ] Task 0: pre-flight — api permission, branches, baselines
- [ ] Task 1: api — KV comment listing carries the client author flags
- [ ] Task 2: `external` on every author, `internalOnly` on the KV post
- [ ] Task 3: visibility rules (pure)
- [ ] Task 4: analytics helpers, chips, toggle, ReactNode hint slot
- [ ] Task 5: CommentThread — Team-only styling, reply toggle, New marker
- [ ] Task 6: CommentSidePanel — Client label and pill, Visibility › Team only
- [ ] Task 7: CommentThreadPopover — Team-only default for new root threads
- [ ] Task 8: CommentPinOverlay — yellow ring on client faces
- [ ] Task 9: KV editor wiring
- [ ] Task 10: client page "New" on agency replies
- [ ] Task 11: gates, review, smoke, Lark rows

Manual smoke (Task 11 Step 3): <PASS/FAIL per line 1–9>.
PENDING (human): Lark "frndOS Event Taxonomy" rows below.
```

Tick each task as done. Append a Session Log entry: `### <date> — daffa (Part C executor)` with what landed, the final tsc count, and any test not run (fast mode).

Api `docs/tracks/client-lane-multi-item.track.md`: add one line under its Part A section:

```markdown
- [x] Part C: `tests/Feature/Comment/KvCommentAuthorFlagsTest.php` pins `author.guest` / `author.external` / `internal_only` on the KV comment endpoints (presenter already present — no product change). Test permission granted <date> for that one file, scratch DB `frnd_testing`.
```

(If permission was declined in Task 0, write that instead.)

Lark rows for Daffa to add (https://fcn.sg.larksuite.com/wiki/DMbKwqbzQiWrXSkha5zl1wFvgod), section *Client Lane* (the analytics skill's lifecycle step 4):

| Event | Fires when | Properties |
|---|---|---|
| `comments.client_filter_used` | KV Comments dock: the Client pill or Filter › Visibility › Team only is switched ON | `filter`: `client` \| `team_only` |
| `comments.reply_visibility_toggled` | The "Client sees this / Team only" toggle is clicked in a reply or new-thread composer | `to`: `client` \| `team`; `composer`: `reply` \| `root` |
| `comments.team_only_thread_created` | A new root thread is posted Team only from the KV canvas | `defaulted`: bool (the Team-only default was left on) |

- [ ] **Step 5: Commit the track files**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add docs/tracks/client-lane-multi-item.track.md && /usr/bin/git commit -m "$(cat <<'EOF'
docs(web): track KV approval requests Part C — comments dock

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && /usr/bin/git add docs/tracks/client-lane-multi-item.track.md && /usr/bin/git commit -m "docs(api): track KV approval requests Part C — author flags pinned"
```

---

## Self-Review

**Spec coverage (§6.2):**

| Spec item | Task |
|---|---|
| `CommentAuthor.external`; KV mapper sets it from `author.guest \|\| author.external` | 2 |
| `lib/client-lane/commentThreads.ts` keeps the flag | 2 |
| api check: agency serialisation carries `guest`/`external`, add + test if missing | 1 (present; pinned by a characterisation test; presenter code given for the fail path) |
| Opt-in props, deck dock unchanged | 5, 6, 7, 8 (regression tests in each), 9 (only KV passes them, flag-gated) |
| Client label (yellow `Label`) in the anchor row, `Artboard deleted` slot | 4 (`ClientChip`), 6 |
| Client pill second, `All · Client {n} · Open · Done · @me`, only while the file has client comments | 6 |
| Visibility group › Team only in the Filter dropdown | 6 |
| Team-only threads: dashed border + grey `Team only` label | 4 (`TeamOnlyChip`), 5 (dashed), 6 (label) |
| Team-only replies: lock + `team only` where `edited` sits | 5 |
| Reply composer `hintText` hosts the toggle; Team only posts `internal_only: true` | 4 (slot + toggle), 5, 6, 2 (wire), 9 |
| New root threads default Team only while the artboard is pending in an open request; toggle shown then | 3 (`isPendingSpec`), 7, 9 |
| api hides `internal_only` from the lane (`scopeVisibleTo`) | existing; relied upon, smoke-checked in Task 11 lines 2–3 |
| Client pins: 2px yellow avatar ring | 8, 9 |
| Client page "New" per token in `localStorage` | 10 |
| Analytics: `comments.client_filter_used`, `comments.reply_visibility_toggled{to}`, `comments.team_only_thread_created` + Lark | 4, 6, 7, 11 |
| §8 web tests: Client pill + label, Team-only toggle posting `internal_only`, root default while a request is open; mutation checks | 6, 7 (+ every task's mutation step) |
| §11 frndOS components first, tokens, tri-mode, review gate | Global Constraints, 4, 11 |

**Placeholder scan:** every code step carries its code. The `<N>`/`<n>`/`<date>` markers in the track text are values the executor records at run time.

**Type consistency:**
- `PostVisibility` / `ThreadVisibility` are defined in Task 3 and used with the same names in 5, 6, 7 and 9.
- `onReply` takes a 4th argument on `CommentThread` and the popover, and a 5th on `CommentSidePanel`.
- `draftVisibility: { defaultTeamOnly: boolean } | null` is used in 7 and 9.
- `PendingArtboards` / `isPendingSpec` / `requestThreadIds` are defined in 3 and used in 9.
- `KvClientVisibility.requestThreadIds` / `.pending` are defined in 9 and used in 9.
- `trackComments*` are defined in 4 and used in 4, 6 and 7.
- `newCommentIds` is used in 5 and 10.
- `markClientFaces` is used in 8 and 9.

**Review Focus:** all five lines have named tests (Tasks 3, 6, 7, 6, 10).
