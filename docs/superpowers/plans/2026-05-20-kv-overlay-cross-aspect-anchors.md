# KV Overlay Cross-Aspect Anchors — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the alpha-preserving aspect transform in `web/src/lib/studio/kv/overlayAspect.ts` with an edge-anchor-inferring, pixel-size-preserving algorithm so overlays placed in craft mode stay visually consistent when viewed across resize-mode tiles of different aspect ratios.

**Architecture:** Single-file FE-only change. `transformOverlayForAspect(overlay, srcW, srcH, dstW, dstH)` signature stays the same; body is rewritten. Anchor classification is runtime-derived from `(x, y, w, h)` against a proximity threshold; no schema, store, or UI changes. Test file is updated to lock in new behavior; existing tests that codify old behavior are replaced with restated intents.

**Tech Stack:** TypeScript, Vitest, Bun. Pure functions over `StudioOverlay` value objects.

**Reference spec:** [docs/superpowers/specs/2026-05-20-kv-overlay-cross-aspect-anchors-design.md](../specs/2026-05-20-kv-overlay-cross-aspect-anchors-design.md)

---

## Task 1: Write failing tests for new behavior (TDD red)

**Files:**
- Modify: `web/src/lib/studio/kv/overlayAspect.test.ts`

Add new test cases that lock in the target algorithm. Existing tests stay untouched for now — some will fail after Task 2 lands; we'll replace them in Task 3.

- [ ] **Step 1: Add the new test block at the bottom of the existing `describe("transformOverlayForAspect", …)` block**

Append the following tests inside `describe("transformOverlayForAspect", () => { … })`, immediately after the existing `it("does not mutate the input overlay", …)` test:

