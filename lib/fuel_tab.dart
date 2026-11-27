import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'attachments.dart';
import 'database.dart';
import 'models.dart';
import 'settings.dart';

// The "Fuel" tab: a list of fill-ups for one vehicle.
class FuelTab extends StatefulWidget {
  final Vehicle vehicle;

  const FuelTab({super.key, required this.vehicle});

  @override
  State<FuelTab> createState() => _FuelTabState();
}

class _FuelTabState extends State<FuelTab> {
  final List<FuelEntry> _entries = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await AppDatabase.loadEntries(widget.vehicle.id);
    if (!mounted) return;
    setState(() {
      _entries
        ..clear()
        ..addAll(entries);
      _loaded = true;
    });
  }

  // Opens the form. Pass an index to edit that entry, or nothing to add one.
  Future<void> _openForm({int? index}) async {
    final existing = index == null ? null : _entries[index];

    // Odometer readings (in km) already used by *other* entries.
    final usedOdometers = _entries
        .where((e) => e.id != existing?.id)
        .map((e) => e.odometer)
        .toSet();

    final result = await Navigator.push<FuelEntry>(
      context,
      MaterialPageRoute(
        builder: (context) => FuelFormPage(
          vehicleId: widget.vehicle.id,
          tankCapacity: widget.vehicle.tankCapacity,
          existing: existing,
          usedOdometers: usedOdometers,
        ),
      ),
    );

    if (result != null) {
      await AppDatabase.insertEntry(result);
    }
    // Always reload: the form may also have deleted an entry.
    await _load();
  }

  // Full-to-full consumption, in whichever unit is selected in settings.
  // Only full-tank entries get a figure. We add up the litres from every
  // fill-up since the previous full tank (including this one) and compare
  // that with the distance between the two full tanks.
  double? _consumption(int index) {
    final entry = _entries[index];
    if (!entry.fullTank) return null;

    double litres = entry.litres;
    for (int i = index - 1; i >= 0; i--) {
      final previous = _entries[i];
      if (previous.fullTank) {
        final km = entry.odometer - previous.odometer;
        if (km <= 0) return null;
        return settings.consumption(litres, km);
      }
      litres += previous.litres;
    }
    return null; // no earlier full tank to measure from
  }

  Widget _buildList() {
    if (!_loaded) return const SizedBox.shrink();
    if (_entries.isEmpty) {
      return const Center(child: Text('No fill-ups yet'));
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        final consumption = _consumption(index);
        final date = entry.date.toIso8601String().split('T').first;

        String detail = '';
        if (!entry.fullTank) {
          detail = 'partial fill';
        } else if (consumption != null) {
          detail =
              '${consumption.toStringAsFixed(1)} ${settings.consumptionUnit}';
        }

        return ListTile(
          title: Text(
            '${entry.litres} L at ${settings.formatDistance(entry.odometer)}',
          ),
          subtitle: Text(detail.isEmpty ? date : '$date  •  $detail'),
          trailing: Text(settings.formatMoney(entry.cost)),
          onTap: () => _openForm(index: index),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Redraws the list when the units setting changes.
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Scaffold(
        body: _buildList(),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _openForm(),
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}

class FuelFormPage extends StatefulWidget {
  final String vehicleId;
  final double? tankCapacity; // litres, if known
  final FuelEntry? existing; // null means "adding a new entry"
  final Set<int> usedOdometers; // readings (km) belonging to other entries

  const FuelFormPage({
    super.key,
    required this.vehicleId,
    this.tankCapacity,
    this.existing,
    this.usedOdometers = const {},
  });

  @override
  State<FuelFormPage> createState() => _FuelFormPageState();
}

class _FuelFormPageState extends State<FuelFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _odometerController;
  late final TextEditingController _litresController;
  late final TextEditingController _costController;
  late final String _initialOdometer;
  late DateTime _date;
  late bool _fullTank;
  late final String _entryId; // known before saving, so receipts can attach
  bool _saved = false;

  @override
  void initState() {
    super.initState();
        final e = widget.existing;
    _entryId = e?.id ?? const Uuid().v4();
    _date = e?.date ?? DateTime.now();
    _fullTank = e?.fullTank ?? true;
    _initialOdometer =
        e == null ? '' : settings.displayDistance(e.odometer).toString();
    _odometerController = TextEditingController(text: _initialOdometer);
    _litresController = TextEditingController(text: e?.litres.toString());
    _costController = TextEditingController(text: e?.cost.toString());
  }

  @override
  void dispose() {
    _odometerController.dispose();
    _litresController.dispose();
        _costController.dispose();
    // Leaving a new entry unsaved: don't keep receipts for it.
    if (widget.existing == null && !_saved) {
      AttachmentStore.removeAllFor(_entryId);
    }
    super.dispose();
  }

  // The odometer in km, ready to store. If the text wasn't changed when
  // editing, keep the original value so unit rounding can't alter it.
  int _odometerKm() {
    final text = _odometerController.text.trim();
    final existing = widget.existing;
    if (existing != null && text == _initialOdometer) {
      return existing.odometer;
    }
    return settings.distanceFromDisplay(int.parse(text));
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _date = picked);
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final entry = FuelEntry(
            id: _entryId, // the same id the receipts are attached to
      vehicleId: widget.vehicleId,
      date: _date,
      odometer: _odometerKm(),
      litres: double.parse(_litresController.text),
      cost: double.parse(_costController.text),
      fullTank: _fullTank,
    );
        _saved = true;
    Navigator.pop(context, entry); // send the entry back to the list page
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this fill-up?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await AppDatabase.deleteEntry(widget.existing!.id);
    if (!mounted) return;
    Navigator.pop(context);
  }

  String? _requiredNumber(String? value) {
    if (value == null || value.trim().isEmpty) return 'Required';
    if (double.tryParse(value) == null) return 'Enter a number';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    final capacity = widget.tankCapacity;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit fill-up' : 'Add fill-up'),
        actions: [
          if (isEditing)
            IconButton(
              icon: const Icon(Icons.delete),
              tooltip: 'Delete',
              onPressed: _delete,
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Date'),
                subtitle: Text(_date.toIso8601String().split('T').first),
                trailing: const Icon(Icons.calendar_today),
                onTap: _pickDate,
              ),
              TextFormField(
                controller: _odometerController,
                decoration: InputDecoration(
                  labelText: 'Odometer (${settings.distanceUnit})',
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  final error = _requiredNumber(value);
                  if (error != null) return error;
                  if (int.tryParse(value!.trim()) == null) {
                    return 'Whole numbers only';
                  }
                  if (widget.usedOdometers.contains(_odometerKm())) {
                    return 'Another entry already has this reading';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _litresController,
                decoration: InputDecoration(
                  labelText: 'Litres',
                  helperText:
                      capacity == null ? null : 'Tank capacity: $capacity L',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                validator: (value) {
                  final error = _requiredNumber(value);
                  if (error != null) return error;
                  final litres = double.parse(value!);
                  // Allow a little tolerance over the stated capacity.
                  if (capacity != null && litres > capacity * 1.1) {
                    return 'More than the tank capacity ($capacity L)';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _costController,
                decoration: InputDecoration(
                  labelText: 'Total cost${settings.currencyLabel}',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                validator: _requiredNumber,
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Full tank'),
                subtitle: const Text('Untick if you only part-filled the tank'),
                value: _fullTank,
                onChanged: (value) => setState(() => _fullTank = value ?? true),
              ),
              const SizedBox(height: 16),
                            const SizedBox(height: 8),
              AttachmentsSection(parentType: 'fuel', parentId: _entryId),
              const SizedBox(height: 16),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ),
      ),
    );
  }
}
