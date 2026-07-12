import 'package:flutter/material.dart';

/// Liquid-glass design tokens + shared widgets used across every screen.
///
/// Design intent (revised 2026-07-12, "clear-glass v6" pass — continuing a
/// same-day session that was interrupted before landing; see `PROGRESS.md`
/// / `THINKING.md` 2026-07-12 "v6" entries for the reference-image color
/// sampling this was built from): this is the FOURTH visual direction this
/// file has gone through in one day, and it walks back v5's backdrop
/// entirely while keeping v5's "color stays off the glass fill" rule.
///
///  1. Original glass pass — flat, low-contrast panels, color only on the
///     small leading-icon chip. Read as dull/monochrome.
///  2. "Vibrancy" pass — tinted each [GlassPanel]'s fill and border with its
///     accent color (iOS Control Center style). Reported back as "not quite
///     what I had in mind, looks ugly."
///  3. "Clear-glass v5" — un-tinted the fill again, but replaced the flat
///     backdrop with a 4-stop gradient plus an animated diagonal light
///     sweep. Reported back as still not matching expectation, this time
///     against a reference screenshot: uniform flat background, no
///     gradient, panels distinctly more see-through than v5's barely-there
///     frost.
///  4. **Clear-glass v6 (this revision)** — [GlassBackground] is now a
///     single flat color (`GlassColors.bg`), not a gradient, and has no
///     ambient motion at all. Once the backdrop is one flat color, blurring
///     it is a no-op (blurring a uniform color returns the same uniform
///     color), so [BackdropFilter] is removed from every glass surface, not
///     just toned down — same visual result, and it fully retires the
///     Android flicker-risk category v5's doc comment used to warn about
///     here, since nothing left re-samples/re-blurs on every paint. Panel
///     translucency instead comes from a lower-alpha, cool-tinted fill
///     (sampled from the reference image's tiles, which read as a
///     lightened/desaturated version of the same background blue, not a
///     white wash) composited directly over that flat backdrop, plus a
///     crisper border to keep panel edges legible now that there's no blur
///     to separate them. "Pure glass over water," not "light glinting on
///     water."
///
/// Modal surfaces (AlertDialog, SnackBar, BottomSheet) are deliberately
/// LEFT as standard Material — glass is for the persistent app chrome and
/// content cards, not for surfaces that need to read unambiguously solid
/// (a transient confirmation dialog blending into a translucent background
/// is a legibility/accessibility risk, not a style win).
class GlassColors {
  GlassColors._({
    required this.violet,
    required this.amber,
    required this.teal,
    required this.blue,
    required this.mint,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.bg,
    required this.panelFillA,
    required this.panelFillB,
    required this.borderBright,
    required this.borderDim,
    required this.specularLine,
    required this.ringBorderAlpha,
    required this.ringGlowAlpha,
    required this.navActiveFill,
    required this.navActiveBorder,
  });

  // Content accents — still used, but now ONLY for icon-chip borders/icon
  // strokes, the hero ring, filled pills, and GlassButton. Never for a
  // panel's fill or base border (that's the whole point of clear glass).
  final Color violet, amber, teal, blue, mint;

  final Color textPrimary, textSecondary, textTertiary;

  // v6: single flat backdrop color — no gradient, no stops. Matches a
  // reference screenshot's sampled background exactly (dark: #27516A).
  // See PROGRESS.md 2026-07-12 "v6" entry for the sampling method/caveats.
  final Color bg;

  // Panel fill/border — always neutral (never accent-tinted, unchanged
  // rule from v5), but v6 lowers the alpha and shifts the hue from
  // white-tinted to a cool blue-cyan tint, matching how the reference
  // image's tiles actually read: a lightened/desaturated version of `bg`,
  // not a white wash mixed into it (a literal white-blend was tested
  // against the sampled tile pixels and ruled out — see PROGRESS.md).
  final Color panelFillA, panelFillB;
  // Border stays crisp/bright — with BackdropFilter gone (see class doc
  // comment), the border is now the primary thing separating a panel's
  // edge from the flat backdrop behind it, so v6 keeps this bright rather
  // than softening it further.
  final Color borderBright, borderDim;