```ts
  // ── New behavior: edge-anchor inference + pixel-size preservation ──

  it("preserves absolute pixel width across aspect change", () => {
    // 282px wide on source (0.3 × 940). Should be 282px on target too.
    const ov = makeOverlay({ width: 0.3 });
    const out = transformOverlayForAspect(ov, 940, 1700, 1200, 630);
    expect(out.width * 1200).toBeCloseTo(0.3 * 940, 3);
  });

  it("preserves absolute pixel height across aspect change", () => {
    // 282px tall on source (0.166 × 1700). Should be 282px on target too.
    const ov = makeOverlay({ height: 0.166 });
    const out = transformOverlayForAspect(ov, 940, 1700, 1200, 630);
    expect(out.height * 630).toBeCloseTo(0.166 * 1700, 3);
  });

  it("keeps a bottom-right anchored overlay flush with the new bottom-right corner", () => {
    // Overlay placed flush against right edge AND bottom edge of portrait.
    // w=0.3, h=0.166, x = 1 - w = 0.7, y = 1 - h = 0.834.
    const ov = makeOverlay({ x: 0.7, y: 0.834, width: 0.3, height: 0.166 });
    const out = transformOverlayForAspect(ov, 940, 1700, 1200, 630);
    expect(out.x + out.width).toBeCloseTo(1.0, 4);
    expect(out.y + out.height).toBeCloseTo(1.0, 4);
  });

  it("keeps a top-left anchored overlay flush with the new top-left corner", () => {
    const ov = makeOverlay({ x: 0, y: 0, width: 0.3, height: 0.166 });
    const out = transformOverlayForAspect(ov, 940, 1700, 1200, 630);
    expect(out.x).toBeCloseTo(0, 4);
    expect(out.y).toBeCloseTo(0, 4);
  });

  it("preserves a near-edge anchor's pixel-equivalent distance (right edge)", () => {
    // Overlay 5% from the right edge in shortest-edge units.
    // Source shortest = 940; 5% × 940 = 47px from right.
    // x = 1 - w - 47/940 = 1 - 0.3 - 0.05 = 0.65. Width 0.3.
    const ov = makeOverlay({ x: 0.65, y: 0.834, width: 0.3, height: 0.166 });
    const out = transformOverlayForAspect(ov, 940, 1700, 1200, 630);
    // Target shortest = 630; 5% × 630 = 31.5px from right.
    // out.x + out.width = 1 - 31.5/1200 = 0.97375.
    expect(out.x + out.width).toBeCloseTo(1 - (31.5 / 1200), 4);
  });

  it("keeps a centered overlay centered on the new canvas", () => {
    // Center-anchored on both axes — overlay far from any edge.
    const w = 0.3;
    const h = 0.166;
    const ov = makeOverlay({ x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h });
    const out = transformOverlayForAspect(ov, 940, 1700, 1200, 630);
    const centerX = out.x + out.width / 2;
    const centerY = out.y + out.height / 2;
    expect(centerX).toBeCloseTo(0.5, 5);
    expect(centerY).toBeCloseTo(0.5, 5);
  });

  it("mixes anchors: top edge + horizontally centered", () => {
    // y=0 → top-anchored. x = (1 - w)/2 → horizontally centered.
    const w = 0.3;
    const h = 0.166;
    const ov = makeOverlay({ x: (1 - w) / 2, y: 0, width: w, height: h });
    const out = transformOverlayForAspect(ov, 940, 1700, 1200, 630);
    expect(out.y).toBeCloseTo(0, 4);
    const centerX = out.x + out.width / 2;
    expect(centerX).toBeCloseTo(0.5, 5);
  });

  it("classifies an overlay at exactly the threshold as center-anchored", () => {
    // T = 0.08 in shortest-edge units. Place overlay so left_dist == T exactly.
    // shortest_src = 940; left_dist_units = (x * 940) / 940 = x → x = 0.08.
    // The comparison is `< T`, so exactly-at-threshold is NOT anchored — falls to center.
    const w = 0.2;
    const h = 0.166;
    const ov = makeOverlay({ x: 0.08, y: 0.5, width: w, height: h });
    const out = transformOverlayForAspect(ov, 940, 1700, 1200, 630);
    // Center-anchored: center_frac_x = 0.08 + 0.1 = 0.18 preserved as overlay center.
    const centerX = out.x + out.width / 2;
    expect(centerX).toBeCloseTo(0.18, 5);
  });

  it("does not clamp overlays that overflow the target canvas", () => {
    // 0.9 × 940 = 846px wide. On a 400px-wide target, new_w = 0.9 × (940/400) = 2.115.
    const ov = makeOverlay({ x: 0, y: 0, width: 0.9, height: 0.166 });
    const out = transformOverlayForAspect(ov, 940, 1700, 400, 300);
    expect(out.width).toBeGreaterThan(1);
  });

  it("preserves anchor on the orthogonal axis when one axis is centered", () => {
    // Bottom-anchored, horizontally centered.
    const w = 0.3;
    const h = 0.166;
    const ov = makeOverlay({ x: (1 - w) / 2, y: 1 - h, width: w, height: h });
    const out = transformOverlayForAspect(ov, 940, 1700, 1200, 630);
    expect(out.y + out.height).toBeCloseTo(1.0, 4);
    const centerX = out.x + out.width / 2;
    expect(centerX).toBeCloseTo(0.5, 5);
  });
```

- [ ] **Step 2: Run the new tests to confirm they fail (red phase)**

Run from the `web/` directory:

```bash
cd web && bun test src/lib/studio/kv/overlayAspect.test.ts 2>&1 | tail -40
```

Expected: the new tests fail with the OLD algorithm (most will produce wrong values; the threshold and corner tests will be most obviously off). At least the following should fail:
- `preserves absolute pixel width across aspect change` — width unchanged in old algorithm, so `out.width * 1200 = 360`, not 282.
- `keeps a bottom-right anchored overlay flush with the new bottom-right corner` — old algorithm doesn't touch x, so right edge drifts.
- `keeps a top-left anchored overlay flush with the new top-left corner` — y=0 case will pass (alpha=0), but x untouched at 0 also passes. This test might pass on the old algorithm; that's fine — it's a regression guard for the new one.
- `preserves a near-edge anchor's pixel-equivalent distance (right edge)` — fails.
- `mixes anchors: top edge + horizontally centered` — top edge passes (alpha=0), x untouched at center passes too. OK if it passes.
- `classifies an overlay at exactly the threshold as center-anchored` — old algorithm doesn't have thresholds. The center calc may coincidentally match for some setups; here x=0.08 stays 0.08 in old, so centerX = 0.18 — actually MATCHES our expected. So this test may pass on old algorithm. That's still OK; the test is a determinism guard against the new algorithm.

