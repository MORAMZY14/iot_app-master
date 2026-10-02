import 'package:flutter/material.dart';
import 'adaptive_home_navigation.dart';

/// Shared Material components. No screen artwork or downloaded fonts are needed.
abstract final class HomeDesign {
  static const blue = Color(0xFF5265E8);
  static const cyan = Color(0xFF8DA9FF);
  static const violet = Color(0xFF8B72D8);
  static const background = Color(0xFF0D111B);
  static const panel = Color(0xFF171D2A);
  static const border = Color(0xFF2B3447);
  static const gradient = LinearGradient(colors: [blue, Color(0xFF6B7AF0)]);

  static ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: blue, brightness: brightness)
        .copyWith(
          primary: dark ? cyan : blue,
          onPrimary: dark ? background : Colors.white,
          surface: dark ? panel : Colors.white,
          onSurface: dark ? const Color(0xFFEDF1FA) : const Color(0xFF202636),
          onSurfaceVariant: dark ? const Color(0xFFA5B0C4) : const Color(0xFF616C80),
          outlineVariant: dark ? border : const Color(0xFFE2E7F0),
        );
    final canvas = dark ? background : const Color(0xFFF4F6FB);
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(color: scheme.onSurface, fontSize: 22, fontWeight: FontWeight.w700),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        border: outline,
        enabledBorder: outline,
        focusedBorder: outline.copyWith(borderSide: BorderSide(color: scheme.primary, width: 2)),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      chipTheme: ChipThemeData(
        side: BorderSide(color: scheme.outlineVariant),
        selectedColor: scheme.primary.withValues(alpha: .12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primary.withValues(alpha: .12),
        elevation: 0,
      ),
    );
  }
}

class HomeBackground extends StatelessWidget {
  const HomeBackground({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: child,
  );
}

class HomeCard extends StatelessWidget {
  const HomeCard({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.glowColor});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? glowColor;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: glowColor?.withValues(alpha: .35) ?? scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

class HomeBrandMark extends StatelessWidget {
  const HomeBrandMark({super.key});
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(28),
    ),
    padding: const EdgeInsets.all(18),
    child: FittedBox(child: Icon(Icons.home_rounded, color: Theme.of(context).colorScheme.primary)),
  );
}

class HomeGlowIcon extends StatelessWidget {
  const HomeGlowIcon(this.icon, {super.key, this.color = HomeDesign.blue, this.size = 48});
  final IconData icon;
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(size * .3)),
    child: Icon(icon, size: size * .55, color: color),
  );
}

class HomeHero extends StatelessWidget {
  const HomeHero({
    super.key, required this.title, required this.subtitle,
    this.icon = Icons.home_outlined, this.trailing, this.height = 116,
    this.compact = false, this.photograph = false, this.showTop = true,
  });
  final String title, subtitle;
  final IconData icon;
  final Widget? trailing;
  final double height;
  // Kept as source-compatible arguments for existing screens; artwork is not used.
  final bool compact, photograph, showTop;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showTop) ...[
                  Row(children: [
                    Icon(icon, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Text('SMART HOME', style: TextStyle(color: scheme.primary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
                  ]),
                  const SizedBox(height: 14),
                ],
                Text(title, style: TextStyle(color: scheme.onSurface, fontSize: compact ? 28 : 30, height: 1.15, fontWeight: FontWeight.w700, letterSpacing: -.6)),
                const SizedBox(height: 8),
                Text(subtitle, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14, height: 1.5)),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
  }
}

class HomeSection extends StatelessWidget {
  const HomeSection(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Row(children: [
      Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
      if (trailing != null) trailing!,
    ]),
  );
}

class HomePrimaryButton extends StatelessWidget {
  const HomePrimaryButton({super.key, required this.label, required this.onPressed, this.icon = Icons.arrow_forward_rounded, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData icon;
  final bool busy;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: busy,
    child: SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16)),
        icon: busy
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icon, size: 20),
        label: Text(label, textAlign: TextAlign.center),
      ),
    ),
  );
}

class HomeVoiceButton extends StatelessWidget {
  const HomeVoiceButton({super.key, required this.onPressed, this.listening = false, this.label = 'Tap to speak', this.large = false});
  final VoidCallback? onPressed;
  final bool listening, large;
  final String label;
  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    button: true,
    child: SizedBox(
      width: large ? 84 : 64,
      height: large ? 84 : 64,
      child: IconButton.filled(
        onPressed: onPressed,
        tooltip: label,
        style: IconButton.styleFrom(backgroundColor: listening ? const Color(0xFFC84757) : HomeDesign.blue, foregroundColor: Colors.white),
        icon: Icon(listening ? Icons.stop_rounded : Icons.mic_none, size: large ? 38 : 30, color: Colors.white),
      ),
    ),
  );
}

class HomeBottomNav extends StatelessWidget {
  const HomeBottomNav({super.key, required this.index, required this.onChanged, this.unreadCount = 0});
  final int index, unreadCount;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => AdaptiveHomeNavigation(index: index, unreadCount: unreadCount, onChanged: onChanged);
}

class HomeSettingsRow extends StatelessWidget {
  const HomeSettingsRow({super.key, required this.icon, required this.title, required this.subtitle, required this.onTap, this.color = HomeDesign.blue, this.action});
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;
  final Color color;
  final String? action;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    leading: HomeGlowIcon(icon, color: color, size: 40),
    title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
    subtitle: Text(subtitle, style: TextStyle(fontSize: 13, height: 1.4, color: Theme.of(context).colorScheme.onSurfaceVariant)),
    onTap: onTap,
    trailing: action != null
        ? ConstrainedBox(constraints: const BoxConstraints(maxWidth: 104), child: Text(action!, textAlign: TextAlign.end, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12, fontWeight: FontWeight.w600)))
        : onTap != null ? const Icon(Icons.chevron_right_rounded) : null,
  );
}

class ReferenceGroup extends StatelessWidget {
  const ReferenceGroup({super.key, required this.title, required this.child, this.subtitle = ''});
  final String title, subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: HomeCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1)),
            if (subtitle.isNotEmpty) ...[const SizedBox(height: 4), Text(subtitle, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12))],
          ]),
        ),
        child,
      ]),
    ),
  );
}

class ReferenceChoice extends StatelessWidget {
  const ReferenceChoice({super.key, required this.label, required this.icon, required this.selected, required this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? scheme.primary.withValues(alpha: .12) : scheme.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 5),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 22, color: selected ? scheme.primary : scheme.onSurfaceVariant),
              const SizedBox(height: 7),
              Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: selected ? scheme.primary : scheme.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
    );
  }
}
