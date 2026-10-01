# Client Lane — KV Approval Requests, Part D (verification code once per device) — API + Web Implementation Plan

> **⚠ VISION CHANGE — AWAITING JEFF.** Spec §7 / D-9 / §9 Q2: the vision (*Clients in frndOS*, 11 Sep) keeps codes for money, scope and sign-off; Part D asks for one code per device before the first KV request decision. Part D ships **last** and must be droppable without touching Parts A–C. **Task A0 asks Daffa whether Jeff has signed off. If not, stop after A0** — nothing in this plan is started speculatively.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every step that writes, runs or mutation-checks a test has **(test)** in its title — in fast mode those steps are the ones skipped, and the track file must say so.

**Goal:** On a KV approval-request link, the first decision from a device with no honoured lane is answered `403 verification_required`; the page asks for a 6-digit emailed code, verifies it, cookies the lane (personal lane handed back, else a 30-day verified-guest lane) and re-submits the stored decision by itself — so every later decision on that device is one tap.

**Architecture:** api — a `client_verification_codes` table (HMAC-SHA256 of the code, attempts, 10-minute expiry), `ClientVerificationCodeService` (request / verify) behind two throttled public routes on `PublicLaneController`, lane minting shared with the magic link through two new `ClientLaneService` helpers, the 403 gate in `PublicShareLinkController::decideOnRequest`, and one widening of `ApprovalService::ownPinsOn` so pins placed before verifying still ride on the decision. web — a new frndOS v2 `CodeInput` on Base UI `OTPField`, a client-lane `CodeSheet`, a pure-ish `laneCode.ts` (api calls, `/s/session` cookie write, analytics, summary string), `POST /s/session` taking the lane's `expires_at`, and `DecisionPage` wiring that reuses the AC-14 draft-resubmit effect.

**Tech Stack:** Laravel 13 / PHP 8.5 / PostgreSQL / Pest 4 (api); Next.js 16 / React 19 / TypeScript / Tailwind / `@base-ui/react` 1.6.0 / bun test + RTL (web).

**Spec:** `docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md` (workspace root) — this plan implements **§7 (Part D)** plus its §8 tests ("D: a code's lifecycle, attempts, the non-oracle 202, the personal-lane hand-back, and the gate on KV request links only"; web "the code sheet") under the §11 UI rules. Parts A (implemented, fast mode, untested), B and C are out of scope.

### Rulings (spec gaps resolved here; every one is written into the contract notes in Task A1)

- **R-D1 — the gate covers every C-3 outcome on an approval link**, request-level `deferred` included ("a request with no honoured lane returns 403"). Order inside `decideOnRequest`: body validation → request lookup → `guest_required` → `verification_required` → anything recorded. So the name gate still comes first and its email prefills the code sheet.
- **R-D2 — a code is bound to (address, link).** Requesting a new one ends every still-usable code for that pair (`expires_at = now()`); verify checks the newest usable code only.
- **R-D3 — the fifth wrong try answers `code_expired`** (it also ends the code), so `invalid_code.attempts_left` is always 1..4. "No usable code" — never sent, expired, spent, replaced, killed, or an unknown / revoked / non-approval link — is also `code_expired`.
- **R-D4 — the spec's optional `name` on `POST public/lane/code` is dropped.** Rendering user-typed text into a mail we send to any address turns the endpoint into a phishing relay; the decider's name keeps coming from the name gate.
- **R-D5 — `code_hash` = HMAC-SHA256 keyed with `app.key`** (still sha256, still 64 hex chars). A plain sha256 of a 6-digit code is reversed from a DB dump in milliseconds; the key makes a dump alone useless. Compared with `hash_equals`.
- **R-D6 — a code is only sent for an active `purpose = approval`, `role = comment` link whose request is still `pending`.** Everything else answers the same `202` and sends nothing.
- **R-D7 — the personal lane is looked up at verify time** (the magic link stores it at request time); a lane rotated between the two is still found.
- **R-D8 — verify answers `{ lane_code, kind, expires_at }`** and `POST /s/session` takes an optional `expires_at`, so the cookie dies with a 30-day guest lane instead of living 400 days.
- **R-D9 — a lane actor also owns guest pins (no author, no lane) whose `guest_email` equals the lane's email** (lower-cased). Without it every pin a guest placed before verifying fails the resubmitted decision with `422 pins` — the spec's own flow would break on its most common path.
- **R-D10 — `CodeInput` is built on `@base-ui/react/otp-field`** (`OTPField.Root` / `OTPField.Input`, shipped in the installed 1.6.0), not six `@base-ui/react/input` boxes as §11.2 says. It is the purpose-built primitive: paste distribution, `one-time-code` autofill on the first box, roving focus, backspace. **Flag to Daffa** (spec deviation).
- **R-D11 — `CodeSheet` sends the code once as it opens** when the email is prefilled (Shop/Kiwi pattern); "Change" returns to the email step; resend unlocks after 60 s; an expired code offers "Send a new code" at once.
- **R-D12 — closing the code sheet abandons the decision** (`clearDraft`). A stored draft would otherwise auto-submit on some later visit that happens to have a lane.
- **R-D13 — summary line:** `Verified as {name} · this device, 30 days` right after verifying on this page; `Verified as {name} · this device` on later visits (C-1 carries no lane expiry); nothing for anonymous viewers or `client` (personal-lane) viewers. `{name}` = the device's name-gate name, else `viewer.name`.
- **R-D14 — only request links get `CodeSheet`.** Campaign plans keep the magic-link `VerifySheet` (C-5); decks never ask.
- **R-D15 — a failed `POST /s/session` does not block.** The lane code is already in page memory, so this visit's decision still goes through; only the device memory is lost (the next visit asks again).

## Global Constraints

- **Jeff gate:** Part D is a vision change awaiting Jeff (spec D-9). Task A0 asks; no task starts without a yes.
- **Worktrees + shell:** api = `/Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item`, web = `/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item`, both on branch `feature/daffa/vc-client-lane-multi-item` (unpushed). Agent shells reset cwd: prefix every shell call with `cd <worktree> && `. zsh: put file lists in arrays (`F=(a b); vendor/bin/pint "${F[@]}"`). Use `/usr/bin/git` and `/usr/bin/grep` (an rtk hook rewrites plain `git` / `grep`).
- **Never push. Never `git stash`** (a popped stale stash once corrupted files). Never commit on `develop`.
- **api/AGENTS.md rule, verbatim: "DO NOT MAKE OR RUN ANY TESTS WITHOUT USER PERMISSION."** Task A0 asks Daffa **once** (AskUserQuestion) for exactly: create + run `tests/Feature/ClientLane/LaneVerificationCodeTest.php` and `tests/Feature/ClientLane/RequestDecisionVerificationGateTest.php`, and add two helpers to `tests/Support/ClientLaneFixtures.php`. Nothing else.
- **api tests only on the scratch DB `frnd_testing`, never the dev DB `frnd`.** Before every run: (1) `ls bootstrap/cache/config.php 2>/dev/null` prints nothing, else `php artisan config:clear`; (2) if `bootstrap/cache/routes-v7.php` exists, `mv` it to `/private/tmp/claude-501/routes-v7.php.bak`, never restore it, tell Daffa; (3) one file path per process:
  `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest <file> --compact`
  Never `php artisan test`, never a directory, never `--filter` alone. The full Feature suite is known-broken on fresh migrate; run only this plan's two files.
- **Dev DB `frnd`:** Task A5 migrates it with `TELESCOPE_ENABLED=false` **only after asking Daffa** (Telescope OOMs data migrations).
- **Part A is untested (fast mode).** If a Part D test fails inside Part A code (request creation, C-1, C-3 per-id results, digest), STOP and report the failure with the stack to Daffa — do not patch Part A in this plan.
- **api gates per commit:** `php -l` on each touched PHP file; `vendor/bin/pint <files>` then `vendor/bin/pint --test <files>`. api commit messages carry **NO `Co-Authored-By`** and no "Generated with" line: `feat(api): …`, `test(api): …`, `docs(api): …`, `refactor(api): …`.
- **Queue is `sync` in tests:** every api test file does `Mail::fake()` and `Bus::fake([SendApprovalRequestDigest::class])`. Public write throttle `public-share-link-write` = 10/min per IP: ≤ 9 decision/comment POSTs per test.
- **Security (api):** the raw code exists only in the mail. Stored as HMAC-SHA256 (R-D5), compared with `hash_equals`, never logged (`Log::` never sees it), never in a response, never in the mail subject, tags or metadata. `POST public/lane/code` is a non-oracle: one body, one status (`202`), for every input. Throttled per IP and per address (`sha1` of the lower-cased address in the key, never the raw address).
- **Web tests:** `bun test <file>` — one file per invocation, never a directory, never `bunx vitest`. Query through `const body = () => within(document.body)`, never `screen`. **Never `vi.mock` a module** — spy on `axiosPublic` (`get`/`post`), `globalThis.fetch` (`/s/session`) and `posthog.capture` (`import posthog from "posthog-js"`). No `vi.waitFor`, `vi.hoisted`, `vi.mocked` — use RTL `waitFor` and cast spies (`as unknown as { mock: … }`). Anything rendering `DecisionPage` needs the `QueryClientProvider` wrapper. Keep every test file < 45 KB.
- **Web type/lint gates:** `npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"` stays at the baseline **895** (re-measured in W0); touched files have **0**: `npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "<touched-paths-regex>"` prints nothing. `npx eslint <touched files>` clean (no warnings). `bunx prettier --write <touched files>` before each commit. `bun run build` is broken locally — if a build is ever needed: `node node_modules/next/dist/bin/next build`.
- **Web commits** `<type>(web): …`, body ending with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **frndOS UI (spec §11):** every UI task first reads `.agents/skills/frndos-ui/SKILL.md`, `.agents/skills/frndos-components-v2/SKILL.md`, `.agents/skills/frndos-design-foundations/SKILL.md` (§Appearance). Priority v2 → v1 → base → **new v2**. The new `CodeInput` lives in `src/components/frndos/v2/CodeInput.tsx`, is exported from `v2/index.ts`, has `src/components/frndos/stories/CodeInputV2.stories.tsx` (`title: "FrndOS v2/CodeInput"`) and a row in the v2 skill's component table — all in the same task. One file never imports both `@/components/frndos` (v1) and `@/components/frndos/v2`. Client sheets use the client-lane `Sheet` (a phone bottom sheet; v2 `Sheet` is a side dialog) with v2 `Button` inside; the email field is a native `<input>` styled with tokens (v2 has no text field, and v1 `Input` cannot share a file with v2 `Button`).
- **Tokens only** on every line this plan writes: `text-text-inverse*`, `text-textXs` / `text-textSm` / `text-textSmMedium` / `text-displayXs`, `text-negative-400` for errors, `rounded-full|2xl|xl|lg|md`, `bg-white/5|10`, `border-white/10|20`, `font-geist`, `transition-all duration-200 ease-out`, `focus-visible:ring-2 focus-visible:ring-white/40`. Never `text-[Npx]`, `rounded-[Npx]`, `px-[Npx]`, `text-white`, `text-gray-*`, a new dark hex. The `/s/` page is dark-scoped (`data-theme-scope="dark"` + `[data-client-lane-page]`) and nothing on it portals out (no `Popover`, `Tooltip`, `ActionMenu`).
- **Analytics:** only through typed helpers in `src/lib/analytics/client-lane-events.ts` (load the `frndos-analytics-events` skill in W1). Public events are PII-free: no name, email, token, lane code or code.
- **Mutation checks are mandatory** (each "(test)" mutation step): break exactly the named line, run the named test file, watch the NAMED test fail, restore, run green. A test that passes against its mutation is wrong — fix the test, never keep the mutation. If an expectation disagrees with unchanged production code, fix the expectation only when the code matches the spec; otherwise fix the code.
- Line numbers below cite branch HEAD on 2026-10-01 (api `646f2b29a`, web `752323bba`). Earlier tasks shift them — anchor every edit on the quoted code, not the number.

## Review Focus

Five inputs the spec implies but its happy path never exercises, most likely to bite a real client first. Each has its test in the owning task.

1. **Pins placed before verifying.** The common path is: guest pins a note → taps Approve → 403 → code → resubmit. The resubmitted decision carries pins authored as an anonymous guest while the decider is now a lane; they must still count (`approved_with_changes`), not fail the whole decision with `422 pins`. → Task A4 test *"pins placed before verifying ride on the verified decision"* (and its twin *"a pin typed under another address does not ride, and nothing is recorded"*).
2. **The wrong-code counter must survive the transaction.** Throwing `invalid_code` from inside `DB::transaction` would roll the `attempts` increment back and make the 5-try cap infinite. → Task A3 test *"a wrong code counts down, and the fifth miss ends the code"* (asserts the stored `attempts = 5`).
3. **Codes with leading zeros** (`004219`): an `int` cast anywhere (generation, validation, hashing, the six boxes) turns them into a code nobody can type. → Task A3 test *"a code with leading zeros verifies as typed"*; Task W3 test *"fills every box from a pasted code, spaces and dashes dropped"* (`"004 219"`).
4. **A lane that is not honoured** — a 30-day guest lane that has expired, or a lane cookie from another brand — must produce the code sheet again, never an error page or a silent advisory. → Task A4 test *"an expired lane or another brand's lane asks for a code again"*.
5. **Pasting the code from a mail app** (`"482 913"`, `"482-913"`, a trailing newline) and iOS `one-time-code` autofill into box 1 must fill all six boxes and verify on its own. → Task W3 tests *"fills every box from a pasted code, spaces and dashes dropped"*, *"keeps only digits"*; Task W5 page test pastes into box 1.

---

## File Structure

### api (`/Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item`)

| File | Status | Responsibility |
|---|---|---|
| `docs/prd/client-lane-p0a/api.md` | Modify | Append the Part D contract notes block (A1) |
| `database/migrations/2026_10_01_100300_create_client_verification_codes_table.php` | Create | `client_verification_codes` |
| `app/Models/ClientVerificationCode.php` | Create | Constants (TTL, attempts, digits), `generate()`, `hashCode()`, `scopeLive` |
| `app/Mail/ClientVerificationCodeMail.php` | Create | Queued mail carrying the raw code |
| `resources/views/emails/client-lane/verification-code.blade.php` | Create | Mail body on the client-lane layout |
| `app/Exceptions/ClientLane/InvalidVerificationCodeException.php` | Create | `422 invalid_code` + `attemptsLeft` |
| `app/Exceptions/ClientLane/VerificationCodeExpiredException.php` | Create | `422 code_expired` |
| `app/Services/ClientLane/ClientVerificationCodeService.php` | Create | `request()`, `verify()` |
| `app/Services/ClientLane/ClientLaneService.php` | Modify | `activePersonalLane()`, `laneForProvenEmail()`, private `mintVerifiedGuestLane()`; magic link reuses them |
| `app/Http/Controllers/Api/PublicLaneController.php` | Modify | `requestCode()`, `verifyCode()` |
| `app/Providers/AppServiceProvider.php` | Modify | Limiters `public-lane-code`, `public-lane-code-verify` |
| `routes/api.php` | Modify | `public/lane/code`, `public/lane/code/verify` |
| `app/Http/Controllers/Api/PublicShareLinkController.php` | Modify | 403 gate in `decideOnRequest`; `access.verification_required` |
| `app/Services/Approval/ApprovalService.php` | Modify | `ownPinsOn`: lane owns same-email guest pins (R-D9) |
| `tests/Support/ClientLaneFixtures.php` | Modify | `requestLink()`, `sentCode()` |
| `tests/Feature/ClientLane/LaneVerificationCodeTest.php` | Create | Request + verify lifecycle (A2, A3) |
| `tests/Feature/ClientLane/RequestDecisionVerificationGateTest.php` | Create | Gate, pins, advisory, non-request links (A4) |
| `docs/tracks/client-lane-multi-item.track.md` | Modify | Part D section + session log (A5) |

### web (`/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item`)

| File | Status | Responsibility |
|---|---|---|
| `docs/prd/client-lane-p0a/web.md` | Modify | Same Part D block, byte-identical (W1) |
| `src/lib/client-lane/types.ts` | Modify | `invalid_code` / `code_expired` error codes; `LaneCodeVerified` |
| `src/lib/client-lane/publicApi.ts` | Modify | `requestLaneCode`, `verifyLaneCode`; `publicApiError().attemptsLeft` |
| `src/lib/analytics/client-lane-events.ts` | Modify | `trackClientCodeRequested` / `Verified` / `Failed` |
| `src/lib/client-lane/laneCode.ts` | Create | `sendLaneCode`, `confirmLaneCode`, `persistLaneCookie`, `verifiedSummary` |
| `src/lib/client-lane/laneCode.test.ts` | Create | Tests for `laneCode.ts` |
| `src/lib/client-lane/cookie.ts` | Modify | `sessionCookieFromBody()` |
| `src/lib/client-lane/cookie.test.ts` | Create | Tests for it |
| `src/app/s/session/route.ts` | Modify | `POST` honours `expires_at` |
| `src/components/frndos/v2/CodeInput.tsx` | Create | v2 one-time-code boxes on `OTPField` |
| `src/components/frndos/v2/CodeInput.test.tsx` | Create | Tests |
| `src/components/frndos/v2/index.ts` | Modify | Export |
| `src/components/frndos/stories/CodeInputV2.stories.tsx` | Create | Story |
| `.agents/skills/frndos-components-v2/SKILL.md` | Modify | Component row |
| `src/components/client-lane/sheets/CodeSheet.tsx` | Create | Email step + code step |
| `src/components/client-lane/sheets/CodeSheet.test.tsx` | Create | Tests |
| `src/components/client-lane/RequestRail.tsx` | Modify | `RequestOverview` `identityLine` |
| `src/components/client-lane/DecisionPage.tsx` | Modify | 403 → `CodeSheet`, verify → resubmit, summary line |
| `src/lib/client-lane/testFixtures.ts` | Modify | `kvRequest()` |
| `src/components/client-lane/DecisionPage.code.test.tsx` | Create | Page-level code flow |
| `docs/tracks/client-lane-multi-item.track.md` | Modify | Part D section + session log (W6) |

---

# API

### Task A0: Pre-flight — Jeff, permission, scratch DB

**Files:** none changed.

**Interfaces:**
- Consumes: nothing.
- Produces: a recorded "yes" for the Jeff gate and for the two test files; a migrated-on-demand `frnd_testing`.

- [ ] **Step 1: Ask the Jeff gate.** AskUserQuestion: "Part D (one verification code per device before a KV request decision) is a vision change awaiting Jeff (spec D-9). Has Jeff approved it?" Options: "Yes — build it" / "No — stop". On "No", stop the plan and report.

- [ ] **Step 2: Ask once for test permission (test).** AskUserQuestion, verbatim list: "May I create and run, on the scratch DB `frnd_testing` only: `tests/Feature/ClientLane/LaneVerificationCodeTest.php`, `tests/Feature/ClientLane/RequestDecisionVerificationGateTest.php`, and add `requestLink()` + `sentCode()` to `tests/Support/ClientLaneFixtures.php`?" Options: "Yes" / "No — fast mode (no tests)". Record the answer in the track file in A5. On "No", every "(test)" step below is skipped.

