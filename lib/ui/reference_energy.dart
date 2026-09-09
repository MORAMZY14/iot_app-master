import 'package:flutter/material.dart';
import 'smart_home_design.dart';

class ReferenceEnergy extends StatefulWidget {
  const ReferenceEnergy({
    super.key,
    required this.data,
    required this.onSettings,
  });
  final Map data;
  final VoidCallback onSettings;
  @override
  State<ReferenceEnergy> createState() => _ReferenceEnergyState();
}

class _ReferenceEnergyState extends State<ReferenceEnergy> {
  int period = 0;
  @override
  Widget build(BuildContext context) {
    final e = widget.data;
    final raw = e[['hourly', 'daily', 'monthly'][period]];
    final values = raw is List
        ? raw.whereType<num>().map((v) => v.toDouble()).toList()
        : <double>[];
    String number(String key, [String unit = '']) =>
        e[key] is num ? '${(e[key] as num).toStringAsFixed(1)}$unit' : '—$unit';
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
      children: [
        HomeHero(
          title: 'Energy',
          subtitle: 'Usage and monitoring',
          trailing: IconButton(
            onPressed: widget.onSettings,
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
          ),
        ),
        HomeCard(
          glowColor: HomeDesign.violet,
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const HomeGlowIcon(
                          Icons.bolt,
                          color: HomeDesign.cyan,
                          size: 42,
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Today’s Usage',
                          style: TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 9),
                        Text(
                          number('today', ' kWh'),
                          style: const TextStyle(
                            fontSize: 25,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'vs. yesterday',
                          style: TextStyle(
                            fontSize: 9,
                            color: Color(0xFF9BADCC),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: Column(
                      children: [
                        Row(
                          children: [
                            for (final (i, t) in [
                              'Day',
                              'Week',
                              'Month',
                            ].indexed)
                              Expanded(
                                child: InkWell(
                                  onTap: () => setState(() => period = i),
                                  child: Container(
                                    alignment: Alignment.center,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: period == i
                                            ? HomeDesign.violet
                                            : HomeDesign.border,
                                      ),
                                      color: period == i
                                          ? HomeDesign.blue.withValues(
                                              alpha: .2,
                                            )
                                          : null,
                                    ),
                                    child: Text(
                                      t,
                                      style: const TextStyle(fontSize: 9),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 108,
                          child: CustomPaint(
                            painter: _UsagePlot(values),
                            child: values.isEmpty
                                ? const Center(
                                    child: Text(
                                      'No readings yet',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: Color(0xFF9BADCC),
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const HomeCard(
                padding: EdgeInsets.all(9),
                child: Row(
                  children: [
                    Icon(
                      Icons.eco_outlined,
                      color: Color(0xFF20E098),
                      size: 23,
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Usage comparison awaits meter readings.',
                        style: TextStyle(fontSize: 10),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final (i, v) in [
              (Icons.toll, 'Estimated Cost', number('cost')),
              (
                Icons.access_time,
                'Peak Time',
                e['peakTime']?.toString() ?? '—',
              ),
              (
                Icons.home_outlined,
                'Most Active Room',
                e['mostActiveRoom']?.toString() ?? '—',
              ),
            ].indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: HomeCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        v.$1,
                        color: HomeDesign.cyan,
                        shadows: const [
                          Shadow(color: HomeDesign.blue, blurRadius: 12),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(v.$2, style: const TextStyle(fontSize: 9)),
                      const SizedBox(height: 8),
                      Text(
                        v.$3,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Meter data',
                        style: TextStyle(fontSize: 8, color: Color(0xFF9BADCC)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        HomeCard(
          child: Column(
            children: [
              const SizedBox(height: 8),
              const HomeGlowIcon(
                Icons.electric_meter_outlined,
                color: HomeDesign.violet,
                size: 56,
              ),
              const SizedBox(height: 10),
              Text(
                values.isEmpty
                    ? 'No energy meter connected'
                    : 'Energy monitoring',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 7),
              const Text(
                'Connect a compatible smart energy meter to track your electricity usage and view real-time consumption.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Color(0xFFA8BADA)),
              ),
              const SizedBox(height: 13),
              HomePrimaryButton(
                label: 'Add Energy Meter',
                icon: Icons.add,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Energy meter setup'),
                    content: const Text(
                      'The current firmware has no energy-meter driver. A compatible meter and its firmware integration are needed before readings can appear.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const HomeCard(
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: HomeDesign.cyan),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Temperature and humidity sensors do not measure electricity use. They track environmental conditions only, not power consumption.',
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xFFA8BADA),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _UsagePlot extends CustomPainter {
  _UsagePlot(this.values);
  final List<double> values;
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..color = HomeDesign.border
      ..strokeWidth = .7;
    for (int i = 0; i < 4; i++) {
      final y = 10 + (s.height - 24) * i / 3;
      for (double x = 0; x < s.width; x += 5)
        c.drawLine(Offset(x, y), Offset(x + 2, y), p);
    }
    if (values.isEmpty) return;
    final max = values.fold<double>(1, (m, v) => v > m ? v : m);
    final w = s.width / values.length;
    for (int i = 0; i < values.length; i++) {
      final h = (values[i] / max).clamp(0, 1) * (s.height - 20);
      final r = Rect.fromLTWH(
        i * w + 1,
        s.height - 10 - h,
        (w - 2).clamp(1, 100),
        h,
      );
      c.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(2)),
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [HomeDesign.cyan, HomeDesign.blue, HomeDesign.violet],
          ).createShader(r),
      );
    }
  }

  @override
  bool shouldRepaint(_UsagePlot old) => old.values != values;
}
