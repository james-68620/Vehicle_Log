import 'package:flutter/material.dart';

import 'database.dart';
import 'models.dart';
import 'settings.dart';

// Quick-pick suggestions for the reminder's service type.
const List<String> _reminderSuggestions = [
  'Oil change',
  'Tyres',
  'Brakes',
  'Inspection',
  'Battery',
];

const int _soonKm = 1000; // "due soon" when this close in distance...
const int _soonDays = 30; // ...or this close in time

enum ReminderStatus { ok, soon, overdue, unknown }

class ReminderInfo {
  final ReminderStatus status;
  final String summary;
  const ReminderInfo(this.status, this.summary);
}

// Adds whole months to a date, clamping to the end of shorter months.
DateTime _addMonths(DateTime date, int months) {
  final total = date.month - 1 + months;
  final year = date.year + total ~/ 12;
  final month = total % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, date.day > lastDay ? lastDay : date.day);
}

// Works out whether a reminder is due, from the last matching service.
ReminderInfo evaluateReminder(
  ServiceReminder reminder,
  ServiceEntry? last,
  int? currentKm,
) {
  if (last == null) {
    return const ReminderInfo(
      ReminderStatus.unknown,
      'No matching service logged yet',
    );
  }

  var status = ReminderStatus.ok;
  void raise(ReminderStatus s) {
    if (s.index > status.index) status = s;
  }

  final parts = <String>[];

    // Distance (needs the last service to have a mileage)
  final intervalKm = reminder.intervalKm;
  final lastKm = last.odometer;
  if (intervalKm != null && lastKm != null) {
    final nowKm =
        (currentKm != null && currentKm > lastKm) ? currentKm : lastKm;
    final left = lastKm + intervalKm - nowKm;
    if (left < 0) {
      parts.add('${settings.formatDistance(-left)} overdue');
      raise(ReminderStatus.overdue);
    } else if (left == 0) {
      parts.add('due now');
      raise(ReminderStatus.overdue);
    } else {
      parts.add('due in ${settings.formatDistance(left)}');
      if (left <= _soonKm) raise(ReminderStatus.soon);
    }
  }

  // Time
  final months = reminder.intervalMonths;
  if (months != null) {
    final dueDate = _addMonths(last.date, months);
    final now = DateTime.now();
    // Compare as UTC dates so daylight-saving changes can't skew the count.
    final dueDay = DateTime.utc(dueDate.year, dueDate.month, dueDate.day);
    final today = DateTime.utc(now.year, now.month, now.day);
    final days = dueDay.difference(today).inDays;
    if (days < 0) {
      parts.add('${-days} days overdue');
      raise(ReminderStatus.overdue);
    } else if (days == 0) {
      parts.add('due today');
      raise(ReminderStatus.overdue);
    } else {
      parts.add('due in $days days');
      if (days <= _soonDays) raise(ReminderStatus.soon);
    }
  }
  if (parts.isEmpty) {
    return const ReminderInfo(
      ReminderStatus.unknown,
      'Last service has no mileage recorded',
    );
  }
  final text = parts.join('  •  ');
  return ReminderInfo(status, text[0].toUpperCase() + text.substring(1));
}

// The "Service reminders" block shown on the Details tab.
class RemindersSection extends StatefulWidget {
  final Vehicle vehicle;
  final int? currentMileage; // km

  const RemindersSection({
    super.key,
    required this.vehicle,
    required this.currentMileage,
  });

  @override
  State<RemindersSection> createState() => _RemindersSectionState();
}

