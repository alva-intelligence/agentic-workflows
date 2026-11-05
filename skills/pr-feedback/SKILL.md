---
name: pr-feedback
description: Deliver and monitor pull requests — run the pr_review feedback loop and the post-verification delivery gate, honor the task's recorded delivery choice, inventory every review thread with pagination, reply without overwriting reviewers, resolve only addressed threads, and run bounded head-specific merge automation when explicitly authorized.
---

# PR Feedback, Watch & Delivery Gate

Playbook for the `pr_review` feedback phase and the delivery/merge checkpoint that follows
independent verification. `pr_review` stays the feedback phase; delivery is a separate decision, not
a phase rename. It covers the mechanics learned on real frndOS PRs: how to find **every** thread,
classify each finding, apply fixes, reply, resolve only what was addressed, and — only when the
task's delivery choice explicitly authorizes it — monitor the PR within bounds and merge under the
full gate.

## When to use

- Owner/bot posted review comments on an open PR.
- User says "address PR feedback", "resolve the threads", or "open, watch, fix and merge it".
- PR shows `CHANGES_REQUESTED`, failing required checks, or unresolved review threads.
- The delivery checkpoint needs a merge decision.

## Delivery checkpoint (read before touching the PR)

Delivery is a **per-task, explicit** choice recorded against the task and its PR. It is not a global
default, and it is never inferred from a branch, PR, phase status, or reconstructed artifact.

| `delivery` | What the agent may do |
|---|---|
| `null` | Stop at the last completed human checkpoint. Do not push, open a PR, monitor, or merge. |
| `local_test` | Manual local testing **first**: run the task's local checks, then hand the running app/service to the user with the URL/path and commands. Keep a requested dev server running; say what is left running. This is not completion: no PR, no branch/server cleanup, and the PR checkpoint stays pending until the user finishes and chooses `open_pr` or `auto_merge`. |
| `open_pr` | Push the branch and open the PR, then stop. Addressing feedback is a separate explicit request; it never authorizes a merge. |
| `auto_merge` | The explicit opt-in for **open + monitor + fix + merge** under the gate below. Still bounded and still per task. |

`local_test` is not a synonym for "run the automated checks", and it is not a terminal delivery
state. The user's manual pass is the point; the agent's checks are preparation for it. Do not mark
the task complete or tear down the branch/server while that pass is pending.

Rules:

- **Missing authorization fails closed.** If `delivery` is absent/null, or `auto_merge` was not
  explicitly chosen for this task, do not open/monitor/merge. Report what is missing.
- **Same-task consent survives a resume.** An explicit, recorded consent for the **same task and PR**
  may continue after a session restart when the scope and target still match and the user has not
  revoked it. Preserve its watch deadline/rounds; do not reset the clock or the round count.
- **Never inherit other consent.** Do not carry consent from another task or PR, a global default, or
  a reconstructed artifact/session with no task-specific record. Never infer it from an open PR, a
  green check, a prior task's `auto_merge`, a reconstructed feature, or `phase_status: completed`.
- **Do not re-ask a decision already recorded for the same task.** Re-confirm only when the scope,
  PR, or watch bounds changed.
- **Independent decisions.** Scope auto-selection, implementation auto-start, and merge consent are
  independent. Scope approval alone never authorizes code changes, and implementation approval never
  authorizes a merge.
