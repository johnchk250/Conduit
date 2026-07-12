import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

/// Liquid-glass design tokens + shared widgets used across every screen.
///
/// Design intent (revised 2026-07-12, see PROGRESS.md "vibrancy + Android
/// perf pass"): category colors (Power=amber, Media=teal, Volume=blue,
/// PC-settings/brand=violet, success=mint) now tint each [GlassPanel]'s
/// fill directly — not just its leading icon chip — so distinct controls
/// read as distinct colored glass modules (closer to iOS Control Center)
/// instead of uniform dark cards. Tint alpha is kept low (0.20/0.07) so
/// panels stay translucent glass rather than solid color; that low-alpha
/// ceiling, not the absence of color, is what keeps this from repeating
/// the earlier "flashy" pass.
///
/// [GlassBackground]'s ambient drift no longer runs a continuous 60fps
/// [Ticker] — every [BackdropFilter] on screen re-blurs whatever's beneath
/// it on every paint, so a background that never stops moving forces all
/// of them to redo that work forever, even when idle. It now drifts via a
/// throttled [Timer] + [AnimatedAlign], animating only in short bursts and
/// sitting fully static between them — see [_GlassBackgroundState] for the
/// full reasoning. This was the primary fix for reported Android
/// flicker/slowdown.
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
    required this.violetGlow,
    required this.amberGlow,
    required this.tealGlow,
    required this.blueGlow,
    required this.mintGlow,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.bgTop,
    required this.bgMid,
    required this.bgBottom,
    required this.panelFillA,
    required this.panelFillB,
    required this.borderBright,
    required this.borderDim,
  });

  final Color violet, amber, teal, blue, mint;
  final Color violetGlow, amberGlow, tealGlow, blueGlow, mintGlow;
  final Color textPrimary, textSecondary, textTertiary;
  final Color bgTop, bgMid, bgBottom;
  final Color panelFillA, panelFillB;
  final Color borderBright, borderDim;

  static GlassColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// Dark-mode tokens — the primary, fully-realized direction (matches the
  /// reviewed mockup exactly: same hexes for the five accents).
  static final GlassColors dark = GlassColors._(
    violet: const Color(0xFFAFA4F2),
    amber: const Color(0xFFF0B47A),
    teal: const Color(0xFF6FE0D2),
    blue: const Color(0xFF8FB0EE),
    mint: const Color(0xFF7BDDA0),
    violetGlow: const Color(0xFF8B7CF6).withValues(alpha: 0.11),
    amberGlow: const Color(0xFFFFA24D).withValues(alpha: 0.10),
    tealGlow: const Color(0xFF2DD4BF).withValues(alpha: 0.10),
    blueGlow: const Color(0xFF5B8DEF).withValues(alpha: 0.10),
    mintGlow: const Color(0xFF4ADE80).withValues(alpha: 0.12),
    textPrimary: const Color(0xFFF8F9FC),
    textSecondary: const Color(0xFFB4B9CE),
    textTertiary: const Color(0xFF7F86A0),
    bgTop: const Color(0xFF0B0A14),
    bgMid: const Color(0xFF0E0D1A),
    bgBottom: const Color(0xFF0A0911),
    panelFillA: Colors.white.withValues(alpha: 0.08),
    panelFillB: Colors.white.withValues(alpha: 0.02),
    borderBright: Colors.white.withValues(alpha: 0.20),
    borderDim: Colors.white.withValues(alpha: 0.04),
  );

  /// Light-mode tokens — same structure (translucent panels over a soft
  /// gradient wash) so the app doesn't look broken under
  /// `ThemeMode.system`, but necessarily quieter: light glass reads well
  /// with much lower fill/border contrast than dark glass.
  static final GlassColors light = GlassColors._(
    violet: const Color(0xFF6C5CE7),
    amber: const Color(0xFFB5690C),
    teal: const Color(0xFF0F8F7E),
    blue: const Color(0xFF2E5FAE),
    mint: const Color(0xFF1F9D5C),
    violetGlow: const Color(0xFF6C5CE7).withValues(alpha: 0.10),
    amberGlow: const Color(0xFFB5690C).withValues(alpha: 0.08),
    tealGlow: const Color(0xFF0F8F7E).withValues(alpha: 0.08),
    blueGlow: const Color(0xFF2E5FAE).withValues(alpha: 0.08),
    mintGlow: const Color(0xFF1F9D5C).withValues(alpha: 0.10),
    textPrimary: const Color(0xFF1B1D28),
    textSecondary: const Color(0xFF4B4F63),
    textTertiary: const Color(0xFF767B93),
    bgTop: const Color(0xFFF3F1FA),
    bgMid: const Color(0xFFEFEDF8),
    bgBottom: const Color(0xFFF6F4FC),
    panelFillA: Colors.white.withValues(alpha: 0.55),
    panelFillB: Colors.white.withValues(alpha: 0.22),
    borderBright: Colors.white.withValues(alpha: 0.85),
    borderDim: Colors.white.withValues(alpha: 0.25),
  );
}