- [ ] **Step 3: Confirm branch and state.**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && /usr/bin/git branch --show-current && /usr/bin/git status --short | head -20 && /usr/bin/git log --oneline -1`
Expected: `feature/daffa/vc-client-lane-multi-item`; HEAD `646f2b29a` or later; no unexpected modified files (report any to Daffa before continuing).

- [ ] **Step 4: Scratch DB reachable, caches clear (test).**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && pg_isready -h localhost -p 5432 && psql -h localhost -p 5432 -lqt | cut -d '|' -f1 | /usr/bin/grep -w frnd_testing; ls bootstrap/cache/config.php bootstrap/cache/routes-v7.php 2>/dev/null`
Expected: `accepting connections`, a `frnd_testing` line, and no cache file printed (apply the Global Constraints cache rule otherwise).

---

### Task A1: Contract notes — Part D block in `api.md`

**Files:**
- Modify: `docs/prd/client-lane-p0a/api.md` (insert before the first `## Scope`, currently line 185)

**Interfaces:**
- Consumes: nothing.
- Produces: the contract every later task implements; W1 copies it byte-identical into `web.md`.

- [ ] **Step 1: Write the block to a scratch file.**

```bash
mkdir -p /private/tmp/claude-501 && cat > /private/tmp/claude-501/part-d-contract.md <<'MD'
### Additive notes (KV approval requests Part D — verification code once per device, spec §7, 2026-10-01)

Vision change awaiting Jeff (spec D-9); ships last, and dropping it reverts exactly this block. Byte-identical in `api.md` and `web.md`.

- **Rule.** On a KV approval-request link (`purpose = approval`) every C-3 decision — `approved`, `changes_required` and request-level `deferred` — needs an honoured lane (C-2: active, on the link's brand). Without one: `403 { "code": "verification_required", "message": "…" }`, checked after body validation, the request lookup and `guest_required`, before anything is recorded. Looking, pins and comments (C-4) never need a lane, and the name gate is unchanged. Deck, campaign-plan and every other link keep C-3 exactly as written above; the campaign gate still answers through the magic link (C-5).
- **C-1 on an approval link:** `access.verification_required` is `true` when no lane is honoured and `false` otherwise (replacing the constant `false` of the request notes above).
- **`POST public/lane/code`** `{ "email": "…" (≤ 254), "share_token": "…" (≤ 64) }` → **always** `202 { "message": "If that address can decide here, a code is on its way." }` with `Cache-Control: no-store` — also for an unknown, revoked or expired token, a link that is not an approval link, a request that is no longer pending, and any address. Otherwise it ends every still-usable code for the same (address, link) and mails `ClientVerificationCodeMail` with a fresh 6-digit code (leading zeros kept) that is usable for 10 minutes. Addresses are compared lower-cased. Throttle `public-lane-code`: 5/min per IP and 5/hour per address → `429 { "message", "retry_after_seconds" }`.
- **`POST public/lane/code/verify`** `{ "email": "…", "code": "123456" (exactly 6 digits), "share_token": "…" }` → `200 { "data": { "lane_code": "<16 chars>", "kind": "personal" | "verified_guest", "expires_at": "<ISO>" | null } }`, `Cache-Control: no-store`. The code is checked against the newest usable code for (address, link) and spent on success. The lane is the address' active `personal` lane on the link's brand when there is one (stamped `verified_at`; `expires_at: null`), otherwise a new `verified_guest` lane (30 days, `share_link_id` = this link). Errors, all `422` with `Cache-Control: no-store`: `{ "code": "invalid_code", "message", "attempts_left": 1..4 }` for a wrong code; `{ "code": "code_expired", "message" }` when there is no usable code — never sent, older than 10 minutes, already spent, replaced by a newer code, the fifth wrong try (which also ends it), or an unknown / revoked / non-approval link; standard validation `422` for a malformed body. Throttle `public-lane-code-verify`: 10/min per IP and 20/hour per address.
- **Storage.** `client_verification_codes` (`id` ulid, `email`, `brand_id`, `share_link_id`, `code_hash` = HMAC-SHA256 of the code keyed with the app key, `attempts`, `expires_at`, `used_at`, `created_at`). The raw code exists only in the mail: never stored, logged, returned, or put in the mail's subject or tags.
- **Pins after verifying.** A lane actor also owns guest pins (no author, no lane) whose `guest_email` equals the lane's email, compared lower-cased — so pins placed before verifying ride on the verified decision (C-3 `pins`). A pin placed under a different address is not the decider's: `422` on `pins`, nothing recorded.
- **Web.** `POST /s/session` accepts an optional `"expires_at": "<ISO>"` beside `code`: the cookie's `Max-Age` runs to it (C-2); a past or unparseable value → `400`; absent or `null` → the 400-day default. On `403 verification_required` from a request link the page stores the decision as the draft (`sessionStorage` `frnd_lane_draft:{token}`), opens the code sheet (email prefilled from the name gate, editable), calls `public/lane/code` once as it opens, verifies, `POST /s/session { code, expires_at }`, re-resolves C-1 with the new `X-Lane-Code`, and the draft submits itself (the AC-14 path). Closing the sheet drops the draft. A campaign-plan link keeps the magic-link sheet.
MD
```

- [ ] **Step 2: Insert it before `## Scope`.**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && python3 - <<'PY'
from pathlib import Path
p = Path("docs/prd/client-lane-p0a/api.md")
block = Path("/private/tmp/claude-501/part-d-contract.md").read_text().rstrip("\n")
s = p.read_text()
marker = "\n## Scope\n"
assert s.count(marker) == 1, s.count(marker)
p.write_text(s.replace(marker, "\n" + block + "\n\n## Scope\n", 1))
PY
/usr/bin/grep -n "^### Additive notes (KV approval requests Part D\|^## Scope" docs/prd/client-lane-p0a/api.md
```
Expected: the Part D heading on the line just above `## Scope` (with one blank line between).

- [ ] **Step 3: Commit.**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && /usr/bin/git add docs/prd/client-lane-p0a/api.md && /usr/bin/git commit -m "docs(api): client-lane contract — Part D verification code once per device"
```

---

### Task A2: Request a code — table, model, mail, service, route

**Files:**
- Create: `database/migrations/2026_10_01_100300_create_client_verification_codes_table.php`
- Create: `app/Models/ClientVerificationCode.php`
- Create: `app/Mail/ClientVerificationCodeMail.php`
- Create: `resources/views/emails/client-lane/verification-code.blade.php`
- Create: `app/Services/ClientLane/ClientVerificationCodeService.php` (request half)
- Modify: `app/Http/Controllers/Api/PublicLaneController.php`
- Modify: `app/Providers/AppServiceProvider.php` (after the `public-lane-verify` limiter, ~line 756)
- Modify: `routes/api.php` (after `->name('public.lane.verify');`, ~line 6678)
- Modify: `tests/Support/ClientLaneFixtures.php`
- Test: `tests/Feature/ClientLane/LaneVerificationCodeTest.php`

**Interfaces:**
- Consumes: `ApprovalRequestService::create(StudioFile $file, User $requester, ?array $phases = null, array $approverEmails = [], ?string $message = null, ?CarbonInterface $decideBy = null, bool $notify = true): array{request, share_link, approvers}` (Part A); `ClientLaneService::shareUrl(ShareLink): string`.
- Produces:
  - `ClientVerificationCode` constants `TTL_MINUTES = 10`, `MAX_ATTEMPTS = 5`, `DIGITS = 6`; `static generate(): string`; `static hashCode(string $code): string`; `scopeLive(Builder): Builder`.
  - `ClientVerificationCodeService::request(string $email, string $shareToken): void` (never throws for a bad token).
  - `ClientVerificationCodeMail(public string $code, public string $brandName, public string $reviewUrl)`.
  - Route `POST public/lane/code` → `PublicLaneController::requestCode`, name `public.lane.code`, throttle `public-lane-code`.
  - Fixtures `ClientLaneFixtures::requestLink(array $kv): array{request: ApprovalRequest, link: ShareLink, approval: Approval}` and `ClientLaneFixtures::sentCode(string $email): string`.

- [ ] **Step 1: Fixtures (test).** Add to `tests/Support/ClientLaneFixtures.php` — imports at the top (`use App\Mail\ClientVerificationCodeMail; use App\Models\ApprovalRequest; use App\Models\ShareLink; use App\Services\Approval\ApprovalRequestService; use Illuminate\Support\Facades\Mail;`; `Approval` is already imported), methods before `plan()`:

```php
    /**
     * A KV file with one Craft board marked ready and sent as Request 1 —
     * no named approvers, so `optional` (Part D tests). Callers fake Mail
     * and the digest job first.
     *
     * @param  array{workspace: Workspace, user: User, brand: Brand, file: StudioFile}  $kv
     * @return array{request: ApprovalRequest, link: ShareLink, approval: Approval}
     */
    public static function requestLink(array $kv): array
    {
        $board = self::board($kv['file'], $kv['user'], 'craft', 'Hero board');
        self::markReady('kv_generation', $board->id, $kv['user']);

        $sent = app(ApprovalRequestService::class)->create($kv['file'], $kv['user'], notify: false);
        /** @var ApprovalRequest $request */
        $request = $sent['request'];

        return [
            'request' => $request,
            'link' => $sent['share_link'],
            'approval' => $request->approvals()->firstOrFail(),
        ];
    }

    /** The raw code of the newest ClientVerificationCodeMail queued to $email (needs Mail::fake()). */
    public static function sentCode(string $email): string
    {
        $mail = Mail::queued(
            ClientVerificationCodeMail::class,
            fn (ClientVerificationCodeMail $m): bool => $m->hasTo($email),
        )->last();

        if ($mail === null) {
            throw new \RuntimeException("No verification code was queued to {$email}.");
        }

        return $mail->code;
    }
```

- [ ] **Step 2: Write the failing request tests (test).** Create `tests/Feature/ClientLane/LaneVerificationCodeTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Jobs\SendApprovalRequestDigest;
use App\Mail\ClientVerificationCodeMail;
use App\Models\Approval;
use App\Models\ClientLaneLink;
use App\Models\ClientVerificationCode;
use App\Models\ShareLink;
use App\Models\User;
use App\Services\ClientLane\ClientLaneService;
use App\Services\Sharing\ShareLinkService;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);

    $this->kv = ClientLaneFixtures::kvFile();
    $sent = ClientLaneFixtures::requestLink($this->kv);
    $this->request = $sent['request'];
    $this->link = $sent['link'];
    $this->token = $sent['link']->token;

    $this->askCode = fn (string $email = 'dina@brand.test') => $this->postJson('/api/public/lane/code', [
        'email' => $email,
        'share_token' => $this->token,
    ]);
    $this->sendCode = function (string $email = 'dina@brand.test'): string {
        ($this->askCode)($email)->assertStatus(202);

        return ClientLaneFixtures::sentCode(strtolower($email));
    };
    $this->verify = fn (string $code, string $email = 'dina@brand.test', ?string $token = null) => $this->postJson('/api/public/lane/code/verify', [
        'email' => $email,
        'code' => $code,
        'share_token' => $token ?? $this->token,
    ]);
});

// ── request ────────────────────────────────────────────────────────────

test('a code request answers 202 and mails a six-digit code stored only as a keyed hash', function () {
    $res = ($this->askCode)('Dina@Brand.test')
        ->assertStatus(202)
        ->assertExactJson(['message' => 'If that address can decide here, a code is on its way.']);
    expect($res->headers->get('Cache-Control'))->toContain('no-store');

    $code = ClientLaneFixtures::sentCode('dina@brand.test');
    expect($code)->toMatch('/^\d{6}$/');

    $row = ClientVerificationCode::query()->sole();
    expect($row->email)->toBe('dina@brand.test')
        ->and($row->brand_id)->toBe((string) $this->kv['brand']->id)
        ->and($row->share_link_id)->toBe((string) $this->link->id)
        ->and($row->code_hash)->toBe(ClientVerificationCode::hashCode($code))
        ->and($row->code_hash)->not->toBe(hash('sha256', $code))
        ->and($row->attempts)->toBe(0)
        ->and($row->used_at)->toBeNull()
        ->and($row->expires_at->greaterThan(now()->addMinutes(9)))->toBeTrue()
        ->and($row->expires_at->lessThanOrEqualTo(now()->addMinutes(10)))->toBeTrue();

    Mail::assertQueued(ClientVerificationCodeMail::class, fn (ClientVerificationCodeMail $m): bool => $m->hasTo('dina@brand.test')
        && $m->reviewUrl === ClientLaneService::shareUrl($this->link));
});

test('the code mail shows the code and links back to the review, never in its subject', function () {
    $mail = new ClientVerificationCodeMail(code: '004219', brandName: 'Garuda', reviewUrl: 'https://web.test/s/tok');

    expect($mail->render())->toContain('004219')->toContain('https://web.test/s/tok')
        ->and($mail->envelope()->subject)->not->toContain('004219')
        ->and(json_encode([$mail->envelope()->tags, $mail->envelope()->metadata]))->not->toContain('004219');
});

test('unknown, view, revoked and closed links answer the same 202 and send nothing', function () {
    $view = app(ShareLinkService::class)->create($this->kv['file'], $this->kv['user'], ['craft'], role: ShareLink::ROLE_COMMENT);

    $bodies = [];
    $bodies[] = $this->postJson('/api/public/lane/code', ['email' => 'dina@brand.test', 'share_token' => 'NoSuchToken00000'])->assertStatus(202)->json();
    $bodies[] = $this->postJson('/api/public/lane/code', ['email' => 'dina@brand.test', 'share_token' => $view->token])->assertStatus(202)->json();

    $this->request->forceFill(['status' => Approval::STATUS_NOT_RELEVANT])->save();
    $bodies[] = ($this->askCode)()->assertStatus(202)->json();

    $this->request->forceFill(['status' => Approval::STATUS_PENDING])->save();
    $this->link->forceFill(['revoked_at' => now()])->save();
    $bodies[] = ($this->askCode)()->assertStatus(202)->json();

    expect(array_unique(array_map('json_encode', $bodies)))->toHaveCount(1)
        ->and(ClientVerificationCode::query()->count())->toBe(0);
    Mail::assertNothingQueued();
});

test('a new code ends the previous unused one for that address and link only', function () {
    ($this->askCode)()->assertStatus(202);
    ($this->askCode)()->assertStatus(202);
    ($this->askCode)('bayu@brand.test')->assertStatus(202);

    $dina = ClientVerificationCode::query()->where('email', 'dina@brand.test');
    expect((clone $dina)->count())->toBe(2)
        ->and((clone $dina)->live()->count())->toBe(1)
        ->and((clone $dina)->live()->value('id'))->toBe((clone $dina)->orderByDesc('id')->value('id'))
        ->and(ClientVerificationCode::query()->where('email', 'bayu@brand.test')->live()->count())->toBe(1);
});

test('code requests are throttled per address and per ip', function () {
    foreach (range(1, 5) as $i) {
        $this->withServerVariables(['REMOTE_ADDR' => "10.0.0.{$i}"]);
        ($this->askCode)()->assertStatus(202);
    }
    $this->withServerVariables(['REMOTE_ADDR' => '10.0.0.9']);
    ($this->askCode)()->assertStatus(429);

    $this->withServerVariables(['REMOTE_ADDR' => '10.0.1.1']);
    foreach (range(1, 5) as $i) {
        ($this->askCode)("guest{$i}@brand.test")->assertStatus(202);
    }
    ($this->askCode)('guest6@brand.test')->assertStatus(429);
});
```

- [ ] **Step 3: Run to see it fail (test).**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/ClientLane/LaneVerificationCodeTest.php --compact`
Expected: FAIL — `Class "App\Mail\ClientVerificationCodeMail" not found` (or the missing table). If `requestLink()` itself fails inside `ApprovalRequestService::create`, that is Part A: stop and report.

