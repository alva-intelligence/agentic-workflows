# KV text style runs — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one KV text overlay mix font families, weights and styles across ranges of its own string, rendered identically by the Fabric canvas, the Konva stage (Motion + public share page), and every export.

**Architecture:** A pure model module (`textRuns.ts`) owns the run list, normalization, and all mutations. A pure layout module (`textRunLayout.ts`) wraps styled runs to a box width. Fabric renders through its native per-character `styles`; Konva renders through one custom `Konva.Shape` built on the layout module. Overlays with no runs never enter the new path.

**Tech Stack:** TypeScript, React, Fabric v7, Konva v10, `bun test`.

**Spec:** `docs/superpowers/specs/2026-09-09-kv-text-style-runs-design.md`

**Worktree:** `web/.worktrees/kv-text-runs` on branch `feature/daffa/vc-kv-text-runs` (deps installed).

## Global Constraints

- **Run the API plan first** (`2026-09-09-kv-text-style-runs-api.md`). Until `payload.runs` is whitelisted, `validated()` strips it and nothing persists.
- Per-run properties are `fontFamily`, `fontWeight`, `fontStyle`. Nothing else. No per-run colour, size, or letter spacing.
- `runs` goes on the `type: "text"` arm of `StudioOverlay["payload"]` **only** — never on `BrandOverlayPreset["overlays"][n]["payload"]` (same file, further down).
- Tests run with `bun test <file path>`. Never `bun test <directory>` — it blows past 20 GB of memory on this repo. Never let one test file exceed ~51 KB; past that `bun test` dies with a bogus SCSS error naming `base.module.scss`.
- `bun run build` is broken in this repo; use `node` (see `lesson_web_bun_run_build_broken_use_node`). There is no type gate: `tsc` has a large pre-existing error baseline, so compare against a baseline worktree rather than expecting zero.
- Never `git stash`. Use a WIP commit to set work aside.
- `MAX_RUNS = 200`, matching the API cap.

## File Structure

| File | Responsibility |
|---|---|
| `src/types/studio.ts` (modify) | `TextStyleRun` type + `runs?` on the text payload |
| `src/components/studio/kv-generator/overlays/textRuns.ts` (create) | the model: normalize, resolve spans, index conversion, all mutations |
| `src/components/studio/kv-generator/overlays/textRunLayout.ts` (create) | engine-agnostic word wrap + span positioning |
| `src/components/studio/kv-generator/overlays/konvaRunText.ts` (create) | imperative `Konva.Shape` adapter over the layout, plus measurement and fill resolution |
| `src/components/studio/kv-generator/overlays/KonvaRunText.tsx` (create) | react-konva twin of the same node, for the two JSX editors |
| `src/components/studio/kv-generator/renderBoardStage.ts` (modify) | Konva draw site — Motion + share page |
| `src/components/studio/kv-generator/fabricExport.ts` (modify) | Fabric shared builder — export, Resize tile, unified canvas |
| `src/components/studio/kv-generator/KvFabricCanvas.tsx` (modify) | live Craft canvas + selection reporting |
| `src/components/studio/kv-generator/overlays/overlayStyleSignature.ts` (modify) | make run changes repaint |
| `src/components/studio/kv-generator/overlays/TextTypographyControls.tsx` (modify) | mixed-state display |
| `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (modify) | route panel patches to range or layer |
| `src/components/studio/kv-generator/KvKonvaCanvas.tsx` (modify) | Konva draw site + textarea commit + auto-fit |
| `src/components/studio/kv-generator/KvTileOverlayEditor.tsx` (modify) | Konva draw site + textarea commit + auto-fit |

---

### Task 1: The run model — normalization and spans

**Files:**
- Modify: `src/types/studio.ts`
- Create: `src/components/studio/kv-generator/overlays/textRuns.ts`
- Test: `src/components/studio/kv-generator/overlays/textRuns.test.ts`

**Interfaces:**
- Consumes: `resolveDisplayText` from `./textProps`, `resolveOverlayFamily` from `../fonts/resolveFamily`.
- Produces: `TextStyleRun`, `RunSpan`, `normalizeRuns(content, runs)`, `resolveRunSpans(payload)`, `displayIndexToContent(spans, i)`, `MAX_RUNS`.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/overlays/textRuns.test.ts`:

```ts
import { describe, it, expect } from "bun:test";
import { normalizeRuns, resolveRunSpans, displayIndexToContent } from "./textRuns";
import type { StudioOverlay } from "@/types/studio";

type TextPayload = Extract<StudioOverlay["payload"], { type: "text" }>;

const text = (p: Partial<TextPayload>): TextPayload => ({
  type: "text",
  content: "Hello world",
  color: "#ffffff",
  ...p,
});

describe("normalizeRuns", () => {
  it("appends an unstyled remainder when the runs are short", () => {
    expect(normalizeRuns("Hello world", [{ length: 5, fontWeight: "bold" }])).toEqual([
      { length: 5, fontWeight: "bold" },
      { length: 6 },
    ]);
  });

  it("truncates runs that overrun the content", () => {
    expect(normalizeRuns("Hi", [{ length: 99, fontStyle: "italic" }])).toEqual([
      { length: 2, fontStyle: "italic" },
    ]);
  });

  it("drops non-positive and non-finite lengths", () => {
    expect(normalizeRuns("Hi", [{ length: 0 }, { length: -3 }, { length: 2, fontWeight: "bold" }]))
      .toEqual([{ length: 2, fontWeight: "bold" }]);
  });

  it("returns nothing for empty content", () => {
    expect(normalizeRuns("", [{ length: 4 }])).toEqual([]);
  });
});

describe("resolveRunSpans", () => {
  it("returns null when no run overrides anything (the legacy path)", () => {
    expect(resolveRunSpans(text({}))).toBeNull();
    expect(resolveRunSpans(text({ runs: [] }))).toBeNull();
    expect(resolveRunSpans(text({ runs: [{ length: 5 }, { length: 6 }] }))).toBeNull();
  });

  it("resolves each span against the layer defaults", () => {
    const spans = resolveRunSpans(
      text({ fontWeight: "normal", runs: [{ length: 5, fontWeight: "bold" }] })
    )!;
    expect(spans).toHaveLength(2);
    expect(spans[0]).toMatchObject({ text: "Hello", contentStart: 0, contentLength: 5, fontWeight: "bold" });
    expect(spans[1]).toMatchObject({ text: " world", contentStart: 5, contentLength: 6, fontWeight: "normal" });
  });

  it("applies the case transform PER RUN, so display offsets stay aligned", () => {
    const spans = resolveRunSpans(
      text({ textTransform: "uppercase", runs: [{ length: 5, fontWeight: "bold" }] })
    )!;
    expect(spans.map((s) => s.text)).toEqual(["HELLO", " WORLD"]);
    expect(spans[1].displayStart).toBe(5);
  });

  it("applies paragraph spacing per run without shifting later runs off their own text", () => {
    const spans = resolveRunSpans(
      text({
        content: "a\nb",
        fontSize: 0.1,
        lineHeight: 1,
        paragraphSpacing: 0.1,
        runs: [{ length: 2, fontWeight: "bold" }],
      })
    )!;
    // The run owning the "\n" carries the injected blank line; the next run's
    // display text is untouched.
    expect(spans[0].text).toBe("a\n\n");
    expect(spans[1].text).toBe("b");
    expect(spans[1].displayStart).toBe(spans[0].displayLength);
  });
});

describe("displayIndexToContent", () => {
  it("is the identity when the transform preserves length", () => {
    const spans = resolveRunSpans(
      text({ textTransform: "uppercase", runs: [{ length: 5, fontWeight: "bold" }] })
    )!;
    expect(displayIndexToContent(spans, 0)).toBe(0);
    expect(displayIndexToContent(spans, 3)).toBe(3);
    expect(displayIndexToContent(spans, 8)).toBe(8);
  });

  it("snaps to a run boundary when a run's display length diverges", () => {
    // "ß".toUpperCase() === "SS" — 1 content char, 2 display chars.
    const spans = resolveRunSpans(
      text({ content: "ßx", textTransform: "uppercase", runs: [{ length: 1, fontWeight: "bold" }] })
    )!;
    expect(spans[0].displayLength).toBe(2);
    expect(displayIndexToContent(spans, 0)).toBe(0);
    expect(displayIndexToContent(spans, 2)).toBe(1);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bun test src/components/studio/kv-generator/overlays/textRuns.test.ts
```

Expected: FAIL — `Cannot find module './textRuns'`.

- [ ] **Step 3: Add the payload type**

In `src/types/studio.ts`, above `export type StudioOverlay`:

```ts
/** One consecutive stretch of a text overlay's `content` with its own font
 *  identity. Absent properties inherit the layer-level value — a run is an
 *  OVERRIDE, not a complete style. `length` counts UTF-16 code units of the
 *  STORED content, the same units `content.length` and a textarea selection
 *  use. Runs are normalized at read time (overlays/textRuns.ts); nothing
 *  downstream may assume the raw array is well-formed. */
export type TextStyleRun = {
  length: number;
  fontFamily?: string;
  fontWeight?: "normal" | "bold";
  fontStyle?: "normal" | "italic";
};
```

Then inside the `type: "text"` arm of `StudioOverlay["payload"]`, after `fontStyle`:

```ts
        /** Per-range font overrides — a layer that mixes fonts/weights inside
         *  one string. Absent ⇒ the layer-level fontFamily/fontWeight/fontStyle
         *  govern the whole string, exactly as before this field existed.
         *  Deliberately NOT mirrored onto BrandOverlayPreset below: a preset is
         *  a style template re-stamped onto different content, so a stored run
         *  length would be meaningless there. */
        runs?: TextStyleRun[];
```

- [ ] **Step 4: Write the module**

Create `src/components/studio/kv-generator/overlays/textRuns.ts`:

