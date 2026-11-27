import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'attachments.dart';
import 'database.dart';
import 'models.dart';
import 'settings.dart';

// Quick-pick suggestions for the service type field.
const List<String> _commonServices = [
  'Oil change',
  'Tyres',
  'Brakes',
  'Inspection',
  'Battery',
  'Other',
];

// The "Service" tab: a list of maintenance work for one vehicle.
class ServiceTab extends StatefulWidget {
  final String vehicleId;

  const ServiceTab({super.key, required this.vehicleId});

  @override
  State<ServiceTab> createState() => _ServiceTabState();
}

class _ServiceTabState extends State<ServiceTab> {
  final List<ServiceEntry> _entries = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await AppDatabase.loadServices(widget.vehicleId);
    if (!mounted) return;
    setState(() {
      _entries
        ..clear()
        ..addAll(entries);
      _loaded = true;
    });
  }

  // Opens the form. Pass an entry to edit it, or nothing to add a new one.
  Future<void> _openForm({ServiceEntry? existing}) async {
    final result = await Navigator.push<ServiceEntry>(
      context,
      MaterialPageRoute(
        builder: (context) => ServiceFormPage(
          vehicleId: widget.vehicleId,
          existing: existing,
        ),
      ),
    );

    if (result != null) {
      await AppDatabase.saveService(result);
    }
    // Always reload: the form may also have deleted an entry.
    await _load();
  }

  Widget _buildList() {
    if (!_loaded) return const SizedBox.shrink();
    if (_entries.isEmpty) {
      return const Center(child: Text('No service history yet'));
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        final date = entry.date.toIso8601String().split('T').first;
        return ListTile(
          title: Text(entry.serviceType),
           subtitle: Text(
            '$date'
            '${entry.odometer == null ? '' : '  •  ${settings.formatDistance(entry.odometer!)}'}'
            '${entry.notes.isEmpty ? '' : '\n${entry.notes}'}',
          ),
          isThreeLine: entry.notes.isNotEmpty,
          trailing: Text(settings.formatMoney(entry.cost)),
          onTap: () => _openForm(existing: entry),
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

class ServiceFormPage extends StatefulWidget {
  final String vehicleId;
  final ServiceEntry? existing; // null means "adding a new entry"

  const ServiceFormPage({super.key, required this.vehicleId, this.existing});

  @override
  State<ServiceFormPage> createState() => _ServiceFormPageState();
}

class _ServiceFormPageState extends State<ServiceFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _odometerController;
  late final TextEditingController _typeController;
  late final TextEditingController _costController;
  late final TextEditingController _notesController;
  final _reminderKmController = TextEditingController();
  final _reminderMonthsController = TextEditingController();
  late final String _initialOdometer;
    late DateTime _date;
  late final String _entryId; // known before saving, so receipts can attach
  bool _saved = false;

  bool _setReminder = false; // the "remind me" checkbox
  // Remembers values copied from an existing reminder, so saving them
  // unchanged can't be altered by unit rounding.
  String _prefilledDistanceText = '';
  int? _prefilledDistanceKm;

  @override
  void initState() {
    super.initState();
       final e = widget.existing;
    _entryId = e?.id ?? const Uuid().v4();
    _date = e?.date ?? DateTime.now();
       final km = e?.odometer;
    _initialOdometer = km == null ? '' : settings.displayDistance(km).toString();
    _odometerController = TextEditingController(text: _initialOdometer);
    _typeController = TextEditingController(text: e?.serviceType);
    _costController = TextEditingController(text: e?.cost.toString());
    _notesController = TextEditingController(text: e?.notes);
  }

  @override
  void dispose() {
    _odometerController.dispose();
    _typeController.dispose();
    _costController.dispose();
    _notesController.dispose();
    _reminderKmController.dispose();
       _reminderMonthsController.dispose();
    // Leaving a new entry unsaved: don't keep receipts for it.
    if (widget.existing == null && !_saved) {
      AttachmentStore.removeAllFor(_entryId);
    }
    super.dispose();
  }

    // The odometer in km, ready to store (null if left blank). If the text
  // wasn't changed when editing, keep the original value so unit rounding
  // can't alter it.
  int? _odometerKm() {
    final text = _odometerController.text.trim();
    if (text.isEmpty) return null;
    final existing = widget.existing;
    if (existing != null && text == _initialOdometer) {
      return existing.odometer;
    }
    return settings.distanceFromDisplay(int.parse(text));
  }

  // The reminder distance in km (null if left blank).
  int? _reminderKm() {
    final text = _reminderKmController.text.trim();
    if (text.isEmpty) return null;
    if (_prefilledDistanceKm != null && text == _prefilledDistanceText) {
      return _prefilledDistanceKm;
    }
    return settings.distanceFromDisplay(int.parse(text));
  }

  // Finds this vehicle's reminder for a service type (ignoring capitals).
  Future<ServiceReminder?> _findReminder(String type) async {
    final wanted = type.trim().toLowerCase();
    if (wanted.isEmpty) return null;
    final reminders = await AppDatabase.loadReminders(widget.vehicleId);
    for (final reminder in reminders) {
      if (reminder.serviceType.trim().toLowerCase() == wanted) return reminder;
    }
    return null;
  }

  // Ticking the box reveals the fields. If a reminder for this service type
  // already exists, its values are filled in so you can see and adjust them.
  Future<void> _onReminderToggled(bool value) async {
    setState(() => _setReminder = value);
    if (!value) return;
    if (_reminderKmController.text.isNotEmpty ||
        _reminderMonthsController.text.isNotEmpty) {
      return;
    }

    final existing = await _findReminder(_typeController.text);
    if (existing == null || !mounted) return;

    setState(() {
      final km = existing.intervalKm;
      if (km != null) {
        _prefilledDistanceKm = km;
        _prefilledDistanceText = settings.displayDistance(km).toString();
        _reminderKmController.text = _prefilledDistanceText;
      }
      final months = existing.intervalMonths;
      if (months != null) {
        _reminderMonthsController.text = months.toString();
      }
    });
  }

  // Creates the reminder, or updates the existing one for this service type.
  Future<void> _saveReminder(String type, int? km, int? months) async {
    final existing = await _findReminder(type);
    await AppDatabase.saveReminder(
      ServiceReminder(
        id: existing?.id, // keep the same id when updating
        vehicleId: widget.vehicleId,
        serviceType: type,
        intervalKm: km,
        intervalMonths: months,
      ),
    );
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

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_odometerController.text.trim().isEmpty) {
      final saveAnyway = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('No mileage entered'),
          content: const Text('Save this service without a mileage?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Go back'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save anyway'),
            ),
          ],
        ),
      );
      if (saveAnyway != true || !mounted) return;
    }
    final type = _typeController.text.trim();

    if (_setReminder) {
      final km = _reminderKm();
      final months = int.tryParse(_reminderMonthsController.text.trim());
      if (km == null && months == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enter a distance, a number of months, or both '
                'for the reminder'),
          ),
        );
        return;
      }
      await _saveReminder(type, km, months);
    }

    final entry = ServiceEntry(
            id: _entryId, // the same id the receipts are attached to
      vehicleId: widget.vehicleId,
      date: _date,
      odometer: _odometerKm(),
      serviceType: type,
      cost: double.parse(_costController.text),
      notes: _notesController.text.trim(),
    );
    if (!mounted) return;
        _saved = true;
    Navigator.pop(context, entry); // send the entry back to the list page
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this service entry?'),
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

    await AppDatabase.deleteService(widget.existing!.id);
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

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit service' : 'Add service'),
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
                controller: _typeController,
                decoration: const InputDecoration(labelText: 'Service type'),
                textCapitalization: TextCapitalization.sentences,
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Required'
                    : null,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final service in _commonServices)
                    ActionChip(
                      label: Text(service),
                      onPressed: () => _typeController.text = service,
                    ),
                ],
              ),
                           TextFormField(
                controller: _odometerController,
                decoration: InputDecoration(
                  labelText: 'Odometer (${settings.distanceUnit}) (optional)',
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  if (int.tryParse(value.trim()) == null) {
                    return 'Whole numbers only';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _costController,
                decoration: InputDecoration(
                  labelText: 'Cost${settings.currencyLabel}',
                  helperText: 'Enter 0 if there was no charge',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                validator: _requiredNumber,
              ),
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(labelText: 'Notes (optional)'),
                maxLines: 3,
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Remind me when the next one is due'),
                subtitle: const Text(
                  'Shown on the Details tab. Updates an existing reminder '
                  'for the same service type.',
                ),
                value: _setReminder,
                onChanged: (value) => _onReminderToggled(value ?? false),
              ),
              if (_setReminder) ...[
                TextFormField(
                  controller: _reminderKmController,
                  decoration: InputDecoration(
                    labelText: 'Repeat every (${settings.distanceUnit})',
                    helperText: 'Optional, e.g. 10000',
                  ),
                  keyboardType: TextInputType.number,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) return null;
                    final number = int.tryParse(value.trim());
                    if (number == null || number <= 0) {
                      return 'Whole number above 0';
                    }
                    return null;
                  },
                ),
                TextFormField(
                  controller: _reminderMonthsController,
                  decoration: const InputDecoration(
                    labelText: 'Repeat every (months)',
                    helperText: 'Optional, e.g. 12',
                  ),
                  keyboardType: TextInputType.number,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) return null;
                    final number = int.tryParse(value.trim());
                    if (number == null || number <= 0 || number > 240) {
                      return 'Whole number from 1 to 240';
                    }
                    return null;
                  },
                ),
              ],
              const SizedBox(height: 24),
                            const SizedBox(height: 8),
              AttachmentsSection(parentType: 'service', parentId: _entryId),
              const SizedBox(height: 16),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ),
      ),
    );
  }
}