- [ ] **Step 4: Migration.** Create `database/migrations/2026_10_01_100300_create_client_verification_codes_table.php`:

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * KV approval requests Part D (spec §7) — six-digit codes that verify an
 * address once per device before a KV request decision counts.
 *
 * `code_hash` is HMAC-SHA256 of the code keyed with the app key (never the
 * code): a dump of this table alone cannot enumerate the 10^6 codes. A code
 * is bound to one (address, link); `attempts` caps guessing at 5, and a
 * newer request ends the older code by setting `expires_at = now()`.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('client_verification_codes', function (Blueprint $table) {
            $table->ulid('id')->primary();
            $table->string('email', 254);
            $table->char('brand_id', 26);
            $table->foreignUlid('share_link_id')->constrained('share_links')->cascadeOnDelete();
            $table->char('code_hash', 64);
            $table->unsignedSmallInteger('attempts')->default(0);
            $table->timestampTz('expires_at');
            $table->timestampTz('used_at')->nullable();
            $table->timestampTz('created_at')->useCurrent();

            $table->foreign('brand_id')->references('id')->on('brands')->cascadeOnDelete();
            $table->index(['email', 'share_link_id']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('client_verification_codes');
    }
};
```

- [ ] **Step 5: Model.** Create `app/Models/ClientVerificationCode.php`:

```php
<?php

declare(strict_types=1);

namespace App\Models;

// craftsman-ignore: PHP002 — Eloquent models are not final in this codebase.

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Carbon;

/**
 * A six-digit code that proves an address once per device before a KV
 * request decision counts (KV approval requests Part D, spec §7).
 *
 * Only `hashCode($code)` is stored; the raw code exists in the mail and
 * nowhere else — never logged, never returned.
 *
 * @property string $id
 * @property string $email
 * @property string $brand_id
 * @property string $share_link_id
 * @property string $code_hash
 * @property int $attempts
 * @property Carbon $expires_at
 * @property Carbon|null $used_at
 * @property Carbon|null $created_at
 */
class ClientVerificationCode extends Model
{
    use HasUlids;

    protected $table = 'client_verification_codes';

    public const UPDATED_AT = null;

    /** Minutes a code stays usable. */
    public const TTL_MINUTES = 10;

    /** Wrong tries before a code is dead; the last one answers `code_expired`. */
    public const MAX_ATTEMPTS = 5;

    public const DIGITS = 6;

    protected $fillable = [
        'email',
        'brand_id',
        'share_link_id',
        'code_hash',
        'attempts',
        'expires_at',
        'used_at',
    ];

    protected $hidden = ['code_hash'];

    protected function casts(): array
    {
        return [
            'attempts' => 'integer',
            'expires_at' => 'datetime',
            'used_at' => 'datetime',
            'created_at' => 'datetime',
        ];
    }

    /** Six digits, leading zeros kept — a string end to end, never an int. */
    public static function generate(): string
    {
        return str_pad((string) random_int(0, 10 ** self::DIGITS - 1), self::DIGITS, '0', STR_PAD_LEFT);
    }

    /** HMAC-SHA256 keyed with the app key: a table dump alone cannot enumerate the codes. */
    public static function hashCode(string $code): string
    {
        return hash_hmac('sha256', $code, (string) config('app.key'));
    }

    /** Not spent, not expired (or ended by a newer request), not guessed to death. */
    public function scopeLive(Builder $query): Builder
    {
        return $query
            ->whereNull('used_at')
            ->where('expires_at', '>', now())
            ->where('attempts', '<', self::MAX_ATTEMPTS);
    }

    public function shareLink(): BelongsTo
    {
        return $this->belongsTo(ShareLink::class, 'share_link_id');
    }
}
```

- [ ] **Step 6: Mail + view.** Create `app/Mail/ClientVerificationCodeMail.php`:

```php
<?php

namespace App\Mail;

use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Mail\Mailable;
use Illuminate\Mail\Mailables\Content;
use Illuminate\Mail\Mailables\Envelope;
use Illuminate\Queue\SerializesModels;

/**
 * "Your code" — the six digits a client types on a KV request link before
 * their first decision on this device counts (KV approval requests Part D).
 *
 * Carries the RAW code in `$code` and nowhere else: the subject, tags and
 * metadata never contain it, and nothing user-typed is rendered (spec's
 * `name` was dropped, ruling R-D4). Queued so the `202` never waits on SMTP
 * — and a synchronous send would make the response time an oracle for
 * "this link exists".
 */
class ClientVerificationCodeMail extends Mailable implements ShouldQueue
{
    use Queueable, SerializesModels;

    public function __construct(
        public string $code,
        public string $brandName,
        public string $reviewUrl,
    ) {}

    public function envelope(): Envelope
    {
        return new Envelope(
            subject: "Your code for {$this->brandName} on frndOS",
            tags: ['client-lane', 'verification-code'],
            metadata: ['notification_type' => 'client_verification_code'],
        );
    }

    public function content(): Content
    {
        return new Content(view: 'emails.client-lane.verification-code');
    }
}
```

Create `resources/views/emails/client-lane/verification-code.blade.php`:

```blade
{{-- KV approval requests Part D (spec §7) — six digits, one use, 10 minutes.
     The code is the heading. Nothing user-typed is rendered here. --}}
@extends('emails.client-lane.layout')

@section('title', 'Your code')
@section('heading', $code)
@section('subheading', "Enter this code on the {$brandName} review page to confirm it is you. It works once, for 10 minutes.")
@section('cta_url', $reviewUrl)
@section('cta_label', 'Back to the review')
@section('footnote', 'If you did not ask for it, ignore this email. Never share this code — nobody from frndOS will ask you for it.')
```

- [ ] **Step 7: Service (request half).** Create `app/Services/ClientLane/ClientVerificationCodeService.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\ClientLane;

// craftsman-ignore: PHP002 — resolved from the container and swapped in tests.

use App\Mail\ClientVerificationCodeMail;
use App\Models\ApprovalRequest;
use App\Models\Brand;
use App\Models\ClientVerificationCode;
use App\Models\ShareLink;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Mail;

/**
 * KV approval requests Part D (spec §7): one six-digit code per device
 * before a decision on a KV request link counts.
 *
 * SECURITY: `request()` is not an oracle — it returns nothing and the
 * controller answers one `202` whatever happened. Codes are stored as an
 * HMAC (ruling R-D5), compared with `hash_equals`, capped at 5 tries, live
 * 10 minutes, and are never logged.
 */
class ClientVerificationCodeService
{
    public function __construct(private readonly ClientLaneService $lanes) {}

    /**
     * Mail a fresh code for (address, link) and end the previous one — only
     * for an active comment link of a still-pending KV request (R-D6).
     * Silent for everything else.
     */
    public function request(string $email, string $shareToken): void
    {
        $email = strtolower(trim($email));

        $link = $this->approvalLink($shareToken);
        if ($link === null) {
            return;
        }

        $request = ApprovalRequest::query()->where('share_link_id', $link->id)->first();
        if ($request === null || ! $request->isPending()) {
            return;
        }

        $code = ClientVerificationCode::generate();

        DB::transaction(function () use ($email, $link, $request, $code): void {
            ClientVerificationCode::query()
                ->where('email', $email)
                ->where('share_link_id', $link->id)
                ->live()
                ->update(['expires_at' => now()]);

            ClientVerificationCode::create([
                'email' => $email,
                'brand_id' => (string) $request->brand_id,
                'share_link_id' => (string) $link->id,
                'code_hash' => ClientVerificationCode::hashCode($code),
                'attempts' => 0,
                'expires_at' => now()->addMinutes(ClientVerificationCode::TTL_MINUTES),
            ]);
        });

        $brandName = (string) (Brand::query()->withoutGlobalScopes()->find($request->brand_id)?->name ?? 'your brand');

        Mail::to($email)->queue(new ClientVerificationCodeMail(
            code: $code,
            brandName: $brandName,
            reviewUrl: ClientLaneService::shareUrl($link),
        ));
    }

    /** An active `purpose = approval`, `role = comment` link, else null. */
    private function approvalLink(string $shareToken): ?ShareLink
    {
        $link = ShareLink::query()->where('token', $shareToken)->active()->first();

        return $link !== null
            && $link->purpose === ShareLink::PURPOSE_APPROVAL
            && $link->role === ShareLink::ROLE_COMMENT
                ? $link
                : null;
    }
}
```

(`$this->lanes` is used by `verify()` in A3.)

- [ ] **Step 8: Controller `requestCode`.** In `app/Http/Controllers/Api/PublicLaneController.php` add the import `use App\Services\ClientLane\ClientVerificationCodeService;`, replace the constructor and add the method after `verify()`:

```php
    public function __construct(
        private readonly ClientLaneService $lanes,
        private readonly ClientVerificationCodeService $codes,
    ) {}
```

```php
    /**
     * KV approval requests Part D (spec §7): mail a six-digit code. ALWAYS
     * `202` with the same body — unknown token, view link, closed request
     * and a real send look identical.
     */
    public function requestCode(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'email' => ['required', 'string', 'email', 'max:254'],
            'share_token' => ['required', 'string', 'max:64'],
        ]);

        $this->codes->request($validated['email'], $validated['share_token']);

        return response()
            ->json(['message' => 'If that address can decide here, a code is on its way.'], 202)
            ->header('Cache-Control', 'no-store');
    }
```

Also extend the class docblock with one paragraph: "`requestCode` / `verifyCode` are Part D's code half of the ladder (KV request links): `requestCode` always answers `202`; `verifyCode` spends a code and hands back the lane code the page posts to `/s/session`."

- [ ] **Step 9: Limiter.** In `app/Providers/AppServiceProvider.php`, directly after the `RateLimiter::for('public-lane-verify', …);` block:

```php
        // KV approval requests Part D: code requests. 5/min per IP + 5/hour
        // per address — the endpoint always answers 202, so this limiter is
        // what keeps it from becoming a mail cannon aimed at one inbox.
        RateLimiter::for('public-lane-code', function (Request $request) use ($tooManyAttemptsResponse) {
            $email = strtolower(trim((string) $request->input('email', '')));

            return [
                Limit::perMinute(5)->by('plc-ip|'.$request->ip())->response($tooManyAttemptsResponse),
                Limit::perHour(5)->by('plc-email|'.sha1($email))->response($tooManyAttemptsResponse),
            ];
        });
```

- [ ] **Step 10: Route.** In `routes/api.php`, directly after `->name('public.lane.verify');`:

```php

// KV approval requests Part D (spec §7): a six-digit code once per device
// before a KV request decision counts. `code` always answers 202;
// `code/verify` spends the code and returns the lane code the page posts to
// `/s/session`.
Route::post('public/lane/code', [PublicLaneController::class, 'requestCode'])
    ->middleware('throttle:public-lane-code')
    ->name('public.lane.code');
```

- [ ] **Step 11: Run the request tests (test).** Same command as Step 3 (the verify tests are not written yet).
Expected: 5 passed.

- [ ] **Step 12: Mutation checks (test).** One at a time, restore after each:
  1. In `request()`, store `'code_hash' => hash('sha256', $code)` → *"a code request answers 202 and mails a six-digit code stored only as a keyed hash"* FAILS.
  2. Delete the `->update(['expires_at' => now()])` statement → *"a new code ends the previous unused one for that address and link only"* FAILS.
  3. Delete the `! $request->isPending()` condition → *"unknown, view, revoked and closed links answer the same 202 and send nothing"* FAILS.
  4. Change `Limit::perHour(5)->by('plc-email|'…)` to `perHour(50)` → *"code requests are throttled per address and per ip"* FAILS.

- [ ] **Step 13: Gates and commit.**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F=(database/migrations/2026_10_01_100300_create_client_verification_codes_table.php app/Models/ClientVerificationCode.php app/Mail/ClientVerificationCodeMail.php app/Services/ClientLane/ClientVerificationCodeService.php app/Http/Controllers/Api/PublicLaneController.php app/Providers/AppServiceProvider.php routes/api.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientLane/LaneVerificationCodeTest.php) && for f in "${F[@]}"; do php -l "$f" || exit 1; done && vendor/bin/pint "${F[@]}" && vendor/bin/pint --test "${F[@]}" && /usr/bin/git add "${F[@]}" resources/views/emails/client-lane/verification-code.blade.php && /usr/bin/git commit -m "feat(api): request a six-digit lane code for a KV request link — always 202, throttled, hashed"
```

---

### Task A3: Verify a code — spend, personal hand-back, attempts

**Files:**
- Create: `app/Exceptions/ClientLane/InvalidVerificationCodeException.php`
- Create: `app/Exceptions/ClientLane/VerificationCodeExpiredException.php`
- Modify: `app/Services/ClientLane/ClientLaneService.php` (`requestMagicLink` ~line 205, `verifyMagicLink` create block ~line 280, new public helpers)
- Modify: `app/Services/ClientLane/ClientVerificationCodeService.php` (add `verify()`)
- Modify: `app/Http/Controllers/Api/PublicLaneController.php` (add `verifyCode()`)
- Modify: `app/Providers/AppServiceProvider.php`, `routes/api.php`
- Test: `tests/Feature/ClientLane/LaneVerificationCodeTest.php` (append)

**Interfaces:**
- Consumes: A2's model, service, fixtures, `$this->sendCode` / `$this->verify` closures.
- Produces:
  - `ClientLaneService::activePersonalLane(string $brandId, string $email): ?ClientLaneLink`
  - `ClientLaneService::laneForProvenEmail(string $brandId, string $email, ?string $shareLinkId): ClientLaneLink` (call inside a transaction)
  - `ClientVerificationCodeService::verify(string $email, string $code, string $shareToken): ClientLaneLink` — throws `InvalidVerificationCodeException` (`public readonly int $attemptsLeft`, `CODE = 'invalid_code'`) or `VerificationCodeExpiredException` (`CODE = 'code_expired'`).
  - Route `POST public/lane/code/verify` → `PublicLaneController::verifyCode`, name `public.lane.code.verify`, throttle `public-lane-code-verify`; `200 { data: { lane_code, kind, expires_at } }`.

- [ ] **Step 1: Write the failing verify tests (test).** Append to `tests/Feature/ClientLane/LaneVerificationCodeTest.php`:

```php
// ── verify ─────────────────────────────────────────────────────────────

test('a valid code is spent once and hands back a 30-day verified-guest lane', function () {
    $code = ($this->sendCode)();

    $res = ($this->verify)($code)->assertOk()->assertJsonPath('data.kind', 'verified_guest');
    expect($res->headers->get('Cache-Control'))->toContain('no-store');

    $lane = ClientLaneLink::query()->where('unique_code', $res->json('data.lane_code'))->sole();
    expect($lane->kind)->toBe(ClientLaneLink::KIND_VERIFIED_GUEST)
        ->and($lane->user_id)->toBeNull()
        ->and($lane->email)->toBe('dina@brand.test')
        ->and($lane->brand_id)->toBe((string) $this->kv['brand']->id)
        ->and($lane->share_link_id)->toBe((string) $this->link->id)
        ->and($lane->verified_at)->not->toBeNull()
        ->and($lane->expires_at->isSameDay(now()->addDays(ClientLaneLink::VERIFIED_GUEST_DAYS)))->toBeTrue()
        ->and($res->json('data.expires_at'))->toBe($lane->expires_at->toISOString())
        ->and(ClientVerificationCode::query()->sole()->used_at)->not->toBeNull();

    ($this->verify)($code)->assertStatus(422)->assertJsonPath('code', 'code_expired');
    expect(ClientLaneLink::query()->where('kind', ClientLaneLink::KIND_VERIFIED_GUEST)->count())->toBe(1);
});

test('an address with an active personal lane on the brand gets that lane back', function () {
    $client = User::factory()->create(['email' => 'dina@brand.test']);
    $personal = ClientLaneLink::factory()->create([
        'workspace_id' => $this->kv['workspace']->id,
        'brand_id' => $this->kv['brand']->id,
        'user_id' => $client->id,
        'email' => 'Dina@Brand.test',
    ]);

    ($this->verify)(($this->sendCode)())
        ->assertOk()
        ->assertJsonPath('data.lane_code', $personal->unique_code)
        ->assertJsonPath('data.kind', 'personal')
        ->assertJsonPath('data.expires_at', null);

    expect($personal->fresh()->verified_at)->not->toBeNull()
        ->and(ClientLaneLink::query()->where('kind', ClientLaneLink::KIND_VERIFIED_GUEST)->count())->toBe(0);
});

test('a revoked personal lane is not handed back', function () {
    $client = User::factory()->create(['email' => 'dina@brand.test']);
    ClientLaneLink::factory()->revoked()->create([
        'workspace_id' => $this->kv['workspace']->id,
        'brand_id' => $this->kv['brand']->id,
        'user_id' => $client->id,
        'email' => 'dina@brand.test',
    ]);

    ($this->verify)(($this->sendCode)())->assertOk()->assertJsonPath('data.kind', 'verified_guest');
});

test('a wrong code counts down, and the fifth miss ends the code', function () {
    $code = ($this->sendCode)();
    $wrong = $code === '000000' ? '111111' : '000000';

    foreach ([4, 3, 2, 1] as $left) {
        ($this->verify)($wrong)->assertStatus(422)->assertExactJson([
            'code' => 'invalid_code',
            'message' => "That code didn't match.",
            'attempts_left' => $left,
        ]);
    }
    ($this->verify)($wrong)->assertStatus(422)->assertJsonPath('code', 'code_expired');
    ($this->verify)($code)->assertStatus(422)->assertJsonPath('code', 'code_expired');

    expect(ClientVerificationCode::query()->sole()->attempts)->toBe(5)
        ->and(ClientLaneLink::query()->count())->toBe(0);
});

test('a code older than ten minutes has expired', function () {
    $code = ($this->sendCode)();
    $this->travel(11)->minutes();

    ($this->verify)($code)->assertStatus(422)->assertJsonPath('code', 'code_expired');
});

test('a code with leading zeros verifies as typed', function () {
    ClientVerificationCode::create([
        'email' => 'dina@brand.test',
        'brand_id' => $this->kv['brand']->id,
        'share_link_id' => $this->link->id,
        'code_hash' => ClientVerificationCode::hashCode('004219'),
        'attempts' => 0,
        'expires_at' => now()->addMinutes(10),
    ]);

    ($this->verify)('4219')->assertStatus(422)->assertJsonValidationErrors('code');
    ($this->verify)('004219')->assertOk();
});

test('no code, another address or another link answers code_expired and mints nothing', function () {
    ($this->verify)('123456')->assertStatus(422)->assertJsonPath('code', 'code_expired');

    $code = ($this->sendCode)();
    ($this->verify)($code, 'bayu@brand.test')->assertStatus(422)->assertJsonPath('code', 'code_expired');
    ($this->verify)($code, 'dina@brand.test', 'NoSuchToken00000')->assertStatus(422)->assertJsonPath('code', 'code_expired');

    expect(ClientLaneLink::query()->count())->toBe(0);
});

test('verification is throttled per ip', function () {
    foreach (range(1, 10) as $i) {
        ($this->verify)('123456', "guest{$i}@brand.test")->assertStatus(422);
    }
    ($this->verify)('123456', 'guest11@brand.test')->assertStatus(429);
});
```

- [ ] **Step 2: Run to see the new tests fail (test).**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/ClientLane/LaneVerificationCodeTest.php --compact`
Expected: the 5 request tests pass; the 8 verify tests FAIL with 404 (route missing).

- [ ] **Step 3: Exceptions.** Create `app/Exceptions/ClientLane/InvalidVerificationCodeException.php`:

```php
<?php

declare(strict_types=1);

namespace App\Exceptions\ClientLane;

use RuntimeException;

/**
 * A wrong code with tries left — `422 { code: "invalid_code", attempts_left }`
 * (KV approval requests Part D). The fifth miss is `code_expired` instead.
 */
final class InvalidVerificationCodeException extends RuntimeException
{
    public const CODE = 'invalid_code';

    public function __construct(public readonly int $attemptsLeft)
    {
        parent::__construct("That code didn't match.");
    }
}
```

Create `app/Exceptions/ClientLane/VerificationCodeExpiredException.php`:

```php
<?php

declare(strict_types=1);

namespace App\Exceptions\ClientLane;

use RuntimeException;

/**
 * No usable code for (address, link) — never sent, older than 10 minutes,
 * spent, replaced by a newer one, guessed to death, or an unknown link:
 * `422 { code: "code_expired" }` (KV approval requests Part D, ruling R-D3).
 */
final class VerificationCodeExpiredException extends RuntimeException
{
    public const CODE = 'code_expired';

    public function __construct()
    {
        parent::__construct('This code has expired. Ask for a new one.');
    }
}
```

- [ ] **Step 4: Shared lane helpers in `ClientLaneService`.** Add after `shareUrl()`:

```php
    /**
     * The address' active personal lane on the brand — what a magic link or
     * a code hands back instead of a guest lane when the agency named this
     * address (FR-18; KV approval requests Part D).
     */
    public function activePersonalLane(string $brandId, string $email): ?ClientLaneLink
    {
        return ClientLaneLink::query()
            ->where('brand_id', $brandId)
            ->where('kind', ClientLaneLink::KIND_PERSONAL)
            ->whereRaw('LOWER(email) = ?', [strtolower(trim($email))])
            ->active()
            ->first();
    }

    /**
     * What a proven mailbox gets (Part D, spec §7): the address' personal
     * lane on the brand, stamped verified — looked up NOW, so a lane rotated
     * since the code was sent is still found (R-D7) — else a fresh 30-day
     * verified-guest lane. Call inside the caller's transaction.
     */
    public function laneForProvenEmail(string $brandId, string $email, ?string $shareLinkId): ClientLaneLink
    {
        $personal = $this->activePersonalLane($brandId, $email);
        if ($personal !== null) {
            if ($personal->verified_at === null) {
                $personal->forceFill(['verified_at' => now()])->save();
            }

            return $personal;
        }

        return $this->mintVerifiedGuestLane($brandId, strtolower(trim($email)), $shareLinkId);
    }
```

Add as the last private method (before the closing brace of the class, after `newestDecisionLink()` is fine):

```php
    private function mintVerifiedGuestLane(string $brandId, string $email, ?string $shareLinkId): ClientLaneLink
    {
        $brand = Brand::query()->withoutGlobalScopes()->find($brandId);

        return ClientLaneLink::create([
            'workspace_id' => (string) $brand?->workspace_id,
            'brand_id' => $brandId,
            'user_id' => null,
            'email' => $email,
            'unique_code' => ShareLinkService::mintToken(),
            'status' => ClientLaneLink::STATUS_JOINED,
            'kind' => ClientLaneLink::KIND_VERIFIED_GUEST,
            'share_link_id' => $shareLinkId,
            'custom_permissions' => null,
            'credits' => 0,
            'invited_by_name' => 'frndOS',
            'invited_by_email' => '',
            'verified_at' => now(),
            'expires_at' => now()->addDays(self::VERIFIED_GUEST_DAYS),
        ]);
    }
