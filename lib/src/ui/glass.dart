import 'dart:ui';

import 'package:flutter/material.dart';
import 'typography.dart';

/// Liquid-glass design tokens + shared widgets used across every screen.
///
/// **Design intent (revised 2026-07-12, "exact-match" pass):** this
/// replaces the "clear-glass v6" revision (flat backdrop, no blur — see
/// git history / `PROGRESS.md` for the v1-v6 story if you want it) with a
/// direct, token-for-token translation of a real reference file the person
/// supplied: `conduit-glass-redesign.html` (+ a matching screenshot), not
/// another verbal-description pass. Every color, alpha, radius, and font in
/// this file traces back to a specific CSS rule in that file — see the
/// per-field comments below for the exact source value. Where the CSS
/// doesn't cover something this file still needs (an accent this app uses
/// that the reference screen didn't render, e.g. `amber`/`teal`), the
/// choice is called out explicitly as a *designed extension*, not
/// presented as if it came from the reference.
///
/// **Why `BackdropFilter` is back** (v6 removed it entirely): the previous
/// session's `THINKING.md` traced a real Android flicker bug to
/// `BackdropFilter` sitting on top of a backdrop that was *continuously
/// animating* (a `Timer`-driven light sweep) — `BackdropFilter` re-samples
/// and re-blurs whatever's beneath it on every paint, with no caching, so
/// an always-invalidating background forced every glass panel to pay full
/// blur cost forever, even at rest. The reference file this pass is built
/// from has **no animation anywhere** (checked: no `@keyframes`, no
/// `animation:` rule in the whole stylesheet, including the hero's
/// diagonal highlight band, which is a static gradient). That means the
/// specific mechanism behind the diagnosed bug isn't present here, so
/// blur is reintroduced — but there's no Flutter/Android environment in
/// this sandbox to benchmark that claim, so please do a real on-device
/// check before shipping (see `PROGRESS.md`). If it turns out to still be
/// a problem, the fallback is narrow: drop the `ImageFilter.blur` call in
/// [_glassSurface] (one line) and keep everything else in this file
/// unchanged — the flat-fill/border/shadow recipe still reads fine without
/// it, just less literally "frosted."
///
/// **What's a deliberate simplification, not an oversight:**
///  - The reference's `.ambient::after` 3px grain/noise texture is not
///    reproduced. It's a ~2.5%-opacity dot pattern — barely visible even
///    in the source screenshot — and a faithful Flutter version would need
///    a tiled `ImageShader`/`CustomPainter`, which is real complexity and
///    real per-frame paint cost for an effect that's nearly invisible.
///    Skipped as a bad cost/payoff trade, matching this file's own
///    documented history of flagging exactly this kind of call rather
///    than silently doing (or silently skipping) it.
///  - CSS gradient angles (`115deg`, `155deg`) are approximated with
///    hand-picked [Alignment] pairs, not derived from an exact trig
///    conversion — close enough for a soft decorative gradient, called out
///    here so it doesn't read as more precise than it is.
///  - `backdrop-filter: saturate(160%)` (the color-richness boost behind
///    glass) is not reproduced — Flutter's `ImageFilter` doesn't compose a
///    saturation matrix as cheaply as a blur, and the visual gap without
///    it is small.
///
/// Modal surfaces (AlertDialog, SnackBar, BottomSheet) are deliberately
/// LEFT as standard Material — unchanged from prior sessions' reasoning: a
/// transient confirmation dialog blending into a translucent background is
/// a legibility/accessibility risk, not a style win.
class GlassColors {
  GlassColors._({
    required this.violet,
    required this.amber,
    required this.teal,
    required this.blue,
    required this.mint,
    required this.danger,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.bgTop,
    required this.bgMid,
    required this.bgBottom,
    required this.ambientIndigo,
    required this.ambientTeal,
    required this.ambientSky,
    required this.glassFill,
    required this.glassFillHover,
    required this.glassBorder,
    required this.glassBorderStrong,
    required this.glassHighlight,
    required this.ringBorderAlpha,
    required this.dockFill,
    required this.dockBorder,
  });

  // Content accents. `violet`/`blue`/`mint` map directly onto the
  // reference's `--accent-violet` / `--accent-sky` / `--accent-emerald`
  // (see hex comments below). `amber`/`teal` are accents this app needs
  // for states the reference screenshot doesn't show (e.g. "starting up",
  // a paused-transfer teal elsewhere) — chosen from the *same* palette
  // family as the three the reference does define: every one of
  // violet/emerald/sky in the CSS is exactly Tailwind's 400-weight scale
  // (`#A78BFA`, `#34D399`, `#38BDF8`), so `amber`/`teal` are the
  // Tailwind-400 members of that same family (`#FBBF24`, `#2DD4BF`)
  // rather than an arbitrary guess.
  final Color violet, amber, teal, blue, mint;