  final Color specularLine; // the discrete 1px top-edge highlight on glass

  // Hero/status-banner "ring" alphas — the one place v5/v6 still puts color
  // directly on a panel, as a border + glow ring rather than a fill tint.
  // Kept as tunable tokens (not literals in GlassPanel) so light mode can
  // use a toned-down scale without touching widget code — see plan §7.
  final double ringBorderAlpha;
  final double ringGlowAlpha;

  // Nav bar/rail active-item highlight. Kept as tokens (not hardcoded
  // white-alpha literals in GlassNavBar/GlassNavRail) because a literal
  // white wash reads fine on dark glass but is nearly invisible on light
  // glass — light mode needs a darkening highlight instead of a
  // brightening one. See plan §7 (nav treatment isn't covered by the
  // dark-only mockup, so this split is a designed, not copied, choice).
  final Color navActiveFill;
  final Color navActiveBorder;

  static GlassColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// Dark-mode tokens — v6: `bg` and the panel-fill hue/alpha are sampled
  /// from a user-provided reference screenshot (uniform flat blue backdrop,
  /// clearly-see-through tiles), not carried over from the v5 mockup. See
  /// PROGRESS.md 2026-07-12 "v6" entry for the exact sampling method,
  /// including the samples that were discarded as edge/icon artifacts.
  static final GlassColors dark = GlassColors._(
    violet: const Color(0xFFAFA4F2),
    amber: const Color(0xFFF0B47A),
    teal: const Color(0xFF6FE0D2),
    blue: const Color(0xFF8FB0EE),
    mint: const Color(0xFF7BDDA0),
    textPrimary: const Color(0xFFF8F9FC),
    textSecondary: const Color(0xFFB4B9CE),
    textTertiary: const Color(0xFF7F86A0),
    // Sampled directly from the reference image's open background area
    // (consistent RGB(39,81,106) across multiple margin samples).
    bg: const Color(0xFF27516A),
    // Two-stop gradient (barely distinguishable, kept only for the same
    // subtle top-left/bottom-right light-catching cue the border gradient
    // uses) of a light cyan-blue tint at low alpha over `bg`. Tuned to land
    // close to the reference tiles' sampled RGB(~35-36,91-92,125-127) —
    // see PROGRESS.md for why an exact reverse-engineered blend wasn't
    // pursued (compressed screenshot, icon-blur artifacts in several
    // samples) in favor of this "clearly see-through, right hue family"
    // approximation.
    panelFillA: const Color(0xFF8FD9FF).withValues(alpha: 0.10),
    panelFillB: const Color(0xFF8FD9FF).withValues(alpha: 0.04),
    borderBright: Colors.white.withValues(alpha: 0.32),
    borderDim: Colors.white.withValues(alpha: 0.06),
    specularLine: Colors.white.withValues(alpha: 0.7),
    ringBorderAlpha: 0.4,
    ringGlowAlpha: 0.08,
    navActiveFill: Colors.white.withValues(alpha: 0.08),
    navActiveBorder: Colors.white.withValues(alpha: 0.22),
  );