- **User override wins.** A narrower explicit instruction ("open it and address feedback, but do not
  merge") is honored and recorded; it never implies merge authority. Do not re-ask a decision the
  user already made.
- **Live estate is separate.** For `data-pipeline/`, `delivery: auto_merge` alone is **never enough**.
  The task needs a separate, explicit `live_merge_approved` because both branches are live Prefect
  estates. Production promotion (`development` → `main`) remains separate human work; the agent never
  opens or merges it.

Persist the choice plus the bounded watch contract in the task's track file:

```markdown
## Review Automation

| Field | Value |
|---|---|
| task | <feature-slug or task id> |
| pr | <PR URL or number> |
| delivery | auto_merge |
| authorized_at | 2026-11-05T10:00:00Z |
| live_merge_approved | false (n/a unless data-pipeline) |
| started_at | 2026-11-05T10:00:00Z |
| deadline | 2026-11-05T10:30:00Z |
| max_fix_rounds | 3 |
| fix_rounds_used | 0 |
| last_head_sha | <sha> |
| status | running | paused | complete |
```

Default bounds are **30 minutes** and **3 fix rounds**; the user may override either. Persist the
deadline and rounds before the first poll. A same-task resume keeps the original deadline and
rounds — it does not get a fresh window. There is no background daemon: if the session stops, set
`status: paused`, report the current evidence, and resume later. Never claim a PR is being watched
in the background.

## Workflow

### Step 1 — Inventory everything, with pagination

Never trust the first page. Paginate threads, their comments, PR-level comments, and reviews.

```bash
OWNER=alva-intelligence
REPO=frnd-api-php
PR=42

# Head, base, mergeability, review decision — capture the SHA for every later check.
gh pr view "$PR" --repo "$OWNER/$REPO" \
  --json number,url,state,isDraft,headRefOid,baseRefOid,baseRefName,mergeable,mergeStateStatus,reviewDecision

# Review threads are GraphQL-only for resolution state. --paginate walks every page.
gh api graphql --paginate \
  -F owner="$OWNER" -F repo="$REPO" -F number="$PR" \
  -f query='query($owner:String!,$repo:String!,$number:Int!,$endCursor:String){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$number){
        reviewThreads(first:100,after:$endCursor){
          pageInfo{hasNextPage endCursor}
          nodes{
            id isResolved isOutdated path line
            comments(first:100){
              pageInfo{hasNextPage endCursor}
              nodes{id databaseId author{login} body}
            }
          }
        }
      }
    }
  }' \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]'

# PR-level comments (the issue-comment endpoint, paginated).
gh api --paginate "repos/$OWNER/$REPO/issues/$PR/comments" \
  --jq '.[] | {id, author:.user.login, body, created_at}'

# Reviews (approvals / changes requested) and inline review comments, both paginated.
gh api --paginate "repos/$OWNER/$REPO/pulls/$PR/reviews" \
  --jq '.[] | {id, author:.user.login, state, commit_id, submitted_at, body}'
gh api --paginate "repos/$OWNER/$REPO/pulls/$PR/comments" \
  --jq '.[] | {id, path, line, in_reply_to_id, author:.user.login, body}'
```

If a thread has more than 100 comments, page its `comments` connection too — do not accept the
first page:

```bash
gh api graphql --paginate \
  -F threadId="$THREAD_ID" \
  -f query='query($threadId:ID!,$endCursor:String){
    node(id:$threadId){
      ... on PullRequestReviewThread{
        comments(first:100,after:$endCursor){
          pageInfo{hasNextPage endCursor}
          nodes{id databaseId author{login} body}
        }
      }
    }
  }' \
  --jq '.data.node.comments.nodes[]'
```

Record the inventory: total threads, resolved, unresolved, and each thread's root comment
`databaseId` (needed for a correct reply). Check every service PR in the feature, not just one.

### Step 2 — Classify each thread

| Class | Action |
|---|---|
| must-fix (security, data-loss, crash path, wrong behavior) | Fix code, push, reply, resolve |
| nit / style / low | Fix if cheap, else reply with rationale + resolve |
| question / design concern | Reply with decision + rationale; fix only if it changes the decision |
| already-correct claim (reviewer misread) | Reply with the fact, resolve |
| not addressed / disputed | Reply if useful, leave **unresolved**, report it |

For each addressed finding reply with the specific evidence, not "done":
`Fixed: <what changed> — <why>. Verified: <how>.` Reproduce the evidence; do not describe a
mathematical proof or call checks "formal verification".

### Step 3 — Fix code

1. Apply fixes on the feature branch.
2. Verify locally: lint the changed files, re-run the affected command, confirm the guard/behavior
   both directions (e.g. prod-block exits non-zero AND local passes).
3. Commit with `fix(<scope>): PR review — <summary>`, push.
4. **Every push creates a new head and invalidates prior head-specific proof.** Re-run Step 1 on the
   new SHA before making any further review or merge claim.

Gotchas that bit us before:

- **Env guard fail-open:** `env('APP_ENV', '')` passes when APP_ENV is unset. Fail closed:
  `getenv('APP_ENV') ?: config('app.env', 'production')`, and treat empty string as production
  (`?: 'production'`). Raw `env('APP_ENV')` is NULL when APP_ENV lives only in `.env` — config
  fallback keeps local runs working.
- **Idempotent seeding on refresh:** `updateOrCreate` overwrites existing rows' real ids (e.g.
  `fivetran_connection_id`). Use `firstOrNew` + set demo ids only when `!$row->exists`.
- **Async CH mutations:** `ALTER … DELETE` is async; it can execute AFTER the follow-up INSERT and
  reap fresh rows. Wait for mutations (scoped to your tables via
  `system.mutations WHERE database/table`) before inserting.
- **Unique-constraint collisions:** core+extended rows sharing `(brand, platform, connection_index)`
  — extended must take `max+1` and reuse existing rows by their real identity column.

### Step 4 — Reply and resolve correctly