  // Not in the reference at all (its one status example, "Sync is
  // running", is a success state) — a designed extension for this app's
  // pre-existing `Error` sync status, same Tailwind-400 family as the
  // reference's own accents (`#F87171`, red-400).
  final Color danger;

  final Color textPrimary, textSecondary, textTertiary;

  // Backdrop: reference `.ambient` is `linear-gradient(180deg, #0D1220 0%,
  // #0A0E17 45%, #090C14 100%)` — a 3-stop vertical gradient, not a flat
  // color. These three stops are that gradient's literal stop colors.
  final Color bgTop, bgMid, bgBottom;

  // The three radial "glow" blobs composited over the backdrop gradient —
  // reference `.ambient` values: indigo `rgba(79,70,229,...)` = `#4F46E5`
  // at 15% -5%, teal `rgba(20,184,166,...)` = `#14B8A6` at 105% 35%, sky
  // `rgba(56,189,248,...)` = `#38BDF8` at 30% 115%. Deliberately separate
  // fields from the `violet`/`teal`/`blue` *content* accents above — the
  // ambient teal (`#14B8A6`, Tailwind teal-**500**) is a visibly different
  // shade from the `teal` accent (`#2DD4BF`, teal-400) used on icon chips,
  // and conflating them would be a silent approximation, not a match.
  final Color ambientIndigo, ambientTeal, ambientSky;

  // Reference `--glass-fill` / `--glass-fill-hover` / `--glass-border` /
  // `--glass-border-strong` / `--glass-highlight` — flat alpha-on-white
  // values, not the gradient fill/border v5/v6 used. `glassBorderStrong`
  // is used for the one glass surface that wants a more visible edge (the
  // bottom dock); `glassHighlight` is the color of the discrete 1px
  // top-edge "light catching glass" line every surface gets.
  final Color glassFill, glassFillHover, glassBorder, glassBorderStrong;
  final Color glassHighlight;

  // Hero/status-banner ring — reference `.hero{border-color:
  // rgba(52,211,153,0.22)}`. The 0.22 is a literal CSS value here (not a
  // v5-style tunable "roughly this magnitude" guess), kept as a field
  // rather than a widget-code literal only so light mode can use a
  // different number without touching `GlassStatusBanner`.
  final double ringBorderAlpha;

  // The floating bottom dock deliberately does NOT reuse `glassFill`/
  // `glassBorder` — reference `.dock` overrides `.glass`'s background and
  // border with its own flat, more-opaque values (`rgba(14,18,28,0.65)` /
  // `rgba(255,255,255,0.14)`) while keeping `.glass`'s blur. Two more
  // fields rather than a special-case branch in [_glassSurface].
  final Color dockFill, dockBorder;

  static GlassColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// Dark-mode tokens — sampled directly from
  /// `conduit-glass-redesign.html`'s `:root` custom properties. This is
  /// the mode the reference screenshot shows; treat this palette as the
  /// source of truth.
  static final GlassColors dark = GlassColors._(
    violet: const Color(0xFFA78BFA), // --accent-violet
    amber: const Color(0xFFFBBF24), // designed extension, see field doc
    teal: const Color(0xFF2DD4BF), // designed extension, see field doc
    blue: const Color(0xFF38BDF8), // --accent-sky
    mint: const Color(0xFF34D399), // --accent-emerald
    danger: const Color(0xFFF87171), // designed extension, see field doc
    textPrimary: const Color(0xFFF4F6FA), // --text-primary
    textSecondary: const Color(0xFF93A0B4), // --text-secondary
    textTertiary: const Color(0xFF5F6D82), // --text-tertiary
    bgTop: const Color(0xFF0D1220),
    bgMid: const Color(0xFF0A0E17), // also --bg-deep
    bgBottom: const Color(0xFF090C14),
    ambientIndigo: const Color(0xFF4F46E5), // --glow-indigo
    ambientTeal: const Color(0xFF14B8A6), // --glow-teal
    ambientSky: const Color(0xFF38BDF8), // same hex as --accent-sky
    glassFill: Colors.white.withValues(alpha: 0.055), // --glass-fill
    glassFillHover: Colors.white.withValues(alpha: 0.09), // --glass-fill-hover
    glassBorder: Colors.white.withValues(alpha: 0.12), // --glass-border
    glassBorderStrong:
        Colors.white.withValues(alpha: 0.22), // --glass-border-strong
    glassHighlight: Colors.white.withValues(alpha: 0.35), // --glass-highlight
    ringBorderAlpha: 0.22,
    dockFill: const Color(0xFF0E121C).withValues(alpha: 0.65),
    dockBorder: Colors.white.withValues(alpha: 0.14),
  );

