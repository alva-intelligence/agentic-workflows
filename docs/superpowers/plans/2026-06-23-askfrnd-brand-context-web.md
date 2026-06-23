# Brand-Aware AskFrnd — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure the web client sends enough location signal (`origin_brand_id` / `origin_brand_name` / `origin_path`) on the first message of both AskFrnd surfaces so the API can resolve Condition A (active brand) vs Condition B (Home directory). No deep brand data is sent from web.

**Architecture:** The API derives `active_brand` / `brand_directory` itself from `origin_brand_id` + the authenticated user. Web's only responsibility is to keep sending the origin signal it already sends. This plan is **verification-first**; it only adds code if a gap is found.

**Tech Stack:** Next.js 16, React 19, TypeScript, Zustand, TanStack Query, Bun.

**Spec:** `docs/superpowers/specs/2026-06-23-askfrnd-brand-context-awareness-design.md`

**Sibling plans:** `2026-06-23-askfrnd-brand-context-api.md`, `2026-06-23-askfrnd-brand-context-ai-service.md`

**Test/build:** `cd web && bun test <path>` for unit; the real gate is `cd web && bun run build`.

---

## Why web is light
The API resolves location context from `origin_brand_id` + the authenticated user/workspace (see the api plan). Follow-up turns read the persisted `origin_brand_id` from the thread server-side, so web does **not** need to resend it per turn. Web only needs to send origin context on the **first** message of each surface — which it already does via `getUrlBrandId()` and the `origin_brand_id/name/path` fields. These tasks confirm that and fix only if broken.

---

## Task 1: Verify main-chat sends origin context

**Files (read-only inspection):**
- `web/src/services/mutate.ts` (`mutateCreateThread` — `origin_brand_id/name/path` FormData fields)
- The store action that calls it (`createNewChatWithMessageStream`)
- `web/src/hooks/useUrlBrandId.ts`

- [ ] **Step 1: Confirm the fields are sent**

Run: `cd web && grep -n "origin_brand_id\|origin_brand_name\|origin_path" src/services/mutate.ts`
Expected: shows the three FormData appends inside `mutateCreateThread`.

- [ ] **Step 2: Confirm the brand id is derived from the URL**

Run: `cd web && grep -rn "getUrlBrandId\|originBrandId" src/store src/components/chat src/components/base | head`
Expected: shows `originBrandId` resolved via `getUrlBrandId(pathname)` (null on `/home`) and passed into the create-thread call.

- [ ] **Step 3: Record the result**

If both confirm → main chat is correct, no change. Note it in the track file and move to Task 2.
If a field is missing → add it to `mutateCreateThread`'s FormData exactly like the existing `paa_context` append, sourcing `originBrandId` from `getUrlBrandId(window.location.pathname)`. Then re-run Step 1.

---

## Task 2: Verify PAA sends origin context

**Files (read-only inspection):**
- `web/src/components/base/AskFRNDButton.tsx`
- The PAA store action (`sendPAAMessage`)

- [ ] **Step 1: Confirm PAA forwards origin context**

Run: `cd web && grep -n "originBrandId\|origin_brand_id\|getUrlBrandId\|captureOriginContext" src/components/base/AskFRNDButton.tsx`
Expected: PAA resolves the current brand from route params / `useBrandStore` and passes `originBrandId/Name/Path` into the same create-thread stream path used by main chat.

- [ ] **Step 2: Record the result**

If confirmed → PAA is correct, no change.
If missing → mirror the main-chat origin capture (`getUrlBrandId(pathname)` + brand name from the brands query cache) and pass it through the PAA send path. Re-run Step 1.

---

## Task 3: Build gate

- [ ] **Step 1: Type-check + build**

Run: `cd web && bun run build`
Expected: build succeeds with no type errors. (No runtime behavior changed unless a gap was fixed in Task 1/2.)

- [ ] **Step 2: Commit only if code changed**

```bash
cd web && git diff --quiet || (git add -A && git commit -m "fix(web): ensure AskFrnd origin brand context is sent on first message")
```

If nothing changed, record "web already sends origin context — no change needed" in the track file and skip the commit.

---

## Notes for the implementer
- Do NOT push or open a PR — Daffa pushes manually.
- This plan intentionally adds the least code possible. If Tasks 1–2 both confirm existing behavior, web is a no-op and the feature works end-to-end via api + ai-service.
- No new PostHog event is required: brand awareness changes the *content* of answers, not the set of user interactions. If product later wants a "brand_context_used" signal, that belongs on the server (ai-service emits when the tool fires), not a new web interaction.
- Manual end-to-end check (after all three services are running): inside a brand → ask "what's our brand tone?" (should pull internal knowledge); on Home → ask "translate this: ..." (should NOT fetch brand); on Home → ask about a named brand (should fetch that brand); ask a follow-up brand question (should reuse cached context — confirm via ai-service logs showing no second DB read).
