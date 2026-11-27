import 'package:flutter/material.dart';

import 'background_sync.dart';
import 'database.dart';
import 'fuel_tab.dart';
import 'models.dart';
import 'reminder_notifier.dart';
import 'service_tab.dart';
import 'settings.dart';
import 'settings_page.dart';
import 'stats_tab.dart';
import 'sync_service.dart';
import 'vehicle_tab.dart';

Future<void> main() async {
  // Needed before using plugins (like shared_preferences) at startup.
  WidgetsFlutterBinding.ensureInitialized();
  await settings.load();
   syncService.start(); // runs in the background; doesn't delay startup
    BackgroundSync.apply(); // schedules the Android background job
  ReminderNotifier.check(); // notifies about anything that is due
  runApp(const VehicleApp());
}

class VehicleApp extends StatelessWidget {
  const VehicleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vehicle Log',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  List<Vehicle> _vehicles = [];
  Vehicle? _vehicle; // the vehicle currently selected
  bool _loading = true;
  int _dataVersion = 0; // changes when a sync brings in new data

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dataVersion = syncService.dataVersion;
    syncService.addListener(_onSyncChanged);
    _loadVehicles();
  }

  @override
  void dispose() {
    syncService.removeListener(_onSyncChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Called when the app comes back to the foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
       if (state == AppLifecycleState.resumed) {
      syncService.notifyDataChanged(); // the background job may have changed data
      ReminderNotifier.check();
      syncService.runSync();
    }
  }

  // If a sync received new data, reload everything on screen.
  void _onSyncChanged() {
    if (syncService.dataVersion != _dataVersion) {
      setState(() => _dataVersion = syncService.dataVersion);
      _loadVehicles();
    }
  }

  // Reload the vehicle list. Pass selectId to switch to a specific vehicle.
  Future<void> _loadVehicles({String? selectId}) async {
    final vehicles = await AppDatabase.loadVehicles();
    if (!mounted) return;

    final wantedId = selectId ?? _vehicle?.id;
    Vehicle? selected;
    for (final v in vehicles) {
      if (v.id == wantedId) selected = v;
    }
    selected ??= vehicles.isEmpty ? null : vehicles.first;

    setState(() {
      _vehicles = vehicles;
      _vehicle = selected;
      _loading = false;
    });
  }

  // Opens the vehicle form (add if existing is null, otherwise edit).
  Future<void> _openVehicleForm({Vehicle? existing}) async {
    final result = await Navigator.push<Vehicle>(
      context,
      MaterialPageRoute(
        builder: (context) => VehicleFormPage(existing: existing),
      ),
    );
    if (result == null) return;

    await AppDatabase.saveVehicle(result);
    await _loadVehicles(selectId: result.id);
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SettingsPage()),
    );
  }

  Future<void> _syncNow() async {
    final result = await syncService.runSync();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message)),
    );
  }

  Future<void> _deleteVehicle() async {
    final current = _vehicle;
    if (current == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${current.name}?'),
        content: const Text('Vehicle Log'),
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

    await AppDatabase.deleteVehicle(current.id);
    await _loadVehicles();
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final vehicle = _vehicle;
    if (vehicle == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('No vehicles yet'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _openVehicleForm(),
              child: const Text('Add your first vehicle'),
            ),
          ],
        ),
      );
    }

    // The keys make Flutter rebuild each tab when you switch vehicle or
    // when a sync brings in new data.
    final key = '${vehicle.id}-$_dataVersion';
    return TabBarView(
      children: [
        VehicleTab(
          key: ValueKey('details-$key'),
          vehicle: vehicle,
          onEdit: () => _openVehicleForm(existing: vehicle),
        ),
        FuelTab(key: ValueKey('fuel-$key'), vehicle: vehicle),
        ServiceTab(key: ValueKey('service-$key'), vehicleId: vehicle.id),
        StatsTab(key: ValueKey('stats-$key'), vehicleId: vehicle.id),
      ],
    );
  }

  Widget _syncButton() {
    return ListenableBuilder(
      listenable: syncService,
      builder: (context, _) {
        if (syncService.syncing) {
          return const Padding(
            padding: EdgeInsets.all(14),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return IconButton(
          icon: const Icon(Icons.sync),
          tooltip: 'Sync now',
          onPressed: _syncNow,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: _vehicles.isEmpty
              ? const Text('Vehicle Log')
              : DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _vehicle?.id,
                    items: [
                      for (final v in _vehicles)
                        DropdownMenuItem(value: v.id, child: Text(v.name)),
                    ],
                    onChanged: (id) {
                      setState(() {
                        _vehicle = _vehicles.firstWhere((v) => v.id == id);
                      });
                    },
                  ),
                ),
          actions: [
            _syncButton(),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'add') _openVehicleForm();
                if (value == 'edit') _openVehicleForm(existing: _vehicle);
                if (value == 'delete') _deleteVehicle();
                if (value == 'settings') _openSettings();
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'add', child: Text('Add vehicle')),
                if (_vehicle != null) ...const [
                  PopupMenuItem(value: 'edit', child: Text('Edit vehicle')),
                  PopupMenuItem(value: 'delete', child: Text('Delete vehicle')),
                ],
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'settings', child: Text('Settings')),
              ],
            ),
          ],
          bottom: _vehicle == null
              ? null
              : const TabBar(
                  tabs: [
                    Tab(text: 'Details'),
                    Tab(text: 'Fuel'),
                    Tab(text: 'Maintenance'),
                    Tab(text: 'Stats'),
                  ],
                ),
        ),
        body: _buildBody(),
      ),
    );
  }
}