  /// Light-mode tokens — the reference is dark-mode-only (same limitation
  /// every prior session's mockup had), so this is *designed*, not
  /// sampled: same structural recipe (flat fill/border, blur+saturate,
  /// discrete top highlight) at light-mode-appropriate contrast. Flagging
  /// this plainly rather than presenting it as verified — please
  /// sanity-check light mode against the real app once built.
  static final GlassColors light = GlassColors._(
    violet: const Color(0xFF6C5CE7),
    amber: const Color(0xFFB5690C),
    teal: const Color(0xFF0F8F7E),
    blue: const Color(0xFF2E5FAE),
    mint: const Color(0xFF1F9D5C),
    danger: const Color(0xFFDC2626),
    textPrimary: const Color(0xFF1B1D28),
    textSecondary: const Color(0xFF4B4F63),
    textTertiary: const Color(0xFF767B93),
    bgTop: const Color(0xFFF1EEFA),
    bgMid: const Color(0xFFE9E6F5),
    bgBottom: const Color(0xFFE2DEF0),
    ambientIndigo: const Color(0xFF4F46E5),
    ambientTeal: const Color(0xFF14B8A6),
    ambientSky: const Color(0xFF38BDF8),
    // Light glass needs more opacity than dark glass to read at all
    // against a bright backdrop (unchanged rule from every prior
    // session's light-mode notes).
    glassFill: Colors.white.withValues(alpha: 0.45),
    glassFillHover: Colors.white.withValues(alpha: 0.60),
    glassBorder: Colors.white.withValues(alpha: 0.7),
    glassBorderStrong: Colors.white.withValues(alpha: 0.85),
    glassHighlight: Colors.white.withValues(alpha: 0.9),
    ringBorderAlpha: 0.30,
    dockFill: Colors.white.withValues(alpha: 0.75),
    dockBorder: Colors.black.withValues(alpha: 0.12),
  );
}

/// Darken [c] toward black by [amount] (0-1). Used to build the two-stop
/// radial gradients the reference uses on solid icon chips (e.g. the hero
/// icon's `radial-gradient(..., rgba(52,211,153,.9), rgba(16,145,101,.9))`
/// — the second stop is roughly the first mixed ~35% toward black), so the
/// same recipe works for any accent color this app passes in, not just the
/// one the reference happened to show.
Color _darken(Color c, double amount) {
  return Color.lerp(c, Colors.black, amount) ?? c;
}