/// Persistent ambient backdrop: a soft gradient wash with three diffuse
/// color blobs (violet / teal / amber) that drift very slowly. Rendered
/// with plain [RadialGradient]s rather than [BackdropFilter], since the
/// blobs have no fine detail to blur — a gradient is visually equivalent
/// here and avoids paying a blur cost on every frame for a full-screen
/// layer. Meant to be used once per screen, behind that screen's content.
class GlassBackground extends StatefulWidget {
  const GlassBackground({super.key, this.child});
  final Widget? child;

  @override
  State<GlassBackground> createState() => _GlassBackgroundState();
}

// Every GlassPanel/GlassListTile/GlassNavBar/GlassNavRail on screen paints
// itself with BackdropFilter, which re-samples and re-blurs whatever is
// beneath it EVERY time it paints. The old implementation drove this
// background with a SingleTickerProviderStateMixin AnimationController on
// `repeat(reverse: true)`, which — regardless of its 28s duration — ticks
// and repaints at a full 60fps *forever*, forcing every blur layer above it
// to redo an 18-24 sigma Gaussian blur pass on every single frame, even
// while the screen is completely idle. That sustained, uncapped per-frame
// cost (worse on Android's rasterizer than on Windows) is what surfaces as
// flicker/slowdown. Fix: drive the drift from a slow Timer that nudges the
// target position every few seconds, and let AnimatedAlign (an *implicit*
// animation) ease to it. This means the background — and everything
// blurring it above — only repaints during the short ease window, then
// sits fully static (zero repaint, zero re-blur cost) the rest of the
// time, cutting sustained animation load by roughly 60-65% versus before.
class _GlassBackgroundState extends State<GlassBackground> {
  static const _driftPeriod = Duration(seconds: 10);
  static const _driftEase = Duration(seconds: 4);
  Timer? _timer;
  double _t = 0; // 0..1, toggled — NOT ticked every frame.

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_driftPeriod, (_) {
      if (!mounted) return;
      setState(() => _t = _t == 0 ? 1 : 0);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    final t = _t;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [c.bgTop, c.bgMid, c.bgBottom],
            ),
          ),
        ),
        _blob(c.violet, Alignment(-1.1 + t * 0.12, -1.15), 0.55),
        _blob(c.teal, Alignment(1.15, -0.75 - t * 0.10), 0.5),
        _blob(c.amber, Alignment(-0.55 + t * 0.08, 1.2), 0.55),
        if (widget.child != null) widget.child!,
      ],
    );
  }

  Widget _blob(Color color, Alignment align, double radiusFactor) {
    return AnimatedAlign(
      duration: _driftEase,
      curve: Curves.easeInOutSine,
      alignment: align,
      child: FractionallySizedBox(
        widthFactor: radiusFactor,
        heightFactor: radiusFactor,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withValues(alpha: 0.16),
                color.withValues(alpha: 0.0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The core glass surface: gradient border (bright top-left, dim
/// bottom-right — light catching a curved rim) around a blurred,
/// translucent fill. Drop-in replacement for [Card] wherever a bounded
/// container is needed.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.borderRadius = 18,
    this.accentColor,
    this.blurSigma = 18,
    this.margin,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final Color? accentColor;
  final double blurSigma;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final c = GlassColors.of(context);
    final radius = BorderRadius.circular(borderRadius);

    // When a control has an accent color, let that color tint the glass
    // itself (like iOS Control Center's colored modules — WiFi reads blue,
    // Focus reads indigo) rather than only tinting the small icon chip.
    // Alphas are kept low (0.20/0.07) so the panel stays translucent glass,
    // not a flat solid-colored card — this was the previous "flashy" pass's
    // mistake, not the presence of color itself.
    final fillTop = accentColor != null
        ? accentColor!.withValues(alpha: 0.20)
        : c.panelFillA;
    final fillBottom = accentColor != null
        ? accentColor!.withValues(alpha: 0.07)
        : c.panelFillB;
    final borderTop = accentColor != null
        ? Color.lerp(c.borderBright, accentColor, 0.22)!
        : c.borderBright;

    Widget panel = Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [borderTop, c.borderDim],
        ),
      ),
      padding: const EdgeInsets.all(1.1),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius - 1.1),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius - 1.1),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [fillTop, fillBottom],
              ),
            ),
            child: child,
          ),
        ),
      ),
    );

    if (accentColor != null) {
      panel = Container(
        margin: margin,
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: accentColor!.withValues(alpha: 0.16),
              blurRadius: 26,
              offset: const Offset(0, 12),
              spreadRadius: -14,
            ),
          ],
        ),
        child: panel,
      );
    } else if (margin != null) {
      panel = Padding(padding: margin!, child: panel);
    }

    return panel;
  }
}