  /// Light-mode tokens — the reference image is dark-mode-only (same
  /// limitation v5 had with its mockup), so this palette is *designed*, not
  /// sampled: same v6 structural rules (flat backdrop, no blur, lower-alpha
  /// cool-tinted fill, crisp border) at light-mode-appropriate contrast.
  /// Flagging this explicitly rather than presenting it as verified — please
  /// sanity-check light mode against the app once built.
  static final GlassColors light = GlassColors._(
    violet: const Color(0xFF6C5CE7),
    amber: const Color(0xFFB5690C),
    teal: const Color(0xFF0F8F7E),
    blue: const Color(0xFF2E5FAE),
    mint: const Color(0xFF1F9D5C),
    textPrimary: const Color(0xFF1B1D28),
    textSecondary: const Color(0xFF4B4F63),
    textTertiary: const Color(0xFF767B93),
    // Flat backdrop (was a 4-stop near-white gradient) — picked the old
    // gradient's midpoint as the single flat tone, same "one uniform color,
    // no gradient" rule as dark mode's `bg`.
    bg: const Color(0xFFE9E6F5),
    // Light glass still needs more opacity than dark glass to read at all
    // against a bright backdrop (pre-existing rule, unchanged by v6), but
    // v6 still pushes it more see-through than v5's 0.55/0.22 — moved
    // toward the same direction dark mode moved, just staying legible.
    panelFillA: Colors.white.withValues(alpha: 0.40),
    panelFillB: Colors.white.withValues(alpha: 0.14),
    borderBright: Colors.white.withValues(alpha: 0.85),
    borderDim: Colors.white.withValues(alpha: 0.25),
    specularLine: Colors.white.withValues(alpha: 0.9),
    // Tuned down from dark mode's 0.4/0.08 to land in the same 0.08-0.10
    // magnitude the old *Glow tokens used, rather than the stronger accent
    // presence dark glass can carry (carried over unchanged from v5).
    ringBorderAlpha: 0.30,
    ringGlowAlpha: 0.09,
    // White washes over an already-light panel are nearly invisible, so
    // light mode's active-nav highlight darkens instead of brightens.
    navActiveFill: Colors.black.withValues(alpha: 0.06),
    navActiveBorder: Colors.black.withValues(alpha: 0.14),
  );
}

/// Shared frosted-glass surface: gradient border, blurred neutral fill, and
/// a discrete top-edge specular highlight. Used directly by [GlassPanel]
/// and — via this same function, not a copy-pasted decoration — by
/// [GlassNavBar] / [GlassNavRail], so the three can no longer silently drift
/// out of sync the way they had before (see plan §3.7).
///
/// [ringColor], when set, is v5's one remaining place color touches the
/// glass itself directly: the border gradient's bright corner becomes the
/// accent color instead of neutral white, and a thin accent glow ring is
/// added alongside the panel's normal drop shadow. Everything else about
/// the surface (fill, specular line) stays neutral either way — this is a
/// ring, not a tint.
///
/// v6: no [BackdropFilter]. [GlassBackground] is now a single flat color —
/// blurring a uniform color returns that same uniform color, so the blur
/// pass bought nothing and cost a re-sample/re-blur on every paint (the
/// mechanism behind a previously-fixed Android flicker bug, see the class
/// doc comment above). The fill is now composited directly: a two-stop,
/// low-alpha, cool-tinted gradient (`panelFillA`/`panelFillB`) painted as a
/// plain `Container`, so the flat backdrop reads through clearly with zero
/// per-frame sampling cost.
Widget _clearGlassSurface(
  BuildContext context, {
  required Widget child,
  required double borderRadius,
  Color? ringColor,
  bool specular = true,
}) {
  final c = GlassColors.of(context);
  final borderTop = ringColor != null
      ? ringColor.withValues(alpha: c.ringBorderAlpha)
      : c.borderBright;

  return Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [borderTop, c.borderDim],
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.6),
          blurRadius: 30,
          offset: const Offset(0, 14),
          spreadRadius: -12,
        ),
        if (ringColor != null)
          BoxShadow(
            color: ringColor.withValues(alpha: c.ringGlowAlpha),
            blurRadius: 0,
            spreadRadius: 1,
          ),
      ],
    ),
    padding: const EdgeInsets.all(1.1),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius - 1.1),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius - 1.1),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [c.panelFillA, c.panelFillB],
          ),
        ),
        child: specular ? Stack(children: [child, _specularLine(c)]) : child,
      ),
    ),
  );
}