/// The discrete 1px top-edge highlight every glass surface in the
/// reference gets (`.glass::before`): inset 8% from each side, fading to
/// transparent at both ends — "light catching one edge of real glass."
Widget _specularLine(GlassColors c) {
  return Positioned(
    top: 0,
    left: 0,
    right: 0,
    height: 1,
    child: Align(
      alignment: Alignment.topCenter,
      child: FractionallySizedBox(
        widthFactor: 0.84, // 100% - 8% inset each side
        child: SizedBox(
          height: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  c.glassHighlight.withValues(
                      alpha:
                          c.glassHighlight.a * 0.55), // ::before opacity:0.55
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Shared frosted-glass surface — the Flutter translation of the
/// reference's `.glass` class: flat translucent fill, flat 1px border,
/// `backdrop-filter` blur, a discrete top-edge specular line, and the
/// two-layer drop shadow (`0 12px 24px -12px rgba(0,0,0,.55), 0 2px 4px
/// rgba(0,0,0,.25)` — the reference's third shadow, a 1px inset highlight,
/// is approximated by the specular line above rather than literally
/// reproduced, since Flutter's `boxShadow` has no `inset` variant without
/// extra layering that isn't worth it for a 1px effect already covered).
///
/// [fillOverride] / [borderOverride], when set, replace the flat
/// `glassFill`/`glassBorder` — used by [GlassStatusBanner] (the hero,
/// which gets a ring-tinted gradient fill + border-color per
/// `.hero{border-color; background:}`) and by the dock (flat, more-opaque
/// override per `.dock{background; border;}`). Every other caller uses the
/// plain neutral defaults, same as the reference's base `.glass` class.
///
/// [blur]: **added 2026-07-12, post-delivery perf fix — not something the
/// reference distinguishes.** `BackdropFilter` is real per-frame GPU work,
/// paid independently by every surface that uses it, and a screen like
/// Overview stacks up to 6 of them at once (hero + several list tiles +
/// nav bar) — the person reported this as perceptible lag switching tabs,
/// worst right when a page's panels all build/paint together. `false`
/// skips the `BackdropFilter` entirely and paints the flat/gradient fill
/// directly over the (unblurred) ambient background — still translucent,
/// still reads as glass, just a tinted pane instead of literally frosted.
/// Reserved for [GlassListTile] (the widget that multiplies per screen);
/// [GlassStatusBanner] (one per screen, the visual focal point) and the
/// dock (`GlassNavBar`/`GlassNavRail`, calls `_glassSurface` directly, not
/// through [GlassPanel]) keep the default `true` — those are the two
/// surfaces the reference itself puts front and center, and there's only
/// ever one of each on screen at a time, so the cost doesn't multiply.
Widget _glassSurface(
  BuildContext context, {
  required Widget child,
  required double borderRadius,
  EdgeInsetsGeometry padding = EdgeInsets.zero,
  Gradient? fillOverride,
  Color? borderOverride,
  bool sweep = false,
  bool blur = true,
}) {
  final c = GlassColors.of(context);
  final platform = Theme.of(context).platform;
  final isMobile =
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  final useBlur = blur && !isMobile;

  final Gradient actualFill;
  if (fillOverride != null) {
    actualFill = fillOverride;
  } else {
    final double fillOpacity = isMobile ? 0.12 : c.glassFill.a;
    final baseColor = c.glassFill.withValues(alpha: fillOpacity);
    actualFill = LinearGradient(colors: [baseColor, baseColor]);
  }

  final Color actualBorderColor;
  if (borderOverride != null) {
    actualBorderColor = borderOverride;
  } else {
    final double borderOpacity = isMobile ? 0.16 : c.glassBorder.a;
    actualBorderColor = c.glassBorder.withValues(alpha: borderOpacity);
  }

  final fill = DecoratedBox(
    decoration: BoxDecoration(
      gradient: actualFill,
      border: Border.all(
        color: actualBorderColor,
        width: 1,
      ),
    ),
  );
  return Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.55),
          blurRadius: 24,
          offset: const Offset(0, 12),
          spreadRadius: -12,
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.25),
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Stack(
        children: [
          // Blur whatever's behind this panel (the ambient background),
          // then paint the translucent fill on top in the same layer —
          // the standard Flutter frosted-glass recipe. Sigma is a visual
          // approximation of the reference's `blur(24px)`, not a literal
          // unit conversion (see class doc comment). Skipped entirely
          // when `blur: false` or when on mobile to prevent lagginess.
          //
          // RepaintBoundary added 2026-07-13, perf follow-up: DashboardScreen
          // watches AppState broadly at the shell root (deliberately, for
          // reliable invite delivery — see that file's doc comment), so the
          // active page repaints on every AppState change anywhere in the
          // app, not just ones it visually depends on. Without a boundary,
          // an expensive BackdropFilter can get swept into that repaint even
          // when nothing about the glass surface itself changed. This gives
          // the blurred layer its own compositing layer so Flutter can skip
          // repainting it when nothing about *it* changed, independent of
          // how often its ancestors repaint for unrelated reasons.
          Positioned.fill(
            child: useBlur
                ? RepaintBoundary(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: fill,
                    ),
                  )
                : fill,
          ),
          // The hero's diagonal light band (`.hero::after`) — a static
          // gradient, not an animation (see class doc comment on why that
          // distinction matters here).
          if (sweep) _heroSweep(),
          Padding(padding: padding, child: child),
          _specularLine(c),
        ],
      ),
    ),
  );
}