/// Small uppercase section header, e.g. "Folder pairs" / "Devices on this
/// network" — matches the type treatment used across the app already.
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
          color: c.textSecondary,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
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
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              color: accent.withValues(alpha: 0.16),
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

    final panel = GlassPanel(
      padding: EdgeInsets.symmetric(
          horizontal: 14, vertical: dense ? 10 : 12),
      borderRadius: 16,
      // Previously dropped: GlassListTile computed an accentColor for every
      // caller (violet/teal per row in Settings) but never passed it to the
      // panel underneath, so the tile only ever showed color on its small
      // icon chip — the glass itself stayed a flat, uncolored white fill.
      accentColor: accentColor,
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
/// screen (e.g. "Sync is running", "Remote control enabled").
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
      accentColor: accent,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  accent.withValues(alpha: 0.9),
                  accent.withValues(alpha: 0.35),
                ],
              ),
            ),
            child: Icon(icon, size: 16, color: Colors.black.withValues(alpha: 0.65)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(color: c.textSecondary, fontSize: 11.5),
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
        color: accent.withValues(alpha: filled ? 0.22 : 0.13),
        border: Border.all(color: accent.withValues(alpha: 0.36)),
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
/// action like "Cancel shutdown").
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
            mainAxisAlignment: MainAxisAlignment.center,
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

/// Floating glass bottom nav bar — replaces [NavigationBar].
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
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [c.panelFillA, c.panelFillB],
              ),
              border: Border.all(color: c.borderDim),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (var i = 0; i < destinations.length; i++)
                  _navItem(context, c, i),
              ],
            ),
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
            color: active ? c.violet.withValues(alpha: 0.20) : null,
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
/// existing `_NavRail` so callers barely change.
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
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [c.panelFillA, c.panelFillB],
              ),
              border: Border.all(color: c.borderDim),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (leading != null) leading!,
                const SizedBox(height: 4),
                for (var i = 0; i < destinations.length; i++)
                  _railItem(c, i),
                const Spacer(),
                if (trailing != null) trailing!,
              ],
            ),
          ),
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
              color: active ? c.violet.withValues(alpha: 0.20) : null,
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