/// The discrete 1px top-edge highlight every clear-glass surface gets —
/// inset 8% from each side, fading to transparent at both ends. Replaces
/// the old full-width `inset box-shadow` highlight with the mockup's more
/// literal "light catching one edge of real glass" treatment (plan §1,
/// "Panel highlight" row).
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
                colors: [Colors.transparent, c.specularLine, Colors.transparent],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Persistent ambient backdrop: a single flat color, no gradient, no
/// motion. Meant to be used once per screen, behind that screen's content.
///
/// v6: was a [StatefulWidget] driving a [Timer] + [AnimatedAlign] light
/// sweep over a 4-stop gradient (see git history for that version if it's
/// ever needed again). Once the background is one flat color there is
/// nothing left to animate or blend — a static [DecoratedBox] is strictly
/// equivalent in the one case that mattered (idle-screen repaint cost: was
/// already near-zero thanks to the throttled-Timer fix, now it's exactly
/// zero) and removes the class entirely rather than leaving inert
/// machinery behind.
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key, this.child});
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(decoration: BoxDecoration(color: c.bg)),
        if (child != null) child!,
      ],
    );
  }
}

/// The core glass surface: gradient border (bright top-left, dim
/// bottom-right — light catching a curved rim) around a blurred,
/// translucent, always-neutral fill, with a discrete top-edge specular
/// highlight. Drop-in replacement for [Card] wherever a bounded container
/// is needed. Thin wrapper around [_clearGlassSurface] that adds padding and
/// an optional outer margin.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.borderRadius = 18,
    this.ringColor,
    this.margin,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  /// v5: this used to be `accentColor`, and used to tint the panel's FILL
  /// (the "vibrancy pass" — see this file's top doc comment). Renamed
  /// deliberately, not just re-purposed under the old name: it now only
  /// affects the border + a thin glow ring, never the fill, and every
  /// caller that used to pass a fill-tinting accent needed to be looked at
  /// individually anyway (there were only two: [GlassListTile] and
  /// [GlassStatusBanner]) — see plan §3.2 for why a rename was preferred
  /// over silently changing what `accentColor` meant.
  final Color? ringColor;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    Widget panel = _clearGlassSurface(
      context,
      borderRadius: borderRadius,
      ringColor: ringColor,
      child: Padding(padding: padding, child: child),
    );
    if (margin != null) {
      panel = Padding(padding: margin!, child: panel);
    }
    return panel;
  }
}

/// Small section header, e.g. "Folder pairs" / "Devices on this
/// network". v5: bumped to `textPrimary`/15px/w700 + a text-shadow (was
/// `textSecondary`/12.5px with letter-spacing) — this now matches what
/// `dashboard_screen.dart`'s own private `_sectionHeader` helper already
/// did, so that helper is deleted in favor of this shared widget rather
/// than the two staying divergent (see plan §3.6).
class GlassSectionLabel extends StatelessWidget {
  const GlassSectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
      child: Text(
        text,
        style: TextStyle(
          color: c.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.1,
          shadows: [
            Shadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 1),
            ),
          ],
        ),
      ),
    );
  }
}

/// [ListTile]-shaped glass row: leading icon tile, title/subtitle, trailing
/// widget, optional tap ripple. Covers the very common
/// `Card(child: ListTile(...))` pattern used throughout the app.
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
  });

  final String title;
  final String? subtitle;
  final IconData? leadingIcon;
  final Color? accentColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    final accent = accentColor ?? c.violet;

    final row = Row(
      children: [
        if (leadingIcon != null) ...[
          // v5: bordered chip, not a filled wash — background stays neutral
          // (white α.06) and the accent shows up only as the border/icon
          // stroke color. Matches the mockup's `.icon-chip` exactly.
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              color: Colors.white.withValues(alpha: 0.06),
              border: Border.all(color: accent.withValues(alpha: 0.55)),
            ),
            child: Icon(leadingIcon, size: 18, color: accent),
          ),
          const SizedBox(width: 12),
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
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: dense ? 13 : 14,
                  fontWeight: FontWeight.w600,
                  shadows: [
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 5,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textTertiary,
                    fontSize: dense ? 11 : 12,
                    shadows: [
                      Shadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 5,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
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

    // v5: deliberately does NOT forward `accentColor` into the panel below
    // as a `ringColor` — this is the one place in this file that's a
    // literal re-reversal of the prior "vibrancy" session's fix (which
    // forwarded it so the panel's FILL would tint). Rows never get a ring
    // in v5; only the hero/status banner does. Calling this out explicitly
    // so it doesn't read as accidentally regressing that session's work —
    // see plan §3.3.
    final panel = GlassPanel(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: dense ? 10 : 12),
      borderRadius: 16,
      child: row,
    );

    if (onTap == null) return panel;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: panel,
        ),
      ),
    );
  }
}