/// Reference `.hero::after`: `linear-gradient(115deg, transparent 40%,
/// rgba(255,255,255,.10) 48%, rgba(255,255,255,.18) 50%,
/// rgba(255,255,255,.10) 52%, transparent 60%)`, positioned to run
/// diagonally across the card. `Alignment` values here are a hand-tuned
/// approximation of the 115deg angle, not a trig conversion (see class doc
/// comment).
Widget _heroSweep() {
  return Positioned.fill(
    child: IgnorePointer(
      child: Align(
        alignment: const Alignment(-0.6, -0.9),
        child: FractionallySizedBox(
          widthFactor: 0.7,
          heightFactor: 2.2,
          child: Transform.rotate(
            angle: 0.45, // radians; visual stand-in for the 115deg CSS band
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.white.withValues(alpha: 0.10),
                    Colors.white.withValues(alpha: 0.18),
                    Colors.white.withValues(alpha: 0.10),
                    Colors.transparent,
                  ],
                  stops: const [0.40, 0.48, 0.50, 0.52, 0.60],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Persistent ambient backdrop: the reference's `.ambient` — a 3-stop
/// vertical gradient with three soft radial "glow" blobs composited over
/// it, all fully static (no motion anywhere, matching the reference
/// exactly — see class doc comment on why that matters for
/// `BackdropFilter` cost). Meant to be used once per screen, behind that
/// screen's content.
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key, this.child});
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Perf follow-up, 2026-07-13: this whole layer is static (no
        // animation — see class doc comment), but GlassBackground is
        // reconstructed as part of the same DashboardScreen.build() that
        // runs on every AppState change app-wide, so without a boundary
        // it can get repainted for reasons that have nothing to do with
        // it. RepaintBoundary lets Flutter cache and reuse this layer
        // instead of redrawing 3 radial gradients + a linear gradient on
        // every unrelated rebuild.
        RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [c.bgTop, c.bgMid, c.bgBottom],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              ),
              // Three radial blobs, positioned/sized to approximate the
              // reference's `radial-gradient(600px 500px at 15% -5%, ...)`
              // etc. CSS `at X% Y%` maps onto Flutter's Alignment as
              // `(-1 + 2*X/100, -1 + 2*Y/100)`.
              _ambientBlob(
                  color: c.ambientIndigo,
                  alpha: 0.35,
                  alignment: const Alignment(-0.7, -1.10),
                  width: 600,
                  height: 500),
              _ambientBlob(
                  color: c.ambientTeal,
                  alpha: 0.28,
                  alignment: const Alignment(1.10, -0.30),
                  width: 500,
                  height: 450),
              _ambientBlob(
                  color: c.ambientSky,
                  alpha: 0.14,
                  alignment: const Alignment(-0.40, 1.30),
                  width: 700,
                  height: 600),
            ],
          ),
        ),
        if (child != null) child!,
      ],
    );
  }

  Widget _ambientBlob({
    required Color color,
    required double alpha,
    required Alignment alignment,
    required double width,
    required double height,
  }) {
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        child: SizedBox(
          width: width,
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  color.withValues(alpha: alpha),
                  color.withValues(alpha: 0),
                ],
                stops: const [0.0, 0.6],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The core glass surface — drop-in replacement for [Card] wherever a
/// bounded container is needed. Thin wrapper around [_glassSurface].
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.borderRadius = 18, // reference `.glass{border-radius:18px}`
    this.ringColor,
    this.margin,
    this.blur = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  /// When set, this panel gets the hero/status-banner treatment: a
  /// ring-tinted border (`ringColor` at [GlassColors.ringBorderAlpha]) and
  /// a two-stop tinted fill (`ringColor@0.10 -> white@0.04`), per
  /// reference `.hero{border-color; background:}`. `null` (every other
  /// panel) gets the plain neutral `glassFill`/`glassBorder`.
  final Color? ringColor;
  final EdgeInsetsGeometry? margin;

  /// See [_glassSurface]'s `blur` parameter doc — `false` skips
  /// `BackdropFilter` for this panel (real GPU cost, paid per-instance).
  /// Defaults `true` so plain [GlassPanel] usage is unaffected; only
  /// [GlassListTile] overrides this to `false`.
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    Widget panel = _glassSurface(
      context,
      borderRadius: borderRadius,
      padding: padding,
      sweep: ringColor != null,
      blur: blur,
      borderOverride: ringColor?.withValues(alpha: c.ringBorderAlpha),
      fillOverride: ringColor != null
          ? LinearGradient(
              begin: const Alignment(-0.3, -1),
              end: const Alignment(0.3, 1),
              colors: [
                ringColor!.withValues(alpha: 0.10),
                Colors.white.withValues(alpha: 0.04),
              ],
              stops: const [0.0, 0.55],
            )
          : null,
      child: child,
    );
    if (margin != null) {
      panel = Padding(padding: margin!, child: panel);
    }
    return panel;
  }
}

