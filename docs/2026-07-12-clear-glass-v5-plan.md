# Clear-glass v5 — full-app rollout plan

**Status:** 📋 planning only, no code changed — but both scope decisions this
plan originally flagged for sign-off (§5 Quick Actions row, §3.7 nav active-
item color) are now resolved and reflected throughout. Nothing left in this
document requires stopping to ask before executing. Written for hand-off to
whichever agent (or you) executes it next — see `Roadmap.md` Phase 7 for how
this slots into the existing per-screen checklist.

**Source of truth for the visual target:** `overview_redesign_preview_v5.html`
(supplied 2026-07-12) — a static mockup of the Overview screen in a new
"clear glass" direction. This doc reverse-engineers every token and structural
decision out of that HTML/CSS and maps it onto the app's existing
`lib/src/ui/glass.dart` component library and the 10 screens that consume it.

---

## 0. Why this is a new plan and not just "finish Phase 7"

Phase 7 (see `PROGRESS.md`, 2026-07-12 entries) already went through two
distinct visual directions on the *same* one converted screen
(`dashboard_screen.dart`):

1. **Original glass pass** — flat, low-contrast panels, color only on the
   small leading-icon chip. You reported this read as dull/monochrome.
2. **"Vibrancy" pass** (same day, later session) — fixed that by tinting each
   `GlassPanel`'s *fill* and border with its `accentColor`, so panels read as
   distinctly-colored frosted modules (iOS Control Center style).

`overview_redesign_preview_v5.html` is a **third direction**, and it's closer
to (1) than (2), but not identical to either — its own inline comment says
this explicitly:

> Color now lives only in icons, the status ring, and the "Connected" pill —
> the glass itself is clear... the background is a quiet neutral field with a
> single soft light sweep drifting across it, like light glinting on water
> rather than colored water.

So the concrete instruction this plan turns into code changes is: **pull the
per-panel accent-color fill/border tinting back out of `GlassPanel` /
`GlassListTile`** (i.e., partially revert the vibrancy pass), while **keeping**
that pass's Android flicker/perf fix (`Timer` + `AnimatedAlign` instead of a
free-running `AnimationController`) — that fix is orthogonal to color and
still fully applies, in fact it applies *more* here since v5 adds a second
ambient animation (the light sweep) that must be built the same
flicker-safe way. Section 6 covers this in detail.

This is why v5 needs its own plan rather than just resuming the Phase 7
checklist as-is: the shared library itself has to change again before any
more screens are converted against it, or every screen converted in the
meantime would need re-touching a second time.

---

## 1. Token diff — current `GlassColors.dark` vs. v5 target

Everything below is read directly off the HTML/CSS, not estimated.