**Reply with a new comment. Never PATCH a reviewer's comment.** `PATCH /pulls/comments/{id}`
overwrites the comment body, destroying the reviewer's finding while leaving their name on the
edited text. Only the agent's own comment may be corrected this way, and even then a reply is
usually better history.

```bash
# Correct reply: POST a reply under the thread's root review comment.
# root_comment_id = the thread's first comment databaseId from Step 1.
gh api -X POST "repos/$OWNER/$REPO/pulls/$PR/comments/$ROOT_COMMENT_ID/replies" \
  -f body="Fixed: <what changed> — <why>. Verified: <how>."
```

**Resolve only threads that were actually addressed.** Build a list of addressed thread IDs as you
reply; do not resolve a thread just because it is outdated or because "all threads" was requested.
Outdated ≠ resolved, and an unaddressed thread must stay open.

```bash
# addressed-thread-ids.txt contains ONLY threads with a fix or a reasoned reply.
while IFS= read -r tid; do
  gh api graphql \
    -f query='mutation($threadId:ID!){
      resolveReviewThread(input:{threadId:$threadId}){thread{id isResolved}}
    }' \
    -f threadId="$tid"
done < addressed-thread-ids.txt
```

Reply to PR-level comments too: `gh api "repos/$OWNER/$REPO/issues/$PR/comments" -f body="..."` (PR
comments live under the issues endpoint). Re-read the thread after resolving to prove
`isResolved: true`; a mutation response is not the same as the final inventory.

### Step 5 — Bounded watch and merge gate

Only enter this step when `delivery: auto_merge` was explicitly authorized for this task, and record
the watch bounds in the track before polling.

**Every round, on the current head SHA:**

1. **Re-inventory fully (Step 1).** Zero threads *before the expected review arrives* is not
   completion. A clean page is only meaningful after the configured reviewer/bot has actually
   reviewed the current head.
2. **Check required CI on this exact SHA.** Inventory **both** classic branch protection and
   branch rulesets; either can carry the applicable requirements. If a lookup fails and you cannot
   establish whether requirements apply, fail closed for `auto_merge` — do not assume "no
   requirements".
   ```bash
   gh api "repos/$OWNER/$REPO/branches/$BASE/protection" \
     --jq '{required_checks:.required_status_checks.contexts,
            strict:.required_status_checks.strict,
            reviews:.required_pull_request_reviews,
            conversation_resolution:.required_conversation_resolution.enabled,
            enforce_admins:.enforce_admins.enabled}'
   gh api --paginate "repos/$OWNER/$REPO/rules/branches/$BASE" \
     --jq '.[] | {type, parameters}'
   gh api "repos/$OWNER/$REPO/branches/$BASE" --jq '{protected:.protected}'
   gh pr checks "$PR" --repo "$OWNER/$REPO" --json name,state,bucket,link
   ```
   Required checks must be green. Do not summarize a pending/failing check as "mostly green". An
   explicit empty inventory (`protected: false`, no rulesets) is a recorded result; a failed or
   forbidden lookup is not empty — fail closed.
3. **Check the effective expected review on the latest head.** Reviews carry a `commit_id`; an
   approval on an older commit does not satisfy the latest-head requirement unless the repo keeps it
   valid. Use `reviewDecision` plus the latest decision per reviewer: a later approval supersedes an
   earlier change request; a **current** `CHANGES_REQUESTED` or requested change blocks. Do not block
   on a historical `CHANGES_REQUESTED` that a newer review replaced.
   ```bash
   gh api --paginate "repos/$OWNER/$REPO/pulls/$PR/reviews" \
     | jq -s 'add // [] | sort_by(.submitted_at) | group_by(.user.login)
              | map(last) | .[] | {author:.user.login,state,commit_id,submitted_at}'
   ```
4. **Check mergeability.** `mergeable` is the enum `MERGEABLE` / `CONFLICTING` / `UNKNOWN`, not a
   boolean: require `MERGEABLE` (re-poll `UNKNOWN`). `mergeStateStatus` must not be `DIRTY` /
   `BLOCKED` / `BEHIND` (unless the repo does not require up-to-date branches), and the PR must not
   be a draft.
5. **Check the verification record.** Self-review, security audit, adversarial review, and the
   final whole-change review must be recorded with no must-fix items and no high/critical findings.
   If the head moved after they were recorded, re-run them; prior verification is stale.
6. **Check every paginated thread.** Every thread must be resolved **and** addressed — a thread
   resolved without a fix or a reasoned reply is not addressed. Re-open nothing silently; report it.

**Native auto-merge or a merge queue is allowed only when it enforces the same conditions.** GitHub
auto-merge enforces checks and approvals, but it does **not** enforce review-thread resolution
unless the applicable protection or ruleset requires conversation resolution. If the queue cannot guarantee
every condition above, do not delegate the gate to it; finish the threads and merge manually after a
latest-SHA check. Never enable a queue, auto-merge, or any bypass that ignores branch protections.
Never use `--admin` or any branch-protection override.

