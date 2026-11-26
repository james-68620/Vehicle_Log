import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'database.dart';
import 'models.dart';
import 'settings.dart';

const double _kmPerMile = 1.609344; // same value as in settings.dart

const List<String> _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

// e.g. "26 Nov 25"
String _dateLabel(DateTime d) =>
    '${d.day} ${_monthNames[d.month - 1]} ${(d.year % 100).toString().padLeft(2, '0')}';

// The stretch of driving between two full tanks.
class _Segment {
  final FuelEntry entry; // the full-tank fill-up that ended the stretch
  final double litres; // total litres added during the stretch
  final double cost; // total spent on fuel during the stretch
  final int km; // distance covered

  const _Segment(this.entry, this.litres, this.cost, this.km);
}

// Splits the fill-ups (sorted by odometer) into full-tank to full-tank
// stretches. Partial fills are added into the stretch they belong to.
List<_Segment> _buildSegments(List<FuelEntry> entries) {
  final result = <_Segment>[];
  int? previousFullOdometer;
  double litres = 0;
  double cost = 0;

  for (final entry in entries) {
    if (previousFullOdometer == null) {
      // Nothing can be measured until the first full tank.
      if (entry.fullTank) previousFullOdometer = entry.odometer;
      continue;
    }
    litres += entry.litres;
    cost += entry.cost;
    if (entry.fullTank) {
      final km = entry.odometer - previousFullOdometer;
      if (km > 0) result.add(_Segment(entry, litres, cost, km));
      previousFullOdometer = entry.odometer;
      litres = 0;
      cost = 0;
    }
  }
  return result;
}

// The "Stats" tab: totals and charts for one vehicle.
class StatsTab extends StatefulWidget {
  final String vehicleId;

  const StatsTab({super.key, required this.vehicleId});

  @override
  State<StatsTab> createState() => _StatsTabState();
}

class _StatsTabState extends State<StatsTab> {
  List<FuelEntry> _fuel = []; // sorted by odometer, oldest first
  List<ServiceEntry> _services = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final fuel = await AppDatabase.loadEntries(widget.vehicleId);
    final services = await AppDatabase.loadServices(widget.vehicleId);
    if (!mounted) return;
    setState(() {
      _fuel = fuel;
      _services = services;
      _loaded = true;
    });
  }

  Widget _content(BuildContext context) {
    final segments = _buildSegments(_fuel);

    // ---- Totals ----
    final fuelTotal = _fuel.fold<double>(0, (sum, e) => sum + e.cost);
    final serviceTotal = _services.fold<double>(0, (sum, e) => sum + e.cost);

    final segLitres = segments.fold<double>(0, (sum, s) => sum + s.litres);
    final segCost = segments.fold<double>(0, (sum, s) => sum + s.cost);
    final segKm = segments.fold<int>(0, (sum, s) => sum + s.km);

    final averageConsumption = segments.isEmpty
        ? '–'
        : '${settings.consumption(segLitres, segKm).toStringAsFixed(1)} '
            '${settings.consumptionUnit}';

    final distanceInUnit = settings.imperial ? segKm / _kmPerMile : segKm * 1.0;
    final costPerDistance = segments.isEmpty
        ? '–'
        : settings.formatMoney(segCost / distanceInUnit, decimals: 3);

    final averageFill =
        _fuel.isEmpty ? '–' : settings.formatMoney(fuelTotal / _fuel.length);

    final distanceLogged = _fuel.length < 2
        ? '–'
        : settings.formatDistance(_fuel.last.odometer - _fuel.first.odometer);

    // ---- Consumption chart ----
    final consumptionSpots = <FlSpot>[];
    final consumptionLabels = <String>[];
    for (int i = 0; i < segments.length; i++) {
      consumptionSpots.add(FlSpot(
        i.toDouble(),
        settings.consumption(segments[i].litres, segments[i].km),
      ));
      consumptionLabels.add(_dateLabel(segments[i].entry.date));
    }

    // ---- Price per litre chart ----
    final priceSpots = <FlSpot>[];
    final priceLabels = <String>[];
    for (final fill in _fuel) {
      if (fill.litres <= 0) continue;
      priceSpots.add(FlSpot(priceSpots.length.toDouble(), fill.cost / fill.litres));
      priceLabels.add(_dateLabel(fill.date));
    }

    // ---- Spending per month, last 12 months ----
    final now = DateTime.now();
    final months = [
      for (int i = 11; i >= 0; i--) DateTime(now.year, now.month - i, 1),
    ];
    final fuelByMonth = List<double>.filled(12, 0);
    final serviceByMonth = List<double>.filled(12, 0);
    int slot(DateTime d) =>
        months.indexWhere((m) => m.year == d.year && m.month == d.month);
    for (final fill in _fuel) {
      final i = slot(fill.date);
      if (i >= 0) fuelByMonth[i] += fill.cost;
    }
    for (final service in _services) {
      final i = slot(service.date);
      if (i >= 0) serviceByMonth[i] += service.cost;
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _StatTile(label: 'Fuel spend', value: fuelTotal.toStringAsFixed(2)),
            _StatTile(
              label: 'Service spend',
              value: settings.formatMoney(serviceTotal),
            ),
            _StatTile(label: 'Average consumption', value: averageConsumption),
            _StatTile(
              label: 'Fuel cost per ${settings.distanceUnit}',
              value: costPerDistance,
            ),
            _StatTile(label: 'Average fill-up cost', value: averageFill),
            _StatTile(label: 'Distance logged', value: distanceLogged),
          ],
        ),
        const SizedBox(height: 16),
        _TrendChart(
          title: 'Fuel consumption',
          subtitle: '${settings.consumptionUnit}, full tank to full tank',
          spots: consumptionSpots,
          labels: consumptionLabels,
          decimals: 1,
          emptyText: 'Needs at least two full-tank fill-ups.',
        ),
        const SizedBox(height: 16),
        _TrendChart(
          title: 'Price per litre',
          subtitle: 'Cost divided by litres, for each fill-up',
          spots: priceSpots,
          labels: priceLabels,
          decimals: 2,
          emptyText: 'No fill-ups yet.',
        ),
        const SizedBox(height: 16),
        _MonthlySpendChart(
          labels: [for (final m in months) _monthNames[m.month - 1]],
          fuel: fuelByMonth,
          service: serviceByMonth,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    if (_fuel.isEmpty && _services.isEmpty) {
      return const Center(
        child: Text('Add some fill-ups or services to see statistics'),
      );
    }
    // Redraws when the units setting changes.
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => _content(context),
    );
  }
}

