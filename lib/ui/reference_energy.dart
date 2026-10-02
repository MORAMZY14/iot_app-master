import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'smart_home_design.dart';

class ReferenceEnergy extends StatefulWidget {
  const ReferenceEnergy({super.key, required this.data, required this.onSettings});
  final Map data;
  final VoidCallback onSettings;
  @override
  State<ReferenceEnergy> createState() => _ReferenceEnergyState();
}

class _ReferenceEnergyState extends State<ReferenceEnergy> {
  int _period = 0;
  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final scheme = Theme.of(context).colorScheme;
    final raw = data[['hourly', 'daily', 'monthly'][_period]];
    final values = raw is List ? raw.whereType<num>().where((v) => v.isFinite && v >= 0).map((v) => v.toDouble()).toList() : <double>[];
    String number(String key, String unit) {
      final value = data[key];
      return value is num && value.isFinite ? value.toStringAsFixed(1) + unit : '—';
    }
    final hasReadings = values.isNotEmpty || data['today'] is num;
    return ListView(
      padding: EdgeInsets.fromLTRB(18, 12, 18, 120 + MediaQuery.paddingOf(context).bottom),
      children: [
        HomeHero(title: 'Energy', subtitle: 'Understand your home’s electricity use.', icon: Icons.bolt_outlined,
          trailing: IconButton.filledTonal(onPressed: widget.onSettings, tooltip: 'Settings', icon: const Icon(Icons.settings_outlined))),
        HomeCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('TODAY’S USAGE', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1)),
          const SizedBox(height: 10),
          Text(number('today', ' kWh'), style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: -.8)),
          const SizedBox(height: 20),
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: SegmentedButton<int>(
            segments: const [ButtonSegment(value: 0, label: Text('Day')), ButtonSegment(value: 1, label: Text('Week')), ButtonSegment(value: 2, label: Text('Month'))],
            selected: {_period}, showSelectedIcon: false,
            onSelectionChanged: (selected) => setState(() => _period = selected.first),
          )),
          const SizedBox(height: 24),
          Semantics(label: values.isEmpty ? 'No energy readings' : '${values.length} energy readings',
            child: SizedBox(height: 150, width: double.infinity, child: CustomPaint(
              painter: _UsagePlot(values, scheme.primary, scheme.outlineVariant),
              child: values.isEmpty ? Center(child: Text('No readings yet', style: TextStyle(color: scheme.onSurfaceVariant))) : null,
            ))),
        ])),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, constraints) {
          final columns = constraints.maxWidth < 320 || MediaQuery.textScalerOf(context).scale(1) > 1.3 ? 1 : 2;
          final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
          final currency = data['currency']?.toString() ?? '';
          return Wrap(spacing: 12, runSpacing: 12, children: [
            for (final item in [
              (Icons.payments_outlined, 'Estimated cost', number('cost', currency.isEmpty ? '' : ' $currency')),
              (Icons.schedule_outlined, 'Peak time', data['peakTime']?.toString() ?? '—'),
              (Icons.home_outlined, 'Most active room', data['mostActiveRoom']?.toString() ?? '—'),
            ])
              SizedBox(width: width, child: HomeCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                HomeGlowIcon(item.$1, color: scheme.primary, size: 36),
                const SizedBox(height: 14),
                Text(item.$2, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                Text(item.$3, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600)),
              ]))),
          ]);
        }),
        const SizedBox(height: 18),
        if (!hasReadings)
          HomeCard(child: Column(children: [
            HomeGlowIcon(Icons.electric_meter_outlined, color: scheme.primary, size: 56),
            const SizedBox(height: 16),
            const Text('No energy meter connected', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Text('Electricity readings will appear when a compatible meter is connected. Temperature and humidity sensors do not measure power use.', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, height: 1.5, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 18),
            OutlinedButton.icon(icon: const Icon(Icons.info_outline), label: const Text('Meter requirements'), onPressed: () => showDialog<void>(context: context, builder: (dialog) => AlertDialog(
              title: const Text('Energy monitoring'),
              content: const Text('This controller currently reports environmental readings. Energy monitoring needs a supported electricity meter and its matching controller integration. No electricity use or estimated bill is calculated without meter readings.'),
              actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Close'))],
            ))),
          ])),
      ],
    );
  }
}

class _UsagePlot extends CustomPainter {
  _UsagePlot(this.values, this.color, this.gridColor);
  final List<double> values;
  final Color color, gridColor;
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = gridColor..strokeWidth = 1;
    for (var i = 0; i < 4; i++) {
      final y = 8 + (size.height - 16) * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (values.isEmpty || size.width <= 0) return;
    final maximum = values.fold<double>(1, (a, b) => a > b ? a : b);
    final step = size.width / values.length;
    final bar = Paint()..color = color;
    for (var i = 0; i < values.length; i++) {
      final height = (values[i] / maximum).clamp(0.0, 1.0).toDouble() * (size.height - 16);
      final width = step * .65;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(i * step + step * .175, size.height - 8 - height, width, height), const Radius.circular(4)), bar);
    }
  }
  @override
  bool shouldRepaint(_UsagePlot old) => !listEquals(old.values, values) || old.color != color || old.gridColor != gridColor;
}
