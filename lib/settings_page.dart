import 'dart:io';
import 'package:flutter/material.dart';

import 'background_sync.dart';
import 'csv_tools.dart';
import 'reminder_notifier.dart';
import 'settings.dart';
import 'sync_config.dart';
import 'sync_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  final _hostController = TextEditingController();
  final _shareController = TextEditingController();
  final _folderController = TextEditingController();
  final _domainController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _enabled = false;
  bool _loaded = false;
  bool _busy = false;
  bool _hidePassword = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final c = await SyncConfigStore.load();
    if (!mounted) return;
    setState(() {
      _enabled = c.enabled;
      _hostController.text = c.host;
      _shareController.text = c.share;
      _folderController.text = c.folder;
      _domainController.text = c.domain;
      _usernameController.text = c.username;
      _passwordController.text = c.password;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _hostController.dispose();
    _shareController.dispose();
    _folderController.dispose();
    _domainController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  SyncConfig _currentConfig() => SyncConfig(
        enabled: _enabled,
        host: _hostController.text.trim(),
        share: _shareController.text.trim(),
        folder: _folderController.text.trim(),
        domain: _domainController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // True if the form is valid and has all the details needed to connect.
  bool _checkReady() {
    if (!_formKey.currentState!.validate()) return false;
    if (!_currentConfig().isComplete) {
      _show('Fill in the server, share, folder and username first');
      return false;
    }
    return true;
  }

  Future<bool> _save() async {
    if (!_formKey.currentState!.validate()) return false;
    setState(() => _busy = true);
    try {
      await SyncConfigStore.save(_currentConfig());
      await BackgroundSync.apply(); // start or stop the background job
      return true;
    } catch (e) {
      _show('Could not save: $e');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onSave() async {
    if (await _save()) _show('Saved');
  }

  Future<void> _onTest() async {
    if (!_checkReady()) return;
    setState(() => _busy = true);
    final result = await syncService.testConnection(_currentConfig());
    if (mounted) setState(() => _busy = false);
    _show(result.message);
  }

  Future<void> _onSyncNow() async {
    if (!_checkReady()) return;
    if (!_enabled) {
      _show('Turn on "Sync with a server" first');
      return;
    }
    if (!await _save()) return;
    final result = await syncService.runSync();
    _show(result.message);
  }

  String? _requiredWhenEnabled(String? value) {
    if (_enabled && (value == null || value.trim().isEmpty)) return 'Required';
    return null;
  }

  Widget _unitsSection(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Units', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Metric')),
              ButtonSegment(value: true, label: Text('Imperial')),
            ],
            selected: {settings.imperial},
            onSelectionChanged: (selection) =>
                settings.setImperial(selection.first),
          ),
          const SizedBox(height: 12),
          Text(
            settings.imperial
                ? 'Distances in miles, consumption in MPG (imperial gallons).'
                : 'Distances in kilometres, consumption in L/100km.',
          ),
          const SizedBox(height: 8),
          Text(
            'Fuel is always entered in litres. Your data is stored in '
            'kilometres, so switching units never changes what is saved.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _currencySection(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Currency', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          DropdownButton<String>(
            isExpanded: true,
            value: settings.currency,
            items: [
              for (final option in currencyOptions)
                DropdownMenuItem(
                  value: option.symbol,
                  child: Text(option.name),
                ),
            ],
            onChanged: (value) {
              if (value != null) settings.setCurrency(value);
            },
          ),
          const SizedBox(height: 8),
          Text(
            'This only changes how amounts are shown. Nothing is converted.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<void> _onNotificationsToggled(bool value) async {
    if (value) {
      final granted = await ReminderNotifier.requestPermission();
      if (!granted) {
        _show('Notifications are blocked. Allow them for this app in '
            'Android settings, then try again.');
        return;
      }
    }
    await settings.setNotifications(value);
    await BackgroundSync.apply(); // start or stop the background job
    if (value) await ReminderNotifier.check();
  }

  Widget _notificationsSection(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Notifications',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Remind me about MOT and services'),
            subtitle: const Text(
              'Checks in the background and notifies you when an MOT or '
              'service is due soon or overdue. Nothing is sent between '
              '21:00 and 08:00.',
            ),
            value: settings.notifications,
            onChanged: _onNotificationsToggled,
          ),
          if (settings.notifications)
            OutlinedButton(
              onPressed: ReminderNotifier.showTest,
              child: const Text('Send a test notification'),
            ),
        ],
      ),
    );
  }

    bool _dataBusy = false;

  // Runs an import or export and shows what happened in a dialog.
  Future<void> _runData(Future<String> Function() action) async {
    if (_dataBusy) return;
    setState(() => _dataBusy = true);

    String message;
    try {
      message = await action();
    } catch (e) {
      message = 'Something went wrong: $e';
    }

    if (!mounted) return;
    setState(() => _dataBusy = false);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Data'),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _dataSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Data', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Export your history as CSV files (for backups or spreadsheets), '
          'or import them. Files always use kilometres and litres, whatever '
          'units you display.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (_dataBusy) const LinearProgressIndicator(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed:
                  _dataBusy ? null : () => _runData(CsvTools.exportFuelFile),
              child: const Text('Export fuel log'),
            ),
            OutlinedButton(
              onPressed: _dataBusy
                  ? null
                  : () => _runData(CsvTools.exportServiceFile),
              child: const Text('Export service history'),
            ),
            OutlinedButton(
              onPressed:
                  _dataBusy ? null : () => _runData(CsvTools.importFuelFile),
              child: const Text('Import fuel log'),
            ),
            OutlinedButton(
              onPressed: _dataBusy
                  ? null
                  : () => _runData(CsvTools.importServiceFile),
              child: const Text('Import service history'),
            ),
          ],
        ),
      ],
    );
  }

    Widget _receiptsSection(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Receipts and invoices',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Download all receipts to this device'),
            subtitle: const Text(
              'Off: a receipt is downloaded when you open it. On: every '
              'photo (the smaller copy) and PDF is downloaded during sync, '
              'which uses more storage and data. Full-size originals are '
              'always fetched from the photo viewer.',
            ),
            value: settings.attachmentsFullSync,
            onChanged: settings.setAttachmentsFullSync,
          ),
        ],
      ),
    );
  }

  Widget _statusText() {
    return ListenableBuilder(
      listenable: syncService,
      builder: (context, _) {
        final last = syncService.lastSync;
        final lines = <String>[
          if (last != null)
            'Last synced: ${last.toString().split('.').first}'
          else
            'Not synced yet',
          if (syncService.lastMessage != null) syncService.lastMessage!,
        ];
        return Text(
          lines.join('\n'),
          style: Theme.of(context).textTheme.bodySmall,
        );
      },
    );
  }

  Widget _syncSection(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sync', style: Theme.of(context).textTheme.titleMedium),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sync with a server'),
            subtitle: const Text(
              'Syncs when the app opens and every few minutes while it is '
              'open, whenever the server can be reached.',
            ),
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
          TextFormField(
            controller: _hostController,
            decoration: const InputDecoration(
              labelText: 'Server address',
              helperText: 'IP address or name, e.g. 192.168.1.50',
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
            validator: _requiredWhenEnabled,
          ),
          TextFormField(
            controller: _shareController,
            decoration: const InputDecoration(
              labelText: 'Share name',
              helperText: 'The name of the shared folder, not a path',
            ),
            autocorrect: false,
            validator: _requiredWhenEnabled,
          ),
          TextFormField(
            controller: _folderController,
            decoration: const InputDecoration(
              labelText: 'Folder inside the share',
              helperText: 'Created automatically; the sync files go here',
            ),
            autocorrect: false,
            validator: (value) {
              final text = value ?? '';
              if (text.contains('/') || text.contains('\\')) {
                return 'Just a folder name, no slashes';
              }
              return _requiredWhenEnabled(value);
            },
          ),
          TextFormField(
            controller: _usernameController,
            decoration: const InputDecoration(labelText: 'Username'),
            autocorrect: false,
            validator: _requiredWhenEnabled,
          ),
          TextFormField(
            controller: _passwordController,
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                icon: Icon(
                  _hidePassword ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () =>
                    setState(() => _hidePassword = !_hidePassword),
              ),
            ),
            obscureText: _hidePassword,
            autocorrect: false,
            enableSuggestions: false,
          ),
          TextFormField(
            controller: _domainController,
            decoration: const InputDecoration(
              labelText: 'Domain / workgroup (optional)',
              helperText: 'Leave blank; try WORKGROUP if login fails',
            ),
            autocorrect: false,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _busy ? null : _onSave,
                child: const Text('Save'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _onTest,
                child: const Text('Test connection'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _onSyncNow,
                child: const Text('Save & sync now'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _statusText(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _unitsSection(context),
                const SizedBox(height: 24),
                                _currencySection(context),
                const SizedBox(height: 24),
                _dataSection(context),
                const SizedBox(height: 24),
                _receiptsSection(context),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 24),
                  _notificationsSection(context),
                ],
                const Divider(height: 40),
                _syncSection(context),
              ],
            ),
    );
  }
}