/// Small section header, e.g. "Folder pairs" / "Devices on this network".
/// Reference `.section-label`: uppercase, Manrope 700, 13px, 1px letter
/// spacing, `--text-secondary`.
class GlassSectionLabel extends StatelessWidget {
  const GlassSectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 12),
      child: Text(
        text.toUpperCase(),
        style: AppTypography.manrope(
          textStyle: TextStyle(
            color: c.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
      ),
    );
  }
}

/// The big page heading at the top of each tab's scroll content, e.g.
/// "Overview" — reference `h1.page-title`: Manrope 800, 30px, -0.5
/// letter-spacing, `--text-primary`.
class GlassPageTitle extends StatelessWidget {
  const GlassPageTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 22),
      child: Text(
        text,
        style: AppTypography.manrope(
          textStyle: TextStyle(
            color: c.textPrimary,
            fontSize: 30,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
      ),
    );
  }
}

/// Small colored status dot used before a folder-pair's status text, e.g.
/// "• Two-way · Idle" — reference `.tile-sub .dot`.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color, required this.glow});
  final Color color;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 5,
      height: 5,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: glow
            ? [BoxShadow(color: color.withValues(alpha: 0.9), blurRadius: 6)]
            : null,
      ),
    );
  }
}

/// [ListTile]-shaped glass row: leading icon chip, title/subtitle,
/// trailing widget, optional tap ripple + hover highlight.
class GlassListTile extends StatelessWidget {
  const GlassListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leadingIcon,
    this.accentColor,
    this.trailing,
    this.onTap,
    this.dense = false,
    this.subtitleDotColor,
    this.subtitleMono = false,
    this.subtitleLive = false,
  });

  final String title;
  final String? subtitle;
  final IconData? leadingIcon;
  final Color? accentColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool dense;

  /// If set, a small colored dot (reference `.tile-sub .dot`) renders
  /// before [subtitle] — used for folder-pair status rows
  /// (`.status-idle`/`.status-live`), left `null` for rows that don't have
  /// a live/idle status (e.g. device rows).
  final Color? subtitleDotColor;

  /// Whether this row is in the reference's `.status-live` state: the dot
  /// gets a glow (`box-shadow: 0 0 6px currentColor`) and the subtitle
  /// text itself switches from `--text-secondary` to `--accent-emerald`,
  /// matching `.status-live{color:...}` in the CSS. `false` renders the
  /// plain `.status-idle` look (dot only, secondary text color).
  final bool subtitleLive;

  /// Whether [subtitle] renders in the reference's `.tile-sub.mono`
  /// (JetBrains Mono) treatment — used for device IDs/IP addresses.
  final bool subtitleMono;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    final accent = accentColor ?? c.violet;

    final row = Row(
      children: [
        if (leadingIcon != null) ...[
          _TileIconChip(
              icon: leadingIcon!, accent: accent, size: dense ? 34 : 38),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.manrope(
                  textStyle: TextStyle(
                    color: c.textPrimary,
                    fontSize: dense ? 13.5 : 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (subtitleDotColor != null) ...[
                      _StatusDot(color: subtitleDotColor!, glow: subtitleLive),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: subtitleMono
                            ? AppTypography.jetBrainsMono(
                                textStyle: TextStyle(
                                  color: c.textSecondary,
                                  fontSize: dense ? 10.5 : 11.5,
                                  letterSpacing: 0.2,
                                ),
                              )
                            : AppTypography.inter(
                                textStyle: TextStyle(
                                  color:
                                      subtitleLive ? c.mint : c.textSecondary,
                                  fontSize: dense ? 11.5 : 12.5,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          trailing!,
        ],
      ],
    );

    final panel = GlassPanel(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 10 : 14),
      borderRadius: 18,
      // Perf fix, 2026-07-12: list tiles are the surface that multiplies
      // per screen (a folder-pair or device row per item) — skipping the
      // real BackdropFilter blur here removes most of the per-tab-switch
      // cost while GlassStatusBanner (the hero, one per screen) and the
      // dock keep it, since those are the reference's actual visual
      // focal points and there's only ever one of each on screen.
      blur: false,
      child: row,
    );

    if (onTap == null) return panel;

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          hoverColor: c.glassFillHover,
          child: panel,
        ),
      ),
    );
  }
}