class _RemindersSectionState extends State<RemindersSection> {
  List<ServiceReminder> _reminders = [];
  List<ServiceEntry> _services = []; // newest first
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final reminders = await AppDatabase.loadReminders(widget.vehicle.id);
    final services = await AppDatabase.loadServices(widget.vehicle.id);
    if (!mounted) return;
    setState(() {
      _reminders = reminders;
      _services = services;
      _loaded = true;
    });
  }

  // The most recent service of this type (matching ignores capitals).
  ServiceEntry? _lastService(String type) {
    final wanted = type.trim().toLowerCase();
    for (final service in _services) {
      if (service.serviceType.trim().toLowerCase() == wanted) return service;
    }
    return null;
  }

  Future<void> _openForm({ServiceReminder? existing}) async {
    final result = await Navigator.push<ServiceReminder>(
      context,
      MaterialPageRoute(
        builder: (context) => ReminderFormPage(
          vehicleId: widget.vehicle.id,
          existing: existing,
        ),
      ),
    );
    if (result != null) {
      await AppDatabase.saveReminder(result);
    }
    // Always reload: the form may also have deleted a reminder.
    await _load();
  }

  Widget _tile(BuildContext context, ServiceReminder reminder) {
    final info = evaluateReminder(
      reminder,
      _lastService(reminder.serviceType),
      widget.currentMileage,
    );

    final IconData icon;
    Color? colour;
    switch (info.status) {
      case ReminderStatus.overdue:
        icon = Icons.error;
        colour = Theme.of(context).colorScheme.error;
      case ReminderStatus.soon:
        icon = Icons.warning_amber;
        colour = Colors.orange;
      case ReminderStatus.ok:
        icon = Icons.check_circle_outline;
        colour = Colors.green;
      case ReminderStatus.unknown:
        icon = Icons.help_outline;
        colour = null;
    }

    final every = [
      if (reminder.intervalKm != null)
        settings.formatDistance(reminder.intervalKm!),
      if (reminder.intervalMonths != null)
        '${reminder.intervalMonths} months',
    ].join(' or ');

    return ListTile(
      leading: Icon(icon, color: colour),
      title: Text(reminder.serviceType),
      isThreeLine: true,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Every $every'),
          Text(
            info.summary,
            style: colour == null ? null : TextStyle(color: colour),
          ),
        ],
      ),
      onTap: () => _openForm(existing: reminder),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Redraws when the units setting changes.
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          ListTile(
            title: Text(
              'Service reminders',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Add reminder',
              onPressed: () => _openForm(),
            ),
          ),
          if (_loaded && _reminders.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'No reminders yet. Tap + to add one, for example an oil '
                'change every 10,000 km or 12 months.',
              ),
            ),
          for (final reminder in _reminders) _tile(context, reminder),
        ],
      ),
    );
  }
}

// A full-page form for adding or editing a reminder.
class ReminderFormPage extends StatefulWidget {
  final String vehicleId;
  final ServiceReminder? existing; // null means "adding a new reminder"

  const ReminderFormPage({super.key, required this.vehicleId, this.existing});

  @override
  State<ReminderFormPage> createState() => _ReminderFormPageState();
}

class _ReminderFormPageState extends State<ReminderFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _typeController;
  late final TextEditingController _distanceController;
  late final TextEditingController _monthsController;
  late final String _initialDistance;

  @override
  void initState() {
    super.initState();
    final r = widget.existing;
    final km = r?.intervalKm;
    _initialDistance = km == null ? '' : settings.displayDistance(km).toString();

    _typeController = TextEditingController(text: r?.serviceType);
    _distanceController = TextEditingController(text: _initialDistance);
    _monthsController =
        TextEditingController(text: r?.intervalMonths?.toString());
  }

  @override
  void dispose() {
    _typeController.dispose();
    _distanceController.dispose();
    _monthsController.dispose();
    super.dispose();
  }

  // The distance in km, ready to store (null if left blank). If the text
  // wasn't changed when editing, keep the original value.
  int? _intervalKm() {
    final text = _distanceController.text.trim();
    if (text.isEmpty) return null;
    final existing = widget.existing;
    if (existing?.intervalKm != null && text == _initialDistance) {
      return existing!.intervalKm;
    }
    return settings.distanceFromDisplay(int.parse(text));
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final km = _intervalKm();
    final months = int.tryParse(_monthsController.text.trim());
    if (km == null && months == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a distance, a number of months, or both'),
        ),
      );
      return;
    }

    final reminder = ServiceReminder(
      id: widget.existing?.id, // keep the same id when editing
      vehicleId: widget.vehicleId,
      serviceType: _typeController.text.trim(),
      intervalKm: km,
      intervalMonths: months,
    );
    Navigator.pop(context, reminder); // send it back to the list
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this reminder?'),
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

    await AppDatabase.deleteReminder(widget.existing!.id);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit reminder' : 'Add reminder'),
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
              TextFormField(
                controller: _typeController,
                decoration: const InputDecoration(
                  labelText: 'Service type',
                  helperText:
                      'Must match the type you use when logging services',
                ),
                textCapitalization: TextCapitalization.sentences,
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Required'
                    : null,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final suggestion in _reminderSuggestions)
                    ActionChip(
                      label: Text(suggestion),
                      onPressed: () => _typeController.text = suggestion,
                    ),
                ],
              ),
              TextFormField(
                controller: _distanceController,
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
                controller: _monthsController,
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
              const SizedBox(height: 24),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ),
      ),
    );
  }
}