Don't be surprised if a few new tests pass on the old algorithm — the test suite still locks in correctness for the new one.

---

## Task 2: Replace `transformOverlayForAspect` body with new algorithm

**Files:**
- Modify: `web/src/lib/studio/kv/overlayAspect.ts`

- [ ] **Step 1: Read the current source file to confirm context**

```bash
cat web/src/lib/studio/kv/overlayAspect.ts
```

Note: the function currently spans lines 40–62. `resolveTileOverlays` (lines 71–83) calls it and stays unchanged.

- [ ] **Step 2: Replace the function body and update the docstring**

Replace the entire `transformOverlayForAspect` function (lines 40–62, including JSDoc) with:

```ts
/** Anchor-edge proximity threshold, in shortest-edge units (fraction).
 *  An overlay whose distance to an edge is < this value is treated as
 *  anchored to that edge. Tuned empirically: 0.08 means "within ~8% of
 *  the shorter canvas dimension is close enough to be flush." */
const ANCHOR_THRESHOLD = 0.08;

/**
 * Project an overlay from a source canvas onto a target canvas of
 * different aspect ratio, preserving the overlay's visual relationship
 * to the canvas (anchor edges, absolute pixel size).
 *
 * Algorithm:
 *   1. Width/height are scaled so the overlay keeps its source pixel
 *      dimensions (`w * srcW` and `h * srcH`). The overlay's own pixel
 *      aspect is preserved as a consequence.
 *   2. For each axis, classify the overlay as `left|right|center` (h) or
 *      `top|bottom|center` (v) based on proximity to the nearest edge,
 *      measured in shortest-edge units against {@link ANCHOR_THRESHOLD}.
 *   3. Anchored axes preserve the edge distance (in shortest-edge units)
 *      across the transform. Center-anchored axes preserve the overlay's
 *      center fraction (`x + w/2`).
 *
 * Anchor classification is stateless — derived purely from the overlay's
 * source-canvas coordinates. The same overlay state always classifies
 * the same way.
 *
 * No-ops (returns the input reference) when:
 *   - any dimension is non-positive (divide-by-zero guard),
 *   - source and target aspect ratios are equal within 1e-6 (overlay
 *     dimensions scale naturally with the canvas in normalized coords).
 *
 * Rotation is left untouched. Rotated overlays incur a small pivot
 * offset on aspect change because Konva rotates around the top-left
 * corner — the user can correct by dragging, same as before.
 */
export function transformOverlayForAspect(
  overlay: StudioOverlay,
  srcW: number,
  srcH: number,
  dstW: number,
  dstH: number,
): StudioOverlay {
  if (srcW <= 0 || srcH <= 0 || dstW <= 0 || dstH <= 0) return overlay;
  const aSrc = srcW / srcH;
  const aDst = dstW / dstH;
  if (Math.abs(aSrc - aDst) < 1e-6) return overlay;

  const { x, y, width: w, height: h } = overlay;

  // Pixel-preserve sizing.
  const newW = w * (srcW / dstW);
  const newH = h * (srcH / dstH);

  // Edge distances in shortest-edge units.
  const shortestSrc = Math.min(srcW, srcH);
  const shortestDst = Math.min(dstW, dstH);
  const leftDist = (x * srcW) / shortestSrc;
  const rightDist = ((1 - x - w) * srcW) / shortestSrc;
  const topDist = (y * srcH) / shortestSrc;
  const bottomDist = ((1 - y - h) * srcH) / shortestSrc;

  // Horizontal anchor + projection.
  let newX: number;
  if (leftDist < ANCHOR_THRESHOLD && leftDist <= rightDist) {
    newX = (leftDist * shortestDst) / dstW;
  } else if (rightDist < ANCHOR_THRESHOLD && rightDist < leftDist) {
    newX = 1 - newW - (rightDist * shortestDst) / dstW;
  } else {
    const centerFracX = x + w / 2;
    newX = centerFracX - newW / 2;
  }

  // Vertical anchor + projection.
  let newY: number;
  if (topDist < ANCHOR_THRESHOLD && topDist <= bottomDist) {
    newY = (topDist * shortestDst) / dstH;
  } else if (bottomDist < ANCHOR_THRESHOLD && bottomDist < topDist) {
    newY = 1 - newH - (bottomDist * shortestDst) / dstH;
  } else {
    const centerFracY = y + h / 2;
    newY = centerFracY - newH / 2;
  }

  return { ...overlay, x: newX, y: newY, width: newW, height: newH };
}
```