```

In `requestMagicLink()`, replace

```php
        $personal = ClientLaneLink::query()
            ->where('brand_id', $brandId)
            ->where('kind', ClientLaneLink::KIND_PERSONAL)
            ->whereRaw('LOWER(email) = ?', [$email])
            ->active()
            ->first();
```

with

```php
        $personal = $this->activePersonalLane($brandId, $email);
```

In `verifyMagicLink()`, replace the block from `$brand = Brand::query()->withoutGlobalScopes()->find($locked->brand_id);` through the closing `]);` of its `ClientLaneLink::create([...])` with

```php
                return $this->mintVerifiedGuestLane((string) $locked->brand_id, (string) $locked->email, $locked->share_link_id);
```

(The magic link keeps its stored `lane_link_id` lookup — unchanged behaviour; only the duplicated create moved.)

- [ ] **Step 5: `verify()`.** Add to `ClientVerificationCodeService` (imports `use App\Exceptions\ClientLane\InvalidVerificationCodeException; use App\Exceptions\ClientLane\VerificationCodeExpiredException; use App\Models\ClientLaneLink;`), after `request()`:

```php
    /**
     * Spend a code (spec §7). The newest live code for (address, link) is
     * the only one checked.
     *
     * @throws InvalidVerificationCodeException a wrong code with 1..4 tries left
     * @throws VerificationCodeExpiredException no usable code (ruling R-D3)
     */
    public function verify(string $email, string $code, string $shareToken): ClientLaneLink
    {
        $email = strtolower(trim($email));

        $link = $this->approvalLink($shareToken);
        if ($link === null) {
            throw new VerificationCodeExpiredException;
        }

        // The outcome leaves the transaction as a VALUE: throwing inside it
        // would roll the attempts counter back and make the 5-try cap
        // infinite (Review Focus 2).
        [$outcome, $payload] = DB::transaction(function () use ($email, $code, $link): array {
            /** @var ClientVerificationCode|null $row */
            $row = ClientVerificationCode::query()
                ->where('email', $email)
                ->where('share_link_id', $link->id)
                ->live()
                ->orderByDesc('created_at')
                ->orderByDesc('id')
                ->lockForUpdate()
                ->first();

            if ($row === null) {
                return ['expired', null];
            }

            if (! hash_equals($row->code_hash, ClientVerificationCode::hashCode($code))) {
                $attempts = $row->attempts + 1;
                $row->forceFill(['attempts' => $attempts])->save();
                $left = ClientVerificationCode::MAX_ATTEMPTS - $attempts;

                return $left > 0 ? ['invalid', $left] : ['expired', null];
            }

            $row->forceFill(['used_at' => now()])->save();

            return ['lane', $this->lanes->laneForProvenEmail((string) $row->brand_id, $email, (string) $link->id)];
        });

        return match ($outcome) {
            'lane' => $payload,
            'invalid' => throw new InvalidVerificationCodeException((int) $payload),
            default => throw new VerificationCodeExpiredException,
        };
    }
```

- [ ] **Step 6: Controller `verifyCode`.** In `PublicLaneController` add imports `use App\Exceptions\ClientLane\InvalidVerificationCodeException; use App\Exceptions\ClientLane\VerificationCodeExpiredException;` and, after `requestCode()`:

```php
    /**
     * Spend a code (Part D). `200` hands back the lane the page posts to
     * `/s/session`; `422 invalid_code` (with `attempts_left`) or
     * `422 code_expired` otherwise. Never echoes the code.
     */
    public function verifyCode(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'email' => ['required', 'string', 'email', 'max:254'],
            'code' => ['required', 'string', 'regex:/^\d{6}$/'],
            'share_token' => ['required', 'string', 'max:64'],
        ]);

        try {
            $lane = $this->codes->verify($validated['email'], $validated['code'], $validated['share_token']);
        } catch (InvalidVerificationCodeException $e) {
            return response()
                ->json(['code' => InvalidVerificationCodeException::CODE, 'message' => $e->getMessage(), 'attempts_left' => $e->attemptsLeft], 422)
                ->header('Cache-Control', 'no-store');
        } catch (VerificationCodeExpiredException $e) {
            return response()
                ->json(['code' => VerificationCodeExpiredException::CODE, 'message' => $e->getMessage()], 422)
                ->header('Cache-Control', 'no-store');
        }

        return response()
            ->json(['data' => [
                'lane_code' => $lane->unique_code,
                'kind' => $lane->kind,
                'expires_at' => $lane->expires_at?->toISOString(),
            ]])
            ->header('Cache-Control', 'no-store');
    }
```

- [ ] **Step 7: Limiter + route.** In `AppServiceProvider`, after the `public-lane-code` limiter:

```php
        // Code guesses: 10/min per IP + 20/hour per address. Each code also
        // dies after 5 wrong tries and every new code ends the old one.
        RateLimiter::for('public-lane-code-verify', function (Request $request) use ($tooManyAttemptsResponse) {
            $email = strtolower(trim((string) $request->input('email', '')));

            return [
                Limit::perMinute(10)->by('plcv-ip|'.$request->ip())->response($tooManyAttemptsResponse),
                Limit::perHour(20)->by('plcv-email|'.sha1($email))->response($tooManyAttemptsResponse),
            ];
        });
```

In `routes/api.php`, after `->name('public.lane.code');`:

```php
Route::post('public/lane/code/verify', [PublicLaneController::class, 'verifyCode'])
    ->middleware('throttle:public-lane-code-verify')
    ->name('public.lane.code.verify');
```

- [ ] **Step 8: Run the whole file (test).** Command from Step 2.
Expected: 13 passed.

- [ ] **Step 9: Mutation checks (test).** One at a time, restore after each:
  1. Move the `throw` inside the transaction: replace `return $left > 0 ? ['invalid', $left] : ['expired', null];` with `throw $left > 0 ? new InvalidVerificationCodeException($left) : new VerificationCodeExpiredException;` → *"a wrong code counts down, and the fifth miss ends the code"* FAILS (`attempts_left` stays 4).
  2. In `laneForProvenEmail`, make `activePersonalLane` return `null` (`$personal = null;`) → *"an address with an active personal lane on the brand gets that lane back"* FAILS.
  3. Delete `$row->forceFill(['used_at' => now()])->save();` → *"a valid code is spent once …"* FAILS.
  4. Change `MAX_ATTEMPTS = 5` to `6` → the countdown test FAILS.
  5. Change the regex to `'regex:/^\d{4,6}$/'` → *"a code with leading zeros verifies as typed"* FAILS.

- [ ] **Step 10: Gates and commit.**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F=(app/Exceptions/ClientLane/InvalidVerificationCodeException.php app/Exceptions/ClientLane/VerificationCodeExpiredException.php app/Services/ClientLane/ClientLaneService.php app/Services/ClientLane/ClientVerificationCodeService.php app/Http/Controllers/Api/PublicLaneController.php app/Providers/AppServiceProvider.php routes/api.php tests/Feature/ClientLane/LaneVerificationCodeTest.php) && for f in "${F[@]}"; do php -l "$f" || exit 1; done && vendor/bin/pint "${F[@]}" && vendor/bin/pint --test "${F[@]}" && /usr/bin/grep -n "Log::" app/Services/ClientLane/ClientVerificationCodeService.php app/Http/Controllers/Api/PublicLaneController.php; /usr/bin/git add "${F[@]}" && /usr/bin/git commit -m "feat(api): verify a lane code — personal lane handed back, else a 30-day guest lane; five tries"
```
Expected: the `Log::` grep prints nothing.

---

### Task A4: The gate on request decisions + pins placed before verifying

**Files:**
- Modify: `app/Http/Controllers/Api/PublicShareLinkController.php` (`show()` ~line 132, `decideOnRequest()` ~line 275)
- Modify: `app/Services/Approval/ApprovalService.php` (`ownPinsOn()` ~lines 413–451)
- Test: `tests/Feature/ClientLane/RequestDecisionVerificationGateTest.php`

**Interfaces:**
- Consumes: `ClientLaneFixtures::requestLink()`, `ClientLaneLink::factory()->verifiedGuest()` / `->create()`, `VerificationRequiredException::CODE` (`verification_required`).
- Produces: C-3 `403 verification_required` on approval links without an honoured lane; C-1 `access.verification_required = ($lane === null)` on approval links; `ownPinsOn` lane-email ownership (R-D9).

- [ ] **Step 1: Write the failing tests (test).** Create `tests/Feature/ClientLane/RequestDecisionVerificationGateTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Jobs\SendApprovalRequestDigest;
use App\Models\Approval;
use App\Models\ApprovalDecision;
use App\Models\ClientLaneLink;
use App\Models\ShareLink;
use App\Models\User;
use App\Services\Sharing\ShareLinkService;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);

    $this->kv = ClientLaneFixtures::kvFile();
    $sent = ClientLaneFixtures::requestLink($this->kv);
    $this->request = $sent['request'];
    $this->approval = $sent['approval'];
    $this->link = $sent['link'];
    $this->token = $sent['link']->token;

    $this->decide = fn (array $body, array $headers = []) => $this->postJson("/api/public/share-links/{$this->token}/decision", $body, $headers);
    $this->guestLane = fn (array $attrs = []) => ClientLaneLink::factory()->verifiedGuest()->create([
        'workspace_id' => $this->kv['workspace']->id,
        'brand_id' => $this->kv['brand']->id,
        'email' => 'dina@brand.test',
        'share_link_id' => $this->link->id,
        ...$attrs,
    ]);
    $this->asGuest = ['guest_name' => 'Dina', 'guest_email' => 'dina@brand.test'];
});

test('an anonymous decision on a request link asks for a code and records nothing', function () {
    ($this->decide)(['approval_ids' => [$this->approval->id], 'outcome' => 'approved'])
        ->assertStatus(422)->assertJsonPath('code', 'guest_required');

    ($this->decide)(['approval_ids' => [$this->approval->id], 'outcome' => 'approved', ...$this->asGuest])
        ->assertStatus(403)->assertJsonPath('code', 'verification_required');
    ($this->decide)(['outcome' => 'deferred', 'deferred_until' => now()->addDays(3)->toDateString(), ...$this->asGuest])
        ->assertStatus(403)->assertJsonPath('code', 'verification_required');

    expect(ApprovalDecision::query()->count())->toBe(0)
        ->and($this->approval->fresh()->status)->toBe(Approval::STATUS_PENDING)
        ->and($this->request->fresh()->deferred_until)->toBeNull();
    Bus::assertNotDispatched(SendApprovalRequestDigest::class);
});

test('the resolver asks for a code until a lane is honoured', function () {
    $this->getJson("/api/public/share-links/{$this->token}")
        ->assertOk()->assertJsonPath('data.access.verification_required', true);

    $lane = ($this->guestLane)();
    $this->getJson("/api/public/share-links/{$this->token}", ['X-Lane-Code' => $lane->unique_code])
        ->assertOk()
        ->assertJsonPath('data.access.verification_required', false)
        ->assertJsonPath('data.viewer.kind', 'verified');
});

test('a verified-guest lane decides in one tap', function () {
    $lane = ($this->guestLane)();

    ($this->decide)(['approval_ids' => [$this->approval->id], 'outcome' => 'approved'], ['X-Lane-Code' => $lane->unique_code])
        ->assertCreated()
        ->assertJsonPath('data.results.0.result', 'decided')
        ->assertJsonPath('data.results.0.decision.outcome', 'approved')
        ->assertJsonPath('data.results.0.decision.advisory', false);
});

test('a named approver on their personal lane never needs a code', function () {
    $client = User::factory()->create(['email' => 'dina@brand.test']);
    $lane = ClientLaneLink::factory()->create([
        'workspace_id' => $this->kv['workspace']->id,
        'brand_id' => $this->kv['brand']->id,
        'user_id' => $client->id,
        'email' => 'dina@brand.test',
    ]);

    ($this->decide)(['approval_ids' => [$this->approval->id], 'outcome' => 'approved'], ['X-Lane-Code' => $lane->unique_code])
        ->assertCreated()->assertJsonPath('data.results.0.result', 'decided');
});

test('an expired lane or another brand\'s lane asks for a code again', function () {
    $other = ClientLaneFixtures::kvFile();
    $foreign = ClientLaneLink::factory()->verifiedGuest()->create([
        'workspace_id' => $other['workspace']->id,
        'brand_id' => $other['brand']->id,
        'email' => 'dina@brand.test',
    ]);
    $expired = ($this->guestLane)(['expires_at' => now()->subMinute()]);

    foreach ([$foreign, $expired] as $lane) {
        ($this->decide)(
            ['approval_ids' => [$this->approval->id], 'outcome' => 'approved', ...$this->asGuest],
            ['X-Lane-Code' => $lane->unique_code],
        )->assertStatus(403)->assertJsonPath('code', 'verification_required');
    }
    expect(ApprovalDecision::query()->count())->toBe(0);
});

test('pins placed before verifying ride on the verified decision', function () {
    $v = (string) $this->approval->subject_version_id;
    $pin = $this->postJson("/api/public/share-links/{$this->token}/comments", [
        'body' => 'Logo smaller',
        'anchor' => ['kind' => 'pin', 'id' => "craft:{$v}:board.{$v}", 'x' => 0.4, 'y' => 0.6],
        'guest_name' => 'Dina',
        'guest_email' => 'Dina@Brand.test',
    ])->assertCreated()->json('data.id');

    $lane = ($this->guestLane)();
    ($this->decide)(['approval_ids' => [$this->approval->id], 'outcome' => 'approved', 'pins' => [$pin]], ['X-Lane-Code' => $lane->unique_code])
        ->assertCreated()
        ->assertJsonPath('data.results.0.decision.outcome', 'approved_with_changes')
        ->assertJsonPath('data.results.0.decision.pins', [$pin]);
});

test('a pin typed under another address does not ride, and nothing is recorded', function () {
    $v = (string) $this->approval->subject_version_id;
    $pin = $this->postJson("/api/public/share-links/{$this->token}/comments", [
        'body' => 'Logo smaller',
        'anchor' => ['kind' => 'pin', 'id' => "craft:{$v}:board.{$v}", 'x' => 0.4, 'y' => 0.6],
        'guest_name' => 'Bayu',
        'guest_email' => 'bayu@brand.test',
    ])->assertCreated()->json('data.id');

    $lane = ($this->guestLane)();
    ($this->decide)(['approval_ids' => [$this->approval->id], 'outcome' => 'approved', 'pins' => [$pin]], ['X-Lane-Code' => $lane->unique_code])
        ->assertStatus(422)->assertJsonValidationErrors('pins');
    expect(ApprovalDecision::query()->count())->toBe(0);
});

test('a verified guest stays advisory on a request that waits on named approvers', function () {
    $named = User::factory()->create();
    $approvers = [['user_id' => (string) $named->id, 'lane_link_id' => null, 'email' => $named->email, 'name' => $named->name]];
    $this->request->forceFill(['policy' => Approval::POLICY_REQUIRED, 'approvers' => $approvers])->save();
    $this->approval->forceFill(['policy' => Approval::POLICY_REQUIRED, 'approvers' => $approvers])->save();

    $lane = ($this->guestLane)();
    ($this->decide)(['approval_ids' => [$this->approval->id], 'outcome' => 'approved'], ['X-Lane-Code' => $lane->unique_code])
        ->assertCreated()->assertJsonPath('data.results.0.decision.advisory', true);
    expect($this->approval->fresh()->status)->toBe(Approval::STATUS_PENDING);
});

test('a link that is not a request link is not gated', function () {
    $view = app(ShareLinkService::class)->create($this->kv['file'], $this->kv['user'], ['craft'], role: ShareLink::ROLE_COMMENT);

    // No round behind a share-purpose comment link: P0a's 409, never Part D's 403.
    $this->postJson("/api/public/share-links/{$view->token}/decision", ['outcome' => 'approved', ...$this->asGuest])
        ->assertStatus(409)->assertJsonPath('code', 'round_closed');
});
```