**Immediately before merging, repeat the head check and pass the proof SHA to the merge command.**
A bare `gh pr merge` after a separate SHA check is a time-of-check/time-of-use race; the merge must
be pinned to the checked head.

```bash
: "${PROOF_SHA:?set PROOF_SHA from the latest completed gate}"
CURRENT_SHA=$(gh pr view "$PR" --repo "$OWNER/$REPO" --json headRefOid --jq .headRefOid)
[ "$CURRENT_SHA" = "$PROOF_SHA" ] || { echo "head moved — re-run the gate"; exit 1; }
gh pr merge "$PR" --repo "$OWNER/$REPO" --squash --match-head-commit "$PROOF_SHA"
```

Never add `--admin` or any branch-protection bypass. If any push happened since the proof or the
merge command refuses the head, discard the proof and return to Step 1. A merge authority is specific
to one head; it is not a permission to merge "the PR" after further changes.

**Bounds and failure:**

- Default: 30 minutes, 3 fix rounds. The user may override either; persist the override.
- Before each round, check the deadline and rounds used. On timeout or exhausted rounds: stop,
  record `status: paused`, report the exact remaining blockers and the last verified SHA. Do not
  claim the watch continues in the background.
- If the session ends, the next session resumes from the track's deadline/rounds/SHA; it must
  re-verify, not trust the old proof.
- `data-pipeline/`: require `live_merge_approved` for this task in addition to `auto_merge`, and only
  merge into `development`. Never open or merge `development` → `main`; that promotion is human-only.

## Traps (all hit in real sessions)

- `PATCH /pulls/comments/{id}` **overwrites** the reviewer's comment body. Use the reply endpoint;
  the original finding must survive.
- **Do not resolve all unresolved threads blindly.** Resolve only addressed threads; leave disputed
  or unimplemented ones open with a reply.
- `isResolved` only exists in GraphQL `reviewThreads`; REST `gh pr view` cannot show it.
- `gh api --paginate` is required for REST comments/reviews and GraphQL `reviewThreads`; a first page
  of 30/50/100 is not "all threads".
- Threads on a push that changed the diff become `isOutdated: true` — still resolve them only after
  addressing; outdated ≠ resolved.
- **Zero threads before review arrives is not completion.** Wait for the expected reviewer/bot, then
  re-inventory the latest head.
- **Every push invalidates prior head-specific proof.** Re-check checks, reviews, threads, and SHA
  immediately before merge.
- Native auto-merge/queues can merge with unresolved threads if conversation resolution is not a
  required protection. Verify what the queue enforces; do not assume.
- Shell quoting: GraphQL mutation strings with `$tid` inside double quotes — use single-quoted
  queries and `-f` variables. `sed` with `/` in replacement text breaks — use `|` delimiters or
  avoid sed for such patches.
- No background daemon: a bounded watch that hits its deadline is paused, not "still running".

## Verification checklist (before declaring done)

- [ ] `delivery` was explicitly authorized for **this task**; a resumed run reused only same-task consent, not other-task/global consent or an inferred artifact.
- [ ] Every thread was inventoried with pagination; total/resolved/unresolved recorded.
- [ ] Every thread: addressed with a fix or a reasoned reply.
- [ ] Replies used the reply endpoint; no reviewer comment was PATCHed.
- [ ] Only addressed threads were resolved; all others remain open and are reported.
- [ ] Every thread: `isResolved == true` only where addressed (GraphQL check).
- [ ] PR-level comments answered.
- [ ] Fixes verified locally (both guard directions, idempotent re-run). Evidence reproduced, not
      asserted.
- [ ] `auto_merge`: required CI green on the latest head, expected review complete on the latest
      head, no conflicts, branch protections intact.
- [ ] `data-pipeline`: separate `live_merge_approved` recorded; production promotion left to a human.
- [ ] Watch bounds/deadline/rounds/SHA persisted in the track; paused cleanly on timeout.
- [ ] No re-review requested (unless the user said so).
- [ ] Track file updated with the review round + fixes.

## References

- Phase machine and state contract: `skills/workflow/SKILL.md` — the delivery checkpoint after
  independent verification; `phase_status: completed` satisfies artifacts/checks but does not by
  itself authorize crossing a human gate.
- Security audit before opening PRs: the external `security-reviewer` skill
  (`npx skills add https://github.com/jeffallan/claude-skills --skill security-reviewer`), run during
  PR preparation, not here.
- Commit conventions: `AGENTS.md` → "Commit Messages".