- [ ] **Step 3: Run the test file and verify NEW tests pass**

```bash
cd web && bun test src/lib/studio/kv/overlayAspect.test.ts 2>&1 | tail -50
```

Expected: All 10 new test cases pass. Several OLD tests will fail because they lock in the old algorithm (alpha-preserve and aspect-rescaled height). Specifically:

- `preserves pixel aspect when going portrait → landscape` — old expectation `height = 0.166 × (dstAspect/srcAspect)` no longer holds.
- `preserves pixel aspect when going landscape → portrait` — same.
- `preserves the overlay's fractional position in the canvas free-space` — alpha-preserve is gone.

These three are addressed in Task 3.

---

## Task 3: Update existing tests to reflect the new algorithm

**Files:**
- Modify: `web/src/lib/studio/kv/overlayAspect.test.ts`

The three failing existing tests asserted properties of the OLD algorithm. We replace them with restated intents that hold under the new algorithm. We do not delete the test intent (overlay's pixel aspect is still preserved; vertical position is still meaningful) — we update the assertions.

- [ ] **Step 1: Replace `preserves pixel aspect when going portrait → landscape`**

Find this test (around lines 37–51) and replace its body. The TITLE stays the same — overlay's pixel aspect IS still preserved, just via a different mechanism (pixel-preserve both axes ⇒ aspect preserved automatically). The assertion changes from checking the old formula to checking the property directly.

```ts
  it("preserves pixel aspect when going portrait → landscape", () => {
    // 940×1700 portrait source; overlay is square (282×282 → w=0.3, h=0.166).
    // Move to 1200×630 landscape: width/height become canvas-fraction values
    // that still resolve to 282×282 in pixels, keeping the square square.
    const ov = makeOverlay({ width: 0.3, height: 0.166 });
    const out = transformOverlayForAspect(ov, 940, 1700, 1200, 630);

    const pxW = out.width * 1200;
    const pxH = out.height * 630;
    expect(pxH / pxW).toBeCloseTo(1, 2); // square stays square
    // Pixel-preserve rule: pixel dimensions match source.
    expect(pxW).toBeCloseTo(0.3 * 940, 2);
    expect(pxH).toBeCloseTo(0.166 * 1700, 2);
  });
```

- [ ] **Step 2: Replace `preserves pixel aspect when going landscape → portrait`**

Find this test (around lines 53–62) and replace its body:

```ts
  it("preserves pixel aspect when going landscape → portrait", () => {
    // Mirror case: square overlay on 1200×630 landscape (w=0.3, h=0.571 → 360×360 px),
    // moved to 940×1700 portrait. Pixel-preserve keeps the overlay 360×360.
    const ov = makeOverlay({ width: 0.3, height: 0.571 });
    const out = transformOverlayForAspect(ov, 1200, 630, 940, 1700);

    const pxW = out.width * 940;
    const pxH = out.height * 1700;
    expect(pxH / pxW).toBeCloseTo(1, 2);
    expect(pxW).toBeCloseTo(0.3 * 1200, 2);
    expect(pxH).toBeCloseTo(0.571 * 630, 2);
  });
```

- [ ] **Step 3: Replace `preserves the overlay's fractional position in the canvas free-space`**

This test asserted the OLD alpha-preserve property. The new algorithm doesn't preserve alpha — it preserves center fraction (when center-anchored) or edge distance (when edge-anchored). Replace with a test that asserts the NEW property for the same input (overlay far from edges → center-anchored).

```ts
  it("preserves the overlay's center fraction when far from edges", () => {
    // y=0.2, h=0.166 → top_dist_units = 0.2*1700/940 = 0.362 (> threshold).
    // bottom_dist_units = (1-0.2-0.166)*1700/940 = 1.146 (> threshold).
    // → vertically center-anchored. center_frac_y = 0.2 + 0.083 = 0.283.
    const ov = makeOverlay({ y: 0.2, height: 0.166 });
    const out = transformOverlayForAspect(ov, 940, 1700, 1200, 630);
    const centerSrc = ov.y + ov.height / 2;
    const centerDst = out.y + out.height / 2;
    expect(centerDst).toBeCloseTo(centerSrc, 5);
  });
```

- [ ] **Step 4: Update `degrades gracefully when the source overlay is taller than the canvas`**

The existing test uses `y=0, h=1.5`. Under the new algorithm: `top_dist = 0` (anchored top), so `new_y = 0`. The test as-written still passes. **No change needed** — but verify in Step 5.

- [ ] **Step 5: Run the full test file and confirm all green**

```bash
cd web && bun test src/lib/studio/kv/overlayAspect.test.ts 2>&1 | tail -30
```

Expected: all tests pass (10 new + the original ones, three of which were just rewritten).

---

## Task 4: Run wider test suite to catch downstream regressions

**Files:** None modified — verification only.

- [ ] **Step 1: Run the broader KV test suite**

```bash
cd web && bun test src/lib/studio/kv/ src/components/studio/kv-generator/ 2>&1 | tail -40
```

Expected: all tests pass. Pay attention to `KvKonvaCanvas.overlays.test.tsx`, `KvResizeTileStage.test.tsx`, `KvResizeResultRow.test.tsx`, and `KvTileOverlayEditor.test.tsx` — they exercise the rendering pipeline that consumes transformed overlays.

If any test fails because it depended on the old transform numerically (rather than just rendering without throwing), evaluate whether the test was asserting a property that's no longer true. Update only those test cases — do not change the new algorithm.

- [ ] **Step 2: Run the full web test suite**

```bash
cd web && bun test 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 3: Type check**

```bash
cd web && bun run typecheck 2>&1 | tail -20
```

Expected: clean.

If `typecheck` is not a defined npm script, run TypeScript directly:

```bash
cd web && bunx tsc --noEmit 2>&1 | tail -20
```

---

## Task 5: Commit everything

**Files:** No new edits — staging and commit only.

- [ ] **Step 1: Confirm what's about to be committed**

```bash
git status
git diff --stat docs/superpowers/specs/2026-05-20-kv-overlay-cross-aspect-anchors-design.md docs/superpowers/plans/2026-05-20-kv-overlay-cross-aspect-anchors.md web/src/lib/studio/kv/overlayAspect.ts web/src/lib/studio/kv/overlayAspect.test.ts
```

Expected staged set: the spec, the plan, the source file, and the test file. If other files appear (e.g., test snapshot updates), inspect them — they should be intentional consequences of the algorithm change.

- [ ] **Step 2: Stage and commit**

Stage only the four files relevant to this change. Do not use `git add .` or `-A` — the workspace has other untracked files (PRDs, tracks) that belong to other features.

```bash
git add docs/superpowers/specs/2026-05-20-kv-overlay-cross-aspect-anchors-design.md \
        docs/superpowers/plans/2026-05-20-kv-overlay-cross-aspect-anchors.md \
        web/src/lib/studio/kv/overlayAspect.ts \
        web/src/lib/studio/kv/overlayAspect.test.ts

git commit -m "$(cat <<'EOF'
feat(web): pixel-preserve + edge-anchor inference for KV overlay aspect transform

Replace the alpha-preserve algorithm in transformOverlayForAspect with
proximity-based edge-anchor inference plus absolute pixel-size preservation,
so overlays placed in craft mode stay visually consistent (corner-locked
overlays stay corner-locked; logos keep their absolute pixel size) when
viewed across resize-mode tiles of different aspect ratios.

No schema changes, no API contract change, no UI affordances. Project
overlays without tile snapshots will reposition on next render; tile
snapshots (per-tile edited overlays) are unaffected.

Spec: docs/superpowers/specs/2026-05-20-kv-overlay-cross-aspect-anchors-design.md
Plan: docs/superpowers/plans/2026-05-20-kv-overlay-cross-aspect-anchors.md
EOF
)"
```

- [ ] **Step 3: Verify commit**

```bash
git log -1 --stat
```

Expected: one new commit containing exactly the four files.