/// Leading icon chip shared by [GlassListTile] rows — reference
/// `.tile-icon`: translucent radial-gradient fill (`radial-gradient(circle
/// at 35% 30%, accent@.32, accent@.18)`), a neutral (not accent-colored)
/// border, and an accent glow shadow.
class _TileIconChip extends StatelessWidget {
  const _TileIconChip(
      {required this.icon, required this.accent, this.size = 38});
  final IconData icon;
  final Color accent;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size >= 38 ? 11 : 10),
        gradient: RadialGradient(
          center: const Alignment(-0.30, -0.40), // CSS "circle at 35% 30%"
          radius: 0.9,
          colors: [
            accent.withValues(alpha: 0.32),
            accent.withValues(alpha: 0.18),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(color: accent.withValues(alpha: 0.30), blurRadius: 14),
        ],
      ),
      child: Icon(icon, size: size >= 38 ? 18 : 16, color: accent),
    );
  }
}

/// Status/hero banner — success or in-progress state at the top of a
/// screen (e.g. "Sync is running"). Reference `.hero`: a solid
/// radial-gradient icon chip (not the translucent tile-icon recipe), the
/// ring-tinted [GlassPanel], and the diagonal `::after` light band.
class GlassStatusBanner extends StatelessWidget {
  const GlassStatusBanner({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    this.accentColor,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    final accent = accentColor ?? c.mint;
    return GlassPanel(
      ringColor: accent,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: RadialGradient(
                center: const Alignment(-0.30, -0.40),
                colors: [
                  accent.withValues(alpha: 0.95),
                  _darken(accent, 0.35).withValues(alpha: 0.95),
                ],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
              boxShadow: [
                BoxShadow(color: accent.withValues(alpha: 0.4), blurRadius: 16),
              ],
            ),
            // Reference stroke color for the hero icon is the deep
            // backdrop color (`stroke:#0A0E17`), giving a dark mark on a
            // bright fill — works for any of this app's accent colors
            // since they're all light/pastel, same as `--accent-emerald`.
            child: Icon(icon, size: 21, color: c.bgMid),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: AppTypography.manrope(
                    textStyle: TextStyle(
                      color: c.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 16.5,
                    ),
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    style: AppTypography.inter(
                      textStyle: TextStyle(
                        color: c.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small pill, e.g. "Connected"/"Paired"/"New" — reference `.badge`:
/// Manrope 700 11.5px, `accent@0.14` fill, `accent@0.3` border,
/// asymmetric padding (more on the trailing side to balance the leading
/// icon's own gap).
class GlassChip extends StatelessWidget {
  const GlassChip({
    super.key,
    required this.label,
    this.icon,
    this.accentColor,
    this.filled = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final Color? accentColor;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    final accent = accentColor ?? c.textSecondary;
    final chip = Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 11, 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: accent.withValues(alpha: filled ? 0.20 : 0.14),
        border: Border.all(color: accent.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: accent),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: AppTypography.manrope(
              textStyle: TextStyle(
                color: accent,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(onTap: onTap, child: chip),
      ),
    );
  }
}

/// Icon+label glass button with a press-scale animation. Not part of the
/// reference mockup (it doesn't show any buttons of this shape) — left
/// functionally and visually as-is from the prior session, since nothing
/// in the new reference implies a change and it doesn't reference any of
/// the tokens this pass removed.
class GlassButton extends StatefulWidget {
  const GlassButton({
    super.key,
    required this.icon,
    required this.label,
    required this.accentColor,
    this.enabled = true,
    this.selected = false,
    this.onTap,
    this.style = GlassButtonStyle.tint,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final Color accentColor;
  final bool enabled;
  final bool selected;
  final VoidCallback? onTap;
  final GlassButtonStyle style;
  final bool compact;

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

enum GlassButtonStyle { tint, primary, outline }

class _GlassButtonState extends State<GlassButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 80));
    _scale = Tween<double>(begin: 1, end: 0.94)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    final accent = widget.accentColor;
    final isPrimary = widget.style == GlassButtonStyle.primary;
    final isOutline = widget.style == GlassButtonStyle.outline;

    final Color fg = widget.enabled ? accent : c.textTertiary;
    final double fillA = widget.selected
        ? 0.30
        : isPrimary
            ? 0.24
            : isOutline
                ? 0.0
                : 0.13;
    final double fillB = isPrimary ? 0.08 : fillA * 0.4;
    final double borderA = isPrimary
        ? 0.46
        : isOutline
            ? 0.45
            : widget.selected
                ? 0.4
                : 0.30;

    return GestureDetector(
      onTapDown: widget.enabled ? (_) => _ctrl.forward() : null,
      onTapUp: widget.enabled
          ? (_) {
              _ctrl.reverse();
              widget.onTap?.call();
            }
          : null,
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          padding: EdgeInsets.symmetric(vertical: widget.compact ? 8 : 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                accent.withValues(alpha: widget.enabled ? fillA : 0.05),
                accent.withValues(alpha: widget.enabled ? fillB : 0.02),
              ],
            ),
            border: Border.all(
              color: accent.withValues(alpha: widget.enabled ? borderA : 0.14),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.selected ? Icons.check_rounded : widget.icon,
                size: widget.compact ? 17 : 20,
                color: fg,
              ),
              const SizedBox(height: 3),
              Text(
                widget.selected ? 'Sent!' : widget.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w600,
                  fontSize: widget.compact ? 9.5 : 10.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One destination in [GlassNavBar] / [GlassNavRail].
class GlassNavDestination {
  const GlassNavDestination(
      {required this.icon, required this.selectedIcon, required this.label});
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// Floating glass bottom nav bar — replaces [NavigationBar]. Reference
/// `.dock` (a `.glass` element with overridden fill/border, see
/// [GlassColors.dockFill]/[GlassColors.dockBorder]) + `.dock-item.active`
/// (a violet gradient glow — the one place a nav item gets an accent
/// tint, per the reference; every prior session's "neutral active state"
/// choice was a divergence from what the actual mockup shows, corrected
/// here now that there's a real reference to check against).
class GlassNavBar extends StatelessWidget {
  const GlassNavBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final List<GlassNavDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: _glassSurface(
        context,
        borderRadius: 18, // .dock inherits .glass's border-radius:18px
        fillOverride: LinearGradient(colors: [c.dockFill, c.dockFill]),
        borderOverride: c.dockBorder,
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            for (var i = 0; i < destinations.length; i++)
              _navItem(context, c, i),
          ],
        ),
      ),
    );
  }

  Widget _navItem(BuildContext context, GlassColors c, int i) {
    final d = destinations[i];
    final active = i == selectedIndex;
    return Expanded(
      child: InkWell(
        onTap: () => onDestinationSelected(i),
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: active
                ? LinearGradient(
                    begin: const Alignment(-0.3, -1),
                    end: const Alignment(0.3, 1),
                    colors: [
                      c.violet.withValues(alpha: 0.28),
                      c.violet.withValues(alpha: 0.14),
                    ],
                  )
                : null,
            border: active
                ? Border.all(color: Colors.white.withValues(alpha: 0.12))
                : null,
            boxShadow: active
                ? [
                    BoxShadow(
                        color: c.violet.withValues(alpha: 0.35), blurRadius: 14)
                  ]
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active ? d.selectedIcon : d.icon,
                size: 20,
                color: active ? Colors.white : c.textTertiary,
              ),
              const SizedBox(height: 4),
              Text(
                d.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                style: AppTypography.manrope(
                  textStyle: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: active ? c.textPrimary : c.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Floating glass side rail — replaces [NavigationRail] on wide desktop
/// layouts. Not shown in the reference (which is a phone-width mockup),
/// so this keeps the dock's same visual recipe (flat override fill/border
/// + violet active glow) for consistency rather than inventing a separate
/// desktop-only style.
class GlassNavRail extends StatelessWidget {
  const GlassNavRail({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.leading,
    this.trailing,
  });

  final List<GlassNavDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 14, 6, 14),
      child: _glassSurface(
        context,
        borderRadius: 22,
        fillOverride: LinearGradient(colors: [c.dockFill, c.dockFill]),
        borderOverride: c.dockBorder,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (leading != null) leading!,
            const SizedBox(height: 4),
            for (var i = 0; i < destinations.length; i++) _railItem(c, i),
            const Spacer(),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }

  Widget _railItem(GlassColors c, int i) {
    final d = destinations[i];
    final active = i == selectedIndex;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 3, 10, 3),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => onDestinationSelected(i),
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: active
                  ? LinearGradient(
                      begin: const Alignment(-0.3, -1),
                      end: const Alignment(0.3, 1),
                      colors: [
                        c.violet.withValues(alpha: 0.28),
                        c.violet.withValues(alpha: 0.14),
                      ],
                    )
                  : null,
              border: active
                  ? Border.all(color: Colors.white.withValues(alpha: 0.12))
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  active ? d.selectedIcon : d.icon,
                  size: 19,
                  color: active ? Colors.white : c.textTertiary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    d.label,
                    style: AppTypography.manrope(
                      textStyle: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: active ? c.textPrimary : c.textTertiary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
