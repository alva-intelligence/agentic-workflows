# Manual verification — KV Resize legible tile scale

Nothing here could be automated: it needs a dev server, a real KV file, and
human eyes. No subagent in this build had a browser, so **every item below is
unverified by anyone.** Six task reviews and a whole-branch review covered the
code; none of them covered the screen.

**Branch:** `feature/daffa/vc-kv-resize-legible-tile-scale` (web), 13 commits,
unpushed. Worktree: `web/.worktrees/kv-resize-legible-tile-scale` — it has its
own `bun install`, so run the dev server from there.

**Test a set that spans a wide range.** Ideally: one tile at or near the
widest native width, one mid-size tile (1080px), one tile narrower than 420px,
and — for the height ceiling — one tall-portrait tile (a story at 1080×1920,
and if you can, a custom size past about 1:4).

---

## 1. Scale policy

- [ ] The **widest tile is pixel-identical** to before the branch. Compare
      screenshots, not impressions. This is the load-bearing no-regression
      claim; the final review brute-forced 24³ tile sets and found no input
      that shrinks a tile, so a visible change here would mean something
      outside the policy moved.
- [ ] Every mid-size tile renders at the same width as the others (that is the
      floor, at 420px).
- [ ] A tile whose **native** width is under 420px renders at its native
      width, not stretched past it — no upscaling above 100%.
- [ ] A **tall-portrait tile is not enormous.** The floor is bounded on height
      too (`MAX_TILE_DISPLAY_HEIGHT = 900`), so a story tile should be tall but
      finite, and must not render blank. A blank tile here means the canvas
      exceeded the browser's area ceiling, which would also mean a blank
      export — check the export too if you see one.
- [ ] The page still lays out inside its `max-w-[900px]` column, no horizontal
      scroll.
- [ ] **Stop-and-report:** on a floored tile holding a layer that hangs
      OUTSIDE the frame, the apron must not cover the row header or the
      "Push to all tiles" / download bar. Click both while such a tile sits
      above them. The final review predicts this passes (row headers carry an
      explicit `relative z-20`, and the apron delta on a story tile is only
      90px → 112px), so a failure here is worth reporting rather than
      patching — it is the spec's open question 3.

## 2. Overlay handles

- [ ] On a small tile, select an overlay taking roughly a fifth of the frame.
      The four corner handles sit **outside** its edges.
- [ ] The interior is draggable without grabbing a handle.
- [ ] A resize drag lands where released — no drift. (Handle values are
      fabric's own measured defaults, 13 and 24; only `padding: 6` departs
      from default, and it is the one doing the work.)
- [ ] Known gap, judge whether it matters: a **multi-overlay selection** gets
      no standoff, because fabric builds that group box itself. Single
      selection and multi-selection will look inconsistent.

## 3. The zoom pill

It is the **existing shared pill in the bottom nav** — not a new one, and not
inside the canvas. It has four controls and **no reset**; that was cut because
adding a fifth control touches every canvas the pill serves.

- [ ] The pill is **visible on the Resize tab**, aligned with the other pills.
- [ ] It reads **100% on load.** This one had a real bug — it used to show
      Craft's percentage (e.g. 38%) while the viewport sat at 100%, until your
      first zoom. Fixed, and now covered by a test, but worth one look.
- [ ] `−` / `+` change the percentage and zoom about the viewport centre.
- [ ] The Fit control's tooltip reads **"Fit tile"** on Resize (it says
      "Fit all" on the other canvases, which was wrong here).
- [ ] Fit with a tile active frames **that** tile with a visible surround.
- [ ] Fit with the master row active frames the master row.
- [ ] Fit with **nothing** active now frames the **master row** — it used to
      do nothing at all, which made the feature's only discoverable
      affordance dead on arrival.
- [ ] **Parked, decide if it bothers you:** in that last case the master row
      is framed but *not selected* — no highlight, and the Layers panel keeps
      pointing wherever it was. One line to change if it reads wrong.
- [ ] Panning does not change the percentage readout.
- [ ] `ctrl`/`cmd`+wheel still zooms and the readout tracks it.
- [ ] Switch **Resize → Craft → Resize**: the pill works in both and never
      goes dead. Both canvases register into one `zoomApiRef`, so a bad
      cleanup order would kill it — the final review traced the branches as
      mutually exclusive and predicts this passes.
- [ ] PostHog receives the **existing** `kv_generator.canvas_zoom` with
      `canvas_mode: "resize"` and the right `action`. No new event was added;
      a Resize-specific one would have split the funnel.

## 4. Fit lands slightly under 100% on portrait tiles

Not a bug — a floored 420×747 tile in a ~1000×800 viewport fits at about 96%.
Correct fit semantics, but if you read "fit" as "make this bigger" you will
want `+` afterwards. Flagging so it doesn't read as broken.

---

## Open questions only you can answer

These are why the constants are named exports rather than inlined — each is a
one-edit retune.

1. **Is `MIN_TILE_DISPLAY_WIDTH = 420` right?** It was chosen from arithmetic,
   never seen.
2. **Is `MAX_TILE_DISPLAY_HEIGHT = 900` right?** Same.
3. **Do short-landscape tiles also need a lift?** The height ceiling does
   nothing for them. Text size normalizes against board *height*, so a
   420×220 tile still renders 3%-of-height body text at about 6.6px. This is
   the half of the spec's open question 2 that is still open.
4. **Is a reset-to-100% control worth adding?** Cut deliberately; it would
   touch every canvas using the shared pill.
5. **Should Fit also be reachable from a tile row** (its context menu), not
   only the pill? The spec asked for this and the rewrite dropped it — a real
   gap rather than a decision.
