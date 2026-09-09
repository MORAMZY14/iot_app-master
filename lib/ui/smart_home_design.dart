import 'package:flutter/material.dart';

/// Native components shared by every screen in the reference design.
abstract final class HomeDesign {
  static const blue = Color(0xFF4162FF),
      cyan = Color(0xFF51CEFF),
      violet = Color(0xFF753CFF);
  static const background = Color(0xFF060B14),
      panel = Color(0xFF101725),
      border = Color(0xFF28374F);
  static const house = 'assets/images/smart_home_twilight.png';
  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF3538FF), Color(0xFF1821AA)],
  );
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
          borderRadius: BorderRadius.circular(12),
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
            ? const [Color(0xFF071943), HomeDesign.background]
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
    this.padding = const EdgeInsets.all(12),
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
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF131C2C), Color(0xFF0B111C)]
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

class ReferenceArt extends StatelessWidget {
  const ReferenceArt({super.key, required this.asset, required this.crop});
  final String asset;
  final Rect crop;
  static const house = ReferenceArt(
    asset: 'assets/images/reference_1.png',
    crop: Rect.fromLTWH(134, 930, 670, 350),
  );
  static const logo = ReferenceArt(
    asset: 'assets/images/reference_1.png',
    crop: Rect.fromLTWH(320, 475, 296, 293),
  );
  static const mic = ReferenceArt(
    asset: 'assets/images/reference_4.png',
    crop: Rect.fromLTWH(395, 1207, 145, 145),
  );
  static Widget room(String room) {
    final n = room.toLowerCase();
    return ReferenceArt(
      asset: 'assets/images/reference_3.png',
      crop: RegExp(r'bed|نوم').hasMatch(n)
          ? const Rect.fromLTWH(483, 752, 300, 100)
          : RegExp(r'kitchen|مطبخ').hasMatch(n)
          ? const Rect.fromLTWH(157, 933, 300, 102)
          : RegExp(r'bath|حمام').hasMatch(n)
          ? const Rect.fromLTWH(483, 933, 300, 102)
          : const Rect.fromLTWH(157, 752, 300, 100),
    );
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: crop.width,
        height: crop.height,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              left: -crop.left,
              top: -crop.top,
              width: 941,
              height: 1672,
              child: Image.asset(
                asset,
                width: 941,
                height: 1672,
                fit: BoxFit.fill,
                excludeFromSemantics: true,
              ),
            ),
          ],
        ),
      ),
    ),
  );
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
      borderRadius: BorderRadius.circular(size * .3),
      gradient: RadialGradient(
        colors: [color.withValues(alpha: .18), color.withValues(alpha: .04)],
      ),
      border: Border.all(color: color.withValues(alpha: .35)),
    ),
    child: Icon(
      icon,
      size: size * .6,
      color: Color.lerp(color, Colors.white, .35),
      shadows: [
        Shadow(color: color, blurRadius: 13),
        Shadow(color: color.withValues(alpha: .6), blurRadius: 25),
      ],
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
    this.height = 116,
    this.compact = false,
    this.photograph = true,
    this.showTop = true,
  });
  final String title, subtitle;
  final IconData icon;
  final Widget? trailing;
  final double height;
  final bool compact, photograph, showTop;
  @override
  Widget build(BuildContext context) => SizedBox(
    height:
        (compact ? 108 : height) +
        (MediaQuery.textScalerOf(context).scale(1) - 1).clamp(0, 2) * 120,
    child: Stack(
      clipBehavior: Clip.none,
      fit: StackFit.expand,
      children: [
        if (photograph)
          Positioned(
            left: -14,
            right: -14,
            top: -30,
            bottom: 0,
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (r) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white, Colors.white, Colors.transparent],
                stops: [0, .58, 1],
              ).createShader(r),
              child: ReferenceArt.house,
            ),
          ),
        if (photograph)
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0x99060B14), Color(0x00060B14)],
              ),
            ),
          ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showTop)
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xAA111B32),
                      border: Border.all(color: HomeDesign.border),
                    ),
                    child: Icon(icon, size: 21, color: Colors.white),
                  ),
                  const Spacer(),
                  if (trailing != null) trailing!,
                ],
              ),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 25,
                fontWeight: FontWeight.w500,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              subtitle,
              style: const TextStyle(
                color: Color(0xFFABBFDF),
                fontSize: 13,
                height: 1.3,
              ),
            ),
          ],
        ),
        if (photograph)
          const Positioned(
            right: 0,
            top: 43,
            child: IgnorePointer(
              child: Text(
                'A SMARTER\nBRIGHTER HOME',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 5.5,
                  letterSpacing: 1.2,
                  color: Color(0xFFCDDDFF),
                ),
              ),
            ),
          ),
      ],
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
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      gradient: HomeDesign.gradient,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFFBAB9FF), width: 1.2),
      boxShadow: onPressed == null
          ? []
          : [
              BoxShadow(
                color: HomeDesign.blue.withValues(alpha: .7),
                blurRadius: 12,
              ),
              BoxShadow(
                color: HomeDesign.violet.withValues(alpha: .3),
                blurRadius: 22,
              ),
            ],
    ),
    child: FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: Colors.transparent,
        shadowColor: Colors.transparent,
        disabledBackgroundColor: Colors.black26,
        minimumSize: const Size.fromHeight(48),
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
            Icon(icon, size: 21),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15),
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
    this.large = false,
  });
  final VoidCallback? onPressed;
  final bool listening, large;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Flexible(
        child: CustomPaint(
          size: Size(large ? 112 : 94, large ? 43 : 24),
          painter: _WavePainter(listening),
        ),
      ),
      const SizedBox(width: 5),
      Container(
        width: large ? 86 : 64,
        height: large ? 86 : 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: HomeDesign.blue.withValues(alpha: .65),
              blurRadius: 18,
            ),
            BoxShadow(
              color: HomeDesign.violet.withValues(alpha: .35),
              blurRadius: 28,
            ),
          ],
        ),
        child: ClipOval(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ReferenceArt.mic,
              Material(
                color: Colors.transparent,
                child: IconButton(
                  onPressed: onPressed,
                  tooltip: label,
                  icon: Icon(
                    listening ? Icons.stop_rounded : Icons.mic_none,
                    color: listening ? Colors.white : Colors.transparent,
                    size: 40,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(width: 5),
      Flexible(
        child: CustomPaint(
          size: Size(large ? 112 : 94, large ? 43 : 24),
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
      ..shader = const LinearGradient(
        colors: [HomeDesign.violet, HomeDesign.blue, HomeDesign.cyan],
      ).createShader(Offset.zero & size)
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
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      gradient: const LinearGradient(
        colors: [Color(0xFF101827), Color(0xFF070D17)],
      ),
      border: Border.all(color: HomeDesign.border),
    ),
    child: Row(
      children: [
        for (final (i, item) in const [
          (Icons.home_rounded, 'Home'),
          (Icons.bar_chart_rounded, 'Energy'),
          (Icons.notifications_none_rounded, 'Alerts'),
          (Icons.settings_outlined, 'Settings'),
        ].indexed)
          Expanded(
            child: Semantics(
              selected: index == i,
              child: InkWell(
                onTap: () => onChanged(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Badge(
                        isLabelVisible: i == 2 && unreadCount > 0,
                        label: Text('$unreadCount'),
                        child: Icon(
                          item.$1,
                          size: 28,
                          color: index == i
                              ? const Color(0xFF9DAEFF)
                              : const Color(0xFF8191B3),
                          shadows: index == i
                              ? [
                                  const Shadow(
                                    color: Color(0xFF452BFF),
                                    blurRadius: 13,
                                  ),
                                  const Shadow(
                                    color: Color(0xFF287DFF),
                                    blurRadius: 20,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        item.$2,
                        style: TextStyle(
                          fontSize: 11,
                          color: index == i
                              ? const Color(0xFFAAAFFF)
                              : const Color(0xFF9FAFCF),
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
    this.action,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;
  final Color color;
  final String? action;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      child: Row(
        children: [
          HomeGlowIcon(icon, color: color, size: 34),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (action != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: HomeDesign.blue.withValues(alpha: .6),
                ),
                color: HomeDesign.blue.withValues(alpha: .12),
              ),
              child: Text(action!, style: const TextStyle(fontSize: 9)),
            ),
          const SizedBox(width: 5),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
    ),
  );
}

class ReferenceGroup extends StatelessWidget {
  const ReferenceGroup({
    super.key,
    required this.title,
    required this.child,
    this.subtitle = '',
  });
  final String title, subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: HomeCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 7),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFFA6C1F5),
                    fontSize: 9,
                    letterSpacing: .7,
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 7,
                      color: Color(0xFFA5B5D5),
                    ),
                  ),
                ),
              ],
            ),
          ),
          child,
        ],
      ),
    ),
  );
}

class ReferenceChoice extends StatelessWidget {
  const ReferenceChoice({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          gradient: LinearGradient(
            colors: selected
                ? const [Color(0xFF16205B), Color(0xFF0B1030)]
                : const [Color(0xFF172030), Color(0xFF0C121D)],
          ),
          border: Border.all(
            color: selected ? const Color(0xFFAE84FF) : HomeDesign.border,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: HomeDesign.violet.withValues(alpha: .5),
                    blurRadius: 9,
                  ),
                ]
              : [],
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 19,
              color: selected ? const Color(0xFF9BBDFF) : Colors.white,
              shadows: selected
                  ? [const Shadow(color: HomeDesign.blue, blurRadius: 12)]
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 10, color: Colors.white),
            ),
          ],
        ),
      ),
    ),
  );
}