| Token | Current (`glass.dart` dark) | v5 target | Change |
|---|---|---|---|
| Backdrop gradient | 3-stop diagonal, near-black: `#0B0A14 → #0E0D1A → #0A0911` | 4-stop, 165°: `#35495C 0% → #26374A 38% → #1A2735 68% → #121B25 100%` | **Replace.** This is the single biggest driver of the "flat" look — the old backdrop has almost no luminance range for a blur to reveal. |
| Backdrop overlay | none | radial vignette: `ellipse at 50% 25%, transparent 45% → rgba(6,10,15,0.42) 100%` | **Add.** Darkens the edges/bottom slightly so the sweep and top content stay legible. |
| Ambient motion | 3 colored blobs (violet/teal/amber), `RadialGradient`, drift via `Timer`+`AnimatedAlign` | 1 achromatic diagonal light sweep, `linear-gradient(112deg, transparent 36%, rgba(255,255,255,.10) 47%, rgba(220,235,245,.16) 50%, rgba(255,255,255,.10) 53%, transparent 64%)`, oversized (`inset:-60%`) and translated back and forth over a 13s cycle | **Replace.** No color in the backdrop at all now — see §0 quote. Also cheaper: one gradient layer instead of three. |
| Panel fill | `panelFillA/B` = white α.08 / α.02 (neutral) **or** accent α.20/.07 (vibrancy pass, accent-tinted) | white α.09 / α.02, **always** — no accent tinting | **Revert to neutral, unconditionally.** This is the core "un-vibrancy" change. |
| Panel border | `borderBright` = white α.20, lerped 22% toward accent when accent set | white α.24, **flat, never lerped toward accent** | **Revert to neutral.** Exception: the hero/status banner only — see below. |
| Panel highlight | `inset 0 1px 0 rgba(255,255,255,.28)` (box-shadow inset, full width) | same idea but as a **discrete 1px specular line**, inset 8% from each side, top edge only, `rgba(255,255,255,.7)` fading to transparent at both ends | **New element**, not just a token change — see §3.2. |
| Section-label color | `c.textSecondary` (dashboard's private `_sectionHeader`, `GlassSectionLabel` shared component) | full `#fff` / `textPrimary` | **Bump to primary.** (Also: two divergent implementations exist today — see §3.6.) |
| Row title/subtitle | plain color, no shadow | same colors, **+ `text-shadow`** (`0 1px 5px rgba(0,0,0,.3)` title, `0 1px 5px rgba(0,0,0,.25)` subtitle) | **Add.** Needed now because the backdrop is lighter and busier (gradient + sweep) than the old near-black field — without it, white text loses contrast in the brighter zones of the sweep. |
| Icon chip (row leading icon) | filled circle, `accent.withValues(alpha:.16)` background, no border | **bordered, not filled**: `background: rgba(255,255,255,.06)`, `border: 1px solid accent(alpha .55)`, icon stroke = accent | **Restyle.** Color moves from "wash" to "outline" — matches the mockup's `.icon-chip` exactly. |
| Hero / status banner | `GlassPanel(accentColor:)` — same tinted-fill treatment as any other panel | **fill stays neutral** like every other panel, but gets an accent **border** (`1px solid accent α.4`) and a subtle accent **glow ring** (`box-shadow: 0 0 0 1px accent α.08`, layered on top of the normal shadow) | **New, narrower rule.** The hero is the *one* place v5 still puts color into the glass itself — as a ring, not a fill. |
| Pill (`GlassChip`, filled) | fill α.22/.13, border α.36 | fill α.10, border α.55 | **Tune alphas** — already structurally right, just needs the numbers moved (border more visible, fill quieter). |
| Quick-action button | `GlassButton`: single bordered rounded-rect containing icon+label stacked | n/a — **decided against**, see §5 | **No change.** Overview keeps its single `Send files` row as a `GlassListTile`, restyled by the token changes above like any other row; no new circular-action layout is being built this rollout. |
| Nav bar / rail active item | `c.violet.withValues(alpha:.20)` wash | neutral wash: `rgba(255,255,255,.08)` + `rgba(255,255,255,.22)` border | **Revert to neutral — confirmed.** See §3.7. |

Nothing above is a guess — every v5-column value is copied verbatim from
`overview_redesign_preview_v5.html`. Where the HTML doesn't specify something
(e.g. light mode, since the mockup is dark-only), that's called out
separately in §7.

---

## 2. `GlassColors` — concrete field-level changes

In `lib/src/ui/glass.dart`, `GlassColors.dark`:

```dart
// REMOVE (no longer used — sweep replaces blob drift):
//   violetGlow, amberGlow, tealGlow, blueGlow, mintGlow
// (violet/amber/teal/blue/mint themselves are KEPT — still used for
//  icon-chip borders, pill accents, hero ring, GlassButton, etc. Only the
//  *Glow variants, which existed solely to feed the removed background
//  blobs, become dead code.)

bgTop:    0xFF35495C   // was 0xFF0B0A14
bgMid:    0xFF26374A   // was 0xFF0E0D1A   (add a 3rd/4th stop — see §3.1)
bgBottom: 0xFF121B25   // was 0xFF0A0911
// New 4-stop gradient needs a 4th color the current 3-field struct doesn't
// have room for — recommend adding `bgMid2: 0xFF1A2735` alongside bgMid,
// OR generalizing bgTop/Mid/Bottom into `List<Color> bgStops` with a
// matching `List<double> bgStopPositions`. The latter is more churn
// (every call site that reads bgTop/Mid/Bottom individually needs
// updating — currently only GlassBackground itself) but is the more
// honest fix if there's any chance of a 4th backdrop revision later.
// Recommendation: since only one call site reads these three fields today,
// just add the 4th field (bgMid2) — lower risk, matches existing pattern.

panelFillA:   Colors.white.withValues(alpha: 0.09)  // was 0.08 — tiny bump
panelFillB:   Colors.white.withValues(alpha: 0.02)  // unchanged
borderBright: Colors.white.withValues(alpha: 0.24)  // was 0.20
borderDim:    Colors.white.withValues(alpha: 0.04)  // unchanged — still used by nav bar/rail's own border, fine as-is
```

New fields needed for elements v5 introduces that have no current token:

```dart
final Color vignetteEdge;    // rgba(6,10,15,0.42) — radial overlay edge color
final Color specularLine;    // rgba(255,255,255,0.7) — the 1px top highlight
final Color sweepCore;       // rgba(220,235,245,0.16) — sweep band center
final Color sweepEdge;       // rgba(255,255,255,0.10) — sweep band shoulders
```

`GlassColors.light` needs the equivalent set derived from the existing light
palette — there is no v5 mockup for light mode, so this is designed-not-copied.
See §7 for the actual recommended values and the reasoning.

---

## 3. `glass.dart` component-by-component changes

### 3.1 `GlassBackground` — replace blob drift with a light sweep

Delete the three `_blob()` calls (violet/teal/amber). Replace with:

- The new 4-stop gradient (§2) as the base `DecoratedBox`.
- A radial vignette layer (`RadialGradient`, center ≈ `Alignment(0, -0.5)`,
  colors `[Colors.transparent, vignetteEdge]`, stops `[0.45, 1.0]`).
- A **sweep** layer: an oversized (larger than the screen, e.g. `160%` via
  `Transform.scale` or a `Positioned.fill` with negative insets), rotated
  ~112° band gradient (`sweepEdge → sweepCore → sweepEdge`, transparent
  outside), driven back and forth.

**Critical implementation note, not optional:** do **not** implement the
sweep's motion as a literal translation of the CSS `animation: sweep 13s
ease-in-out infinite` (i.e. a raw `AnimationController.repeat()`). That's
*exactly* the pattern the 2026-07-12 flicker fix (`PROGRESS.md`, same day)
just removed, for a reason that still applies here — probably more so, since
the sweep sits under every `BackdropFilter` on screen just like the blobs did,
and CSS `animation` is cheap in a browser (GPU compositor, no re-blur) in a
way Flutter's `BackdropFilter` is not (it re-samples/re-blurs on every paint).
**Reuse the exact `Timer.periodic` + `AnimatedAlign`/`AnimatedSlide` pattern
already validated for the blob drift** — same idle-cost profile, same visual
effect (short eased bursts, static the rest of the time), just driving a
gradient's alignment/offset instead of three circles' positions. This is the
single most important carry-over instruction in this whole plan — get it
wrong and you reintroduce the bug that was just fixed, on every screen this
plan touches, not just Overview.

### 3.2 `GlassPanel` — un-tint the fill, add the specular line

- Remove the `accentColor`-conditional fill/border branch added in the
  vibrancy pass (lines ~250–258 as of this session's read of the file) —
  `fillTop`/`fillBottom`/`borderTop` become unconditionally `c.panelFillA` /
  `c.panelFillB` / `c.borderBright`.
- Add a `bool ring = false` (or reuse `accentColor` but change its meaning —
  see below) parameter that, when set, adds an accent **border** (α.4) and an
  accent **glow shadow ring** (`0 0 0 1px accent α.08`, additive to the
  existing drop shadow) — this is what the hero card uses instead of a tinted
  fill.
- **Naming decision for the execution agent:** `GlassPanel` currently takes
  `accentColor` and uses it for fill-tinting. Under v5, the only remaining use
  of an accent on `GlassPanel` itself is the hero ring. Two reasonable paths:
  (a) keep the `accentColor` parameter name but change what it does (simpler
    diff, but silently changes behavior for any future caller who assumes the
    old fill-tint semantics — low risk since `GlassPanel` is only consumed by
    `GlassListTile` and `GlassStatusBanner` today, both of which this plan
    already updates), or
  (b) rename to `ringColor` to make the semantic change unmissable in a code
    review (more honest, marginally more churn: 2 call sites).
  **Recommend (b)** — cheap, and this codebase's own conventions (see the
  "previously dropped" / "previously silently dropped" comments already in
  `glass.dart`) show a strong preference for making these swaps explicit
  rather than reusing a name with new meaning.
- Add the specular line as a `Positioned` 1px `Container` (or a
  `ShaderMask`/gradient `DecoratedBox`) — `top: 0, left: 8%, right: 8%`,
  `LinearGradient(colors: [transparent, specularLine, transparent])`. This
  needs `Stack` inside the panel's `ClipRRect` (currently a plain `Container`
  child) — small structural change, not just a style tweak.

### 3.3 `GlassListTile` — bordered icon chip, un-forward accent into panel

- Icon chip: replace the filled-circle `Container` (`color:
  accent.withValues(alpha:.16)`) with a bordered one: `background:
  Colors.white.withValues(alpha: .06)`, `border: Border.all(color:
  accent.withValues(alpha: .55))`. Border radius stays 11–12.
- **Stop forwarding `accentColor` into the inner `GlassPanel`'s fill** (i.e.
  undo the "previously dropped, now forwarded" fix from the vibrancy-pass
  session — this is the one place in this plan that's a literal, deliberate
  re-reversal of a prior session's fix, and it should be called out as such
  in the commit message / `PROGRESS.md` entry so it doesn't read as
  regressing that session's work by accident).
- Title/subtitle: add the text-shadows from §1.

### 3.4 `GlassStatusBanner` (hero) — ring, not fill

- Switch from `GlassPanel(accentColor: accent)` (old fill-tint call) to
  `GlassPanel(ringColor: accent)` (or whatever §3.2's chosen param name is).
- Hero icon chip: same bordered treatment as §3.3's row icon chip, just
  larger (44px vs 36–40px) and using the fixed mint/status accent rather than
  a per-row accent.

### 3.5 `GlassQuickAction` (circular icon + separate label) — **deferred, not needed this rollout**

**Resolved:** Overview's Quick Actions row stays exactly as it is today —
one item (`Send files`), as a `GlassListTile` row. The mockup's 3-across
circular-shortcut layout is **not** being added; the two extra shortcuts it
implied (Clipboard, Remote) were explicitly declined. `Send files` still
gets the same token-level restyle as every other row (§3.3) — it just isn't
becoming a standalone circle.

No component work needed here as a result. The spec for the circular
variant is kept below only as a reference, in case a future screen ever
wants a genuine multi-action row — there's no current call site for it, so
don't build it speculatively:

```dart
// Reference only — no call site in this rollout.
class GlassQuickAction extends StatelessWidget {
  const GlassQuickAction({
    required this.icon,
    required this.label,
    required this.accentColor,
    this.onTap,
  });
  // 54px circle: bg white α.07, border accent α.5,
  // inset highlight white α.22 (top edge) — see mockup .action-circle.
  // Label below, 11.5/600, textSecondary-ish, with the same text-shadow
  // treatment as card text.
}
```

### 3.6 `GlassSectionLabel` vs. dashboard's private `_sectionHeader`

Pre-existing (not v5-caused) inconsistency worth fixing while this file is
open anyway: `dashboard_screen.dart` defines its own private
`_sectionHeader()` helper instead of using the shared `GlassSectionLabel`
widget, and the two already don't fully agree (dashboard's version already
uses `textPrimary`/15px/w700 — coincidentally *already* matching the v5
target — while the shared `GlassSectionLabel` component uses
`textSecondary`/12.5px/w700 with letter-spacing). Recommend: **update
`GlassSectionLabel` to match what `dashboard_screen.dart` already does**
(since that's the v5-correct version), then **delete `_sectionHeader` and
have `dashboard_screen.dart` call the shared component** — one fewer
divergent implementation for every screen this plan converts to use.

### 3.7 `GlassNavBar` / `GlassNavRail`

These two don't call `GlassPanel` — they build their own near-identical
`Container`+`BackdropFilter` decoration inline (see glass.dart lines
~734–746 and ~826–837).

1. Their fill/border move to the new neutral v5 tokens (§2), same as every
   other glass surface.
2. **Active-item color — resolved: neutral.** The active nav item drops the
   `c.violet.withValues(alpha:.20)` wash in favor of the mockup's neutral
   `.navitem.active` treatment (`bg rgba(255,255,255,.08)`, `border
   rgba(255,255,255,.22)`, no hue) — consistent with "no color in chrome,
   color only in content" everywhere else in this plan. If the active tab
   turns out to be harder to spot at a glance once this is actually
   rendered, that's worth a manual look during the visual pass (§8), but the
   default to build against is neutral, confirmed.

Also worth doing while touching these: extract the fill/border/blur
decoration both widgets duplicate into one shared private helper (e.g.
`_clearGlassDecoration(GlassColors c, {double radius})`) so `GlassPanel`,
`GlassNavBar`, and `GlassNavRail` build their surface from one formula
instead of three that can silently drift apart again in a future session —
this exact kind of drift is *why* the vibrancy pass's fix had to explicitly
call out "previously dropped, now forwarded" in its own comments. Small
refactor, meaningfully lowers the odds of a 4th redesign needing to hunt down
three copies of the same math.

### 3.8 `GlassChip` — alpha tune only

`fill α.22/.13 → .10`, `border α.36 → .55`. No structural change.

### 3.9 `GlassButton` — unchanged

Nothing in the mockup implies a change to the existing labeled-button
component (used for Pause/Resume/Quit, etc. — not shown in this Overview
mockup at all). Leave as-is; only the new `GlassQuickAction` (§3.5) is added
alongside it.

---

## 4. Per-screen rollout — inventory + task list

`dashboard_screen.dart` is the only file already on `glass.dart`; it needs
**re-touching**, not fresh conversion, since it was built against the
vibrancy-pass semantics this plan reverses. The other 9 are 100% untouched
Material — inventory below is grepped directly from the files, not estimated.

| # | File | Lines | `Card(` | `ListTile(` | `Chip(` | Dialogs | Notes |
|---|---|---:|---:|---:|---:|---:|---|
| 0 | `dashboard_screen.dart` | 876 | — (already glass) | — | — | 1 (`_InviteDialog`, stays Material) | **Re-touch**, not convert: swap `GlassPanel(accentColor:)`→`ringColor:` call at the hero, confirm `GlassListTile`/`GlassChip` pick up new tokens automatically (they should — no call-site changes needed there), migrate `_sectionHeader` → `GlassSectionLabel` (§3.6). Quick Actions row is **not** changing (§5, resolved) — no layout work there. |
| 1 | `folder_pairs_screen.dart` | 809 | 4 | 2 | 0 | 6 | Largest Material surface after send_flow_view. 6 dialogs — confirm each is a legibility-appropriate case to leave as standard Material per the documented modal rule; skim each before assuming. |
| 2 | `pairing_screen.dart` | 625 | 4 | 5 | 0 | 10 | Most dialog-heavy screen in the app — expect most of this file's *visual* footprint to stay standard Material by design (QR/pairing flows are modal-heavy), with glass only on the persistent list/status chrome. |
| 3 | `remote_control_screen.dart` | 576 | 6 | 0 | 4 | 2 | Already has 4 `Chip(` — direct 1:1 mapping to `GlassChip` with the new v5 alphas (§3.8). |
| 4 | `send_flow_view.dart` | 1138 | 2 | 0 | 3 | 0 | Largest file by far. Recommend splitting this screen's conversion into its own sub-pass (it's roughly the size of two other screens combined) rather than doing it in the same sitting as something else — matches this project's own stated preference for one bounded change at a time. |
| 5 | `send_panel.dart` | 24 | 0 | 0 | 0 | 0 | Trivial — likely just an `AppBar` wrapper; confirm before assuming zero-effort. |
| 6 | `send_widget_screen.dart` | 136 | 0 | 0 | 0 | 0 | Small. |
| 7 | `clipboard_screen.dart` | 246 | 6 | 1 | 0 | 0 | Mid-size, straightforward `Card`→`GlassListTile`/`GlassPanel` mapping. |
| 8 | `activity_screen.dart` | 180 | 0 | 1 | 3 | 0 | Small, has existing `Chip(` usage → `GlassChip`. |
| 9 | `version_history_screen.dart` | 166 | 0 | 1 | 0 | 2 | Small. |

**Suggested order** (risk-ascending — smallest/most isolated first, same
logic the project already used to justify converting `dashboard_screen.dart`
first in the original pass):

1. `glass.dart` itself (§§1–3) — its own commit, independently verifiable
   (balanced-delimiter check + full re-read, same standard every prior
   session in `PROGRESS.md` used — no Flutter SDK in most sandboxes this
   project has been worked in, so static verification is the norm here, not
   `flutter analyze`).
2. `dashboard_screen.dart` re-touch — smallest diff of the "real" screens
   since the structural work is already done, only tokens/one param name and
   the new Quick Actions row change.
3. `send_widget_screen.dart`, `send_panel.dart` (trivial).
4. `version_history_screen.dart`, `activity_screen.dart` (small, few
   dialogs).
5. `clipboard_screen.dart`, `remote_control_screen.dart` (mid-size).
6. `folder_pairs_screen.dart`, `pairing_screen.dart` (large + dialog-heavy —
   more time reasoning about which surfaces stay Material).
7. `send_flow_view.dart` last, as its own dedicated pass (largest file).

Each step = its own commit, same as the existing `Roadmap.md` Phase 7
convention (one row flips ⬜→✅ at a time).

---

## 5. Resolved: Quick Actions row stays as-is (no new shortcuts)

Today's Overview screen has exactly **one** quick action (`Send files`),
rendered as a single `GlassListTile` row (`dashboard_screen.dart`, ~line
581). The v5 mockup shows **three**: `Send files`, `Clipboard`, `Remote`, as
a row of circular shortcuts. `Clipboard` and `Remote` already exist as nav
destinations, so the two extra buttons would only have been shortcuts to
screens already reachable via the nav bar/rail — not new functionality, but
still a scope decision rather than something recoverable from a static
mockup on its own.

**Decision (confirmed):** don't add them. Overview keeps its single
`Send files` row, restyled by the token changes in §§1–3 like any other
row. §3.5's circular-action component is correspondingly not needed this
rollout — see that section for the reference spec, kept in case a future
screen genuinely wants a multi-action row.

---

## 6. Performance guardrail — do not reintroduce the flicker bug

Restating §3.1's warning here as its own section because it's the highest-
consequence mistake available in this plan, and it's easy to make by
accident if the execution agent works mockup-first (i.e. translates the CSS
`@keyframes` literally) rather than codebase-first:

- **What broke it before:** a `SingleTickerProviderStateMixin`
  `AnimationController` on `.repeat()` behind every `BackdropFilter` on
  screen, ticking at full display refresh rate forever, forcing every glass
  panel to redo its Gaussian blur every frame even at rest.
- **What fixed it:** `Timer.periodic` (coarse interval) + an *implicit*
  animation (`AnimatedAlign`) that only ticks while actively easing toward a
  new target, then goes fully idle.
- **Why v5 is at risk of the same bug:** it adds a *second* ambient
  animation (the sweep) on top of the backdrop that already needed this fix
  once. A literal port of `animation: sweep 13s ease-in-out infinite` is,
  mechanically, exactly the free-running-ticker pattern that caused the
  original bug — CSS's version is cheap only because it runs on the browser
  compositor with no re-blur cost model, which does not carry over to
  Flutter's `BackdropFilter`.
- **What to do instead:** already specified in §3.1 — same `Timer` +
  implicit-animation pattern, applied to the sweep's alignment/offset instead
  of the blobs' positions.
- **Verification expectation for whoever executes this:** the existing
  `PROGRESS.md` convention in this repo is explicit that no Flutter/Dart SDK
  has been available in the sandboxes used so far, so verification has
  consistently been static (balanced-delimiter checks, full file re-reads,
  greps for the anti-pattern) with a standing ask to the project owner to
  `flutter run` and confirm on real Android hardware before merging. Recommend
  the same discipline here: after implementing §3.1, grep the touched files
  for `AnimationController` + `.repeat(` and confirm every hit is either
  gone or explicitly justified (e.g. a condition-gated spinner, as already
  exists and was already correctly left alone in `folder_pairs_screen.dart`
  per the prior session's notes).

---

## 7. Light-mode adaptation (designed, not copied — no v5 mockup exists for it)

The mockup is dark-only. `GlassColors.light` needs its own pass following the
same *structure* v5 establishes, at light-mode-appropriate contrast (the
existing light palette is already "quieter" than dark for the same reason —
see the doc comment already on `GlassColors.light`).

Recommended approach, keeping the same relationships v5 establishes rather
than copying dark-mode numbers directly:

- Backdrop: replace the current flat lavender-tinted 3-stop gradient with a
  4-stop gradient that has the *same kind* of real top-to-bottom luminance
  range v5's dark backdrop has — e.g. a soft sky-to-paper gradient (light
  blue-grey top → warm-white bottom) rather than the current near-uniform
  `#F3F1FA`/`#EFEDF8`/`#F6F4FC` (those three are within a few percent of each
  other in lightness, which is the same "nothing for a blur to reveal"
  problem v5's dark backdrop had before this revision — worth fixing here
  too, not just in dark mode).
- Sweep: same idea, lower contrast — a warm-white band instead of the dark
  mode's cool-white one, alpha roughly halved (light-mode glass already
  needs much lower fill/border alphas than dark per the existing comment).
- Panel fill/border/specular line: keep light mode's existing much-higher
  base alphas (white α.55/.22 fill, α.85/.25 border — glass reads
  fundamentally differently on a light field), just add the specular line
  and drop any accent-fill-tinting the same way dark mode does.
- Hero ring: same accent-border-only treatment, alpha tuned down to match
  light mode's existing accent scale (see `GlassColors.light`'s existing
  `*Glow` alphas, e.g. `0.08-0.10`, as the reference point).

This section is intentionally a **direction**, not exact hex values — unlike
§§1–3 (which are verbatim off the HTML), there's no source-of-truth mockup
for light mode, so the execution agent should treat this as "match the same
structural rules dark mode now follows," check it against
`GlassColors.light`'s existing doc comment intent, and do a manual visual
pass rather than trusting numbers pulled from nowhere.

---

## 8. Acceptance criteria (per file, matches existing `Roadmap.md` Phase 7 convention)

- Same interactive behavior as before conversion — no `onTap`/`onChanged`
  logic changes anywhere (§5's Quick Actions row was the one place this
  might have changed, and it's been resolved to "no change" — see §5).
- `flutter analyze lib test` clean (or the sandbox-appropriate static-check
  equivalent, per §6, if no SDK is available in whatever environment executes
  this).
- Manual visual pass on both a wide/desktop window and a phone-width window,
  **in both light and dark mode** — light mode has had noticeably less
  design attention than dark mode throughout Phase 7 so far (see §7), worth
  explicitly checking every screen in both rather than only the mode being
  actively designed against.
- Grep check from §6 (no unguarded free-running `AnimationController` behind
  a `BackdropFilter`) on every touched file, not just `glass.dart`.

---

## 9. Suggested `Roadmap.md` update

Phase 7's existing per-screen table doesn't yet account for the fact that the
shared library itself needs a second pass before more screens should be
converted against it. Recommend inserting a row above the existing
per-screen checklist:

```
| `glass.dart` — clear-glass v5 token/component revision (see docs/2026-07-12-clear-glass-v5-plan.md) | ⬜ not started — do this before any further per-screen rows |
```

...and leaving the 10 existing/added rows as-is (still accurate — they track
per-screen conversion status, which this plan doesn't change, it just changes
what "converted" will look like once work resumes). This edit is included in
the diff patch delivered alongside this plan.

---

## Appendix: exact source values, for copy-paste reference while implementing

Pulled directly from `overview_redesign_preview_v5.html`, collected here so
the execution agent doesn't have to re-derive them from the HTML a second
time:

```
Backdrop:     linear-gradient(165deg, #35495c 0%, #26374a 38%, #1a2735 68%, #121b25 100%)
Vignette:     radial-gradient(ellipse at 50% 25%, transparent 45%, rgba(6,10,15,0.42) 100%)
Sweep band:   linear-gradient(112deg, transparent 36%, rgba(255,255,255,0.10) 47%,
                rgba(220,235,245,0.16) 50%, rgba(255,255,255,0.10) 53%, transparent 64%)
Sweep motion: inset -60%, translate(-8%,-4%) <-> translate(8%,4%), 13s ease-in-out, ping-pong
Glass fill:   linear-gradient(160deg, rgba(255,255,255,0.09), rgba(255,255,255,0.02))
Glass border: 1px solid rgba(255,255,255,0.24)
Glass shadow: 0 14px 30px -12px rgba(0,0,0,0.6), inset 0 1px 0 rgba(255,255,255,0.28)
Specular line:top:0, left/right 8%, height 1px,
                linear-gradient(90deg, transparent, rgba(255,255,255,0.7), transparent)
Hero border:  1px solid rgba(110,231,183,0.4)   [status/mint accent — swap per state]
Hero ring:    0 0 0 1px rgba(110,231,183,0.08), layered onto the normal glass shadow
Hero icon:    44x44, radius 13, bg rgba(110,231,183,0.10), border 1px solid rgba(110,231,183,0.5)
Icon chip:    40x40, radius 12, bg rgba(255,255,255,0.06), border 1px solid <accent alpha .55>
  ic-violet:  rgba(167,139,250,0.55)   ic-blue: rgba(96,165,250,0.55)   ic-amber: rgba(252,191,73,0.55)
Card title:   14.5px/600 #fff, text-shadow 0 1px 5px rgba(0,0,0,0.3)
Card sub:     12px/500 rgba(255,255,255,0.62), text-shadow 0 1px 5px rgba(0,0,0,0.25)
Chevron:      rgba(255,255,255,0.35)
Pill:         padding 6x12, radius 20, bg rgba(110,231,183,0.10),
                border 1px solid rgba(110,231,183,0.55), text/icon #a8f0cf, 11.5px/700
Action circle:54px, radius 50%, bg rgba(255,255,255,0.07),
                border 1px solid <accent alpha .5>, inset 0 1px 0 rgba(255,255,255,0.22)
Action label: 11.5px/600 rgba(255,255,255,0.7), text-shadow 0 1px 5px rgba(0,0,0,0.3)
Navbar:       blur 22px saturate 1.2, same fill/border formula as glass panel, radius 22-24
Navitem active: bg rgba(255,255,255,0.08), border 1px solid rgba(255,255,255,0.22) — no hue
Header:       26px/700 #fff, letter-spacing -0.3px, text-shadow 0 2px 10px rgba(0,0,0,0.35)
Section label:15px/700 #fff, text-shadow 0 1px 8px rgba(0,0,0,0.3)
```

**Not carried over on purpose:** the mockup's font (`Inter`, loaded via
Google Fonts link tag). The app already has an established typeface
(`Outfit`, via `google_fonts`, set in `lib/src/ui/theme.dart`) — swapping the
app's whole typeface is a much bigger, unrelated decision than a glass
re-skin, and Inter/Outfit are visually close enough (both grotesque-leaning
geometric sans) that this doesn't read as a mismatch. Flagging only so it
doesn't look like an oversight — if you *do* want the typeface changed too,
that's a one-line change in `AppTheme` but is deliberately being called out
as out of scope for this plan unless you say otherwise.
