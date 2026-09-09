import 'package:flutter/material.dart';

/// Native components shared by every screen in the reference design.
abstract final class HomeDesign {
  static const blue = Color(0xFF4785FF),
      cyan = Color(0xFF51CEFF),
      violet = Color(0xFF8267FF);
  static const background = Color(0xFF060D19),
      panel = Color(0xFF101E32),
      border = Color(0xFF293F5D);
  static const house = 'assets/images/smart_home_twilight.png';
  static const gradient = LinearGradient(colors: [blue, violet]);
  static ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: blue, brightness: brightness)
        .copyWith(
          primary: dark ? cyan : const Color(0xFF285ED9),
          surface: dark ? panel : const Color(0xFFF5F8FF),
          onSurface: dark ? const Color(0xFFF0F5FF) : const Color(0xFF14243B),
          onSurfaceVariant: dark
              ? const Color(0xFF9DAFC8)
              : const Color(0xFF52637A),
          outlineVariant: dark ? border : const Color(0xFFCBD8EC),
        );
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? background : const Color(0xFFEDF3FF),
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? background : const Color(0xFFEDF3FF),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF0B1627) : Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 17,
        ),
        border: outline,
        enabledBorder: outline,
        focusedBorder: outline.copyWith(
          borderSide: const BorderSide(color: blue, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: blue,
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        side: BorderSide(color: scheme.outlineVariant),
        selectedColor: blue.withValues(alpha: .24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: .7),
        space: 1,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? Colors.white
              : scheme.onSurfaceVariant,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? blue : scheme.outlineVariant,
        ),
      ),
    );
  }
}

class HomeBackground extends StatelessWidget {
  const HomeBackground({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: RadialGradient(
        center: const Alignment(-.8, -1),
        radius: 1.25,
        colors: Theme.of(context).brightness == Brightness.dark
            ? const [Color(0xFF152748), HomeDesign.background]
            : const [Color(0xFFE0EBFF), Color(0xFFF6F9FF)],
        stops: const [0, .8],
      ),
    ),
    child: child,
  );
}

class HomeCard extends StatelessWidget {
  const HomeCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.glowColor,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? glowColor;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF14243A), Color(0xFF0C1729)]
              : const [Colors.white, Color(0xFFF0F5FF)],
        ),
        border: Border.all(
          color:
              glowColor?.withValues(alpha: .55) ??
              Theme.of(context).colorScheme.outlineVariant,
        ),
        boxShadow: [
          BoxShadow(
            color: (glowColor ?? Colors.black).withValues(
              alpha: dark ? .12 : .05,
            ),
            blurRadius: 20,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: child,
    );
  }
}

class HomeGlowIcon extends StatelessWidget {
  const HomeGlowIcon(
    this.icon, {
    super.key,
    this.color = HomeDesign.blue,
    this.size = 48,
  });
  final IconData icon;
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * .28),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color.withValues(alpha: .38), color.withValues(alpha: .10)],
      ),
      border: Border.all(color: color.withValues(alpha: .65)),
      boxShadow: [
        BoxShadow(color: color.withValues(alpha: .24), blurRadius: size * .4),
      ],
    ),
    child: Icon(
      icon,
      color: Theme.of(context).brightness == Brightness.dark
          ? Colors.white
          : color,
      size: size * .52,
    ),
  );
}