- [ ] **Step 2: Run to see it fail (test).**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/ClientLane/RequestDecisionVerificationGateTest.php --compact`
Expected: FAIL — the 403 tests get `201`, the resolver test gets `false`, the pins test gets `422`. The one-tap, personal-lane, advisory and not-gated tests may already pass (they pin current behaviour). If the comments POST or a decision fails with a Part A error, stop and report.

- [ ] **Step 3: The gate.** In `PublicShareLinkController::decideOnRequest()`, replace

```php
        $actor = $this->actor($lane, $validated);
        if ($actor === null) {
            return $this->error(422, 'guest_required', 'Tell us your name and email first.');
        }

        try {
            $result = $this->requestDecisions->decide($approvalRequest, $actor, $validated, $request->ip());
```

with

```php
        $actor = $this->actor($lane, $validated);
        if ($actor === null) {
            return $this->error(422, 'guest_required', 'Tell us your name and email first.');
        }

        // Part D (spec §7, ruling R-D1): every decision on a KV request link
        // — deferral included — needs an honoured lane: a code once per
        // device, or a named approver's personal link. Checked after the
        // name gate so its email prefills the code sheet, and before
        // anything is recorded. Looking, pins and comments never need one.
        if ($lane === null) {
            return $this->error(403, VerificationRequiredException::CODE, 'Confirm your email with a code before your decision counts.');
        }

        try {
            $result = $this->requestDecisions->decide($approvalRequest, $actor, $validated, $request->ip());
```

In `show()`, replace

```php
                    // Part D adds the verification gate; until then KV never asks.
                    'verification_required' => false,
```

with

```php
                    // Part D: a decision here needs an honoured lane.
                    'verification_required' => $lane === null,
```

- [ ] **Step 4: Pins placed before verifying (R-D9).** In `ApprovalService::ownPinsOn()`, add before `$versionId = (string) $approval->subject_version_id;`:

```php
        // A lane proves its mailbox, so it also owns the anonymous guest
        // pins typed under that same address — the pins a client placed
        // before verifying with a code (Part D, ruling R-D9). Without this
        // the resubmitted decision fails `422 pins` on its most common path.
        $laneEmail = $actor->lane !== null ? (strtolower(trim((string) $actor->lane->email)) ?: null) : null;
```

and replace

```php
            $mine = match (true) {
                $actor->isUser() => (string) $comment->author_id === (string) $actor->user->id,
                $actor->lane !== null => $comment->lane_link_id !== null && (int) $comment->lane_link_id === (int) $actor->lane->id,
                default => $comment->author_id === null && $comment->lane_link_id === null
                    && strtolower((string) $comment->guest_email) === (string) $actor->guestEmail,
            };
```

with

```php
            $guestPin = $comment->author_id === null && $comment->lane_link_id === null;
            $guestPinOfLane = $guestPin && $laneEmail !== null
                && strtolower((string) $comment->guest_email) === $laneEmail;
            $mine = match (true) {
                $actor->isUser() => (string) $comment->author_id === (string) $actor->user->id || $guestPinOfLane,
                $actor->lane !== null => ($comment->lane_link_id !== null && (int) $comment->lane_link_id === (int) $actor->lane->id)
                    || $guestPinOfLane,
                default => $guestPin && strtolower((string) $comment->guest_email) === (string) $actor->guestEmail,
            };
```

Update the method's docblock with one line: "A lane actor also owns guest pins typed under the lane's address (Part D, R-D9)."

- [ ] **Step 5: Run green (test).** Command from Step 2.
Expected: 9 passed. Then re-run `tests/Feature/ClientLane/LaneVerificationCodeTest.php` (13 passed) and the Part A characterisation file `tests/Feature/Approval/KvSharePayloadItemsForTest.php` (still green).

- [ ] **Step 6: Mutation checks (test).** One at a time, restore after each:
  1. Delete the `if ($lane === null) { … }` gate → *"an anonymous decision on a request link asks for a code and records nothing"* FAILS.
  2. Move the gate above the `$actor === null` check → the same test FAILS on its first `guest_required` assertion.
  3. Revert `'verification_required' => $lane === null` to `false` → *"the resolver asks for a code until a lane is honoured"* FAILS.
  4. Replace `|| $guestPinOfLane` in the `$actor->lane !== null` arm with nothing → *"pins placed before verifying ride on the verified decision"* FAILS.
  5. Drop the `strtolower(...) === $laneEmail` comparison (`$guestPinOfLane = $guestPin && $laneEmail !== null;`) → *"a pin typed under another address does not ride …"* FAILS.

- [ ] **Step 7: Gates and commit.**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F=(app/Http/Controllers/Api/PublicShareLinkController.php app/Services/Approval/ApprovalService.php tests/Feature/ClientLane/RequestDecisionVerificationGateTest.php) && for f in "${F[@]}"; do php -l "$f" || exit 1; done && vendor/bin/pint "${F[@]}" && vendor/bin/pint --test "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -m "feat(api): KV request decisions need an honoured lane (403 verification_required); pins placed before verifying still count"
```

---

### Task A5: api wrap-up — track file, dev DB

**Files:**
- Modify: `docs/tracks/client-lane-multi-item.track.md`

**Interfaces:**
- Consumes: everything above.
- Produces: an audit trail; a migrated dev DB (only with Daffa's yes).

- [ ] **Step 1: Final named runs (test).** Run each file once more, one process each: `tests/Feature/ClientLane/LaneVerificationCodeTest.php`, `tests/Feature/ClientLane/RequestDecisionVerificationGateTest.php`. Expected: 13 + 9 passed. Record the counts.

- [ ] **Step 2: Route check.**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && php artisan route:list --path=public/lane`
Expected: `public.lane.magic-link`, `public.lane.verify`, `public.lane.code`, `public.lane.code.verify`.

- [ ] **Step 3: Track file.** Append to `docs/tracks/client-lane-multi-item.track.md` a `## Part D — verification code once per device` section with the checklist (A1–A4 checked, A5 dev DB open until Step 5), and a session-log entry `### 2026-10-0X — daffa (plan executor) — Part D (api)` listing: the plan path; the Jeff answer from A0; the test-permission answer (or "FAST MODE: no tests written or run"); test counts; mutation results; rulings R-D1…R-D9 that touch the api; "NOT done: dev DB (unless Step 5 ran), PR (awaits Jeff)".

- [ ] **Step 4: Commit.**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && /usr/bin/git add docs/tracks/client-lane-multi-item.track.md && /usr/bin/git commit -m "docs(api): track KV approval requests Part D"
```

- [ ] **Step 5: Dev DB — ask first.** AskUserQuestion: "Migrate the dev DB `frnd` now? This runs every pending migration, including Part A's three `2026_10_01_10*` (its TASK-16 is still open) and Part D's `2026_10_01_100300_create_client_verification_codes_table`, with `TELESCOPE_ENABLED=false`." Only on "Yes":

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && php artisan migrate:status | tail -8 && TELESCOPE_ENABLED=false php artisan migrate --force && php artisan migrate:status | /usr/bin/grep -E "2026_10_01_10"`
Expected: all four `2026_10_01_10*` rows `Ran`. If Part A's TASK-16 rollback of `2026_09_30_120*` is still needed (they show `Ran`), STOP and hand it back to Daffa — that is Part A's step, not this plan's. Note the result in the track file (amend nothing; add a new log line and commit `docs(api): …`).

---

# WEB

### Task W0: Pre-flight — baseline and skills

**Files:** none changed.

**Interfaces:**
- Consumes: nothing.
- Produces: measured tsc baseline; skills read.

- [ ] **Step 1: State.**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git branch --show-current && /usr/bin/git status --short | head -20 && ls node_modules/@base-ui/react/otp-field/index.d.ts .env.local`
Expected: `feature/daffa/vc-client-lane-multi-item`; no unexpected changes; both files exist (else `bun install` / copy `.env.local` from `web/` and tell Daffa).

- [ ] **Step 2: tsc baseline.**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"`
Expected: `895`. If different, record the new number as the baseline in the track file and use it below.

- [ ] **Step 3: Read the UI and analytics skills.** Read `.agents/skills/frndos-ui/SKILL.md`, `.agents/skills/frndos-components-v2/SKILL.md` (Visual Consistency + "Membuat Komponen v2 Baru"), `.agents/skills/frndos-design-foundations/SKILL.md` (§Appearance), `.agents/skills/frndos-analytics-events/SKILL.md`.

---

### Task W1: Contract, public client, analytics, `laneCode.ts`

**Files:**
- Modify: `docs/prd/client-lane-p0a/web.md`
- Modify: `src/lib/client-lane/types.ts` (`PublicErrorCode` ~line 311; new `LaneCodeVerified`)
- Modify: `src/lib/client-lane/publicApi.ts`
- Modify: `src/lib/analytics/client-lane-events.ts` (end of file)
- Create: `src/lib/client-lane/laneCode.ts`
- Test: `src/lib/client-lane/laneCode.test.ts`

**Interfaces:**
- Consumes: the A1 contract; `axiosPublic`; `failureReason`.
- Produces:
  - `interface LaneCodeVerified { lane_code: string; kind: "personal" | "verified_guest"; expires_at: string | null }` (types.ts)
  - `requestLaneCode(email: string, shareToken: string): Promise<void>`; `verifyLaneCode(email: string, code: string, shareToken: string): Promise<LaneCodeVerified>`; `PublicApiError.attemptsLeft: number | null`
  - `trackClientCodeRequested({ resend })`, `trackClientCodeVerified({ lane_kind })`, `trackClientCodeFailed({ stage, reason, http_status, attempts_left })`
  - `laneCode.ts`: `type SendCodeResult = { ok: true } | { ok: false; reason: "throttled" | "failed" }`; `type CodeVerifyOutcome = { ok: true; lane: LaneCodeVerified } | { ok: false; reason: "invalid_code"; attemptsLeft: number } | { ok: false; reason: "code_expired" | "throttled" | "failed" }`; `sendLaneCode(token, email, resend): Promise<SendCodeResult>`; `confirmLaneCode(token, email, code): Promise<CodeVerifyOutcome>`; `persistLaneCookie(lane): Promise<boolean>`; `verifiedSummary(kind: ViewerKind, name: string | null, justVerified: boolean): string | null`

- [ ] **Step 1: Copy the contract block byte-identical.**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic && python3 - <<'PY'
from pathlib import Path
api = Path("api/.worktrees/client-lane-multi-item/docs/prd/client-lane-p0a/api.md").read_text()
start = api.index("### Additive notes (KV approval requests Part D")
end = api.index("\n## Scope\n", start)
block = api[start:end].rstrip("\n")
p = Path("web/.worktrees/client-lane-multi-item/docs/prd/client-lane-p0a/web.md")
s = p.read_text()
marker = "\n## Scope\n"
assert s.count(marker) == 1 and "KV approval requests Part D" not in s
p.write_text(s.replace(marker, "\n" + block + "\n\n## Scope\n", 1))
PY
diff <(awk '/^### Additive notes \(KV approval requests Part D/{f=1} /^## Scope/{f=0} f' api/.worktrees/client-lane-multi-item/docs/prd/client-lane-p0a/api.md) <(awk '/^### Additive notes \(KV approval requests Part D/{f=1} /^## Scope/{f=0} f' web/.worktrees/client-lane-multi-item/docs/prd/client-lane-p0a/web.md) && echo IDENTICAL
```
Expected: `IDENTICAL`.

- [ ] **Step 2: Types.** In `src/lib/client-lane/types.ts`, extend `PublicErrorCode`:

```ts
export type PublicErrorCode =
  | "verification_required"
  | "round_closed"
  | "read_only_link"
  | "guest_required"
  | "magic_link_expired"
  | "note_required"
  | "invalid_code"
  | "code_expired";
```

and append:

```ts
/**
 * `POST public/lane/code/verify` → 200 (KV approval requests Part D). The
 * lane the page cookies via `POST /s/session` and sends as `X-Lane-Code`;
 * `expires_at` is null for a named approver's personal lane.
 */
export interface LaneCodeVerified {
  lane_code: string;
  kind: "personal" | "verified_guest";
  expires_at: string | null;
}
```

- [ ] **Step 3: Public client.** In `src/lib/client-lane/publicApi.ts` add `LaneCodeVerified` to the type import list, add after `requestMagicLink`:

```ts
/** Always 202 — the api never says whether the address or link is real (Part D). */
export async function requestLaneCode(
  email: string,
  shareToken: string
): Promise<void> {
  await axiosPublic.post("public/lane/code", {
    email,
    share_token: shareToken,
  });
}

/** Spends the code; `422 invalid_code` (with `attempts_left`) or `code_expired` otherwise. */
export async function verifyLaneCode(
  email: string,
  code: string,
  shareToken: string
): Promise<LaneCodeVerified> {
  const res = await axiosPublic.post<{ data: LaneCodeVerified }>(
    "public/lane/code/verify",
    { email, code, share_token: shareToken }
  );
  return res.data.data;
}
```

and replace `PublicApiError` / `publicApiError` with:

```ts
/** The `{code, message}` body the public endpoints answer errors with. */
export interface PublicApiError {
  status: number | null;
  code: PublicErrorCode | string | null;
  message: string | null;
  /** `invalid_code` only (Part D): tries left on this code, 1..4. */
  attemptsLeft: number | null;
}

/** Normalise an axios rejection into the coded error the page branches on. */
export function publicApiError(error: unknown): PublicApiError {
  const axiosError = error as AxiosError<{
    code?: string;
    message?: string;
    attempts_left?: number;
  }>;
  const response = axiosError?.response;
  const attemptsLeft = response?.data?.attempts_left;
  return {
    status: response?.status ?? null,
    code: response?.data?.code ?? null,
    message: response?.data?.message ?? null,
    attemptsLeft: typeof attemptsLeft === "number" ? attemptsLeft : null,
  };
}
```

- [ ] **Step 4: Analytics helpers.** Append to `src/lib/analytics/client-lane-events.ts`:

```ts
/* ── Part D: verification code (spec 2026-10-01 §7) ──────────────────── */

/** Which half of the code flow a failure belongs to. */
export type LaneCodeStage = "request" | "verify";

/** `POST public/lane/code` answered 202 — as the sheet opened, or "Resend". */
export const trackClientCodeRequested = (props: { resend: boolean }) =>
  safeCapture("client_lane.code_requested", props);

/**
 * The code was accepted. `lane_kind: "personal"` = a named approver got their
 * own lane back; `"verified_guest"` = a new 30-day device lane.
 */
export const trackClientCodeVerified = (props: {
  lane_kind: "personal" | "verified_guest";
}) => safeCapture("client_lane.code_verified", props);

/**
 * `reason` = the api code (`invalid_code`, `code_expired`), `throttled` for a
 * 429, else `failureReason()`. `attempts_left` only for `invalid_code`.
 */
export const trackClientCodeFailed = (props: {
  stage: LaneCodeStage;
  reason: string;
  http_status: number | null;
  attempts_left: number | null;
}) => safeCapture("client_lane.code_failed", props);
```

- [ ] **Step 5: Write the failing `laneCode` tests (test).** Create `src/lib/client-lane/laneCode.test.ts`:

```ts
import posthog from "posthog-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { axiosPublic } from "@/services/axios";

import { confirmLaneCode, sendLaneCode, verifiedSummary } from "./laneCode";
import type { LaneCodeVerified } from "./types";

const LANE: LaneCodeVerified = {
  lane_code: "abcdefghijklmnop",
  kind: "verified_guest",
  expires_at: "2026-10-31T09:00:00.000Z",
};

function axiosError(status: number, data: Record<string, unknown> = {}) {
  return Object.assign(new Error(`HTTP ${status}`), {
    isAxiosError: true,
    response: { status, data },
  });
}

type Calls<T extends unknown[]> = { mock: { calls: T[] } };
let capture: unknown;
const captured = (event: string) =>
  (capture as Calls<[string, Record<string, unknown>]>).mock.calls
    .filter(([e]) => e === event)
    .map(([, props]) => props);

beforeEach(() => {
  capture = vi
    .spyOn(posthog, "capture")
    .mockImplementation(() => undefined as never);
});
afterEach(() => {
  vi.restoreAllMocks();
});

describe("sendLaneCode", () => {
  it("asks for a code for this link and records the request", async () => {
    const post = vi
      .spyOn(axiosPublic, "post")
      .mockResolvedValue({ status: 202, data: {} } as never);
    await expect(sendLaneCode("tok", "dina@brand.test", false)).resolves.toEqual({ ok: true });
    expect(post).toHaveBeenCalledWith("public/lane/code", {
      email: "dina@brand.test",
      share_token: "tok",
    });
    expect(captured("client_lane.code_requested")).toEqual([
      expect.objectContaining({ resend: false }),
    ]);
  });

  it("calls a 429 throttled, in the result and in the failure event", async () => {
    vi.spyOn(axiosPublic, "post").mockRejectedValue(axiosError(429, { message: "Too many attempts." }));
    await expect(sendLaneCode("tok", "dina@brand.test", true)).resolves.toEqual({
      ok: false,
      reason: "throttled",
    });
    expect(captured("client_lane.code_failed")).toEqual([
      expect.objectContaining({ stage: "request", reason: "throttled", http_status: 429, attempts_left: null }),
    ]);
  });
});

describe("confirmLaneCode", () => {
  it("spends the code, cookies the lane with its expiry, and records the lane kind", async () => {
    const post = vi
      .spyOn(axiosPublic, "post")
      .mockResolvedValue({ data: { data: LANE } } as never);
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response(null, { status: 204 }));

    await expect(confirmLaneCode("tok", "dina@brand.test", "482913")).resolves.toEqual({ ok: true, lane: LANE });
    expect(post).toHaveBeenCalledWith("public/lane/code/verify", {
      email: "dina@brand.test",
      code: "482913",
      share_token: "tok",
    });
    const [url, init] = (fetchSpy as unknown as Calls<[string, RequestInit]>).mock.calls[0];
    expect(url).toBe("/s/session");
    expect(init.method).toBe("POST");
    expect(JSON.parse(String(init.body))).toEqual({ code: LANE.lane_code, expires_at: LANE.expires_at });
    expect(captured("client_lane.code_verified")).toEqual([
      expect.objectContaining({ lane_kind: "verified_guest" }),
    ]);
  });

  it("still succeeds when the cookie cannot be written — the lane rides in memory", async () => {
    vi.spyOn(axiosPublic, "post").mockResolvedValue({ data: { data: LANE } } as never);
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("offline"));
    await expect(confirmLaneCode("tok", "dina@brand.test", "482913")).resolves.toEqual({ ok: true, lane: LANE });
  });

  it("returns the tries left on a wrong code and writes no cookie", async () => {
    vi.spyOn(axiosPublic, "post").mockRejectedValue(
      axiosError(422, { code: "invalid_code", message: "That code didn't match.", attempts_left: 3 })
    );
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    await expect(confirmLaneCode("tok", "dina@brand.test", "111111")).resolves.toEqual({
      ok: false,
      reason: "invalid_code",
      attemptsLeft: 3,
    });
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(captured("client_lane.code_failed")).toEqual([
      expect.objectContaining({ stage: "verify", reason: "invalid_code", http_status: 422, attempts_left: 3 }),
    ]);
  });

  it("reports an expired code", async () => {
    vi.spyOn(axiosPublic, "post").mockRejectedValue(axiosError(422, { code: "code_expired", message: "…" }));
    await expect(confirmLaneCode("tok", "dina@brand.test", "111111")).resolves.toEqual({
      ok: false,
      reason: "code_expired",
    });
  });
});

describe("verifiedSummary", () => {
  it("names the device and the 30 days right after verifying", () => {
    expect(verifiedSummary("verified", "Dina", true)).toBe("Verified as Dina · this device, 30 days");
  });
  it("drops the 30 days on a later visit", () => {
    expect(verifiedSummary("verified", "Dina", false)).toBe("Verified as Dina · this device");
  });
  it("says nothing for anonymous viewers, named approvers, or no name", () => {
    expect(verifiedSummary("anonymous", "Dina", true)).toBeNull();
    expect(verifiedSummary("client", "Dina", true)).toBeNull();
    expect(verifiedSummary("verified", null, true)).toBeNull();
  });
});
```

- [ ] **Step 6: Run to see it fail (test).**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/laneCode.test.ts`
Expected: FAIL — cannot resolve `./laneCode`.

- [ ] **Step 7: Implement `laneCode.ts`.** Create `src/lib/client-lane/laneCode.ts`:

```ts
/**
 * The code half of the identity ladder on a KV request link (spec
 * 2026-10-01 §7, Part D): ask for a code, spend it, cookie the lane, and
 * say who this device decides as. No React — `CodeSheet` and `DecisionPage`
 * call these.
 */
import {
  failureReason,
  trackClientCodeFailed,
  trackClientCodeRequested,
  trackClientCodeVerified,
} from "@/lib/analytics/client-lane-events";

import { publicApiError, requestLaneCode, verifyLaneCode } from "./publicApi";
import type { LaneCodeVerified, ViewerKind } from "./types";

export type SendCodeResult =
  | { ok: true }
  | { ok: false; reason: "throttled" | "failed" };

export type CodeVerifyOutcome =
  | { ok: true; lane: LaneCodeVerified }
  | { ok: false; reason: "invalid_code"; attemptsLeft: number }
  | { ok: false; reason: "code_expired" | "throttled" | "failed" };

function reasonOf(err: { code: string | null; status: number | null }): string {
  return err.status === 429 ? "throttled" : failureReason(err);
}

export async function sendLaneCode(
  token: string,
  email: string,
  resend: boolean
): Promise<SendCodeResult> {
  try {
    await requestLaneCode(email, token);
    trackClientCodeRequested({ resend });
    return { ok: true };
  } catch (e) {
    const err = publicApiError(e);
    trackClientCodeFailed({
      stage: "request",
      reason: reasonOf(err),
      http_status: err.status,
      attempts_left: null,
    });
    return { ok: false, reason: err.status === 429 ? "throttled" : "failed" };
  }
}

/**
 * Cookie the lane for this device (`POST /s/session`, C-2 + Part D's
 * `expires_at`). A failure is not fatal (ruling R-D15): the caller already
 * holds the code in memory for this visit.
 */
export async function persistLaneCookie(lane: LaneCodeVerified): Promise<boolean> {
  try {
    const res = await fetch("/s/session", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: lane.lane_code, expires_at: lane.expires_at }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

export async function confirmLaneCode(
  token: string,
  email: string,
  code: string
): Promise<CodeVerifyOutcome> {
  let lane: LaneCodeVerified;
  try {
    lane = await verifyLaneCode(email, code, token);
  } catch (e) {
    const err = publicApiError(e);
    trackClientCodeFailed({
      stage: "verify",
      reason: reasonOf(err),
      http_status: err.status,
      attempts_left: err.attemptsLeft,
    });
    if (err.code === "invalid_code") {
      return { ok: false, reason: "invalid_code", attemptsLeft: err.attemptsLeft ?? 0 };
    }
    if (err.code === "code_expired") return { ok: false, reason: "code_expired" };
    return { ok: false, reason: err.status === 429 ? "throttled" : "failed" };
  }
  await persistLaneCookie(lane);
  trackClientCodeVerified({ lane_kind: lane.kind });
  return { ok: true, lane };
}

/** Ruling R-D13: who this device decides as, for a verified-guest viewer only. */
export function verifiedSummary(
  kind: ViewerKind,
  name: string | null,
  justVerified: boolean
): string | null {
  if (kind !== "verified" || !name) return null;
  return justVerified
    ? `Verified as ${name} · this device, 30 days`
    : `Verified as ${name} · this device`;
}
```

- [ ] **Step 8: Run green (test).** Command from Step 6. Expected: 9 pass.

- [ ] **Step 9: Mutation checks (test).** One at a time, restore after each:
  1. In `confirmLaneCode`, drop `expires_at: lane.expires_at` from the cookie body (in `persistLaneCookie`) → *"spends the code, cookies the lane with its expiry…"* FAILS.
  2. Make `persistLaneCookie` rethrow (`catch (e) { throw e; }`) → *"still succeeds when the cookie cannot be written…"* FAILS.
  3. Return `"Verified as … · this device, 30 days"` regardless of `justVerified` → *"drops the 30 days on a later visit"* FAILS.

- [ ] **Step 10: Gates and commit.**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/lib/client-lane/types.ts src/lib/client-lane/publicApi.ts src/lib/analytics/client-lane-events.ts src/lib/client-lane/laneCode.ts src/lib/client-lane/laneCode.test.ts) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "src/lib/client-lane/(types|publicApi|laneCode)|client-lane-events"; /usr/bin/git add "${F[@]}" docs/prd/client-lane-p0a/web.md && /usr/bin/git commit -m "$(printf 'feat(web): lane code client — request, verify, cookie the lane, Part D contract notes\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```
Expected: the tsc grep prints nothing.