```ts
import type { StudioOverlay, TextStyleRun } from "@/types/studio";
import { resolveOverlayFamily } from "../fonts/resolveFamily";
import { resolveDisplayText } from "./textProps";

type TextPayload = Extract<StudioOverlay["payload"], { type: "text" }>;

/** Matches the API cap (UpdateStudioFileOverlaysRequest). A crafted payload
 *  must not make a renderer walk an unbounded list. */
export const MAX_RUNS = 200;

/** The three properties a run may override. Anything else is layer-level. */
export const RUN_PROPS = ["fontFamily", "fontWeight", "fontStyle"] as const;
export type RunProp = (typeof RUN_PROPS)[number];

/** One run resolved against the layer defaults and transformed for display.
 *  Carries BOTH index axes: `content*` addresses the stored string (what a
 *  selection and the payload speak), `display*` addresses the painted string
 *  (what Fabric's styles map and our Konva layout speak). */
export type RunSpan = {
  text: string;
  contentStart: number;
  contentLength: number;
  displayStart: number;
  displayLength: number;
  fontFamily: string;
  fontWeight: "normal" | "bold";
  fontStyle: "normal" | "italic";
};

function overridesOf(r: TextStyleRun): Omit<TextStyleRun, "length"> {
  const out: Omit<TextStyleRun, "length"> = {};
  if (r.fontFamily) out.fontFamily = r.fontFamily;
  if (r.fontWeight) out.fontWeight = r.fontWeight;
  if (r.fontStyle) out.fontStyle = r.fontStyle;
  return out;
}

function sameOverrides(a: TextStyleRun, b: TextStyleRun): boolean {
  return RUN_PROPS.every((k) => a[k] === b[k]);
}

/** Merge adjacent runs that carry identical overrides. Keeps the list minimal
 *  so a round-trip through the panel doesn't grow it without bound. */
export function coalesceRuns(runs: TextStyleRun[]): TextStyleRun[] {
  const out: TextStyleRun[] = [];
  for (const r of runs) {
    if (r.length <= 0) continue;
    const prev = out[out.length - 1];
    if (prev && sameOverrides(prev, r)) prev.length += r.length;
    else out.push({ ...r });
  }
  return out;
}

/**
 * Force a raw run list to cover `content` exactly: drop junk lengths, truncate
 * the tail that overruns, and append one unstyled run for any remainder.
 *
 * The invariant lives HERE rather than in server validation on purpose. The
 * overlays PATCH is a full-array autosave, so a 422 on one derived value would
 * poison every subsequent save for the file.
 */
export function normalizeRuns(
  content: string,
  runs?: TextStyleRun[] | null
): TextStyleRun[] {
  const total = content.length;
  if (total === 0) return [];
  const out: TextStyleRun[] = [];
  let used = 0;
  for (const r of runs ?? []) {
    if (out.length >= MAX_RUNS) break;
    const len = Math.floor(Number(r?.length));
    if (!Number.isFinite(len) || len <= 0) continue;
    const take = Math.min(len, total - used);
    if (take <= 0) break;
    out.push({ length: take, ...overridesOf(r) });
    used += take;
  }
  if (used < total) out.push({ length: total - used });
  return out;
}

/**
 * The spans a renderer should draw, or `null` when this payload has no run
 * overrides at all — the back-compat guarantee, expressed in the type system:
 * a legacy overlay cannot reach the run code path.
 *
 * The display transform (case + paragraph spacing) is applied PER RUN, not to
 * the joined string. Injection only ever happens at `\n`, and a `\n` lives
 * entirely inside one run, so this is exactly equivalent to transforming the
 * whole string — while making index drift structurally impossible.
 */
export function resolveRunSpans(payload: TextPayload): RunSpan[] | null {
  const raw = payload.runs;
  if (!raw || raw.length === 0) return null;
  const content = payload.content ?? "";
  const norm = normalizeRuns(content, raw);
  if (!norm.some((r) => RUN_PROPS.some((k) => r[k] != null))) return null;

  const baseFamily = resolveOverlayFamily(payload);
  const baseWeight = payload.fontWeight ?? "normal";
  const baseStyle = payload.fontStyle ?? "normal";

  const spans: RunSpan[] = [];
  let contentStart = 0;
  let displayStart = 0;
  for (const r of norm) {
    const slice = content.slice(contentStart, contentStart + r.length);
    const display = resolveDisplayText(slice, payload);
    spans.push({
      text: display,
      contentStart,
      contentLength: r.length,
      displayStart,
      displayLength: display.length,
      fontFamily: r.fontFamily ?? baseFamily,
      fontWeight: r.fontWeight ?? baseWeight,
      fontStyle: r.fontStyle ?? baseStyle,
    });
    contentStart += r.length;
    displayStart += display.length;
  }
  return spans;
}

/**
 * Painted-string index → stored-content index. Exact whenever the display
 * transform preserved the run's length, which is every case except a handful
 * of scripts ("ß".toUpperCase() is "SS"). When it didn't, snap to the nearer
 * run boundary — a half-mapped index is worse than a slightly wider selection.
 */
export function displayIndexToContent(spans: RunSpan[], i: number): number {
  if (spans.length === 0) return 0;
  for (let k = 0; k < spans.length; k++) {
    const s = spans[k];
    const end = s.displayStart + s.displayLength;
    if (i >= end && k < spans.length - 1) continue;
    const off = Math.max(0, i - s.displayStart);
    if (s.displayLength === s.contentLength) {
      return s.contentStart + Math.min(s.contentLength, off);
    }
    return off * 2 >= s.displayLength
      ? s.contentStart + s.contentLength
      : s.contentStart;
  }
  const last = spans[spans.length - 1];
  return last.contentStart + last.contentLength;
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bun test src/components/studio/kv-generator/overlays/textRuns.test.ts
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/types/studio.ts src/components/studio/kv-generator/overlays/textRuns.ts src/components/studio/kv-generator/overlays/textRuns.test.ts
git commit -m "feat(web): model per-run font styling for text overlays"
```

---

### Task 2: Run mutations — apply, clear, query, remap

**Files:**
- Modify: `src/components/studio/kv-generator/overlays/textRuns.ts`
- Test: `src/components/studio/kv-generator/overlays/textRuns.mutations.test.ts`

**Interfaces:**
- Consumes: `normalizeRuns`, `coalesceRuns`, `RUN_PROPS` from Task 1.
- Produces: `applyRunStyle(payload, start, end, patch): TextStyleRun[]`, `clearRunProp(runs, prop): TextStyleRun[]`, `runStyleAtRange(payload, start, end): EffectiveRunStyle`, `remapRuns(oldContent, newContent, runs): TextStyleRun[]`, and the type `EffectiveRunStyle = { fontFamily: string | null; fontWeight: "normal" | "bold" | null; fontStyle: "normal" | "italic" | null }` where `null` means MIXED.

A separate test file from Task 1 on purpose: `bun test` dies with a bogus SCSS error once a test file passes ~51 KB.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/overlays/textRuns.mutations.test.ts`:

```ts
import { describe, it, expect } from "bun:test";
import {
  applyRunStyle,
  clearRunProp,
  runStyleAtRange,
  remapRuns,
} from "./textRuns";
import type { StudioOverlay } from "@/types/studio";

type TextPayload = Extract<StudioOverlay["payload"], { type: "text" }>;

const text = (p: Partial<TextPayload>): TextPayload => ({
  type: "text",
  content: "Hello world",
  color: "#ffffff",
  ...p,
});

describe("applyRunStyle", () => {
  it("splits a single implicit run into styled and unstyled parts", () => {
    expect(applyRunStyle(text({}), 0, 5, { fontWeight: "bold" })).toEqual([
      { length: 5, fontWeight: "bold" },
      { length: 6 },
    ]);
  });

  it("styles a range in the middle", () => {
    expect(applyRunStyle(text({}), 6, 11, { fontStyle: "italic" })).toEqual([
      { length: 6 },
      { length: 5, fontStyle: "italic" },
    ]);
  });

  it("coalesces back down when a range is re-styled to match its neighbour", () => {
    const once = applyRunStyle(text({}), 0, 5, { fontWeight: "bold" });
    const twice = applyRunStyle(text({ runs: once }), 5, 11, { fontWeight: "bold" });
    expect(twice).toEqual([{ length: 11, fontWeight: "bold" }]);
  });

  it("treats an explicit undefined as clearing that override", () => {
    const bold = applyRunStyle(text({}), 0, 5, { fontWeight: "bold" });
    expect(applyRunStyle(text({ runs: bold }), 0, 5, { fontWeight: undefined }))
      .toEqual([{ length: 11 }]);
  });

  it("is a no-op for a collapsed range", () => {
    expect(applyRunStyle(text({}), 4, 4, { fontWeight: "bold" })).toEqual([{ length: 11 }]);
  });
});

describe("clearRunProp", () => {
  it("removes one property and collapses to nothing when no override is left", () => {
    const runs = [{ length: 5, fontWeight: "bold" as const }, { length: 6 }];
    expect(clearRunProp(runs, "fontWeight")).toEqual([]);
  });

  it("keeps the other properties", () => {
    const runs = [
      { length: 5, fontWeight: "bold" as const, fontStyle: "italic" as const },
      { length: 6 },
    ];
    expect(clearRunProp(runs, "fontWeight")).toEqual([
      { length: 5, fontStyle: "italic" },
      { length: 6 },
    ]);
  });
});

describe("runStyleAtRange", () => {
  it("reports the resolved value when the range is uniform", () => {
    const p = text({ runs: [{ length: 5, fontWeight: "bold" }] });
    expect(runStyleAtRange(p, 0, 5)).toEqual({
      fontFamily: expect.any(String),
      fontWeight: "bold",
      fontStyle: "normal",
    });
  });

  it("reports null (mixed) when the range spans differing runs", () => {
    const p = text({ runs: [{ length: 5, fontWeight: "bold" }] });
    expect(runStyleAtRange(p, 0, 11).fontWeight).toBeNull();
  });

  it("falls back to the layer style outside any override", () => {
    const p = text({ fontStyle: "italic", runs: [{ length: 5, fontWeight: "bold" }] });
    expect(runStyleAtRange(p, 6, 11).fontStyle).toBe("italic");
  });
});

