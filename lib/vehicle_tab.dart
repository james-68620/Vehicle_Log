import 'package:flutter/material.dart';

import 'database.dart';
import 'models.dart';
import 'reminders.dart';
import 'settings.dart';

// The "Details" tab: shows everything we know about one vehicle.
class VehicleTab extends StatefulWidget {
  final Vehicle vehicle;
  final VoidCallback onEdit; // called when "Edit details" is pressed

  const VehicleTab({super.key, required this.vehicle, required this.onEdit});

  @override
  State<VehicleTab> createState() => _VehicleTabState();
}

class _VehicleTabState extends State<VehicleTab> {
  int? _latestOdometer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final latest = await AppDatabase.latestOdometer(widget.vehicle.id);
    if (!mounted) return;
    setState(() => _latestOdometer = latest);
  }

  // The higher of the saved mileage and the highest logged reading (in km).
  int? get _currentMileage {
    final stored = widget.vehicle.mileage;
    final latest = _latestOdometer;
    if (stored == null) return latest;
    if (latest == null) return stored;
    return stored > latest ? stored : latest;
  }

  Widget _row(IconData icon, String label, String? value) {
    return ListTile(
      leading: Icon(icon),
      title: Text(value ?? 'Not set'),
      subtitle: Text(label),
    );
  }

  Widget _motRow(BuildContext context) {
    final mot = widget.vehicle.motDate;
    if (mot == null) return _row(Icons.event, 'MOT date', null);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final due = DateTime(mot.year, mot.month, mot.day);
    final days = DateTime.utc(due.year, due.month, due.day)
        .difference(DateTime.utc(today.year, today.month, today.day))
        .inDays;

    String status;
    Color? colour;
    if (days < 0) {
      status = 'Expired ${-days} days ago';
      colour = Theme.of(context).colorScheme.error;
    } else if (days == 0) {
      status = 'Due today';
      colour = Colors.orange;
    } else {
      status = 'Due in $days days';
      if (days <= 30) colour = Colors.orange;
    }

    return ListTile(
      leading: const Icon(Icons.event),
      title: Text(due.toIso8601String().split('T').first),
      subtitle: Text(
        'MOT date  •  $status',
        style: colour == null ? null : TextStyle(color: colour),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vehicle;
    final mileage = _currentMileage;

    // Redraws when the units setting changes.
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => ListView(
        children: [
          _row(Icons.pin, 'Registration', v.regNumber),
          _row(Icons.directions_car, 'Make', v.make),
          _row(Icons.directions_car_outlined, 'Model', v.model),
          _row(Icons.calendar_month, 'Year', v.year?.toString()),
          _row(
            Icons.local_gas_station,
            'Fuel tank capacity',
            v.tankCapacity == null ? null : '${v.tankCapacity} L',
          ),
          _row(
            Icons.speed,
            'Current mileage',
            mileage == null ? null : settings.formatDistance(mileage),
          ),
          _motRow(context),
          RemindersSection(vehicle: v, currentMileage: mileage),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: widget.onEdit,
              icon: const Icon(Icons.edit),
              label: const Text('Edit details'),
            ),
          ),
        ],
      ),
    );
  }
}

// A full-page form for adding or editing a vehicle.
class VehicleFormPage extends StatefulWidget {
  final Vehicle? existing; // null means "adding a new vehicle"

  const VehicleFormPage({super.key, this.existing});

  @override
  State<VehicleFormPage> createState() => _VehicleFormPageState();
}