---

### Task W2: `POST /s/session` takes the lane's expiry

**Files:**
- Modify: `src/lib/client-lane/cookie.ts`
- Modify: `src/app/s/session/route.ts` (`POST`, lines ~42–83)
- Test: `src/lib/client-lane/cookie.test.ts`

**Interfaces:**
- Consumes: `laneCookie`, `laneMaxAge`, `isLaneCode`, `LANE_COOKIE_MAX_AGE_DEFAULT` (existing).
- Produces: `sessionCookieFromBody(body: unknown): LaneCookieOptions | null`; `POST /s/session { code, expires_at? }` → 204 with `Max-Age` to `expires_at`, 400 for a bad code or a past / non-date `expires_at`.

- [ ] **Step 1: Write the failing tests (test).** Create `src/lib/client-lane/cookie.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { LANE_COOKIE_MAX_AGE_DEFAULT, sessionCookieFromBody } from "./cookie";

const CODE = "abcdefghijklmnop";

describe("sessionCookieFromBody", () => {
  it("keeps the 400-day default when no expiry is sent", () => {
    expect(sessionCookieFromBody({ code: CODE })?.maxAge).toBe(LANE_COOKIE_MAX_AGE_DEFAULT);
    expect(sessionCookieFromBody({ code: CODE, expires_at: null })?.maxAge).toBe(LANE_COOKIE_MAX_AGE_DEFAULT);
  });

  it("runs the cookie to the lane's expiry", () => {
    const in30Days = new Date(Date.now() + 30 * 86_400_000).toISOString();
    const maxAge = sessionCookieFromBody({ code: CODE, expires_at: in30Days })?.maxAge ?? 0;
    expect(maxAge).toBeGreaterThan(30 * 86_400 - 5);
    expect(maxAge).toBeLessThanOrEqual(30 * 86_400);
  });

  it("refuses a bad code, a past expiry and a non-date", () => {
    expect(sessionCookieFromBody({ code: "short" })).toBeNull();
    expect(sessionCookieFromBody({ code: CODE, expires_at: "2020-01-01T00:00:00Z" })).toBeNull();
    expect(sessionCookieFromBody({ code: CODE, expires_at: "soon" })).toBeNull();
    expect(sessionCookieFromBody({ code: CODE, expires_at: 123 })).toBeNull();
    expect(sessionCookieFromBody(null)).toBeNull();
  });

  it("keeps the cookie HttpOnly, Lax and scoped to /s", () => {
    expect(sessionCookieFromBody({ code: CODE })).toMatchObject({
      name: "frnd_lane",
      value: CODE,
      httpOnly: true,
      sameSite: "lax",
      path: "/s",
    });
  });
});
```

- [ ] **Step 2: Run to see it fail (test).**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/cookie.test.ts`
Expected: FAIL — `sessionCookieFromBody` is not exported.

- [ ] **Step 3: Implement.** Append to `src/lib/client-lane/cookie.ts`:

```ts
/**
 * The cookie `POST /s/session` sets from its JSON body (C-2 + Part D):
 * `{ code, expires_at? }`. `expires_at` (the lane's own expiry, from the
 * code verify) bounds `Max-Age`; absent or null keeps the 400-day default.
 * Null — the route answers 400 — for a bad code or a past / non-date expiry.
 */
export function sessionCookieFromBody(body: unknown): LaneCookieOptions | null {
  if (!body || typeof body !== "object") return null;
  const { code, expires_at: expiresAt } = body as {
    code?: unknown;
    expires_at?: unknown;
  };
  if (!isLaneCode(code)) return null;
  if (expiresAt === undefined || expiresAt === null) {
    return laneCookie(code, LANE_COOKIE_MAX_AGE_DEFAULT);
  }
  if (typeof expiresAt !== "string") return null;
  const maxAge = laneMaxAge(expiresAt);
  return maxAge > 0 ? laneCookie(code, maxAge) : null;
}
```

In `src/app/s/session/route.ts`, change the import list to

```ts
import {
  LANE_COOKIE,
  isLaneCode,
  laneCookie,
  sessionCookieFromBody,
} from "@/lib/client-lane/cookie";
```

and replace the POST body-parsing tail — from `let body: { code?: unknown } | null = null;` through `return response;` — with:

```ts
  let body: unknown = null;
  try {
    body = await request.json();
  } catch {
    body = null;
  }
  // `expires_at` (Part D) is the lane's own expiry from the code verify; a
  // `?k=` capture cannot know it, so it falls back to the 400-day default and
  // the api's per-call check retires a revoked or expired lane.
  const cookie = sessionCookieFromBody(body);
  if (!cookie) {
    return NextResponse.json(
      { message: "Invalid lane code." },
      { status: 400, headers: NO_STORE }
    );
  }

  const response = new NextResponse(null, { status: 204, headers: NO_STORE });
  response.cookies.set(cookie);
  return response;
```

Add one sentence to the file's top docblock: "`POST {code, expires_at?}` — `expires_at` (Part D) bounds the cookie to the lane's own expiry."

- [ ] **Step 4: Run green (test).** Command from Step 2. Expected: 4 pass.

- [ ] **Step 5: Mutation check (test).** Return `laneCookie(code, LANE_COOKIE_MAX_AGE_DEFAULT)` when `maxAge <= 0` instead of `null` → *"refuses a bad code, a past expiry and a non-date"* FAILS. Restore.

- [ ] **Step 6: Gates and commit.**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/lib/client-lane/cookie.ts src/lib/client-lane/cookie.test.ts src/app/s/session/route.ts) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "src/lib/client-lane/cookie|src/app/s/session"; /usr/bin/git add "${F[@]}" && /usr/bin/git commit -m "$(printf 'feat(web): /s/session cookies a lane until its own expiry\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```
Expected: `LANE_COOKIE_MAX_AGE_DEFAULT` is no longer imported by `route.ts` — eslint must not report an unused import; the tsc grep prints nothing.

---

### Task W3: frndOS v2 `CodeInput`

**Files:**
- Create: `src/components/frndos/v2/CodeInput.tsx`
- Test: `src/components/frndos/v2/CodeInput.test.tsx`
- Modify: `src/components/frndos/v2/index.ts`
- Create: `src/components/frndos/stories/CodeInputV2.stories.tsx`
- Modify: `.agents/skills/frndos-components-v2/SKILL.md` (component table, after the `| DropSuggestionBar` row, ~line 95)

**Interfaces:**
- Consumes: `@base-ui/react/otp-field` (`OTPField.Root`, `OTPField.Input`).
- Produces: `CodeInput(props: CodeInputProps)`; `interface CodeInputProps { value: string; onChange: (next: string) => void; onComplete?: (code: string) => void; label: string; length?: number; invalid?: boolean; disabled?: boolean; autoFocus?: boolean; describedBy?: string; className?: string }`. The first box's accessible name is `label`; box n (n ≥ 2) is `"Digit n of {length}"`.

- [ ] **Step 1: Write the failing tests (test).** Create `src/components/frndos/v2/CodeInput.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { fireEvent, render, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";

import { CodeInput } from "./CodeInput";

const body = () => within(document.body);
const first = () => body().getByRole("textbox", { name: "Verification code" });
const paste = (text: string) =>
  fireEvent.paste(first(), { clipboardData: { getData: () => text } });

function Harness({
  onComplete,
  invalid = false,
}: {
  onComplete?: (code: string) => void;
  invalid?: boolean;
}) {
  const [value, setValue] = useState("");
  return (
    <>
      <CodeInput
        label="Verification code"
        value={value}
        onChange={setValue}
        onComplete={onComplete}
        invalid={invalid}
      />
      <output data-testid="value">{value}</output>
    </>
  );
}

describe("CodeInput", () => {
  it("labels the first box with the field and the rest by position", () => {
    render(<Harness />);
    expect(first()).toBeInTheDocument();
    expect(body().getByRole("textbox", { name: "Digit 6 of 6" })).toBeInTheDocument();
    expect(body().getAllByRole("textbox")).toHaveLength(6);
    expect(first()).toHaveAttribute("autocomplete", "one-time-code");
  });

  it("fills every box from a pasted code, spaces and dashes dropped", () => {
    const onComplete = vi.fn();
    render(<Harness onComplete={onComplete} />);
    paste("004 219");
    expect(body().getByTestId("value")).toHaveTextContent("004219");
    expect(onComplete).toHaveBeenCalledWith("004219");
    for (const [i, digit] of [..."004219"].entries()) {
      expect(body().getAllByRole("textbox")[i]).toHaveValue(digit);
    }
  });

  it("keeps only digits", () => {
    render(<Harness />);
    paste("Code: 48-29\n");
    expect(body().getByTestId("value")).toHaveTextContent("4829");
  });

  it("moves to the next box as digits are typed", async () => {
    const user = userEvent.setup();
    render(<Harness />);
    await user.click(first());
    await user.keyboard("48");
    expect(body().getByTestId("value")).toHaveTextContent("48");
    expect(body().getByRole("textbox", { name: "Digit 3 of 6" })).toHaveFocus();
  });

  it("marks every box invalid in the error state", () => {
    render(<Harness invalid />);
    for (const box of body().getAllByRole("textbox")) {
      expect(box).toHaveAttribute("aria-invalid", "true");
    }
  });
});
```

- [ ] **Step 2: Run to see it fail (test).**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/frndos/v2/CodeInput.test.tsx`
Expected: FAIL — cannot resolve `./CodeInput`.

- [ ] **Step 3: Implement.** Create `src/components/frndos/v2/CodeInput.tsx`:

```tsx
"use client";

import { OTPField } from "@base-ui/react/otp-field";
import clsx from "clsx";
import { useId } from "react";

export interface CodeInputProps {
  /** Digits entered so far (controlled). */
  value: string;
  onChange: (next: string) => void;
  /** Fires once every box is filled — typed, pasted or autofilled. */
  onComplete?: (code: string) => void;
  /** The field's accessible name; it labels the first box, the rest read "Digit n of N". */
  label: string;
  /** Number of boxes. @default 6 */
  length?: number;
  /** Error state: alert border and `aria-invalid` on every box. */
  invalid?: boolean;
  disabled?: boolean;
  autoFocus?: boolean;
  /** Id of the text that explains the error, for `aria-describedby`. */
  describedBy?: string;
  className?: string;
}

const digitsOnly = (raw: string) => raw.replace(/\D/g, "");

const BOX = clsx(
  "h-12 w-10 rounded-xl border border-white/10 bg-white/5 text-center font-geist text-displayXs text-text-inverse",
  "outline-none transition-all duration-200 ease-out",
  "hover:bg-white/10 focus:border-white/20 focus-visible:ring-2 focus-visible:ring-white/40",
  "data-[filled]:bg-white/10",
  "disabled:cursor-not-allowed disabled:opacity-50",
  "sm:h-14 sm:w-12"
);

/**
 * frndOS v2 — a one-time code in `length` boxes on Base UI `OTPField`.
 *
 * Paste and `one-time-code` autofill land in any box and fill them all;
 * anything that is not a digit (spaces, dashes, "Code:", a trailing newline
 * from a mail app) is dropped by `normalizeValue`, so a code with leading
 * zeros stays a string. State is CSS-driven (`data-[filled]`, `focus-visible`,
 * `disabled:`), per the v2 Visual Consistency rules.
 */
export function CodeInput({
  value,
  onChange,
  onComplete,
  label,
  length = 6,
  invalid = false,
  disabled = false,
  autoFocus = false,
  describedBy,
  className,
}: CodeInputProps) {
  const id = useId();
  return (
    <div className={clsx("flex flex-col", className)}>
      {/* OTPField names its first box from a <label>, never `aria-label`. */}
      <label htmlFor={id} className="sr-only">
        {label}
      </label>
      <OTPField.Root
        id={id}
        length={length}
        value={value}
        onValueChange={(next) => onChange(next)}
        onValueComplete={(code) => onComplete?.(code)}
        validationType="none"
        inputMode="numeric"
        normalizeValue={digitsOnly}
        disabled={disabled}
        className="flex items-center gap-2"
      >
        {Array.from({ length }, (_, i) => (
          <OTPField.Input
            key={i}
            autoFocus={autoFocus && i === 0}
            aria-label={i === 0 ? undefined : `Digit ${i + 1} of ${length}`}
            aria-invalid={invalid || undefined}
            aria-describedby={describedBy}
            className={clsx(
              BOX,
              invalid && "border-negative-400 focus:border-negative-400"
            )}
          />
        ))}
      </OTPField.Root>
    </div>
  );
}

export default CodeInput;
```

- [ ] **Step 4: Run green (test).** Command from Step 2. Expected: 5 pass. If a test fails because `OTPField` behaves differently under jsdom than its d.ts promises (e.g. `onValueComplete` not firing on paste), read `node_modules/@base-ui/react/otp-field/input/OTPFieldInput.js` and fix the component or the expectation per the Global Constraints rule — do not switch primitives without telling Daffa.

- [ ] **Step 5: Mutation checks (test).** One at a time, restore after each:
  1. Remove `normalizeValue={digitsOnly}` and set `validationType="numeric"` → *"keeps only digits"* or *"fills every box … dashes dropped"* must FAIL; if both still pass, the primitive filters on its own — note it in the commit body and keep `normalizeValue` anyway (it is what guarantees `"Code: 48-29"`).
  2. Delete `aria-invalid={invalid || undefined}` → *"marks every box invalid in the error state"* FAILS.

- [ ] **Step 6: Export.** In `src/components/frndos/v2/index.ts`, after the `AutoGrowTextarea` export block:

```ts
// CodeInput
export { CodeInput } from "./CodeInput";
export type { CodeInputProps } from "./CodeInput";
```

- [ ] **Step 7: Story.** Create `src/components/frndos/stories/CodeInputV2.stories.tsx`:

```tsx
import type { Meta, StoryObj } from "@storybook/react";
import React, { useState } from "react";
import { CodeInput } from "../v2/CodeInput";

const meta: Meta<typeof CodeInput> = {
  title: "FrndOS v2/CodeInput",
  component: CodeInput,
  tags: ["autodocs"],
  parameters: {
    backgrounds: { default: "dark" },
    docs: {
      description: {
        component:
          "**frndOS v2** — a one-time code in N boxes (default 6) on Base UI `OTPField`. Paste or `one-time-code` autofill fills every box; digits only (spaces and dashes dropped); `invalid` marks every box; `onComplete` fires once all boxes are filled. Used by the client lane's code sheet on `/s/{token}`.",
      },
    },
  },
};

export default meta;
type Story = StoryObj<typeof CodeInput>;

function Controlled({
  initial = "",
  invalid,
  disabled,
}: {
  initial?: string;
  invalid?: boolean;
  disabled?: boolean;
}) {
  const [value, setValue] = useState(initial);
  return (
    <CodeInput
      label="Verification code"
      value={value}
      onChange={setValue}
      invalid={invalid}
      disabled={disabled}
    />
  );
}

export const Empty: Story = { render: () => <Controlled /> };
export const Filled: Story = { render: () => <Controlled initial="004219" /> };
export const Invalid: Story = {
  render: () => <Controlled initial="482913" invalid />,
};
export const Disabled: Story = {
  render: () => <Controlled initial="48" disabled />,
};
```

- [ ] **Step 8: Skill row.** In `.agents/skills/frndos-components-v2/SKILL.md`, insert directly after the line that starts with `| DropSuggestionBar`:

```markdown
| CodeInput                           | `@/components/frndos/v2`        | `@base-ui/react/otp-field`                      | One-time code in `length` boxes (default 6): controlled `value` / `onChange`, `onComplete(code)` once every box is filled, `label` (names the first box via a hidden `<label>`; the rest read "Digit n of N"), `invalid` (alert border + `aria-invalid` on every box), `disabled`, `autoFocus`, `describedBy`. Digits only — paste and `one-time-code` autofill fill every box, spaces/dashes dropped, leading zeros kept. Client lane code sheet (`/s/{token}`). |
```

- [ ] **Step 9: Gates and commit.**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/frndos/v2/CodeInput.tsx src/components/frndos/v2/CodeInput.test.tsx src/components/frndos/v2/index.ts src/components/frndos/stories/CodeInputV2.stories.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "frndos/v2/(CodeInput|index)|CodeInputV2"; /usr/bin/grep -nE -- "-\[[0-9]+px\]|text-white\b|text-gray-" src/components/frndos/v2/CodeInput.tsx; /usr/bin/git add "${F[@]}" .agents/skills/frndos-components-v2/SKILL.md && /usr/bin/git commit -m "$(printf 'feat(web): frndOS v2 CodeInput — one-time code boxes on Base UI OTPField\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```
Expected: both greps print nothing.

---

### Task W4: `CodeSheet`

**Files:**
- Create: `src/components/client-lane/sheets/CodeSheet.tsx`
- Test: `src/components/client-lane/sheets/CodeSheet.test.tsx`