/// Status/hero banner — success or in-progress state at the top of a
/// screen (e.g. "Sync is running", "Remote control enabled"). v5: the one
/// place color still touches the glass directly — as a border + glow ring
/// via `GlassPanel(ringColor:)`, never as a fill tint. Icon chip switches
/// from a filled gradient circle to the same bordered treatment every row
/// icon chip uses, just larger (44px vs 36px) — see plan §3.4.
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              color: Colors.white.withValues(alpha: 0.06),
              border: Border.all(color: accent.withValues(alpha: 0.5)),
            ),
            child: Icon(icon, size: 21, color: accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 17.5,
                    letterSpacing: -0.2,
                    shadows: [
                      Shadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 5,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      shadows: [
                        Shadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 5,
                          offset: const Offset(0, 1),
                        ),
                      ],
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

/// Small pill, e.g. a time chip or a "Connected"/"Paired"/"New" status tag.
/// v5: quieter fill, more visible border (plan §3.8 — "already structurally
/// right, just needs the numbers moved").
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
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: accent.withValues(alpha: filled ? 0.10 : 0.05),
        border: Border.all(color: accent.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: accent),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: accent,
              fontSize: 11,
              fontWeight: FontWeight.w700,
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

/// Icon+label glass button with a press-scale animation. Three visual
/// weights: tinted (default), primary (more saturated fill+glow, for the
/// one emphasized action in a group), and outline (for a rare/destructive
/// action like "Cancel shutdown"). v5: unchanged — nothing in the mockup
/// implies a change to this component (plan §3.9).
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

/// Floating glass bottom nav bar — replaces [NavigationBar]. v5: now built
/// from [_clearGlassSurface] (same formula as [GlassPanel]) instead of its
/// own hand-rolled decoration, so this and [GlassPanel] can't silently
/// drift apart again (plan §3.7). Active-item highlight is neutral —
/// v5 removes the violet tint that used to mark the selected tab.
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
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: _clearGlassSurface(
        context,
        borderRadius: 24,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < destinations.length; i++)
                _navItem(context, c, i),
            ],
          ),
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
          padding: const EdgeInsets.symmetric(vertical: 7),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: active ? c.navActiveFill : null,
            border: active ? Border.all(color: c.navActiveBorder) : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active ? d.selectedIcon : d.icon,
                size: 20,
                color: active ? c.textPrimary : c.textTertiary,
              ),
              const SizedBox(height: 2),
              Text(
                d.label,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: active ? c.textPrimary : c.textTertiary,
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
/// layouts. Keeps the same leading/trailing slot shape as the app's
/// existing `_NavRail` so callers barely change. v5: same
/// [_clearGlassSurface]-based rebuild and neutral active-item highlight as
/// [GlassNavBar] — see that class's doc comment.
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
      child: _clearGlassSurface(
        context,
        borderRadius: 22,
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
              color: active ? c.navActiveFill : null,
              border: active ? Border.all(color: c.navActiveBorder) : null,
            ),
            child: Row(
              children: [
                Icon(
                  active ? d.selectedIcon : d.icon,
                  size: 19,
                  color: active ? c.textPrimary : c.textTertiary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    d.label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: active ? c.textPrimary : c.textTertiary,
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