describe("remapRuns", () => {
  const runs = [{ length: 5, fontWeight: "bold" as const }, { length: 6 }];

  it("grows the run that owns an append", () => {
    expect(remapRuns("Hello world", "Hello world!!", runs)).toEqual([
      { length: 5, fontWeight: "bold" },
      { length: 8 },
    ]);
  });

  it("grows the styled run when typing inside it", () => {
    expect(remapRuns("Hello world", "Helllllo world", runs)).toEqual([
      { length: 8, fontWeight: "bold" },
      { length: 6 },
    ]);
  });

  it("shrinks across a deletion that spans two runs", () => {
    expect(remapRuns("Hello world", "Helrld", runs)).toEqual([
      { length: 3, fontWeight: "bold" },
      { length: 3 },
    ]);
  });

  it("returns nothing when everything is deleted", () => {
    expect(remapRuns("Hello world", "", runs)).toEqual([]);
  });

  it("passes an unchanged string straight through", () => {
    expect(remapRuns("Hello world", "Hello world", runs)).toEqual(runs);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bun test src/components/studio/kv-generator/overlays/textRuns.mutations.test.ts
```

Expected: FAIL — `applyRunStyle` is not exported.

- [ ] **Step 3: Append the mutations to `textRuns.ts`**

```ts
export type EffectiveRunStyle = {
  fontFamily: string | null;
  fontWeight: "normal" | "bold" | null;
  fontStyle: "normal" | "italic" | null;
};

/** Apply `patch` to one run; a key present with an `undefined` value CLEARS
 *  that override (back to the layer default) rather than being ignored. */
function mergeRun(base: TextStyleRun, patch: Partial<TextStyleRun>): TextStyleRun {
  const next: TextStyleRun = { ...base };
  for (const k of RUN_PROPS) {
    if (!(k in patch)) continue;
    const v = patch[k];
    if (v == null) delete next[k];
    else (next as Record<string, unknown>)[k] = v;
  }
  return next;
}

/** All runs carry no override ⇒ return [] so the caller can drop `runs`
 *  entirely and put the overlay back on the legacy render path. */
function dropIfEmpty(runs: TextStyleRun[]): TextStyleRun[] {
  return runs.some((r) => RUN_PROPS.some((k) => r[k] != null)) ? runs : [];
}

/** Style the stored-content range [start, end). Splits the runs it straddles,
 *  merges the patch into the covered pieces, then coalesces. */
export function applyRunStyle(
  payload: TextPayload,
  start: number,
  end: number,
  patch: Partial<TextStyleRun>
): TextStyleRun[] {
  const content = payload.content ?? "";
  const norm = normalizeRuns(content, payload.runs);
  const lo = Math.max(0, Math.min(content.length, Math.min(start, end)));
  const hi = Math.max(0, Math.min(content.length, Math.max(start, end)));
  if (hi <= lo) return dropIfEmpty(coalesceRuns(norm));

  const out: TextStyleRun[] = [];
  let pos = 0;
  for (const r of norm) {
    const rStart = pos;
    const rEnd = pos + r.length;
    pos = rEnd;
    const a = Math.max(rStart, lo);
    const b = Math.min(rEnd, hi);
    if (b <= a) {
      out.push({ ...r });
      continue;
    }
    if (a > rStart) out.push({ ...r, length: a - rStart });
    out.push(mergeRun({ ...r, length: b - a }, patch));
    if (b < rEnd) out.push({ ...r, length: rEnd - b });
  }
  return dropIfEmpty(coalesceRuns(out));
}

/** Strip one property from every run — what a layer-level control does. */
export function clearRunProp(
  runs: TextStyleRun[],
  prop: RunProp
): TextStyleRun[] {
  const stripped = runs.map((r) => {
    const next = { ...r };
    delete next[prop];
    return next;
  });
  return dropIfEmpty(coalesceRuns(stripped));
}

/** The style the panel should display for [start, end). `null` = MIXED. An
 *  empty range reports the style of the run containing `start`. */
export function runStyleAtRange(
  payload: TextPayload,
  start: number,
  end: number
): EffectiveRunStyle {
  const spans = resolveRunSpans(payload);
  const baseFamily = resolveOverlayFamily(payload);
  const baseWeight = payload.fontWeight ?? "normal";
  const baseStyle = payload.fontStyle ?? "normal";
  const base: EffectiveRunStyle = {
    fontFamily: baseFamily,
    fontWeight: baseWeight,
    fontStyle: baseStyle,
  };
  if (!spans) return base;

  const lo = Math.min(start, end);
  const hi = Math.max(start, end);
  const covered = spans.filter((s) => {
    const sEnd = s.contentStart + s.contentLength;
    return hi === lo ? s.contentStart <= lo && lo < sEnd : s.contentStart < hi && sEnd > lo;
  });
  const touched = covered.length > 0 ? covered : spans;

  const uniform = <T,>(pick: (s: RunSpan) => T): T | null => {
    const first = pick(touched[0]);
    return touched.every((s) => pick(s) === first) ? first : null;
  };
  return {
    fontFamily: uniform((s) => s.fontFamily),
    fontWeight: uniform((s) => s.fontWeight),
    fontStyle: uniform((s) => s.fontStyle),
  };
}

/**
 * Keep runs aligned across a content edit, by common prefix/suffix diff.
 *
 * This is not a nicety: Resize editing goes through a plain `<textarea>`
 * (`OverlayTextEditor`), which hands back a whole new string with no notion of
 * what changed. For the dominant gestures — typing at the end, backspacing,
 * replacing a selection — prefix/suffix recovers the edit exactly.
 */
export function remapRuns(
  oldContent: string,
  newContent: string,
  runs?: TextStyleRun[] | null
): TextStyleRun[] {
  const norm = normalizeRuns(oldContent, runs);
  if (norm.length === 0) return [];
  if (oldContent === newContent) return dropIfEmpty(coalesceRuns(norm));
  if (newContent.length === 0) return [];

  let p = 0;
  const maxP = Math.min(oldContent.length, newContent.length);
  while (p < maxP && oldContent[p] === newContent[p]) p++;
  let s = 0;
  const maxS = Math.min(oldContent.length - p, newContent.length - p);
  while (
    s < maxS &&
    oldContent[oldContent.length - 1 - s] === newContent[newContent.length - 1 - s]
  ) {
    s++;
  }
  const removedStart = p;
  const removedEnd = oldContent.length - s;
  const inserted = newContent.length - s - p;

  const out: TextStyleRun[] = [];
  let pos = 0;
  let insertInto = -1;
  for (const r of norm) {
    const rStart = pos;
    const rEnd = pos + r.length;
    pos = rEnd;
    const overlap = Math.max(0, Math.min(rEnd, removedEnd) - Math.max(rStart, removedStart));
    const kept = r.length - overlap;
    // The insertion belongs to the run that owned the edit point — the one
    // containing removedStart, else the last run that ends at or before it.
    if (rStart <= removedStart && removedStart < rEnd) insertInto = out.length;
    else if (rEnd <= removedStart) insertInto = out.length;
    out.push({ ...r, length: kept });
  }
  if (inserted > 0) {
    const target = insertInto >= 0 ? insertInto : 0;
    out[target].length += inserted;
  }
  return dropIfEmpty(coalesceRuns(normalizeRuns(newContent, out.filter((r) => r.length > 0))));
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bun test src/components/studio/kv-generator/overlays/textRuns.mutations.test.ts
bun test src/components/studio/kv-generator/overlays/textRuns.test.ts
```

Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/overlays/textRuns.ts src/components/studio/kv-generator/overlays/textRuns.mutations.test.ts
git commit -m "feat(web): run-style mutations — apply, clear, query, remap"
```

---

### Task 3: Engine-agnostic run layout

**Files:**
- Create: `src/components/studio/kv-generator/overlays/textRunLayout.ts`
- Test: `src/components/studio/kv-generator/overlays/textRunLayout.test.ts`

**Interfaces:**
- Consumes: `RunSpan` from `./textRuns` (structurally — the layout takes the subset `{ text, fontFamily, fontWeight, fontStyle }`).
- Produces: `layoutRunText(args): RunTextLayout` with `RunTextLayout = { lines: LayoutLine[]; lineHeightPx: number; height: number }`, `LayoutLine = { spans: LayoutSpan[]; width: number }`, `LayoutSpan = { text: string; x: number; width: number; fontFamily: string; fontWeight: "normal" | "bold"; fontStyle: "normal" | "italic" }`, and `MeasureFn = (text: string, fontFamily: string, fontWeight: "normal" | "bold", fontStyle: "normal" | "italic") => number`.

Measurement is injected so the layout is testable with no canvas — jsdom has no 2D context.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/overlays/textRunLayout.test.ts`:

```ts
import { describe, it, expect } from "bun:test";
import { layoutRunText, type MeasureFn } from "./textRunLayout";

/** 10 px per character, 14 px per character when bold — wide enough that a
 *  weight change visibly moves the wrap point. */
const measure: MeasureFn = (t, _family, weight) =>
  t.length * (weight === "bold" ? 14 : 10);

const span = (text: string, weight: "normal" | "bold" = "normal") => ({
  text,
  fontFamily: "Geist",
  fontWeight: weight,
  fontStyle: "normal" as const,
});

const base = {
  boxWidth: 100,
  fontSizePx: 20,
  lineHeight: 1,
  letterSpacingPx: 0,
  align: "left" as const,
  measure,
};

describe("layoutRunText", () => {
  it("wraps greedily on spaces", () => {
    // "aaa " is 40px and "bbb " is 40px, so only one fits in 60px.
    const out = layoutRunText({ ...base, boxWidth: 60, spans: [span("aaa bbb ccc")] });
    expect(out.lines.map((l) => l.spans.map((s) => s.text).join(""))).toEqual([
      "aaa ",
      "bbb ",
      "ccc",
    ]);
  });

  it("measures each run in its OWN font, so a bold run wraps earlier", () => {
    const out = layoutRunText({ ...base, spans: [span("aaaa", "bold"), span(" bb")] });
    // "aaaa" bold is 56px, " bb" normal is 30px — 86px, still one line.
    expect(out.lines).toHaveLength(1);
    const wide = layoutRunText({ ...base, spans: [span("aaaaa", "bold"), span(" bbb")] });
    // "aaaaa" bold is 70px; " bbb" normal is 40px — 110px, must break.
    expect(wide.lines).toHaveLength(2);
  });

  it("breaks on explicit newlines regardless of width", () => {
    const out = layoutRunText({ ...base, spans: [span("a\nb")] });
    expect(out.lines.map((l) => l.spans.map((s) => s.text).join(""))).toEqual(["a", "b"]);
  });

  it("gives a word wider than the box its own line and lets it overflow", () => {
    const out = layoutRunText({ ...base, spans: [span("aaaaaaaaaaaaaaa bb")] });
    expect(out.lines[0].spans[0].text).toBe("aaaaaaaaaaaaaaa ");
    expect(out.lines[0].width).toBeGreaterThan(100);
  });

  it("centers and right-aligns by offsetting the line's spans", () => {
    const centered = layoutRunText({ ...base, align: "center", spans: [span("aa")] });
    expect(centered.lines[0].spans[0].x).toBe(40); // (100 - 20) / 2
    const right = layoutRunText({ ...base, align: "right", spans: [span("aa")] });
    expect(right.lines[0].spans[0].x).toBe(80);
  });

  it("adds letter spacing to every character, matching Konva's convention", () => {
    const out = layoutRunText({ ...base, letterSpacingPx: 2, spans: [span("aa")] });
    expect(out.lines[0].width).toBe(24); // 2 chars * (10 + 2)
  });

  it("derives height from the line count and the line-height multiplier", () => {
    // 60px forces "aaa " (40px) and "bbb" (30px) onto separate lines.
    const out = layoutRunText({ ...base, boxWidth: 60, lineHeight: 1.5, spans: [span("aaa bbb")] });
    expect(out.lineHeightPx).toBe(30);
    expect(out.height).toBe(60);
  });

  it("justifies every line but the last of a paragraph", () => {
    // Atoms are "aa " (30), "bb " (30), "cc" (20). At 70px the first two fit
    // and "cc" wraps, so line 1 is a non-final line with 10px of slack.
    const out = layoutRunText({
      ...base,
      align: "justify",
      boxWidth: 70,
      spans: [span("aa bb cc")],
    });
    expect(out.lines).toHaveLength(2);
    expect(out.lines[0].width).toBe(70);
    expect(out.lines[0].spans[1].x).toBe(40); // 30 + 10px of distributed slack
    expect(out.lines[1].width).toBe(20);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bun test src/components/studio/kv-generator/overlays/textRunLayout.test.ts
```

Expected: FAIL — module not found.

- [ ] **Step 3: Write the layout module**

Create `src/components/studio/kv-generator/overlays/textRunLayout.ts`:

```ts
/**
 * Word wrap + span positioning for text that mixes fonts within one string.
 *
 * This exists because Konva has no rich text: `Konva.Text` applies one style
 * to the whole node, and its `charRenderFunc` hook only runs at draw time —
 * it does not participate in measurement, so changing the font inside it
 * would leave the glyphs mispositioned.
 *
 * Kept renderer-agnostic and measurement-injected: jsdom has no 2D context, so
 * a layout that measured for itself could not be unit-tested at all.
 *
 * Wrapping mirrors Fabric's `Textbox` with `splitByGrapheme: false` — greedy,
 * on spaces. KNOWN DIVERGENCE: Fabric will grapheme-break a single word wider
 * than the box as a last resort; this lets it overflow on its own line. Only
 * runs-bearing overlays can observe the difference.
 */

export type MeasureFn = (
  text: string,
  fontFamily: string,
  fontWeight: "normal" | "bold",
  fontStyle: "normal" | "italic"
) => number;

export type LayoutSpan = {
  text: string;
  /** Left edge in box-local pixels. */
  x: number;
  width: number;
  fontFamily: string;
  fontWeight: "normal" | "bold";
  fontStyle: "normal" | "italic";
};

export type LayoutLine = { spans: LayoutSpan[]; width: number };

export type RunTextLayout = {
  lines: LayoutLine[];
  lineHeightPx: number;
  height: number;
};

type StyledSpan = {
  text: string;
  fontFamily: string;
  fontWeight: "normal" | "bold";
  fontStyle: "normal" | "italic";
};

/** A word plus its trailing spaces, or a lone newline. Atoms never straddle a
 *  span, so every atom has exactly one font. */
type Atom = Omit<StyledSpan, "text"> & {
  text: string;
  width: number;
  isBreak: boolean;
};

function toAtoms(spans: StyledSpan[], measure: MeasureFn, letterSpacingPx: number): Atom[] {
  const atoms: Atom[] = [];
  for (const s of spans) {
    // Keep trailing whitespace attached to the word before it, and keep "\n"
    // as its own atom so an explicit break is never merged into a word.
    for (const piece of s.text.split(/(\n)|(?<=\s)(?=\S)/g)) {
      if (piece == null || piece === "") continue;
      atoms.push({
        text: piece,
        fontFamily: s.fontFamily,
        fontWeight: s.fontWeight,
        fontStyle: s.fontStyle,
        width:
          piece === "\n"
            ? 0
            : measure(piece, s.fontFamily, s.fontWeight, s.fontStyle) +
              letterSpacingPx * piece.length,
        isBreak: piece === "\n",
      });
    }
  }
  return atoms;
}

/** Merge neighbouring atoms that share a font into one fillText call.
 *
 *  `merge` is false for justified lines: justify redistributes slack BETWEEN
 *  the pieces of a line, so the pieces have to stay separate. Merging first
 *  would collapse a uniformly-styled line into one span with nothing to
 *  distribute across, and justify would silently do nothing. */
function packLine(atoms: Atom[], merge: boolean): { spans: LayoutSpan[]; width: number } {
  const spans: LayoutSpan[] = [];
  let x = 0;
  for (const a of atoms) {
    const prev = spans[spans.length - 1];
    if (
      merge &&
      prev &&
      prev.fontFamily === a.fontFamily &&
      prev.fontWeight === a.fontWeight &&
      prev.fontStyle === a.fontStyle
    ) {
      prev.text += a.text;
      prev.width += a.width;
    } else {
      spans.push({
        text: a.text,
        x,
        width: a.width,
        fontFamily: a.fontFamily,
        fontWeight: a.fontWeight,
        fontStyle: a.fontStyle,
      });
    }
    x += a.width;
  }
  return { spans, width: x };
}

export function layoutRunText(args: {
  spans: StyledSpan[];
  boxWidth: number;
  fontSizePx: number;
  lineHeight: number;
  letterSpacingPx: number;
  align: "left" | "center" | "right" | "justify";
  measure: MeasureFn;
}): RunTextLayout {
  const { boxWidth, fontSizePx, lineHeight, letterSpacingPx, align, measure } = args;
  const atoms = toAtoms(args.spans, measure, letterSpacingPx);

  // 1. Greedy wrap into rows of atoms.
  const rows: Atom[][] = [];
  let row: Atom[] = [];
  let rowWidth = 0;
  const endsParagraph: boolean[] = [];
  const flush = (paragraphEnd: boolean) => {
    rows.push(row);
    endsParagraph.push(paragraphEnd);
    row = [];
    rowWidth = 0;
  };
  for (const a of atoms) {
    if (a.isBreak) {
      flush(true);
      continue;
    }
    if (row.length > 0 && rowWidth + a.width > boxWidth) flush(false);
    row.push(a);
    rowWidth += a.width;
  }
  flush(true);

  // 2. Position each row, then align it.
  const lineHeightPx = fontSizePx * lineHeight;
  const lines: LayoutLine[] = rows.map((r, i) => {
    const packed = packLine(r, align !== "justify");
    if (packed.spans.length === 0) return packed;
    const slack = boxWidth - packed.width;
    if (align === "center") {
      for (const s of packed.spans) s.x += slack / 2;
    } else if (align === "right") {
      for (const s of packed.spans) s.x += slack;
    } else if (align === "justify" && slack > 0 && !endsParagraph[i] && packed.spans.length > 1) {
      const step = slack / (packed.spans.length - 1);
      packed.spans.forEach((s, k) => {
        s.x += step * k;
      });
      packed.width = boxWidth;
    }
    return packed;
  });

  return { lines, lineHeightPx, height: lines.length * lineHeightPx };
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bun test src/components/studio/kv-generator/overlays/textRunLayout.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/overlays/textRunLayout.ts src/components/studio/kv-generator/overlays/textRunLayout.test.ts
git commit -m "feat(web): engine-agnostic word wrap for mixed-font text"
```

---

### Task 4: The Konva run-text node

**Files:**
- Create: `src/components/studio/kv-generator/overlays/konvaRunText.ts`
- Test: `src/components/studio/kv-generator/overlays/konvaRunText.test.ts`

**Interfaces:**
- Consumes: `layoutRunText`, `MeasureFn` (Task 3); `RunSpan` (Task 1); `hasGradient`, `gradientLineCoords` from `./resolveTextFill`.
- Produces: `runFontShorthand(family, weight, style, sizePx): string`, `canvasMeasure(fontSizePx): MeasureFn`, `runTextFill(payload, w, h): RunTextFill`, `resolveFillStyle(ctx, fill): string | CanvasGradient`, `buildRunTextNode(args): Konva.Shape`, and the type `RunTextFill` (solid | linear-with-coords | radial-with-centre-and-radius).

One `Konva.Shape`, not N `Konva.Text` nodes — so Motion's `applyTimeline`
animates it like any other layer and z-order, opacity and blend behave
unchanged.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/overlays/konvaRunText.test.ts`:

```ts
import { describe, it, expect } from "bun:test";
import Konva from "konva";
import { buildRunTextNode, runTextFill } from "./konvaRunText";
import type { RunSpan } from "./textRuns";

const span = (
  text: string,
  weight: "normal" | "bold",
  contentStart: number
): RunSpan => ({
  text,
  contentStart,
  contentLength: text.length,
  displayStart: contentStart,
  displayLength: text.length,
  fontFamily: "Geist",
  fontWeight: weight,
  fontStyle: "normal",
});

const measure = (t: string, _f: string, w: "normal" | "bold") =>
  t.length * (w === "bold" ? 14 : 10);

describe("buildRunTextNode", () => {
  it("returns ONE Konva node, centred on its box like every other overlay", () => {
    const node = buildRunTextNode({
      spans: [span("Hello", "bold", 0), span(" world", "normal", 5)],
      centerX: 200,
      centerY: 100,
      boxWidth: 120,
      fontSizePx: 20,
      lineHeight: 1,
      letterSpacingPx: 0,
      align: "center",
      rotation: 0,
      opacity: 1,
      fill: { type: "solid", color: "#ffffff" },
      measure,
    });
    expect(node).toBeInstanceOf(Konva.Shape);
    expect(node.x()).toBe(200);
    expect(node.y()).toBe(100);
    expect(node.offsetX()).toBe(60);
    expect(node.offsetY()).toBe(node.height() / 2);
  });

  it("sizes itself from the wrapped line count", () => {
    const node = buildRunTextNode({
      spans: [span("aaa bbb ccc", "normal", 0)],
      centerX: 0,
      centerY: 0,
      boxWidth: 40,
      fontSizePx: 20,
      lineHeight: 1,
      letterSpacingPx: 0,
      align: "left",
      rotation: 0,
      opacity: 1,
      fill: { type: "solid", color: "#ffffff" },
      measure,
    });
    expect(node.height()).toBe(60); // three lines at 20px
  });

  it("draws every span, each with its own font", () => {
    const seen: string[] = [];
    const node = buildRunTextNode({
      spans: [span("Hi", "bold", 0), span(" yo", "normal", 2)],
      centerX: 0,
      centerY: 0,
      boxWidth: 500,
      fontSizePx: 20,
      lineHeight: 1,
      letterSpacingPx: 0,
      align: "left",
      rotation: 0,
      opacity: 1,
      fill: { type: "solid", color: "#ffffff" },
      measure,
    });
    const ctx = {
      save: () => {},
      restore: () => {},
      fillText: (t: string) => seen.push(t),
      set font(v: string) {
        seen.push(`font:${v}`);
      },
      set fillStyle(_v: unknown) {},
      set textBaseline(_v: unknown) {},
      set textAlign(_v: unknown) {},
    } as unknown as Konva.Context;
    node.sceneFunc()!.call(node, ctx, node);
    expect(seen).toContain("font:bold normal 20px Geist");
    expect(seen).toContain("Hi");
    expect(seen).toContain(" yo");
  });
});

describe("runTextFill", () => {
  it("reports a solid fill when there is no gradient", () => {
    expect(runTextFill({ type: "text", content: "x", color: "#abcdef" }, 10, 10))
      .toEqual({ type: "solid", color: "#abcdef" });
  });

  it("reports gradient coordinates in box-local space", () => {
    const fill = runTextFill(
      {
        type: "text",
        content: "x",
        color: "#000000",
        gradient: { type: "linear", from: "#ff0000", to: "#0000ff", angle: 0 },
      },
      100,
      50
    );
    expect(fill).toMatchObject({ type: "linear", from: "#ff0000", to: "#0000ff" });
  });

  it("gives a radial gradient a radius that reaches the box corner", () => {
    const fill = runTextFill(
      {
        type: "text",
        content: "x",
        color: "#000000",
        gradient: { type: "radial", from: "#ff0000", to: "#0000ff", angle: 0 },
      },
      100,
      50
    );
    // Same value resolveTextFill.ts's radialEndRadius produces — a coincident
    // start/end point here would collapse the gradient to a hard edge.
    expect(fill).toMatchObject({
      type: "radial",
      center: { x: 50, y: 25 },
      radius: Math.sqrt(100 * 100 + 50 * 50) / 2,
    });
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bun test src/components/studio/kv-generator/overlays/konvaRunText.test.ts
```

Expected: FAIL — module not found.

- [ ] **Step 3: Write the node builder**

Create `src/components/studio/kv-generator/overlays/konvaRunText.ts`:

```ts
import Konva from "konva";

import type { StudioOverlay } from "@/types/studio";
import { gradientLineCoords, hasGradient } from "./resolveTextFill";
import type { RunSpan } from "./textRuns";
import { layoutRunText, type MeasureFn } from "./textRunLayout";

type TextPayload = Extract<StudioOverlay["payload"], { type: "text" }>;

export type RunTextFill =
  | { type: "solid"; color: string }
  | {
      type: "linear";
      coords: { x1: number; y1: number; x2: number; y2: number };
      from: string;
      to: string;
    }
  | {
      /** Centre-out, angle ignored — same model as resolveTextFill's radial. */
      type: "radial";
      center: { x: number; y: number };
      radius: number;
      from: string;
      to: string;
    };

/** The CSS font shorthand a run draws with. Single source so the measurer and
 *  the painter can never disagree about what was measured. */
export function runFontShorthand(
  fontFamily: string,
  fontWeight: "normal" | "bold",
  fontStyle: "normal" | "italic",
  fontSizePx: number
): string {
  return `${fontWeight} ${fontStyle} ${fontSizePx}px ${fontFamily}`;
}

/** Canvas 2D measurement, curried on the font size. Browser only — returns 0
 *  without a document, same contract as measureText.ts. */
export function canvasMeasure(fontSizePx: number): MeasureFn {
  if (typeof document === "undefined") return () => 0;
  const ctx = document.createElement("canvas").getContext("2d");
  if (!ctx) return () => 0;
  return (text, family, weight, style) => {
    ctx.font = runFontShorthand(family, weight, style, fontSizePx);
    return ctx.measureText(text).width;
  };
}

/** Text fill for the run renderer, in box-local coordinates. Deliberately its
 *  own resolver rather than `konvaFill`: that helper returns Konva node props,
 *  which a custom sceneFunc cannot use — it paints with ctx.fillStyle. */
export function runTextFill(
  payload: TextPayload,
  w: number,
  h: number
): RunTextFill {
  const g = payload.gradient;
  if (!hasGradient(g)) return { type: "solid", color: payload.color };
  if (g.type === "radial") {
    return {
      type: "radial",
      center: { x: w / 2, y: h / 2 },
      // Reaches the farthest corner, so the gradient covers the whole box —
      // the same radius resolveTextFill.ts's radialEndRadius computes.
      radius: Math.sqrt(w * w + h * h) / 2,
      from: g.from,
      to: g.to,
    };
  }
  return { type: "linear", coords: gradientLineCoords(g.angle, w, h), from: g.from, to: g.to };
}

/**
 * One Konva node drawing text whose font changes mid-string.
 *
 * A single Shape rather than one Text per run: Motion animates layers by
 * setting transforms on the node `buildBoardStage` registered for an overlay
 * id, so an overlay MUST be exactly one node. Positioned centre-origin with
 * offsetX/offsetY, matching every other overlay so rotation pivots the same.
 *
 * Vertical placement mirrors Konva.Text's own convention (`textBaseline
 * = "middle"`, line i centred at i * lineHeight + lineHeight / 2) so run text
 * and legacy text at the same geometry sit on the same baseline.
 */
export function buildRunTextNode(args: {
  spans: RunSpan[];
  centerX: number;
  centerY: number;
  boxWidth: number;
  fontSizePx: number;
  lineHeight: number;
  letterSpacingPx: number;
  align: "left" | "center" | "right" | "justify";
  rotation: number;
  opacity: number;
  fill: RunTextFill;
  blendMode?: GlobalCompositeOperation;
  measure: MeasureFn;
}): Konva.Shape {
  const layout = layoutRunText({
    spans: args.spans,
    boxWidth: args.boxWidth,
    fontSizePx: args.fontSizePx,
    lineHeight: args.lineHeight,
    letterSpacingPx: args.letterSpacingPx,
    align: args.align,
    measure: args.measure,
  });

  const shape = new Konva.Shape({
    x: args.centerX,
    y: args.centerY,
    width: args.boxWidth,
    height: layout.height,
    offsetX: args.boxWidth / 2,
    offsetY: layout.height / 2,
    rotation: args.rotation,
    opacity: args.opacity,
    globalCompositeOperation: args.blendMode,
    sceneFunc: (ctx) => {
      ctx.save();
      ctx.textBaseline = "middle";
      ctx.textAlign = "left";
      ctx.fillStyle = resolveFillStyle(ctx, args.fill);
      layout.lines.forEach((line, i) => {
        const y = i * layout.lineHeightPx + layout.lineHeightPx / 2;
        for (const s of line.spans) {
          ctx.font = runFontShorthand(s.fontFamily, s.fontWeight, s.fontStyle, args.fontSizePx);
          ctx.fillText(s.text, s.x, y);
        }
      });
      ctx.restore();
    },
  });
  return shape;
}

/** Exported because the react-konva twin (KonvaRunText.tsx) paints with the
 *  same rule — one implementation, so preview and export cannot disagree. */
export function resolveFillStyle(
  ctx: Konva.Context,
  fill: RunTextFill
): string | CanvasGradient {
  if (fill.type === "solid") return fill.color;
  const g =
    fill.type === "radial"
      ? ctx.createRadialGradient(
          fill.center.x,
          fill.center.y,
          0,
          fill.center.x,
          fill.center.y,
          fill.radius
        )
      : ctx.createLinearGradient(
          fill.coords.x1,
          fill.coords.y1,
          fill.coords.x2,
          fill.coords.y2
        );
  g.addColorStop(0, fill.from);
  g.addColorStop(1, fill.to);
  return g;
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bun test src/components/studio/kv-generator/overlays/konvaRunText.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/overlays/konvaRunText.ts src/components/studio/kv-generator/overlays/konvaRunText.test.ts
git commit -m "feat(web): Konva node for mixed-font text"
```

---

### Task 5: Draw runs on the Konva stage (Motion + share page + export)

**Files:**
- Modify: `src/components/studio/kv-generator/renderBoardStage.ts` (the `ov.payload.type === "text"` branch, ~line 152-186)
- Test: `src/components/studio/kv-generator/renderBoardStage.runs.test.ts`

**Interfaces:**
- Consumes: `resolveRunSpans` (Task 1), `buildRunTextNode`, `runTextFill`, `canvasMeasure` (Task 4).
- Produces: no new exports. `buildBoardStage`'s `nodeById` map now maps a runs-bearing overlay id to a `Konva.Shape` instead of a `Konva.Text`.

This one branch covers the Motion live stage, Motion export, the Motion
size-picker preview, and the public share page.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/renderBoardStage.runs.test.ts`:

```ts
import { describe, it, expect } from "bun:test";
import Konva from "konva";
import { buildBoardStage } from "./renderBoardStage";
import type { StudioOverlay } from "@/types/studio";

const overlay = (payload: Partial<Extract<StudioOverlay["payload"], { type: "text" }>>): StudioOverlay => ({
  id: "ov1",
  studio_file_id: "f1",
  type: "text",
  x: 0.1,
  y: 0.1,
  width: 0.5,
  height: 0.1,
  rotation: 0,
  z: 1,
  payload: { type: "text", content: "Hello world", color: "#ffffff", ...payload },
  created_at: "t",
  updated_at: "t",
});

describe("buildBoardStage — text runs", () => {
  it("still uses a Konva.Text for an overlay with no runs", async () => {
    const { nodeById } = await buildBoardStage({
      baseImageUrl: null,
      overlays: [overlay({})],
      targetWidth: 800,
      targetHeight: 600,
    });
    expect(nodeById.get("ov1")).toBeInstanceOf(Konva.Text);
  });

  it("uses a Konva.Text when the runs override nothing", async () => {
    const { nodeById } = await buildBoardStage({
      baseImageUrl: null,
      overlays: [overlay({ runs: [{ length: 5 }, { length: 6 }] })],
      targetWidth: 800,
      targetHeight: 600,
    });
    expect(nodeById.get("ov1")).toBeInstanceOf(Konva.Text);
  });

  it("swaps to the run node when a run overrides a font property", async () => {
    const { nodeById } = await buildBoardStage({
      baseImageUrl: null,
      overlays: [overlay({ runs: [{ length: 5, fontWeight: "bold" }] })],
      targetWidth: 800,
      targetHeight: 600,
    });
    const node = nodeById.get("ov1")!;
    expect(node).toBeInstanceOf(Konva.Shape);
    expect(node).not.toBeInstanceOf(Konva.Text);
    // Registered under the overlay id, centred like every other overlay —
    // this is what applyTimeline animates.
    expect(node.x()).toBeCloseTo(0.1 * 800 + (0.5 * 800) / 2, 5);
  });

  it("does not render a hidden runs-bearing layer", async () => {
    const { nodeById } = await buildBoardStage({
      baseImageUrl: null,
      overlays: [overlay({ runs: [{ length: 5, fontWeight: "bold" }], hidden: true })],
      targetWidth: 800,
      targetHeight: 600,
    });
    expect(nodeById.get("ov1")).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bun test src/components/studio/kv-generator/renderBoardStage.runs.test.ts
```

Expected: the first two PASS (today's behaviour), the third FAILS — the node is
a `Konva.Text`.

- [ ] **Step 3: Branch the text renderer**

In `renderBoardStage.ts`, add to the imports:

```ts
import { resolveRunSpans } from "./overlays/textRuns";
import { buildRunTextNode, canvasMeasure, runTextFill } from "./overlays/konvaRunText";
```

Then inside `if (ov.payload.type === "text") { ... }`, after `const boxW = metrics.boxWidth;` and before the existing `const family = ...` line, insert:

```ts
      // A layer that mixes fonts within one string cannot be a Konva.Text —
      // that node applies one style to everything, and `charRenderFunc` runs
      // after measurement, so a font change inside it would misplace glyphs.
      // Overlays with no run overrides never reach this branch (resolveRunSpans
      // returns null), so legacy text keeps its exact previous node and paint.
      const runSpans = resolveRunSpans(ov.payload);
      if (runSpans) {
        const runNode = buildRunTextNode({
          spans: runSpans,
          centerX: cx,
          centerY: cy,
          boxWidth: boxW,
          fontSizePx,
          lineHeight: metrics.lineHeight,
          letterSpacingPx: metrics.letterSpacingPx,
          align: metrics.align,
          rotation: ov.rotation,
          opacity: resolveOpacity(ov.payload.opacity),
          // `fontSizePx` as the height argument is deliberate: it is exactly
          // what the sibling `konvaTextFill(ov.payload, boxW, fontSizePx)` call
          // a few lines below passes. That second argument differs across the
          // five text call sites in this codebase — a known pre-existing wart
          // that makes gradient-filled text differ between preview and
          // download. Matching the sibling keeps run text and legacy text
          // consistent WITHIN this renderer; fixing the wart everywhere is its
          // own change and must not ride along here.
          fill: runTextFill(ov.payload, boxW, fontSizePx),
          blendMode: resolveBlendMode(ov.payload) as GlobalCompositeOperation,
          measure: canvasMeasure(fontSizePx),
        });
        overlayGroup.add(runNode);
        nodeById.set(ov.id, runNode);
        continue;
      }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/renderBoardStage.runs.test.ts
bun test src/components/studio/kv-generator/renderBoardStage.test.ts
```

Expected: both PASS. The second is the existing suite — it must stay green,
because it covers the legacy path this change must not touch.

- [ ] **Step 5: Add the Konva parity test**

The spec's parity invariant must hold on BOTH engines, not just Fabric. Append
to `renderBoardStage.runs.test.ts`:

```ts
it("lays a uniform-run layer out exactly like the plain Konva.Text it replaces", async () => {
  const geom = { fontSize: 0.04, lineHeight: 1, textAlign: "center" as const };
  const plain = await buildBoardStage({
    baseImageUrl: null,
    overlays: [overlay(geom)],
    targetWidth: 800,
    targetHeight: 600,
  });
  const uniform = await buildBoardStage({
    baseImageUrl: null,
    overlays: [
      overlay({
        ...geom,
        // Every run restates the layer style, so this exercises the whole run
        // path — layout, node construction, positioning — while promising the
        // legacy result. That is what makes the two wrapping implementations
        // trustworthy: drift shows up here rather than in a user's download.
        runs: [
          { length: 5, fontWeight: "normal", fontStyle: "normal" },
          { length: 6, fontWeight: "normal", fontStyle: "normal" },
        ],
      }),
    ],
    targetWidth: 800,
    targetHeight: 600,
  });

  const a = plain.nodeById.get("ov1")!;
  const b = uniform.nodeById.get("ov1")!;
  expect(b).not.toBeInstanceOf(Konva.Text); // the run path really did run
  expect(b.x()).toBeCloseTo(a.x(), 5);
  expect(b.y()).toBeCloseTo(a.y(), 5);
  expect(b.width()).toBeCloseTo(a.width(), 5);
  expect(b.height()).toBeCloseTo(a.height(), 0);
  expect(b.offsetX()).toBeCloseTo(a.offsetX(), 5);
  expect(b.offsetY()).toBeCloseTo(a.offsetY(), 0);
});
```

Run it:

```bash
bun test src/components/studio/kv-generator/renderBoardStage.runs.test.ts
```

Expected: PASS. If the heights disagree, the cause is almost certainly the
baseline convention — `buildRunTextNode` must centre line `i` at
`i * lineHeightPx + lineHeightPx / 2` with `textBaseline = "middle"`, which is
Konva.Text's own convention. Fix the node, not the test.

- [ ] **Step 6: Load fonts before the stage is built**

Canvas 2D does not trigger font loading, so a run whose family differs from the
layer's would paint in the fallback on first render. At the top of
`buildBoardStage`, before the overlay loop:

```ts
  // Canvas 2D paints with whatever is loaded — unlike the DOM, it does not
  // trigger a fetch. Force-load every distinct family the run spans ask for,
  // or the first paint silently falls back. Best-effort: a font that will not
  // load must not fail the whole stage.
  if (typeof document !== "undefined" && document.fonts) {
    const families = new Set<string>();
    for (const ov of overlays) {
      if (ov.payload.type !== "text") continue;
      for (const s of resolveRunSpans(ov.payload) ?? []) families.add(s.fontFamily);
    }
    await Promise.all(
      [...families].map((f) => document.fonts.load(`24px ${f}`).catch(() => undefined))
    );
  }
```

- [ ] **Step 7: Commit**

```bash
git add src/components/studio/kv-generator/renderBoardStage.ts src/components/studio/kv-generator/renderBoardStage.runs.test.ts
git commit -m "feat(web): draw mixed-font text on the Konva stage (Motion, share, export)"
```

---

### Task 6: Draw runs through the shared Fabric builder

**Files:**
- Modify: `src/components/studio/kv-generator/fabricExport.ts` (`buildTextObject`, ~line 261-311)
- Test: `src/components/studio/kv-generator/fabricExport.runs.test.ts`

**Interfaces:**
- Consumes: `resolveRunSpans` (Task 1).
- Produces: `applyRunStylesToTextbox(box, spans): void`, exported from `fabricExport.ts` so `KvFabricCanvas` (Task 7) applies the identical mapping.

This covers the Craft download/flatten, the read-only Resize tile, and the
unified Resize canvas — all three already go through `buildTextObject`.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/fabricExport.runs.test.ts`:

```ts
import { describe, it, expect } from "bun:test";
import { buildTextObject } from "./fabricExport";
import type { StudioOverlay } from "@/types/studio";

type TextPayload = Extract<StudioOverlay["payload"], { type: "text" }>;

const geom = { x: 0.1, y: 0.1, width: 0.5, height: 0.1, rotation: 0 };
const payload = (p: Partial<TextPayload>): TextPayload => ({
  type: "text",
  content: "Hello world",
  color: "#ffffff",
  fontSize: 0.05,
  ...p,
});

describe("buildTextObject — runs", () => {
  it("leaves the styles map empty for an overlay with no runs", () => {
    const box = buildTextObject(payload({}), geom, 100, 100, 800, 600);
    expect(box.styles).toEqual({});
  });

  it("applies a run's weight to exactly its characters", () => {
    const box = buildTextObject(
      payload({ runs: [{ length: 5, fontWeight: "bold" }] }),
      geom,
      100,
      100,
      800,
      600
    );
    const styles = box.getSelectionStyles(0, 11) as Array<Record<string, unknown>>;
    expect(styles.slice(0, 5).every((s) => s.fontWeight === "bold")).toBe(true);
    expect(styles.slice(5).every((s) => s.fontWeight !== "bold")).toBe(true);
  });

  it("applies a run's family and style", () => {
    const box = buildTextObject(
      payload({ runs: [{ length: 5 }, { length: 6, fontFamily: "Inter", fontStyle: "italic" }] }),
      geom,
      100,
      100,
      800,
      600
    );
    const styles = box.getSelectionStyles(5, 11) as Array<Record<string, unknown>>;
    expect(styles.every((s) => s.fontFamily === "Inter" && s.fontStyle === "italic")).toBe(true);
  });

  it("indexes runs against the DISPLAY string, so a case transform stays aligned", () => {
    const box = buildTextObject(
      payload({ textTransform: "uppercase", runs: [{ length: 5, fontWeight: "bold" }] }),
      geom,
      100,
      100,
      800,
      600
    );
    expect(box.text.startsWith("HELLO")).toBe(true);
    const styles = box.getSelectionStyles(0, 5) as Array<Record<string, unknown>>;
    expect(styles.every((s) => s.fontWeight === "bold")).toBe(true);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bun test src/components/studio/kv-generator/fabricExport.runs.test.ts
```

Expected: the first PASSES, the rest FAIL — no styles are ever set.

- [ ] **Step 3: Apply run styles after construction**

In `fabricExport.ts`, add the import:

```ts
import { resolveRunSpans, type RunSpan } from "./overlays/textRuns";
```

Add this exported helper above `buildTextObject`:

```ts
/**
 * Paint run overrides onto a Textbox via Fabric's own per-character styles.
 *
 * Fabric is kept as the authority for mixed-style wrapping on purpose: it
 * already maintains character styles correctly through typing, paste and
 * backspace, and reimplementing that would put LEGACY text on new code too.
 * The shared layout module exists for Konva, which has no equivalent.
 *
 * Offsets are DISPLAY offsets — `RunSpan.displayStart/displayLength` — because
 * the Textbox holds the transformed string, not the stored content.
 *
 * Only properties a run actually overrides are written, so an unstyled span
 * inherits the object-level font exactly as before.
 */
export function applyRunStylesToTextbox(
  box: fabric.Textbox,
  spans: RunSpan[] | null
): void {
  if (!spans) return;
  for (const s of spans) {
    if (s.displayLength <= 0) continue;
    box.setSelectionStyles(
      {
        fontFamily: s.fontFamily,
        fontWeight: s.fontWeight,
        fontStyle: s.fontStyle,
      },
      s.displayStart,
      s.displayStart + s.displayLength
    );
  }
  box.initDimensions();
}
```

Then in `buildTextObject`, replace the final two lines:

```ts
  applyTextFill(box, payload);
  return box;
```

with:

```ts
  applyRunStylesToTextbox(box, resolveRunSpans(payload));
  // AFTER the run styles: mixed fonts change the wrapped width/height, and the
  // gradient's coords are sized off the object's rendered box.
  applyTextFill(box, payload);
  return box;
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/fabricExport.runs.test.ts
bun test src/components/studio/kv-generator/fabricExport.test.ts
```

Expected: both PASS.

- [ ] **Step 5: Add the parity test**

Append to `fabricExport.runs.test.ts`:

```ts
it("renders identically to a no-runs payload when every run matches the layer style", () => {
  const plain = buildTextObject(
    payload({ fontWeight: "bold", fontFamily: "Inter" }),
    geom,
    100,
    100,
    800,
    600
  );
  const uniform = buildTextObject(
    payload({
      fontWeight: "bold",
      fontFamily: "Inter",
      // Every run restates the layer style, so this exercises the run path
      // while promising the legacy result.
      runs: [
        { length: 5, fontWeight: "bold", fontFamily: "Inter" },
        { length: 6, fontWeight: "bold", fontFamily: "Inter" },
      ],
    }),
    geom,
    100,
    100,
    800,
    600
  );
  expect(uniform.text).toBe(plain.text);
  expect(uniform.width).toBeCloseTo(plain.width!, 5);
  expect(uniform.height).toBeCloseTo(plain.height!, 5);
  expect(uniform.textLines).toEqual(plain.textLines);
});
```

Run it:

```bash
bun test src/components/studio/kv-generator/fabricExport.runs.test.ts
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/fabricExport.ts src/components/studio/kv-generator/fabricExport.runs.test.ts
git commit -m "feat(web): render text runs through the shared Fabric builder"
```

---

### Task 7: The live Craft canvas

**Files:**
- Modify: `src/components/studio/kv-generator/overlays/overlayStyleSignature.ts`
- Modify: `src/components/studio/kv-generator/KvFabricCanvas.tsx` (both Textbox branches of the reconcile, ~line 2289-2352)
- Test: `src/components/studio/kv-generator/overlays/overlayStyleSignature.test.ts` (extend)

**Interfaces:**
- Consumes: `applyRunStylesToTextbox` from `./fabricExport` (Task 6), `resolveRunSpans` from `./overlays/textRuns` (Task 1).
- Produces: no new exports.

- [ ] **Step 1: Write the failing test**

Append to `src/components/studio/kv-generator/overlays/overlayStyleSignature.test.ts`:

```ts
describe("runs", () => {
  it("changes the signature when a run's styling changes", () => {
    const a = overlayStyleSignature([text({ runs: [{ length: 5, fontWeight: "bold" }] })]);
    const b = overlayStyleSignature([text({ runs: [{ length: 5, fontStyle: "italic" }] })]);
    const none = overlayStyleSignature([text({})]);
    expect(a).not.toBe(b);
    expect(a).not.toBe(none);
  });

  it("changes the signature when only a run BOUNDARY moves", () => {
    const a = overlayStyleSignature([text({ runs: [{ length: 5, fontWeight: "bold" }] })]);
    const b = overlayStyleSignature([text({ runs: [{ length: 6, fontWeight: "bold" }] })]);
    expect(a).not.toBe(b);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bun test src/components/studio/kv-generator/overlays/overlayStyleSignature.test.ts
```

Expected: FAIL — all three signatures are identical.

- [ ] **Step 3: Include runs in the signature**

In `overlayStyleSignature.ts`, extend the text branch's template literal with a
trailing `:${JSON.stringify(o.payload.runs ?? null)}`, and add to the module
docstring:

```
 * `runs` is included because the style effect applies per-character styles from
 * it. A run boundary moving changes nothing else in this string, so without it
 * a re-style would not repaint until an unrelated edit re-ran the reconcile.
```

- [ ] **Step 4: Apply runs in both Textbox branches**

In `KvFabricCanvas.tsx`, import:

```ts
import { applyRunStylesToTextbox } from "./fabricExport";
import { resolveRunSpans } from "./overlays/textRuns";
```

In the **existing-object** branch, after the second `found.set({ ... })` call and
before `applyTextFill(found, overlay);`:

```ts
          // Clear stale per-character styles before re-applying: a shrunken or
          // removed run would otherwise leave its styling on characters that no
          // longer belong to it.
          found.styles = {};
          applyRunStylesToTextbox(found, resolveRunSpans(overlay.payload));
```

In the **new-object** branch, replace `applyTextFill(box, overlay);` with:

```ts
          applyRunStylesToTextbox(box, resolveRunSpans(overlay.payload));
          applyTextFill(box, overlay);
```

In the style-sync effect keyed on `overlayStyleSig` (the one that applies
`fontWeight`/`fontStyle`), add the same two lines after its font-property
`set(...)` so a run change repaints without a full reconcile. Guard it with the
existing `isEditing` check that effect already uses, so live typing is never
churned.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/overlays/overlayStyleSignature.test.ts
bun test src/components/studio/kv-generator/overlays/textRuns.test.ts
bun test src/components/studio/kv-generator/fabricExport.runs.test.ts
```

Expected: PASS. `KvFabricCanvas` itself cannot be component-tested (documented
in PR #425); it rests on the shared builder's tests, type-check and the manual
check in Task 9.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/overlays/overlayStyleSignature.ts src/components/studio/kv-generator/overlays/overlayStyleSignature.test.ts src/components/studio/kv-generator/KvFabricCanvas.tsx
git commit -m "feat(web): paint text runs on the live Craft canvas"
```

---

### Task 8: Selection-scoped controls

**Files:**
- Modify: `src/components/studio/kv-generator/KvFabricCanvas.tsx` (add the outbound selection prop)
- Modify: `src/components/studio/kv-generator/overlays/TextTypographyControls.tsx`
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (~line 7703, the `<TextTypographyControls>` call site)
- Test: `src/components/studio/kv-generator/overlays/TextTypographyControls.test.tsx` (extend)

**Interfaces:**
- Consumes: `applyRunStyle`, `clearRunProp`, `runStyleAtRange`, `displayIndexToContent`, `resolveRunSpans`, `EffectiveRunStyle` (Tasks 1-2).
- Produces: `KvFabricCanvas` prop `onTextSelectionChange?: (sel: { overlayId: string; start: number; end: number } | null) => void` (DISPLAY indices); `TextTypographyControls` prop `effectiveStyle?: EffectiveRunStyle`.

- [ ] **Step 1: Write the failing test**

Append to `TextTypographyControls.test.tsx`:

```ts
it("shows Bold as inactive when the range is mixed", () => {
  render(
    <TextTypographyControls
      brandId="b1"
      payload={{ type: "text", content: "Hello world", color: "#fff", runs: [{ length: 5, fontWeight: "bold" }] }}
      overlayHeightNorm={0.1}
      imageNaturalHeight={1000}
      effectiveStyle={{ fontFamily: "Geist", fontWeight: null, fontStyle: "normal" }}
      onPatch={() => {}}
    />
  );
  expect(within(document.body).getByTitle("Bold").getAttribute("data-active")).toBe("mixed");
});

it("falls back to the payload when no effectiveStyle is supplied", () => {
  render(
    <TextTypographyControls
      brandId="b1"
      payload={{ type: "text", content: "Hi", color: "#fff", fontWeight: "bold" }}
      overlayHeightNorm={0.1}
      imageNaturalHeight={1000}
      onPatch={() => {}}
    />
  );
  expect(within(document.body).getByTitle("Bold").getAttribute("data-active")).toBe("true");
});
```

Use `within(document.body)` rather than RTL's `screen` — `screen` is broken
under `bun` in this repo and one use makes every component test in the file fail.

- [ ] **Step 2: Run the test to verify it fails**

```bash
bun test src/components/studio/kv-generator/overlays/TextTypographyControls.test.tsx
```

Expected: FAIL — `effectiveStyle` is not a prop and `SegBtn` renders no
`data-active`.

- [ ] **Step 3: Add mixed-state display to the controls**

In `TextTypographyControls.tsx`:

- Add the import: `import type { EffectiveRunStyle } from "./textRuns";`
- Add to the props type:

```ts
  /** Resolved style for whatever the controls currently act on — the selected
   *  text range while inline-editing, else the whole layer. `null` for a
   *  property means MIXED across that range. Absent ⇒ read the payload, which
   *  is what call sites that have not been wired for selection still do. */
  effectiveStyle?: EffectiveRunStyle;
```

- Derive the displayed state once, near the top of the component:

```ts
  const eff: EffectiveRunStyle = effectiveStyle ?? {
    fontFamily: payload.fontFamily ?? null,
    fontWeight: payload.fontWeight ?? "normal",
    fontStyle: payload.fontStyle ?? "normal",
  };
```

- Give `SegBtn` a `state` of `"true" | "false" | "mixed"` rendered as
  `data-active`, and drive the Bold and Italic buttons from `eff.fontWeight`
  and `eff.fontStyle` (`null` ⇒ `"mixed"`). Style `[data-active="mixed"]` with
  the same subdued treatment the existing inactive state uses plus a dotted
  underline, so mixed reads as "not simply off".
- Pass `currentFamily={eff.fontFamily ?? undefined}` to `KvTextFontToolbar`.
- Toggle semantics stay: pressing Bold when `eff.fontWeight` is `"bold"` sends
  `"normal"`; when it is `null` (mixed) or `"normal"`, send `"bold"`.

- [ ] **Step 4: Route patches by selection in `KvGeneratorLayout`**

Add the import:

```ts
import {
  applyRunStyle,
  clearRunProp,
  displayIndexToContent,
  resolveRunSpans,
  runStyleAtRange,
} from "./overlays/textRuns";
```

Add state and a handler near the other overlay-selection state:

```ts
  // DISPLAY indices, reported by the Fabric canvas. Converted to stored-content
  // indices at use, because the painted string is case-transformed and
  // paragraph-spaced while the payload is not.
  const [textSelection, setTextSelection] = useState<{
    overlayId: string;
    start: number;
    end: number;
  } | null>(null);
```

Pass `onTextSelectionChange={setTextSelection}` to `<KvCanvas>` (forwarded to
`KvFabricCanvas`). At the `<TextTypographyControls>` call site:

```tsx
                    <TextTypographyControls
                      /* ...existing props... */
                      effectiveStyle={(() => {
                        if (selectedTextPayload == null) return undefined;
                        const sel =
                          textSelection?.overlayId === selectedOverlayId ? textSelection : null;
                        if (!sel || sel.start === sel.end) {
                          return runStyleAtRange(
                            selectedTextPayload,
                            0,
                            (selectedTextPayload.content ?? "").length
                          );
                        }
                        const spans = resolveRunSpans(selectedTextPayload) ?? [];
                        return runStyleAtRange(
                          selectedTextPayload,
                          displayIndexToContent(spans, sel.start),
                          displayIndexToContent(spans, sel.end)
                        );
                      })()}
                      onPatch={(partial) => {
                        const sel =
                          textSelection?.overlayId === selectedOverlayId ? textSelection : null;
                        const runProps = ["fontFamily", "fontWeight", "fontStyle"] as const;
                        const touched = runProps.filter((k) => k in partial);

                        // Nothing run-scoped in this patch (size, align, colour,
                        // spacing) — always a whole-layer change.
                        if (touched.length === 0) return patchOverlayPayload(selectedOverlayId, partial);

                        if (sel && sel.start !== sel.end) {
                          const spans = resolveRunSpans(selectedTextPayload) ?? [];
                          const a = displayIndexToContent(spans, sel.start);
                          const b = displayIndexToContent(spans, sel.end);
                          return patchOverlayPayload(selectedOverlayId, {
                            runs: applyRunStyle(selectedTextPayload, a, b, partial),
                          });
                        }

                        // No selection: the control owns the whole layer, so the
                        // layer value changes AND that property's run overrides
                        // are cleared — otherwise pressing Bold would leave some
                        // words stubbornly un-bold with no way to explain why.
                        let runs = selectedTextPayload.runs ?? [];
                        for (const k of touched) runs = clearRunProp(runs, k);
                        return patchOverlayPayload(selectedOverlayId, { ...partial, runs });
                      }}
                    />
```

`patchOverlayPayload` is the existing persistence path at that call site (the
one currently passed as `onPatch`); keep whatever it is called there.

- [ ] **Step 5: Report selection from the Fabric canvas**

In `KvFabricCanvas.tsx`, add the optional prop and wire it to Fabric's editing
events, next to the existing `selection:created` / `selection:cleared`
handlers:

```ts
    const reportTextSelection = () => {
      const obj = canvas.getActiveObject();
      if (!(obj instanceof fabric.Textbox) || !obj.isEditing) {
        onTextSelectionChange?.(null);
        return;
      }
      const overlayId = overlayIdOf(obj);
      if (!overlayId) return;
      onTextSelectionChange?.({
        overlayId,
        start: obj.selectionStart ?? 0,
        end: obj.selectionEnd ?? 0,
      });
    };
    canvas.on("text:selection:changed", reportTextSelection);
    canvas.on("text:editing:entered", reportTextSelection);
    canvas.on("text:editing:exited", () => onTextSelectionChange?.(null));
    canvas.on("selection:cleared", () => onTextSelectionChange?.(null));
```

`overlayIdOf` is the existing accessor this file already uses to read an
overlay id off a Fabric object; reuse it rather than adding another.

Register the three new listeners in the same teardown the sibling handlers use.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/overlays/TextTypographyControls.test.tsx
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/components/studio/kv-generator/overlays/TextTypographyControls.tsx src/components/studio/kv-generator/overlays/TextTypographyControls.test.tsx src/components/studio/kv-generator/KvFabricCanvas.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): style a selected text range instead of the whole layer"
```

---

### Task 9: The Konva authoring surfaces

**Files:**
- Modify: `src/components/studio/kv-generator/KvTileOverlayEditor.tsx` (text render ~2551, auto-fit measure ~2564, textarea commit)
- Modify: `src/components/studio/kv-generator/KvKonvaCanvas.tsx` (text render ~1465 and ~1855, auto-fit measure ~1474, textarea commit)
- Test: `src/components/studio/kv-generator/overlays/textRunMeasure.test.ts`

**Interfaces:**
- Consumes: `resolveRunSpans`, `remapRuns` (Tasks 1-2); `canvasMeasure` (Task 4).
- Produces: `measureRunSpansWidth(spans, fontSizePx, letterSpacingPx, measure): number` exported from `overlays/textRunLayout.ts`.

Both files render text with `Konva.Text` and edit it with a plain `<textarea>`.
Rendering swaps to the run node; editing keeps runs aligned via `remapRuns`.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/overlays/textRunMeasure.test.ts`:

```ts
import { describe, it, expect } from "bun:test";
import { measureRunSpansWidth } from "./textRunLayout";

const measure = (t: string, _f: string, w: "normal" | "bold") =>
  t.length * (w === "bold" ? 14 : 10);

describe("measureRunSpansWidth", () => {
  it("sums each span in its OWN font", () => {
    const spans = [
      { text: "Hi", fontFamily: "Geist", fontWeight: "bold" as const, fontStyle: "normal" as const },
      { text: " yo", fontFamily: "Geist", fontWeight: "normal" as const, fontStyle: "normal" as const },
    ];
    expect(measureRunSpansWidth(spans, 20, 0, measure)).toBe(2 * 14 + 3 * 10);
  });

  it("includes letter spacing per character", () => {
    const spans = [
      { text: "ab", fontFamily: "Geist", fontWeight: "normal" as const, fontStyle: "normal" as const },
    ];
    expect(measureRunSpansWidth(spans, 20, 3, measure)).toBe(2 * 10 + 2 * 3);
  });

  it("measures only the longest line for multi-line text", () => {
    const spans = [
      { text: "a\nbbb", fontFamily: "Geist", fontWeight: "normal" as const, fontStyle: "normal" as const },
    ];
    expect(measureRunSpansWidth(spans, 20, 0, measure)).toBe(30);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bun test src/components/studio/kv-generator/overlays/textRunMeasure.test.ts
```

Expected: FAIL — `measureRunSpansWidth` is not exported.

- [ ] **Step 3: Add the measurer**

Append to `textRunLayout.ts`:

```ts
/**
 * Widest line of a styled string, each run measured in its own font — what the
 * auto-fit box needs. The existing `measureTextWidth` call sites pass a single
 * font (and today do not even pass family or style), which under-measures a
 * bold run and clips the box.
 */
export function measureRunSpansWidth(
  spans: StyledSpan[],
  fontSizePx: number,
  letterSpacingPx: number,
  measure: MeasureFn
): number {
  let widest = 0;
  let current = 0;
  for (const s of spans) {
    const parts = s.text.split("\n");
    parts.forEach((part, i) => {
      if (i > 0) {
        widest = Math.max(widest, current);
        current = 0;
      }
      current += measure(part, s.fontFamily, s.fontWeight, s.fontStyle) + letterSpacingPx * part.length;
    });
  }
  return Math.max(widest, current);
}
```

- [ ] **Step 4: Swap the render in both files**

First add the react-konva wrapper, next to `ShapeKonvaNode.tsx` — the existing
precedent for a Konva node used from JSX. Create
`src/components/studio/kv-generator/overlays/KonvaRunText.tsx`:

```tsx
"use client";

import { Shape } from "react-konva";

import type { RunSpan } from "./textRuns";
import { layoutRunText } from "./textRunLayout";
import { canvasMeasure, runFontShorthand, type RunTextFill } from "./konvaRunText";

/** Declarative twin of `buildRunTextNode`. Both draw from `layoutRunText`, so
 *  the interactive editors and the offscreen stage cannot disagree about where
 *  a glyph goes — the drift that put four hand-written overlay renderers out of
 *  sync before. Props mirror `buildRunTextNode`'s arguments exactly. */
export function KonvaRunText(props: {
  spans: RunSpan[];
  centerX: number;
  centerY: number;
  boxWidth: number;
  fontSizePx: number;
  lineHeight: number;
  letterSpacingPx: number;
  align: "left" | "center" | "right" | "justify";
  rotation: number;
  opacity: number;
  fill: RunTextFill;
  blendMode?: GlobalCompositeOperation;
  listening?: boolean;
  onClick?: () => void;
}) {
  const layout = layoutRunText({
    spans: props.spans,
    boxWidth: props.boxWidth,
    fontSizePx: props.fontSizePx,
    lineHeight: props.lineHeight,
    letterSpacingPx: props.letterSpacingPx,
    align: props.align,
    measure: canvasMeasure(props.fontSizePx),
  });
  return (
    <Shape
      x={props.centerX}
      y={props.centerY}
      width={props.boxWidth}
      height={layout.height}
      offsetX={props.boxWidth / 2}
      offsetY={layout.height / 2}
      rotation={props.rotation}
      opacity={props.opacity}
      globalCompositeOperation={props.blendMode}
      listening={props.listening}
      onClick={props.onClick}
      sceneFunc={(ctx) => {
        ctx.save();
        ctx.textBaseline = "middle";
        ctx.textAlign = "left";
        ctx.fillStyle = resolveFillStyle(ctx, props.fill);
        layout.lines.forEach((line, i) => {
          const y = i * layout.lineHeightPx + layout.lineHeightPx / 2;
          for (const s of line.spans) {
            ctx.font = runFontShorthand(s.fontFamily, s.fontWeight, s.fontStyle, props.fontSizePx);
            ctx.fillText(s.text, s.x, y);
          }
        });
        ctx.restore();
      }}
    />
  );
}
```

Export `resolveFillStyle` from `konvaRunText.ts` (it is currently module-private)
and import it here, so the gradient logic has exactly one implementation.

Then, in each of `KvTileOverlayEditor.tsx` and `KvKonvaCanvas.tsx`, at every
place a text overlay becomes a `<Text>`, take the run branch first. Feed it the
same values that file already computes for its `<Text>`: `cx`/`cy` for
`centerX`/`centerY`, `metrics.boxWidth` for `boxWidth`, `metrics.fontSizePx`,
`metrics.lineHeight`, `metrics.letterSpacingPx`, `metrics.align`,
`overlay.rotation`, `resolveOpacity(overlay.payload.opacity)`,
`runTextFill(overlay.payload, metrics.boxWidth, metrics.fontSizePx)`, and
`resolveBlendMode(overlay.payload)`. Keep whatever `listening`/`onClick` the
existing `<Text>` passes:

```tsx
              const runSpans = resolveRunSpans(overlay.payload);
              if (runSpans) {
                return (
                  <KonvaRunText
                    key={overlay.id}
                    spans={runSpans}
                    centerX={cx}
                    centerY={cy}
                    boxWidth={metrics.boxWidth}
                    fontSizePx={metrics.fontSizePx}
                    lineHeight={metrics.lineHeight}
                    letterSpacingPx={metrics.letterSpacingPx}
                    align={metrics.align}
                    rotation={overlay.rotation}
                    opacity={resolveOpacity(overlay.payload.opacity)}
                    fill={runTextFill(overlay.payload, metrics.boxWidth, metrics.fontSizePx)}
                    blendMode={resolveBlendMode(overlay.payload) as GlobalCompositeOperation}
                  />
                );
              }
```

If a call site names those locals differently, use its names — do not rename
existing variables to match this snippet.

- [ ] **Step 5: Fix the auto-fit measurement in both files**

`KvKonvaCanvas.tsx:1474` and `KvTileOverlayEditor.tsx:2564` both read:

```ts
              const textWidthPx = measureTextWidth(text, fontSizePx);
```

Replace each with:

```ts
              // Runs measure per-span; a layer without them keeps the old
              // single-font call, but now actually passes the family and style
              // it always should have — bold and italic glyphs are wider, and
              // under-measuring here clips the auto-fit box.
              const runSpans = resolveRunSpans(overlay.payload);
              const textWidthPx = runSpans
                ? measureRunSpansWidth(runSpans, fontSizePx, metrics.letterSpacingPx, canvasMeasure(fontSizePx))
                : measureTextWidth(
                    text,
                    fontSizePx,
                    resolveOverlayFamily(overlay.payload),
                    resolveFontStyle(overlay.payload)
                  );
```

- [ ] **Step 6: Keep runs across a textarea commit**

In both files, at the `OverlayTextEditor`'s `onCommit` handler, the new content
is written to the payload. Carry the runs with it:

```ts
              onCommit={(next) => {
                commitOverlayPayload(overlay.id, {
                  content: next,
                  // The textarea hands back a whole new string with no notion of
                  // what changed, so recover the edit by prefix/suffix diff.
                  // Without this, fixing one typo in Resize would silently wipe
                  // every per-word style on the layer.
                  runs: remapRuns(overlay.payload.content ?? "", next, overlay.payload.runs),
                });
              }}
```

Use whichever commit function that call site already uses; only the extra
`runs` key is new.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/overlays/textRunMeasure.test.ts
bun test src/components/studio/kv-generator/overlays/textRunLayout.test.ts
bun test src/components/studio/kv-generator/KvKonvaCanvas.overlays.test.tsx
```

Expected: PASS. The third is the existing Konva canvas suite — it covers the
legacy path and must stay green.

- [ ] **Step 8: Full check, then commit**

```bash
node ./node_modules/next/dist/bin/next build
```

Expected: the build completes. It does not type-check (`ignoreBuildErrors` is
on), so also diff `npx tsc --noEmit` against a baseline worktree rather than
expecting zero errors.

```bash
git add src/components/studio/kv-generator/KvKonvaCanvas.tsx src/components/studio/kv-generator/KvTileOverlayEditor.tsx src/components/studio/kv-generator/overlays/KonvaRunText.tsx src/components/studio/kv-generator/overlays/textRunLayout.ts src/components/studio/kv-generator/overlays/textRunMeasure.test.ts
git commit -m "feat(web): render and preserve text runs on the Konva editors"
```

---

## Manual verification

Automated tests cannot cover `KvFabricCanvas` (no component harness) or actual
pixels. Walk these in the browser before opening a PR:

- [ ] Craft: double-click a text layer, select one word, press Bold. Only that word bolds.
- [ ] The Bold button reads "mixed" when the selection spans a bold and a non-bold word.
- [ ] Click away, select the layer normally, press Bold. The whole layer bolds and the per-word styling is gone.
- [ ] Reload the file. The styling is still there (this is what proves the API whitelist landed).
- [ ] Download the board. The PNG matches the canvas.
- [ ] Open the Resize page. The tile shows the same styling; edit the text and confirm the styling survives.
- [ ] Open the public share link for the file. Same styling.
- [ ] Build a Motion project from that board and export it. Same styling in the video.
- [ ] Open a pre-existing KV file with plain text. Nothing about it changed.

## Analytics

Per the standing rule that a web feature is not done without its events, run the
`frndos-analytics-events` agent before calling this complete. The natural event
is a `scope` dimension (`"range"` | `"layer"`) on the existing
`trackKvTextStyleChanged`, which already fires for `font_weight` / `font_style`.