class _VehicleFormPageState extends State<VehicleFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _regController;
  late final TextEditingController _makeController;
  late final TextEditingController _modelController;
  late final TextEditingController _yearController;
  late final TextEditingController _tankController;
  late final TextEditingController _mileageController;
  late final String _initialMileage;
  DateTime? _motDate;

  @override
  void initState() {
    super.initState();
    final v = widget.existing;
    final mileageKm = v?.mileage;
    _initialMileage =
        mileageKm == null ? '' : settings.displayDistance(mileageKm).toString();

    _nameController = TextEditingController(text: v?.name);
    _regController = TextEditingController(text: v?.regNumber);
    _makeController = TextEditingController(text: v?.make);
    _modelController = TextEditingController(text: v?.model);
    _yearController = TextEditingController(text: v?.year?.toString());
    _tankController = TextEditingController(text: v?.tankCapacity?.toString());
    _mileageController = TextEditingController(text: _initialMileage);
    _motDate = v?.motDate;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _regController.dispose();
    _makeController.dispose();
    _modelController.dispose();
    _yearController.dispose();
    _tankController.dispose();
    _mileageController.dispose();
    super.dispose();
  }

  Future<void> _pickMotDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _motDate ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 5, 12, 31),
    );
    if (picked != null) {
      setState(() => _motDate = picked);
    }
  }

  // Returns the trimmed text, or null if the box is empty.
  String? _textOrNull(TextEditingController controller) {
    final text = controller.text.trim();
    return text.isEmpty ? null : text;
  }

  // The mileage in km, ready to store (null if left blank). If the text
  // wasn't changed when editing, keep the original value.
  int? _mileageKm() {
    final text = _mileageController.text.trim();
    if (text.isEmpty) return null;
    final existing = widget.existing;
    if (existing?.mileage != null && text == _initialMileage) {
      return existing!.mileage;
    }
    return settings.distanceFromDisplay(int.parse(text));
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final vehicle = Vehicle(
      id: widget.existing?.id, // keep the same id when editing
      name: _nameController.text.trim(),
      regNumber: _textOrNull(_regController)?.toUpperCase(),
      make: _textOrNull(_makeController),
      model: _textOrNull(_modelController),
      year: int.tryParse(_yearController.text.trim()),
      tankCapacity: double.tryParse(_tankController.text.trim()),
      mileage: _mileageKm(),
      motDate: _motDate,
    );
    Navigator.pop(context, vehicle); // send the vehicle back
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;

    return Scaffold(
      appBar: AppBar(title: Text(isEditing ? 'Edit vehicle' : 'Add vehicle')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  helperText: 'Shown in the title bar, e.g. "Family car"',
                ),
                textCapitalization: TextCapitalization.words,
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Required'
                    : null,
              ),
              TextFormField(
                controller: _regController,
                decoration:
                    const InputDecoration(labelText: 'Registration (optional)'),
                textCapitalization: TextCapitalization.characters,
              ),
              TextFormField(
                controller: _makeController,
                decoration: const InputDecoration(labelText: 'Make (optional)'),
                textCapitalization: TextCapitalization.words,
              ),
              TextFormField(
                controller: _modelController,
                decoration: const InputDecoration(labelText: 'Model (optional)'),
                textCapitalization: TextCapitalization.words,
              ),
              TextFormField(
                controller: _yearController,
                decoration: const InputDecoration(labelText: 'Year (optional)'),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  final year = int.tryParse(value.trim());
                  if (year == null ||
                      year < 1886 ||
                      year > DateTime.now().year + 1) {
                    return 'Enter a valid year';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _tankController,
                decoration: const InputDecoration(
                  labelText: 'Fuel tank capacity in litres (optional)',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  final litres = double.tryParse(value.trim());
                  if (litres == null) return 'Enter a number';
                  if (litres <= 0) return 'Must be more than 0';
                  return null;
                },
              ),
              TextFormField(
                controller: _mileageController,
                decoration: InputDecoration(
                  labelText: 'Mileage in ${settings.distanceUnit} (optional)',
                  helperText:
                      'The app also uses the highest reading from your logs',
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  final reading = int.tryParse(value.trim());
                  if (reading == null || reading < 0) {
                    return 'Whole numbers only';
                  }
                  return null;
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('MOT date (optional)'),
                subtitle: Text(
                  _motDate == null
                      ? 'Not set'
                      : _motDate!.toIso8601String().split('T').first,
                ),
                trailing: _motDate == null
                    ? const Icon(Icons.calendar_today)
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: 'Clear date',
                        onPressed: () => setState(() => _motDate = null),
                      ),
                onTap: _pickMotDate,
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
