# KV Motion editor — KV design language Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the KV motion timeline editor so it reads as the same product as KV Studio — dot-grid canvas, transparent top nav with floating pills, and floating side panels — without changing any motion behaviour.

**Architecture:** Every change lands in the shell section of a single file, `KvMotionEditor.tsx` lines 820–1057. The root becomes KV's dot-grid canvas, the top bar becomes a `fixed` transparent row of pills, and the rail and inspector become floating cards while the stage keeps `flex-1` so it is never occluded. The timeline dock is only given a gutter — its own file is not touched.

**Tech Stack:** Next.js 16 / React 19, Tailwind, Zustand (`useAppearanceStore`), Bun test runner.

**Spec:** `docs/superpowers/specs/2026-08-03-kv-motion-page-kv-design-language-design.md`

## Global Constraints

- **Only one file may be modified:** `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx`. Do **not** edit `TimelineDock.tsx`, `BlockTrackRow.tsx`, `TrackRow.tsx`, `Transport.tsx`, `TimelineRuler.tsx`, `InspectorPanel.tsx`, `presets.ts`, or `useMotionEditorState.ts` — they are under active edit in a parallel session and any change there will conflict.
- **This is a `className` / inline-`style` change only.** No handler, prop, hook order, state, or JSX element may be added or removed except the wrapper `<div>`s this plan names explicitly.
- **Preserve every accessibility hook verbatim.** After each task these two commands must return exactly the lists below — that is the regression gate for this plan, since no test renders this component.

  ```bash
  cd web && grep -o 'data-testid="[^"]*"' \
    src/components/studio/kv-generator/motion/KvMotionEditor.tsx | sort -u
  ```
  ```
  data-testid="motion-preview-wrapper"
  data-testid="motion-save-indicator"
  ```

  ```bash
  cd web && grep -o 'aria-label="[^"]*"' \
    src/components/studio/kv-generator/motion/KvMotionEditor.tsx | sort -u
  ```
  ```
  aria-label="More actions"
  aria-label="Motion project actions"
  aria-label="Preset for stagger"
  aria-label="Preview ratio"
  ```

  (The rail's `aria-label={\`Apply motion preset to ${trackName}\`}` is a template literal and does not appear in the static grep. It lives in `TrackPresetMenu`, which this plan does not touch.)
- **Dot-grid values are copied verbatim from KV** (`KvGeneratorLayout.tsx:4037–4042`): midnight background `#0E0E0E` with dots `rgba(255,255,255,0.08)`; aurora background `transparent` with dots `rgba(255,255,255,0.22)`; `backgroundSize: "20px 20px"`; `backgroundPosition: "0 0"`.
- **Floating-card treatment is copied verbatim from the in-KV motion panel** (`KvMotionPanel.tsx:90`): `frndos-float-panel` + `shadow-[0_24px_48px_rgba(0,0,0,0.4)]` + `backdrop-blur-[20px]`.
- **Gutter is 12px everywhere** (`px-3` / `pb-3` / `gap-3`), so the side cards, the stage, and the dock all share one rhythm.
- `bun run build` is the real gate for this repo (it is what type-checks); `bun test` is the unit gate. There is **no** `test` script in `package.json` — run the binary directly.

## Why there are no new unit tests

No test file renders `KvMotionEditor` — the motion suites all target hooks and pure helpers (`useMotionEditorState.test.ts`, `applyTimeline.test.ts`, `exportMotion.test.ts`, `KvMotionAudioRow.*`). Standing up a render harness for an 1100-line component that builds a Konva stage in a ref and reads React Query would cost far more than the change it guards, and would be brittle mocking rather than a real behaviour test.

The genuine risk in this plan is **dropping an `aria-label` or `data-testid` while re-wrapping the top bar** (Task 3). The grep invariant in Global Constraints tests exactly that risk, runs in a second, and cannot pass falsely. Each task therefore verifies with: grep invariant → `eslint` → `bun test` → (final task) `bun run build`.

## File Structure

- **Modify:** `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx`
  - import block (~line 51) — add the appearance store
  - `MotionEditorCanvas` hook block (~line 293) — read the theme
  - JSX shell, lines 820–1057 — root, top bar, body row, rail, stage, inspector, dock wrapper

No files are created. No other file is modified.

---

### Task 1: Root shell becomes the KV dot-grid canvas

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx:51` (imports), `:294` (hook), `:821` (root element)

**Interfaces:**
- Consumes: `useAppearanceStore` from `@/store/useAppearanceStore` — a Zustand store; `useAppearanceStore((s) => s.theme)` returns the appearance theme string, `"aurora"` for the aurora theme. Same selector KV uses at `KvGeneratorLayout.tsx:359`.
- Produces: `isAurora: boolean` in `MotionEditorCanvas` scope — Tasks 2 and 3 do **not** need it (the aurora variants for panels and pills come from the existing `[data-theme="aurora"]` CSS rules on `.frndos-float-panel`), so nothing else depends on it.

- [ ] **Step 1: Add the store import**

In the `@/` import group, between the `@/services/kv/motionProjects` import and the `@/types/kv/motionProject` import (this keeps the file's existing `services` → `store` → `types` ordering):

```tsx
import { useAppearanceStore } from "@/store/useAppearanceStore";
```

- [ ] **Step 2: Read the theme in `MotionEditorCanvas`**

`MotionEditorCanvas` begins at line 282; its hook block starts at line 293 with `const qc = useQueryClient();`. Add the selector immediately after `const state = useMotionEditorState(project);` (line 294). It must sit in the hook block — `MotionEditorCanvas` has no early return before the JSX, but keeping it with the other hooks preserves that guarantee:

```tsx
  // KV Studio's canvas is appearance-theme aware (KvGeneratorLayout.tsx:359);
  // the motion editor matches it so switching to aurora doesn't leave this
  // page as the only dark surface in the app.
  const isAurora = useAppearanceStore((s) => s.theme) === "aurora";
```

- [ ] **Step 3: Repaint the root element**

Replace the root opening tag at line 821:

```tsx
    <div className="bg-app flex h-screen flex-col font-geist text-text-inverse">
```

with:

```tsx
    <div
      className="relative flex h-screen w-screen flex-col overflow-hidden font-geist text-text-inverse"
      style={{
        // Dot-grid workspace — the same values KV Studio's canvas uses
        // (KvGeneratorLayout.tsx), so the two surfaces read as one product.
        // Aurora: transparent so the body gradient shows through, brighter dots.
        backgroundColor: isAurora ? "transparent" : "#0E0E0E",
        backgroundImage: isAurora
          ? "radial-gradient(circle, rgba(255,255,255,0.22) 1px, transparent 1px)"
          : "radial-gradient(circle, rgba(255,255,255,0.08) 1px, transparent 1px)",
        backgroundSize: "20px 20px",
        backgroundPosition: "0 0",
      }}
    >
```

`bg-app` is dropped (the inline background replaces it). `flex flex-col` is **kept** — unlike KV, whose canvas has no in-flow children, this column is what stacks the body row above the docked timeline, and Task 4 depends on the dock being its last child.

- [ ] **Step 4: Run the accessibility invariant**

Run both grep commands from Global Constraints.
Expected: the two lists match exactly. (Nothing in this task touches a label; this establishes the baseline you will re-check after Task 3.)

- [ ] **Step 5: Lint and test**

```bash
cd web && bunx eslint src/components/studio/kv-generator/motion/KvMotionEditor.tsx
cd web && bun test src/components/studio/kv-generator/motion/
```
Expected: eslint clean; motion suites pass. If a motion suite was already failing before you started, note the baseline and confirm you did not add to it — do not "fix" unrelated reds.

- [ ] **Step 6: Commit**

```bash
git add web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx
git commit -m "feat(web): paint the motion editor on KV's dot-grid canvas"
```

---

### Task 2: Rail and inspector become floating cards

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx:950` (body row), `:952` (rail), `:993` (stage), `:1010` (inspector)

**Interfaces:**
- Consumes: nothing from Task 1 beyond the repainted root — the cards must sit on the dot grid to look right, which is why this task follows it.
- Produces: the body row's spacing classes (`gap-3 px-3 pb-3`). Task 3 adds `pt-20` to this same element; Task 4 matches its `px-3 pb-3` on the dock wrapper.

This task deliberately leaves the top bar in flow. The page stays usable at every step — the cards are correct here, and only Task 3 lifts the bar out of flow.

- [ ] **Step 1: Give the body row its gutters**

Line 950 is already `flex min-h-0 flex-1` — keep both (`min-h-0` is what stops a tall track list from squeezing the dock). Add spacing only:

```tsx
      <div className="flex min-h-0 flex-1 gap-3 px-3 pb-3">
```

- [ ] **Step 2: Turn the left rail into a card**

Line 952, replace:

```tsx
        <div className="frndos-float-panel w-56 shrink-0 overflow-y-auto border-r border-border-default">
```

with:

```tsx
        <div className="frndos-float-panel w-56 shrink-0 overflow-y-auto rounded-2xl border border-border-default shadow-[0_24px_48px_rgba(0,0,0,0.4)] backdrop-blur-[20px]">
```

`border-r` becomes a full `border` — the card is no longer a column divider.

- [ ] **Step 3: Let the dot grid show through the stage**

Line 993, replace:

```tsx
        <div className="bg-app-canvas flex flex-1 items-center justify-center overflow-hidden p-6">
```

with:

```tsx
        <div className="flex flex-1 items-center justify-center overflow-hidden p-6">
```

Only `bg-app-canvas` is dropped. `flex-1` **must** stay — it is what makes the stage occupy exactly the space between the two cards, which is the whole reason the preview can never be covered (spec decision D2). Leave the `editingInTime` ring at line 999 untouched.

- [ ] **Step 4: Turn the right inspector into a card**

Line 1010, replace:

```tsx
        <div className="frndos-float-panel w-72 shrink-0 overflow-y-auto border-l border-border-default">
```

with:

```tsx
        <div className="frndos-float-panel w-72 shrink-0 overflow-y-auto rounded-2xl border border-border-default shadow-[0_24px_48px_rgba(0,0,0,0.4)] backdrop-blur-[20px]">
```

`overflow-y-auto` stays here: `InspectorPanel`'s own root is `flex flex-col gap-3 p-4` (`InspectorPanel.tsx:110`) with no height of its own, so scrolling belongs to this wrapper.

- [ ] **Step 5: Run the accessibility invariant**

Run both grep commands from Global Constraints.
Expected: unchanged lists.

- [ ] **Step 6: Lint and test**

```bash
cd web && bunx eslint src/components/studio/kv-generator/motion/KvMotionEditor.tsx
cd web && bun test src/components/studio/kv-generator/motion/
```
Expected: eslint clean; motion suites pass.

- [ ] **Step 7: Commit**

```bash
git add web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx
git commit -m "feat(web): float the motion rail and inspector over the canvas"
```

---

### Task 3: Top bar becomes a transparent row of floating pills

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx:823–947` (the bar), `:950` (body top offset)

**Interfaces:**
- Consumes: the body row from Task 2 — this task adds `pt-20` to that same element.
- Produces: nothing consumed later; Task 4 is independent.

This is the highest-risk task in the plan: it re-wraps six control clusters, and dropping an `aria-label` or `data-testid` in the process is exactly the regression the grep invariant exists to catch. **Move the existing JSX, do not retype it.**

The bar becomes `fixed`, which removes it from the flow — so the body offset in Step 3 is part of this task, not a later one. Skipping it leaves the rail and inspector sliding under the pills.

- [ ] **Step 1: Replace the bar's opening and closing wrappers**

Line 823, replace the opening tag:

```tsx
      <div className="frndos-panel-header flex items-center gap-3 border-b border-border-default px-4 py-3 backdrop-blur-[16px]">
```

with the KV pattern — a `pointer-events-none` fixed row whose children opt back in (mirrors `KvGeneratorLayout.tsx:4256`):

```tsx
      {/* Floating top nav — overlays the canvas. Like KV Studio's own top nav,
          the row itself has no background; its child pills float over the dot
          grid (KvGeneratorLayout.tsx:4247). */}
      <div className="pointer-events-none fixed inset-x-0 top-0 z-40 flex items-center gap-3 px-3 py-3">
```

`frndos-panel-header`, `border-b`, and the old padding all go. The matching `</div>` at line 947 stays where it is.

- [ ] **Step 2: Group the two halves into pills**

**Left pill** — wrap the existing `<Link>` (line 824), the divider (line 830), and the project name (line 831) in a pill. Keep all three children byte-for-byte:

```tsx
        <div className="frndos-float-panel pointer-events-auto flex items-center gap-3 rounded-full border border-border-default px-3 py-1.5 shadow-[0_24px_48px_rgba(0,0,0,0.4)] backdrop-blur-[20px]">
          {/* existing <Link href={backHref}> … </Link> */}
          {/* existing <div className="h-4 w-px bg-border-default" /> */}
          {/* existing <p className="truncate text-textSmMedium">{project.name}</p> */}
        </div>
```

**Right side** — line 833 is already `<div className="ml-auto flex items-center gap-3">`. Add `pointer-events-auto` to it:

```tsx
        <div className="pointer-events-auto ml-auto flex items-center gap-3">
```

Then upgrade its three existing cluster wrappers to pill surfaces, changing **only** the wrapper `className` and leaving every child untouched:

- line 834, the preset + Stagger cluster:
  ```tsx
          <div className="frndos-float-panel flex items-center gap-1.5 rounded-full border border-border-default px-2 py-1 shadow-[0_24px_48px_rgba(0,0,0,0.4)] backdrop-blur-[20px]">
  ```
- line 880, the ratio group — **keep `role="group"` and `aria-label="Preview ratio"` exactly as they are**, change only the class:
  ```tsx
          <div
            role="group"
            aria-label="Preview ratio"
            className="frndos-float-panel flex items-center gap-1 rounded-full border border-border-default p-1 shadow-[0_24px_48px_rgba(0,0,0,0.4)] backdrop-blur-[20px]"
          >
  ```
- the Export button (line 897), the save indicator (line 912, `data-testid="motion-save-indicator"`), and the `⋮` popover (line 924) have no shared wrapper today. Wrap those three — and only those three — in one pill so they read as a single control group:
  ```tsx
          <div className="frndos-float-panel flex items-center gap-2 rounded-full border border-border-default px-2 py-1 shadow-[0_24px_48px_rgba(0,0,0,0.4)] backdrop-blur-[20px]">
            {/* existing Export <Button> … */}
            {/* existing <span data-testid="motion-save-indicator"> … */}
            {/* existing <Popover open={menuOpen}> … */}
          </div>
  ```

- [ ] **Step 3: Offset the body so it clears the pills**

The bar is now `fixed` and out of flow. On the body row from Task 2 (line 950), add `pt-20` — 80px, which is the ~56px pill row plus the 12px gap above and below it:

```tsx
      <div className="flex min-h-0 flex-1 gap-3 px-3 pb-3 pt-20">
```

- [ ] **Step 4: Run the accessibility invariant — this is the real gate**

Run both grep commands from Global Constraints.

Expected, exactly:
```
data-testid="motion-preview-wrapper"
data-testid="motion-save-indicator"
```
```
aria-label="More actions"
aria-label="Motion project actions"
aria-label="Preset for stagger"
aria-label="Preview ratio"
```

A missing entry means a control was dropped or a label lost during the re-wrap. Fix it before continuing — do not proceed on a shortened list.

- [ ] **Step 5: Lint and test**

```bash
cd web && bunx eslint src/components/studio/kv-generator/motion/KvMotionEditor.tsx
cd web && bun test src/components/studio/kv-generator/motion/
```
Expected: eslint clean (watch for an unclosed-tag parse error here — this task moves JSX wrappers); motion suites pass.

- [ ] **Step 6: Commit**

```bash
git add web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx
git commit -m "feat(web): float the motion top nav as KV-style pills"
```

---

### Task 4: Give the timeline dock its gutter

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx:1021–1057` (the `<TimelineDock>` call site)

**Interfaces:**
- Consumes: the `px-3 pb-3` rhythm established in Task 2.
- Produces: nothing.

`TimelineDock`'s own root is already `rounded-2xl border border-border-default bg-app-panel` (`TimelineDock.tsx:71`) — it was authored as a card, but rendering it flush against the viewport edge means the rounding never reads. Wrapping the call site fixes that with **zero edits to `TimelineDock.tsx`**, which is what keeps this plan clear of the parallel session's work.

- [ ] **Step 1: Wrap the call site**

Wrap the entire `<TimelineDock … />` element (lines 1021–1057, from `<TimelineDock` through its closing `/>`) in a padded container, indenting the element one level:

```tsx
      <div className="px-3 pb-3">
        <TimelineDock
          {/* …every existing prop, unchanged… */}
        />
      </div>
```

Do not add, remove, or reorder a single prop — `audioSlot` in particular carries a whole `<KvMotionAudioRow>` element.

- [ ] **Step 2: Run the accessibility invariant**

Run both grep commands from Global Constraints.
Expected: unchanged lists.

- [ ] **Step 3: Lint and test**

```bash
cd web && bunx eslint src/components/studio/kv-generator/motion/KvMotionEditor.tsx
cd web && bun test src/components/studio/kv-generator/motion/
```
Expected: eslint clean; motion suites pass.

- [ ] **Step 4: Run the full build — the real gate**

```bash
cd web && bun run build
```
Expected: build succeeds. This is the type-check for this repo; `bun test` alone will not catch a broken JSX type. Run it here rather than after every task because it is slow — but do not skip it.

- [ ] **Step 5: Run the full unit suite for regressions**

```bash
cd web && bun test
```
Expected: no new failures versus the baseline you recorded in Task 1. This repo has known pre-existing reds — compare, do not chase.

- [ ] **Step 6: Commit**

```bash
git add web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx
git commit -m "feat(web): let the motion timeline dock read as a floating card"
```

---

## Manual verification (after Task 4)

Automated checks cannot see the thing this plan is actually about. Run the app and look:

1. `cd web && bun dev`, open a motion project at
   `/brands/<id>/studio/kv-generator/<file_id>/motion/<projectId>`.
   The editor is behind the `KV_MOTION_EDITOR` experimental flag
   (`page.tsx:32`) — if the page redirects to the KV editor, the flag is off
   for your workspace and nothing is wrong with the restyle.
2. **Midnight:** dot grid runs edge to edge and behind the top pills; rail,
   inspector, and dock read as three separate floating cards; preview is fully
   visible.
3. **Aurora:** switch the appearance theme. Background goes transparent to the
   body gradient, dots brighten, and the panels pick up the indigo glass from
   the existing `[data-theme="aurora"] .frndos-float-panel` rule.
4. **Narrow window:** shrink to ~1100px. The stage must shrink between the two
   cards, never disappear underneath them — this is spec decision D2 and the
   single most important thing to eyeball.
5. **Controls still work:** Back, preset + Stagger, ratio switch, Export dialog,
   `⋮` → Resync, and the save indicator all behave as before.

> **While you are testing in the browser, no agent should be editing these
> files.** Mid-edit saves plus HMR produce phantom `ReferenceError`s that look
> like real bugs. If something looks broken, check `git status` before believing
> it.

## Self-review notes

- **Spec coverage:** §1 root canvas → Task 1. §2 transparent pill top bar → Task 3. §3 floating rail/inspector + stage reserving space → Task 2. §4 dock gutter → Task 4. Aurora support → Task 1 (canvas) plus the existing CSS rules the card classes pick up in Tasks 2–3. Verification section → Task 4 Steps 4–5 plus Manual verification.
- **Spec correction folded in:** the spec asks for the body row to be `min-h-0 flex-1`; it already is (`:950`), so Task 2 Step 1 preserves it rather than adding it.
- **Ordering rationale:** Task 3 comes after Task 2 because making the bar `fixed` requires the body offset in the same task; doing it earlier would leave a broken intermediate state at a commit boundary.
- **Class consistency:** the floating-card triple (`frndos-float-panel` + `shadow-[0_24px_48px_rgba(0,0,0,0.4)]` + `backdrop-blur-[20px]`) is written identically in Tasks 2 and 3; the gutter is `px-3` / `pb-3` / `gap-3` in Tasks 2, 3, and 4.