**Interfaces:**
- Consumes: `CodeInput`, v2 `Button`, client-lane `Sheet`, `SendCodeResult` / `CodeVerifyOutcome` (W1).
- Produces: `CodeSheet({ open, initialEmail, onSend, onVerify, onClose })` with `onSend: (email: string, resend: boolean) => Promise<SendCodeResult>`, `onVerify: (email: string, code: string) => Promise<CodeVerifyOutcome>`, `onClose: () => void`; `export const RESEND_SECONDS = 60`. Dialog name `"Confirm it's you"`; email field name `"Email"`. Mount it with a `key` per open (state resets).

- [ ] **Step 1: Write the failing tests (test).** Create `src/components/client-lane/sheets/CodeSheet.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { ComponentProps } from "react";
import { describe, expect, it, vi } from "vitest";

import type { CodeVerifyOutcome, SendCodeResult } from "@/lib/client-lane/laneCode";

import { CodeSheet } from "./CodeSheet";

const body = () => within(document.body);
const VERIFIED: CodeVerifyOutcome = {
  ok: true,
  lane: { lane_code: "abcdefghijklmnop", kind: "verified_guest", expires_at: null },
};

function renderSheet(over: Partial<ComponentProps<typeof CodeSheet>> = {}) {
  const onSend = vi.fn(async (): Promise<SendCodeResult> => ({ ok: true }));
  const onVerify = vi.fn(async (): Promise<CodeVerifyOutcome> => VERIFIED);
  const onClose = vi.fn();
  render(
    <CodeSheet
      open
      initialEmail="dina@brand.test"
      onSend={onSend}
      onVerify={onVerify}
      onClose={onClose}
      {...over}
    />
  );
  return { onSend, onVerify, onClose };
}

const paste = (code: string) =>
  fireEvent.paste(body().getByRole("textbox", { name: "Verification code" }), {
    clipboardData: { getData: () => code },
  });

describe("CodeSheet", () => {
  it("sends a code to the prefilled address once, as it opens", async () => {
    const { onSend } = renderSheet();
    expect(await body().findByText(/We sent a 6-digit code to/)).toBeInTheDocument();
    expect(onSend).toHaveBeenCalledTimes(1);
    expect(onSend).toHaveBeenCalledWith("dina@brand.test", false);
    expect(body().getByRole("button", { name: "Resend in 60s" })).toBeDisabled();
  });

  it("verifies as soon as the code is pasted", async () => {
    const { onVerify } = renderSheet();
    await body().findByText(/We sent a 6-digit code to/);
    paste("482913");
    await waitFor(() => expect(onVerify).toHaveBeenCalledWith("dina@brand.test", "482913"));
  });

  it("says how many tries are left after a wrong code, and clears the boxes", async () => {
    renderSheet({
      onVerify: vi.fn(async (): Promise<CodeVerifyOutcome> => ({
        ok: false,
        reason: "invalid_code",
        attemptsLeft: 3,
      })),
    });
    await body().findByText(/We sent a 6-digit code to/);
    paste("111111");
    expect(await body().findByRole("alert")).toHaveTextContent("That code didn't match — 3 tries left.");
    for (const box of body().getAllByRole("textbox")) expect(box).toHaveValue("");
  });

  it("offers a new code at once when the code has expired", async () => {
    const { onSend } = renderSheet({
      onVerify: vi.fn(async (): Promise<CodeVerifyOutcome> => ({ ok: false, reason: "code_expired" })),
    });
    await body().findByText(/We sent a 6-digit code to/);
    paste("111111");
    expect(await body().findByRole("alert")).toHaveTextContent("This code has expired. Send a new one.");
    fireEvent.click(body().getByRole("button", { name: "Send a new code" }));
    await waitFor(() => expect(onSend).toHaveBeenLastCalledWith("dina@brand.test", true));
  });

  it("lets the viewer change the address and sends there instead", async () => {
    const user = userEvent.setup();
    const { onSend } = renderSheet();
    await body().findByText(/We sent a 6-digit code to/);
    await user.click(body().getByRole("button", { name: "Change" }));
    const field = body().getByRole("textbox", { name: "Email" });
    await user.clear(field);
    await user.type(field, "dina.n@brand.test");
    await user.click(body().getByRole("button", { name: "Send code" }));
    await waitFor(() => expect(onSend).toHaveBeenLastCalledWith("dina.n@brand.test", false));
    expect(await body().findByText("dina.n@brand.test")).toBeInTheDocument();
  });

  it("asks for an address first when none is known, and sends nothing until then", () => {
    const { onSend } = renderSheet({ initialEmail: "" });
    expect(body().getByRole("textbox", { name: "Email" })).toBeInTheDocument();
    expect(onSend).not.toHaveBeenCalled();
  });

  it("says so when the code could not be sent", async () => {
    renderSheet({
      onSend: vi.fn(async (): Promise<SendCodeResult> => ({ ok: false, reason: "throttled" })),
    });
    expect(await body().findByRole("alert")).toHaveTextContent(
      "Too many codes asked for. Try again in a little while."
    );
  });
});
```

- [ ] **Step 2: Run to see it fail (test).**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/sheets/CodeSheet.test.tsx`
Expected: FAIL — cannot resolve `./CodeSheet`.

- [ ] **Step 3: Implement.** Create `src/components/client-lane/sheets/CodeSheet.tsx`:

```tsx
"use client";

import { useEffect, useRef, useState } from "react";

import { Button, CodeInput } from "@/components/frndos/v2";
import type { CodeVerifyOutcome, SendCodeResult } from "@/lib/client-lane/laneCode";

import { Sheet } from "../Sheet";

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const CODE_LENGTH = 6;
const ERROR_ID = "lane-code-error";
export const RESEND_SECONDS = 60;

const FIELD =
  "h-11 rounded-xl border border-white/10 bg-white/5 px-3 font-geist text-textSm text-text-inverse outline-none transition-all duration-200 ease-out placeholder:text-text-inverse-subtlest focus:border-white/20 focus-visible:ring-2 focus-visible:ring-white/40";

/**
 * Part D's code sheet (spec 2026-10-01 §7): the first decision on a KV
 * request link from a device with no lane lands here. Email step (prefilled
 * from the name gate, editable) → six boxes. With a prefilled address the
 * code is sent once as the sheet opens (ruling R-D11); the page remounts the
 * sheet per open (`key`), which resets everything here.
 */
export function CodeSheet({
  open,
  initialEmail,
  onSend,
  onVerify,
  onClose,
}: {
  open: boolean;
  initialEmail: string;
  onSend: (email: string, resend: boolean) => Promise<SendCodeResult>;
  onVerify: (email: string, code: string) => Promise<CodeVerifyOutcome>;
  onClose: () => void;
}) {
  const start = initialEmail.trim();
  const prefilled = EMAIL.test(start);
  const [step, setStep] = useState<"email" | "code">(prefilled ? "code" : "email");
  const [email, setEmail] = useState(start);
  const [draftEmail, setDraftEmail] = useState(start);
  const [touched, setTouched] = useState(false);
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [expired, setExpired] = useState(false);
  const [sending, setSending] = useState(false);
  const [verifying, setVerifying] = useState(false);
  const [resendAt, setResendAt] = useState(0);
  const [now, setNow] = useState(() => Date.now());
  const autoSent = useRef(false);

  const send = async (to: string, resend: boolean) => {
    setSending(true);
    setError(null);
    setExpired(false);
    setCode("");
    const res = await onSend(to, resend);
    setSending(false);
    if (!res.ok) {
      setError(
        res.reason === "throttled"
          ? "Too many codes asked for. Try again in a little while."
          : "Couldn't send the code. Try again in a moment."
      );
      return;
    }
    setEmail(to);
    setStep("code");
    const sentAt = Date.now();
    setNow(sentAt);
    setResendAt(sentAt + RESEND_SECONDS * 1000);
  };

  useEffect(() => {
    if (!open || !prefilled || autoSent.current) return;
    autoSent.current = true;
    void send(start, false);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- once per open; the page remounts the sheet per open
  }, [open]);

  useEffect(() => {
    if (resendAt <= now) return;
    const id = window.setTimeout(() => setNow(Date.now()), 1000);
    return () => window.clearTimeout(id);
  }, [resendAt, now]);

  const verify = async (value: string) => {
    if (verifying || value.length !== CODE_LENGTH) return;
    setVerifying(true);
    setError(null);
    const res = await onVerify(email, value);
    setVerifying(false);
    if (res.ok) return; // The page closes the sheet once the decision resubmits.
    setCode("");
    if (res.reason === "invalid_code") {
      setError(
        res.attemptsLeft === 1
          ? "That code didn't match — 1 try left."
          : `That code didn't match — ${res.attemptsLeft} tries left.`
      );
      return;
    }
    if (res.reason === "code_expired") {
      setExpired(true);
      setError("This code has expired. Send a new one.");
      return;
    }
    setError(
      res.reason === "throttled"
        ? "Too many tries. Wait a minute and try again."
        : "That didn't go through. Check your connection and try again."
    );
  };

  const secondsLeft = Math.max(0, Math.ceil((resendAt - now) / 1000));

  return (
    <Sheet open={open} title="Confirm it's you" onClose={onClose} dismissible={!verifying}>
      {step === "code" ? (
        <form
          className="flex flex-col gap-4 pb-2 font-geist"
          onSubmit={(e) => {
            e.preventDefault();
            void verify(code);
          }}
        >
          <p className="text-textSm text-text-inverse-subtle">
            {sending ? "Sending a 6-digit code to " : "We sent a 6-digit code to "}
            <span className="text-textSmMedium text-text-inverse">{email}</span>.{" "}
            <Button
              type="button"
              variant="text"
              size="tiny"
              disabled={sending || verifying}
              onClick={() => {
                setDraftEmail(email);
                setTouched(false);
                setError(null);
                setStep("email");
              }}
            >
              Change
            </Button>
          </p>
          <CodeInput
            label="Verification code"
            value={code}
            onChange={(next) => {
              setCode(next);
              if (error && !expired) setError(null);
            }}
            onComplete={(full) => void verify(full)}
            invalid={error !== null && !expired}
            disabled={verifying || expired}
            autoFocus
            describedBy={error ? ERROR_ID : undefined}
          />
          {error && (
            <p id={ERROR_ID} role="alert" className="text-textXs text-negative-400">
              {error}
            </p>
          )}
          <Button
            type="submit"
            size="large"
            loading={verifying}
            disabled={verifying || expired || code.length !== CODE_LENGTH}
          >
            Confirm
          </Button>
          <div className="flex items-center justify-between gap-3">
            <p className="text-textXs text-text-inverse-subtlest">
              Once per device — your decisions here count for 30 days.
            </p>
            <Button
              type="button"
              variant="text"
              size="tiny"
              disabled={sending || verifying || (!expired && secondsLeft > 0)}
              onClick={() => void send(email, true)}
            >
              {expired
                ? "Send a new code"
                : secondsLeft > 0
                  ? `Resend in ${secondsLeft}s`
                  : "Resend code"}
            </Button>
          </div>
        </form>
      ) : (
        <form
          className="flex flex-col gap-3 pb-2 font-geist"
          onSubmit={(e) => {
            e.preventDefault();
            setTouched(true);
            const to = draftEmail.trim();
            if (!EMAIL.test(to) || to.length > 254 || sending) return;
            void send(to, false);
          }}
        >
          <p className="text-textSm text-text-inverse-subtle">
            We&apos;ll email you a 6-digit code. Looking and pinning never need one —
            only decisions do.
          </p>
          <label className="flex flex-col gap-1.5">
            <span className="text-textXs text-text-inverse-subtle">Email</span>
            <input
              autoFocus
              type="email"
              inputMode="email"
              autoComplete="email"
              maxLength={254}
              value={draftEmail}
              onChange={(e) => setDraftEmail(e.target.value)}
              placeholder="dina@brand.co.id"
              className={FIELD}
            />
          </label>
          {touched && !EMAIL.test(draftEmail.trim()) && (
            <p role="alert" className="text-textXs text-negative-400">
              Enter a valid email address.
            </p>
          )}
          {error && (
            <p role="alert" className="text-textXs text-negative-400">
              {error}
            </p>
          )}
          <Button type="submit" size="large" loading={sending} disabled={sending}>
            Send code
          </Button>
        </form>
      )}
    </Sheet>
  );
}
```

Note: with a prefilled address and a failed first send, the sheet stays on the code step with the alert; "Resend code" is enabled (no countdown started) — that is the retry.

- [ ] **Step 4: Run green (test).** Command from Step 2. Expected: 7 pass.

- [ ] **Step 5: Mutation checks (test).** One at a time, restore after each:
  1. Delete the `autoSent.current` guard (`if (!open || !prefilled) return;`) and wrap the render in `<StrictMode>` in the first test temporarily → `toHaveBeenCalledTimes(1)` FAILS. (Restore the test file too.)
  2. Replace `setCode("")` after a failed verify with nothing → *"says how many tries are left … clears the boxes"* FAILS.
  3. Change the resend button's disabled rule to `disabled={sending || verifying || secondsLeft > 0}` → *"offers a new code at once when the code has expired"* FAILS.

- [ ] **Step 6: Gates and commit.**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/client-lane/sheets/CodeSheet.tsx src/components/client-lane/sheets/CodeSheet.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "sheets/CodeSheet"; /usr/bin/grep -nE -- "-\[[0-9]+px\]|text-white\b|text-gray-|@/components/frndos\"|@/components/frndos/[A-Z]" src/components/client-lane/sheets/CodeSheet.tsx; /usr/bin/git add "${F[@]}" && /usr/bin/git commit -m "$(printf 'feat(web): client-lane code sheet — email, six boxes, resend in 60s\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```
Expected: both greps print nothing (no arbitrary values, no v1 import beside v2).

---

### Task W5: Decision page — 403 → code → resubmit, and the summary line

**Files:**
- Modify: `src/components/client-lane/DecisionPage.tsx` (imports ~lines 9–98; `OpenSheet` ~line 125; state ~line 232; `doSubmitRequest` 403 branch ~lines 676–682; after the AC-14 effect ~line 809; `RequestOverview` usage ~line 1263; sheets ~line 1503)
- Modify: `src/components/client-lane/RequestRail.tsx` (`RequestOverview`)
- Modify: `src/lib/client-lane/testFixtures.ts`
- Test: `src/components/client-lane/DecisionPage.code.test.tsx`

**Interfaces:**
- Consumes: `CodeSheet` (W4); `sendLaneCode`, `confirmLaneCode`, `verifiedSummary` (W1); `LaneCodeVerified`; `resolveShareLink`; `readDraft` / `writeDraft` / `clearDraft`; the existing AC-14 auto-submit effect (`autoSubmittedRef`, `hasLane`, `requestCanDecide`, `submitRequest(draft, { kind: "resumed" })`).
- Produces: `RequestOverview` prop `identityLine?: string | null`; fixture `kvRequest(overrides?: Partial<ShareLinkKv>): ShareLinkKv` (two pending artboards `a1` craft/HERO and `a2` resize/STORY, anonymous viewer, `verification_required: true`).

- [ ] **Step 1: Fixture.** In `src/lib/client-lane/testFixtures.ts`, add `PublicRequestApproval` to the type import from `./types`, and append:

```ts
/**
 * A KV approval-request link (spec 2026-10-01 §4.6): Request 1 with two
 * pending artboards (Craft HERO = a1, Resize STORY = a2), seen by an
 * anonymous viewer — Part D asks this viewer for a code.
 */
export function kvRequest(overrides: Partial<ShareLinkKv> = {}): ShareLinkKv {
  const approvals: PublicRequestApproval[] = [
    {
      id: "a1",
      phase: "craft",
      label: "Craft · Hero board",
      round: 1,
      version_id: HERO.id,
      status: "pending",
      snapshot: HERO,
      replaced: false,
      decisions: [],
    },
    {
      id: "a2",
      phase: "resize",
      label: "Resize · IG Story · 1080×1920",
      round: 1,
      version_id: STORY.id,
      status: "pending",
      snapshot: STORY,
      replaced: false,
      decisions: [],
    },
  ];
  return kvRound({
    version: {
      type: "approval_request",
      id: "req1",
      label: "Request 1",
      created_at: "2026-10-01T00:00:00.000Z",
    },
    items: [],
    document: {
      name: "Ramadan hero",
      brand_slug: "garuda",
      phases: [
        { phase: "craft", items: [HERO] },
        { phase: "resize", items: [STORY] },
      ],
    },
    approval: null,
    request: {
      id: "req1",
      number: 1,
      status: "pending",
      message: null,
      decide_by: null,
      deferred_until: null,
      deferred_note: null,
      approvers: [],
      counts: { approved: 0, approved_with_changes: 0, changes_required: 0, pending: 2, superseded: 0 },
    },
    approvals,
    access: { role: "comment", expires_at: null, can_decide: true, verification_required: true },
    viewer: { kind: "anonymous", name: null, email: null },
    ...overrides,
  });
}
```