class HomeHero extends StatelessWidget {
  const HomeHero({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon = Icons.home_outlined,
    this.trailing,
    this.height = 190,
    this.compact = false,
  });
  final String title, subtitle;
  final IconData icon;
  final Widget? trailing;
  final double height;
  final bool compact;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(24),
    child: Container(
      constraints: BoxConstraints(minHeight: height),
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage(HomeDesign.house),
          fit: BoxFit.cover,
          alignment: Alignment(0, .25),
        ),
      ),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x35060D19), Color(0xED060D19)],
          ),
        ),
        padding: EdgeInsets.all(compact ? 16 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                HomeGlowIcon(icon, size: compact ? 34 : 42),
                const Spacer(),
                if (trailing != null) trailing!,
              ],
            ),
            SizedBox(height: compact ? 12 : 30),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 27,
                fontWeight: FontWeight.w800,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              subtitle,
              style: const TextStyle(
                color: Color(0xFFC1CEE2),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class HomeSection extends StatelessWidget {
  const HomeSection(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 14),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

class HomePrimaryButton extends StatelessWidget {
  const HomePrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.arrow_forward_rounded,
    this.busy = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData icon;
  final bool busy;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: HomeDesign.gradient,
      borderRadius: BorderRadius.circular(15),
      boxShadow: [
        BoxShadow(
          color: HomeDesign.blue.withValues(alpha: onPressed == null ? 0 : .25),
          blurRadius: 18,
          offset: const Offset(0, 5),
        ),
      ],
    ),
    child: FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: Colors.transparent,
        disabledBackgroundColor: Colors.black26,
        minimumSize: const Size.fromHeight(52),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          else
            Icon(icon, size: 20),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
        ],
      ),
    ),
  );
}

class HomeVoiceButton extends StatelessWidget {
  const HomeVoiceButton({
    super.key,
    required this.onPressed,
    this.listening = false,
    this.label = 'Tap to speak',
  });
  final VoidCallback? onPressed;
  final bool listening;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Flexible(
        child: CustomPaint(
          size: const Size(100, 32),
          painter: _WavePainter(listening),
        ),
      ),
      const SizedBox(width: 16),
      Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: HomeDesign.gradient,
          boxShadow: [
            BoxShadow(
              color: HomeDesign.blue.withValues(alpha: .4),
              blurRadius: 25,
            ),
          ],
        ),
        child: IconButton(
          onPressed: onPressed,
          tooltip: label,
          padding: const EdgeInsets.all(18),
          iconSize: 30,
          icon: Icon(
            listening ? Icons.stop_rounded : Icons.mic_rounded,
            color: Colors.white,
          ),
        ),
      ),
      const SizedBox(width: 16),
      Flexible(
        child: CustomPaint(
          size: const Size(100, 32),
          painter: _WavePainter(listening),
        ),
      ),
    ],
  );
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.active);
  final bool active;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = HomeDesign.cyan.withValues(alpha: active ? .9 : .35)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    const heights = [
      .1,
      .2,
      .16,
      .5,
      .25,
      .8,
      .4,
      1,
      .6,
      .25,
      .65,
      .3,
      .15,
      .4,
      .2,
      .1,
    ];
    for (var i = 0; i < heights.length; i++) {
      final x = i * size.width / heights.length;
      final h = heights[i] * size.height / 2;
      canvas.drawLine(
        Offset(x, size.height / 2 - h),
        Offset(x, size.height / 2 + h),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) => oldDelegate.active != active;
}

class HomeBottomNav extends StatelessWidget {
  const HomeBottomNav({
    super.key,
    required this.index,
    required this.onChanged,
    this.unreadCount = 0,
  });
  final int index, unreadCount;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => HomeCard(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        for (final (i, item) in const [
          (Icons.home_rounded, 'Home'),
          (Icons.bolt_rounded, 'Energy'),
          (Icons.notifications_outlined, 'Alerts'),
          (Icons.settings_outlined, 'Settings'),
        ].indexed)
          Expanded(
            child: Semantics(
              selected: index == i,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onChanged(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Badge(
                        isLabelVisible: i == 2 && unreadCount > 0,
                        label: Text('$unreadCount'),
                        child: Icon(
                          item.$1,
                          color: index == i
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        item.$2,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: index == i
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: index == i
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class HomeSettingsRow extends StatelessWidget {
  const HomeSettingsRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.color = HomeDesign.blue,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;
  final Color color;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
    leading: HomeGlowIcon(icon, color: color, size: 38),
    title: Text(
      title,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    ),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(subtitle, style: const TextStyle(fontSize: 12)),
    ),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: onTap,
  );
}