// A small card showing one number.
class _StatTile extends StatelessWidget {
  final String label;
  final String value;

  const _StatTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SizedBox(
      width: 150,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(value, style: textTheme.titleMedium),
            ],
          ),
        ),
      ),
    );
  }
}

// A line chart of values over time. The x position of each point is just its
// order in the list; `labels` supplies the text shown under it.
class _TrendChart extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<FlSpot> spots;
  final List<String> labels;
  final int decimals;
  final String emptyText;

  const _TrendChart({
    required this.title,
    required this.subtitle,
    required this.spots,
    required this.labels,
    required this.decimals,
    required this.emptyText,
  });

  Widget _chart(BuildContext context) {
    const smallText = TextStyle(fontSize: 10);

    // Leave some room above and below the line.
    double lo = spots.first.y;
    double hi = spots.first.y;
    for (final spot in spots) {
      if (spot.y < lo) lo = spot.y;
      if (spot.y > hi) hi = spot.y;
    }
    final pad = (hi - lo) < 0.001 ? 1.0 : (hi - lo) * 0.2;
    final minY = (lo - pad) < 0 ? 0.0 : lo - pad;
    final maxY = hi + pad;

    // Show roughly four labels along the bottom.
    final step = (spots.length / 4).ceil().clamp(1, 1000);

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: spots.length > 1 ? (spots.length - 1).toDouble() : 1,
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (value, meta) => Text(
                value.toStringAsFixed(decimals),
                style: smallText,
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: step.toDouble(),
              getTitlesWidget: (value, meta) {
                final i = value.round();
                final onAPoint = (value - i).abs() < 0.01;
                if (!onAPoint || i < 0 || i >= labels.length) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(labels[i], style: smallText),
                );
              },
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: false,
            color: Theme.of(context).colorScheme.primary,
            barWidth: 3,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: textTheme.titleMedium),
            Text(subtitle, style: textTheme.bodySmall),
            const SizedBox(height: 16),
            if (spots.isEmpty)
              Text(emptyText)
            else
              SizedBox(height: 220, child: _chart(context)),
          ],
        ),
      ),
    );
  }
}

// Stacked bars: fuel and service spending for each of the last 12 months.
class _MonthlySpendChart extends StatelessWidget {
  final List<String> labels; // 12 month names, oldest first
  final List<double> fuel;
  final List<double> service;

  const _MonthlySpendChart({
    required this.labels,
    required this.fuel,
    required this.service,
  });

  Widget _legendItem(Color colour, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 12, height: 12, color: colour),
        const SizedBox(width: 6),
        Text(text),
      ],
    );
  }

  Widget _chart(BuildContext context, Color fuelColour, Color serviceColour) {
    const smallText = TextStyle(fontSize: 9);

    return BarChart(
      BarChartData(
        gridData: FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (value, meta) => Text(
                value.toStringAsFixed(0),
                style: smallText,
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (value, meta) {
                final i = value.round();
                if (i < 0 || i >= labels.length) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(labels[i], style: smallText),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (int i = 0; i < labels.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: fuel[i] + service[i],
                  width: 14,
                  color: fuelColour,
                  rodStackItems: [
                    BarChartRodStackItem(0, fuel[i], fuelColour),
                    BarChartRodStackItem(
                      fuel[i],
                      fuel[i] + service[i],
                      serviceColour,
                    ),
                  ],
                ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final fuelColour = Theme.of(context).colorScheme.primary;
    final serviceColour = Theme.of(context).colorScheme.tertiary;
    final hasData = fuel.any((v) => v > 0) || service.any((v) => v > 0);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Spending, last 12 months', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                _legendItem(fuelColour, 'Fuel'),
                _legendItem(serviceColour, 'Service'),
              ],
            ),
            const SizedBox(height: 16),
            if (!hasData)
              const Text('Nothing recorded in the last 12 months.')
            else
              SizedBox(
                height: 220,
                child: _chart(context, fuelColour, serviceColour),
              ),
          ],
        ),
      ),
    );
  }
}