- [ ] **Step 2: Write the failing page tests (test).** Create `src/components/client-lane/DecisionPage.code.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { GUEST_STORAGE_KEY, draftStorageKey } from "@/lib/client-lane/storage";
import { kvRequest } from "@/lib/client-lane/testFixtures";
import type {
  LaneCodeVerified,
  RequestDecisionResponse,
  ShareLinkData,
} from "@/lib/client-lane/types";
import { axiosPublic } from "@/services/axios";

import { DecisionPage } from "./DecisionPage";

const body = () => within(document.body);
const LANE: LaneCodeVerified = {
  lane_code: "abcdefghijklmnop",
  kind: "verified_guest",
  expires_at: "2026-10-31T09:00:00.000Z",
};
const DIALOG = { name: "Confirm it's you" };

function axiosError(status: number, data: Record<string, unknown>) {
  return Object.assign(new Error(`HTTP ${status}`), {
    isAxiosError: true,
    response: { status, data },
  });
}

type PostCall = [string, Record<string, unknown>, { headers?: Record<string, string> } | undefined];
const postCalls = (post: unknown) => (post as { mock: { calls: PostCall[] } }).mock.calls;
const decisionCalls = (post: unknown) =>
  postCalls(post).filter(([url]) => url === "public/share-links/tok/decision");

/**
 * The public api edge, spied (never vi.mock'ed). The decision endpoint
 * enforces Part D: no `X-Lane-Code` → 403 verification_required.
 */
function stubApi(opts: { sessionCode?: string | null; verify?: () => Promise<unknown> } = {}) {
  const fetchSpy = vi.spyOn(globalThis, "fetch").mockImplementation((async (
    _url: unknown,
    init?: RequestInit
  ) =>
    init?.method === "POST"
      ? new Response(null, { status: 204 })
      : new Response(JSON.stringify({ code: opts.sessionCode ?? null }), { status: 200 })) as unknown as typeof fetch);

  const verified = kvRequest({
    viewer: { kind: "verified", name: "dina", email: "dina@brand.test" },
    access: { role: "comment", expires_at: null, can_decide: true, verification_required: false },
  });
  const get = vi.spyOn(axiosPublic, "get").mockImplementation((async (url: string) => {
    if (url === "public/share-links/tok/comments") return { data: { data: [] } };
    if (url === "public/share-links/tok") return { data: { data: verified } };
    throw new Error(`unexpected GET ${url}`);
  }) as never);

  const decided: RequestDecisionResponse = {
    results: [
      { approval_id: "a1", result: "decided", decision: null },
      { approval_id: "a2", result: "decided", decision: null },
    ],
    request: {
      ...verified.request!,
      status: "approved",
      counts: { approved: 2, approved_with_changes: 0, changes_required: 0, pending: 0, superseded: 0 },
    },
    approvals: verified.approvals!.map((a) => ({ ...a, status: "approved" as const })),
  };
  const post = vi.spyOn(axiosPublic, "post").mockImplementation((async (
    url: string,
    _input: unknown,
    config?: { headers?: Record<string, string> }
  ) => {
    if (url === "public/share-links/tok/decision") {
      if (!config?.headers?.["X-Lane-Code"]) {
        throw axiosError(403, { code: "verification_required", message: "Confirm your email with a code first." });
      }
      return { data: { data: decided } };
    }
    if (url === "public/lane/code") return { status: 202, data: { message: "…" } };
    if (url === "public/lane/code/verify") return opts.verify ? opts.verify() : { data: { data: LANE } };
    throw new Error(`unexpected POST ${url}`);
  }) as never);

  const capture = vi.spyOn(posthog, "capture").mockImplementation(() => undefined as never);
  return { fetchSpy, get, post, capture };
}

function QueryWrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

function renderPage(data: ShareLinkData) {
  return render(<DecisionPage token="tok" initialData={data} />, { wrapper: QueryWrapper });
}

/** The comments load runs once the lane bootstrap has put the code in state. */
async function laneSettled(get: unknown) {
  await waitFor(() =>
    expect(
      (get as { mock: { calls: [string][] } }).mock.calls.some(([u]) => u === "public/share-links/tok/comments")
    ).toBe(true)
  );
}

const pasteCode = (code: string) =>
  fireEvent.paste(body().getByRole("textbox", { name: "Verification code" }), {
    clipboardData: { getData: () => code },
  });

beforeEach(() => {
  window.localStorage.setItem(GUEST_STORAGE_KEY, JSON.stringify({ name: "Dina", email: "dina@brand.test" }));
  window.sessionStorage.clear();
});
afterEach(() => {
  vi.restoreAllMocks();
  window.localStorage.clear();
  window.sessionStorage.clear();
});

describe("DecisionPage — Part D verification code on a request link", () => {
  it("asks for a code on the first decision, then records it on its own once verified", async () => {
    const { fetchSpy, get, post, capture } = stubApi();
    renderPage(kvRequest());
    await laneSettled(get);

    fireEvent.click(await body().findByRole("button", { name: "Approve all 2" }));

    expect(await body().findByRole("dialog", DIALOG)).toBeInTheDocument();
    await waitFor(() =>
      expect(post).toHaveBeenCalledWith("public/lane/code", { email: "dina@brand.test", share_token: "tok" })
    );
    expect(window.sessionStorage.getItem(draftStorageKey("tok"))).toContain('"approval_ids":["a1","a2"]');

    pasteCode("482913");

    await waitFor(() => expect(decisionCalls(post)).toHaveLength(2));
    const [, input, config] = decisionCalls(post)[1];
    expect(config?.headers).toEqual({ "X-Lane-Code": "abcdefghijklmnop" });
    expect(input).toMatchObject({ approval_ids: ["a1", "a2"], outcome: "approved" });
    expect(input).not.toHaveProperty("guest_email");

    const sessionPost = (fetchSpy as unknown as { mock: { calls: [string, RequestInit | undefined][] } }).mock.calls.find(
      ([, init]) => init?.method === "POST"
    );
    expect(JSON.parse(String(sessionPost?.[1]?.body))).toEqual({
      code: "abcdefghijklmnop",
      expires_at: "2026-10-31T09:00:00.000Z",
    });

    expect(await body().findByText("Verified as Dina · this device, 30 days")).toBeInTheDocument();
    expect(body().queryByRole("dialog", DIALOG)).toBeNull();
    expect(window.sessionStorage.getItem(draftStorageKey("tok"))).toBeNull();
    const events = (capture as unknown as { mock: { calls: [string][] } }).mock.calls.map(([e]) => e);
    expect(events).toEqual(expect.arrayContaining(["client_lane.code_requested", "client_lane.code_verified"]));
  });

  it("keeps the decision waiting after a wrong code and says how many tries are left", async () => {
    const { get, post, capture } = stubApi({
      verify: () =>
        Promise.reject(
          axiosError(422, { code: "invalid_code", message: "That code didn't match.", attempts_left: 3 })
        ),
    });
    renderPage(kvRequest());
    await laneSettled(get);
    fireEvent.click(await body().findByRole("button", { name: "Approve all 2" }));
    await body().findByRole("dialog", DIALOG);
    await waitFor(() => expect(post).toHaveBeenCalledWith("public/lane/code", expect.anything()));

    pasteCode("111111");

    expect(await body().findByText("That code didn't match — 3 tries left.")).toBeInTheDocument();
    expect(decisionCalls(post)).toHaveLength(1);
    expect(window.sessionStorage.getItem(draftStorageKey("tok"))).not.toBeNull();
    expect(capture).toHaveBeenCalledWith(
      "client_lane.code_failed",
      expect.objectContaining({ stage: "verify", reason: "invalid_code", attempts_left: 3 })
    );
  });

  it("drops the decision when the code sheet is closed", async () => {
    const { get, post } = stubApi();
    renderPage(kvRequest());
    await laneSettled(get);
    fireEvent.click(await body().findByRole("button", { name: "Approve all 2" }));
    const dialog = await body().findByRole("dialog", DIALOG);
    await waitFor(() => expect(post).toHaveBeenCalledWith("public/lane/code", expect.anything()));

    fireEvent.click(within(dialog).getByRole("button", { name: "Close" }));

    expect(body().queryByRole("dialog", DIALOG)).toBeNull();
    expect(window.sessionStorage.getItem(draftStorageKey("tok"))).toBeNull();
  });

  it("lets a device that already verified decide in one tap and says who it decides as", async () => {
    const { get, post } = stubApi({ sessionCode: "abcdefghijklmnop" });
    renderPage(
      kvRequest({
        viewer: { kind: "verified", name: "dina", email: "dina@brand.test" },
        access: { role: "comment", expires_at: null, can_decide: true, verification_required: false },
      })
    );
    await laneSettled(get);
    expect(body().getByText("Verified as Dina · this device")).toBeInTheDocument();

    fireEvent.click(await body().findByRole("button", { name: "Approve all 2" }));

    await waitFor(() => expect(decisionCalls(post)).toHaveLength(1));
    expect(decisionCalls(post)[0][2]?.headers).toEqual({ "X-Lane-Code": "abcdefghijklmnop" });
    expect(body().queryByRole("dialog", DIALOG)).toBeNull();
  });
});
```

- [ ] **Step 3: Run to see it fail (test).**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/DecisionPage.code.test.tsx`
Expected: FAIL — the first three find the magic-link sheet ("This one moves budget") instead of "Confirm it's you"; the fourth fails on the missing summary line.

- [ ] **Step 4: `RequestOverview` identity line.** In `src/components/client-lane/RequestRail.tsx`, add the prop to `RequestOverview`'s destructuring and type:

```tsx
export function RequestOverview({
  request,
  workspaceName,
  progress,
  identityLine,
  footer,
  className,
}: {
  request: PublicRequest;
  workspaceName: string;
  progress: RequestProgress;
  /** "Verified as Dina · this device, 30 days" (Part D) — who this device decides as. */
  identityLine?: string | null;
  /** The approver hint ("Email me my link"), when it applies. */
  footer?: ReactNode;
  className?: string;
}) {
```

and inside the `<div className="flex flex-col gap-2">`, after the `Waiting on …` paragraph block:

```tsx
        {identityLine && (
          <p className="text-textXs text-text-inverse-subtle">{identityLine}</p>
        )}
```

- [ ] **Step 5: Wire `DecisionPage`.** In `src/components/client-lane/DecisionPage.tsx`:

(a) Imports — add beside the existing client-lane imports:

```tsx
import {
  confirmLaneCode,
  sendLaneCode,
  verifiedSummary,
} from "@/lib/client-lane/laneCode";
```

add `LaneCodeVerified` to the existing `import type { … } from "@/lib/client-lane/types";` list, and beside the other sheets:

```tsx
import { CodeSheet } from "./sheets/CodeSheet";
```

(b) `OpenSheet` — add a member after `| { kind: "verify"; email: string }`:

```tsx
  | { kind: "code"; email: string }
```

(c) State — after `const [verifySent, setVerifySent] = useState(false);`:

```tsx
  /** Set when this page just verified a code (Part D summary, ruling R-D13). */
  const [justVerified, setJustVerified] = useState(false);
```

(d) In `doSubmitRequest`'s catch, replace

```tsx
          if (err.code === "verification_required") {
            writeDraft(token, draft);
            setVerifySent(false);
            setSheet({
              kind: "verify",
              email: g?.email ?? data.viewer.email ?? "",
            });
          } else if (err.code === "guest_required") {
            setLaneRejected(true);
            clearGuest();
            setGuest(null);
            afterIdentityRef.current = (identity) =>
              doSubmitRequest(draft, meta, identity);
```

with

```tsx
          if (err.code === "verification_required") {
            // Part D: a request link asks for a code once per device; the
            // decision waits as the draft and submits itself once verified
            // (the AC-14 effect below).
            writeDraft(token, draft);
            setSheet({
              kind: "code",
              email: g?.email ?? data.viewer.email ?? "",
            });
          } else if (err.code === "guest_required") {
            setLaneRejected(true);
            clearGuest();
            setGuest(null);
            afterIdentityRef.current = (identity) =>
              doSubmitRequest(draft, meta, identity);
```

(The round path in `doSubmit` keeps `kind: "verify"` — plans keep the magic link, R-D14.)

(e) Directly after the AC-14 `useEffect` (the one ending with `submitRequest,\n  ]);`), add:

```tsx
  /* ── Part D: verification code (spec 2026-10-01 §7) ───────────────── */

  const sendCode = useCallback(
    (email: string, resend: boolean) => sendLaneCode(token, email, resend),
    [token]
  );

  // Verified: hold the lane in memory, re-resolve C-1 with it (so the viewer
  // becomes `verified` / `client`), and let the AC-14 effect above resubmit
  // the stored draft with the new `X-Lane-Code`.
  const onCodeVerified = useCallback(
    async (lane: LaneCodeVerified) => {
      let next: ShareLinkData | null = null;
      try {
        next = await resolveShareLink(token, lane.lane_code);
      } catch {
        next = null;
      }
      setLaneCode(lane.lane_code);
      setLaneRejected(false);
      setJustVerified(true);
      autoSubmittedRef.current = false;
      if (next) {
        setData(next);
      } else {
        clearDraft(token);
        setError("You're verified — tap your decision again.");
      }
      setSheet(null);
    },
    [token]
  );

  const checkCode = useCallback(
    async (email: string, code: string) => {
      const outcome = await confirmLaneCode(token, email, code);
      if (outcome.ok) await onCodeVerified(outcome.lane);
      return outcome;
    },
    [token, onCodeVerified]
  );

  // Closing abandons the decision (ruling R-D12): a stored draft must never
  // auto-submit on some later visit that happens to hold a lane.
  const closeCodeSheet = () => {
    clearDraft(token);
    setSheet(null);
  };

  const identityLine = verifiedSummary(
    hasLane ? data.viewer.kind : "anonymous",
    guest?.name ?? data.viewer.name,
    justVerified
  );
```

(f) On the `<RequestOverview` element, add the prop after `progress={progress}`:

```tsx
                identityLine={identityLine}
```

(g) After the `<VerifySheet … />` element, add:

```tsx
      {req && (
        <CodeSheet
          key={sheet?.kind === "code" ? `code-${sheet.email}` : "code-closed"}
          open={sheet?.kind === "code"}
          initialEmail={sheet?.kind === "code" ? sheet.email : ""}
          onSend={sendCode}
          onVerify={checkCode}
          onClose={closeCodeSheet}
        />
      )}
```

If `ShareLinkData` or `resolveShareLink` is not already imported in the file, add it to the existing `@/lib/client-lane/types` / `@/lib/client-lane/publicApi` import lists (both are used today: `useState<ShareLinkData>`, `refresh()`).

- [ ] **Step 6: Run green (test).** Command from Step 3. Expected: 4 pass. Then the regression file (one process each): `bun test src/components/client-lane/DecisionPage.test.tsx` — every test still passes (deck / round / plan paths untouched).

- [ ] **Step 7: Mutation checks (test).** One at a time, restore after each:
  1. In (d), set `kind: "verify"` back → *"asks for a code on the first decision …"* FAILS.
  2. In (e), delete `setJustVerified(true);` → the same test FAILS on `"Verified as Dina · this device, 30 days"`.
  3. In `closeCodeSheet`, delete `clearDraft(token);` → *"drops the decision when the code sheet is closed"* FAILS.
  4. In (e), skip the re-resolve (`next = null;` without calling `resolveShareLink`) and keep the else-branch → the first test FAILS (no second decision post).

- [ ] **Step 8: Gates and commit.**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/client-lane/DecisionPage.tsx src/components/client-lane/RequestRail.tsx src/lib/client-lane/testFixtures.ts src/components/client-lane/DecisionPage.code.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "client-lane/(DecisionPage|RequestRail)|client-lane/testFixtures"; wc -c src/components/client-lane/DecisionPage.code.test.tsx; /usr/bin/git diff -U0 src/components/client-lane/DecisionPage.tsx src/components/client-lane/RequestRail.tsx | /usr/bin/grep -E "^\+" | /usr/bin/grep -nE -- "-\[[0-9]+px\]|text-white\b|text-gray-"; /usr/bin/git add "${F[@]}" && /usr/bin/git commit -m "$(printf 'feat(web): request links ask for a code once per device, then the decision submits itself\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```
Expected: tsc grep and the added-lines grep print nothing; the test file is < 45 KB.

---

### Task W6: Web wrap-up — gates, track file, taxonomy hand-off

**Files:**
- Modify: `docs/tracks/client-lane-multi-item.track.md`

**Interfaces:**
- Consumes: everything above.
- Produces: the audit trail; a hand-off for the Lark taxonomy rows.

- [ ] **Step 1: All Part D web tests, one file per process (test).**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && for f in src/lib/client-lane/laneCode.test.ts src/lib/client-lane/cookie.test.ts src/components/frndos/v2/CodeInput.test.tsx src/components/client-lane/sheets/CodeSheet.test.tsx src/components/client-lane/DecisionPage.code.test.tsx src/components/client-lane/DecisionPage.test.tsx; do bun test "$f" || echo "FAILED: $f"; done
```
Expected: no `FAILED:` line.

- [ ] **Step 2: Type baseline.**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"`
Expected: the W0 baseline (895).

- [ ] **Step 3: §11.3 review gate.** No arbitrary values on added lines and no v1/v2 mix in touched files:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && BASE=$(/usr/bin/git log --format=%H -1 --grep="lane code client" ) && /usr/bin/git diff "$BASE~1" -U0 -- src | /usr/bin/grep -E "^\+" | /usr/bin/grep -nE -- "-\[[0-9]+px\]|text-white\b|text-gray-"; for f in src/components/client-lane/sheets/CodeSheet.tsx src/components/frndos/v2/CodeInput.tsx src/components/client-lane/DecisionPage.tsx; do if /usr/bin/grep -q '@/components/frndos/v2' "$f" && /usr/bin/grep -qE '@/components/frndos/[A-Z]|@/components/frndos"' "$f"; then echo "MIX: $f"; fi; done
```
Expected: no output. (`DecisionPage.tsx` imports neither directly today; if it now matches, move the import into a client-lane wrapper.)

- [ ] **Step 4: Track file.** Append to `docs/tracks/client-lane-multi-item.track.md` a `## Part D — verification code once per device` section (checklist W1–W5) and a session-log entry: plan path, Jeff answer, test counts per file (or "FAST MODE"), mutation results, rulings R-D8 and R-D10–R-D15, the tsc number, and "NOT done: Lark taxonomy rows (Daffa), manual phone + laptop pass, PR (awaits Jeff)".

- [ ] **Step 5: Commit.**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add docs/tracks/client-lane-multi-item.track.md && /usr/bin/git commit -m "$(printf 'docs(web): track KV approval requests Part D\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')"
```

- [ ] **Step 6: Hand-offs to Daffa (no action by the agent).** Report: (1) three PostHog taxonomy rows for Lark — `client_lane.code_requested {resend}`, `client_lane.code_verified {lane_kind}`, `client_lane.code_failed {stage, reason, http_status, attempts_left}`; (2) a manual pass on phone + laptop with the dev api: anonymous viewer → pin → Approve → code sheet → paste the code from the mail (Mailpit / log mailer) → decision lands with the pin; reload → "Verified as … · this device"; (3) R-D10 (OTPField instead of `input`) and R-D4 (`name` dropped) for Jeff/Daffa to confirm.

---

## Self-Review (done while writing)

- **Spec coverage (§7):** table → A2 Step 4; `POST public/lane/code` always 202 / throttled / 6-digit mail / invalidates previous → A2; `POST public/lane/code/verify` spend / personal hand-back / `verified_guest` 30 days / `invalid_code` + `attempts_left` / dead after 5 / `code_expired` → A3; gate on `purpose = approval` decisions, existing exception and code → A4; "looking, pins and comments never need a code" → A4 (comments POST unauthenticated in the pins tests); "named approvers on their personal link never see a code" → A4 personal-lane test; "verified guest stays advisory under required" → A4 advisory test; web `CodeSheet` (six boxes, paste, editable prefilled email, resend in 60s) → W3/W4; `POST /s/session` sets the cookie → W2 + W1 `persistLaneCookie`; draft resubmit (AC-14) → W5; summary line → W1 `verifiedSummary` + W5; analytics `code_requested` / `code_verified` / `code_failed{reason}` → W1; §11 rules → Global Constraints + W3/W4/W6 greps; §8 tests "D: …" and "the code sheet" → A2–A4, W3–W5.
- **Spec gaps resolved as rulings:** R-D1 (deferral gated, order), R-D3 (5th miss), R-D4 (`name`), R-D5 (HMAC), R-D6 (when a code is sent), R-D8 (`expires_at`), R-D9 (pins ownership — the spec's flow fails without it), R-D10 (OTPField), R-D12 (abandon), R-D13 ("30 days" only right after verifying).
- **Not covered, recorded for Daffa:** a verified guest's decisions are attributed by the email's local part unless the page sends `guest_name` (P0a behaviour, `PublicShareLinkController::actor()`), so the agency may read "dina" not "Dina Nasution"; the page's summary uses the name-gate name. Fixing attribution is a C-3 contract change outside Part D.
- **Type consistency:** `SendCodeResult`, `CodeVerifyOutcome`, `LaneCodeVerified`, `sendLaneCode`, `confirmLaneCode`, `verifiedSummary`, `sessionCookieFromBody`, `CodeInputProps`, `RESEND_SECONDS`, `identityLine`, `kvRequest`, `requestLink`, `sentCode`, `laneForProvenEmail`, `activePersonalLane`, `ClientVerificationCode::{generate,hashCode,live}` are spelled identically in every task that uses them.
