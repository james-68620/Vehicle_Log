import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:smb_connect/smb_connect.dart';

import 'database.dart';
import 'sync_config.dart';

const int _fileFormat = 1; // bump if the sync file layout ever changes
const Duration _connectTimeout = Duration(seconds: 8);
const Duration _syncInterval = Duration(minutes: 5);

class SyncResult {
  final bool ok;
  final String message;
  const SyncResult(this.ok, this.message);
}

// Does the syncing, and tells the screens what it is doing.
class SyncService extends ChangeNotifier {
  bool _syncing = false;
  bool get syncing => _syncing;

  String? _lastMessage;
  String? get lastMessage => _lastMessage;

  DateTime? _lastSync;
  DateTime? get lastSync => _lastSync;

  // Goes up whenever a sync brought in changes, so screens know to reload.
  int _dataVersion = 0;
  int get dataVersion => _dataVersion;

  // Tells screens to reload from the database. Used when the app returns
  // from the background, because the background job may have changed data.
  void notifyDataChanged() {
    _dataVersion++;
    notifyListeners();
  }

  Timer? _timer;

  // Syncs now, then again every few minutes while the app is open.
  Future<void> start() async {
    _lastSync = await SyncConfigStore.lastSync();
    notifyListeners();
    runSync();
    _timer?.cancel();
    _timer = Timer.periodic(_syncInterval, (_) => runSync());
  }

  Future<SyncResult> runSync() async {
    if (_syncing) return const SyncResult(false, 'A sync is already running');
    _syncing = true;
    notifyListeners();

    SyncResult result;
    try {
      final config = await SyncConfigStore.load();
      if (!config.enabled || !config.isComplete) {
        result = const SyncResult(false, 'Sync is not set up (see Settings)');
      } else {
        final changed = await _syncOnce(config);
        _lastSync = DateTime.now();
        await SyncConfigStore.setLastSync(_lastSync!);
        if (changed > 0) _dataVersion++;
        result = SyncResult(
          true,
          changed == 0 ? 'Up to date' : 'Synced: $changed changes received',
        );
      }
    } on TimeoutException {
      result = const SyncResult(
        false,
        'Could not reach the server (not on your home network?)',
      );
    } catch (e) {
      result = SyncResult(false, 'Sync failed: $e');
    }

    _lastMessage = result.message;
    _syncing = false;
    notifyListeners();
    return result;
  }

  // Checks the details work, without syncing any data.
  Future<SyncResult> testConnection(SyncConfig config) async {
    try {
      final connect = await _connect(config);
      try {
        await _ensureFolder(connect, _folderPath(config));
      } finally {
        await connect.close();
      }
      return const SyncResult(true, 'Connection works');
    } on TimeoutException {
      return const SyncResult(false, 'Could not reach the server');
    } catch (e) {
      return SyncResult(false, 'Connection failed: $e');
    }
  }

  Future<SmbConnect> _connect(SyncConfig c) {
    return SmbConnect.connectAuth(
      host: c.host,
      domain: c.domain,
      username: c.username,
      password: c.password,
    ).timeout(_connectTimeout);
  }

  // e.g. /vehiclelog/VehicleLog  (the first part is the share name)
  String _folderPath(SyncConfig c) {
    final share = c.share.replaceAll('/', '');
    final folder = c.folder.replaceAll('/', '');
    return '/$share/$folder';
  }

  Future<SmbFile> _ensureFolder(SmbConnect connect, String path) async {
    final folder = await connect.file(path);
    if (folder.isExists) return folder;
    return connect.createFolder(path);
  }

  Future<String> _readText(SmbConnect connect, SmbFile file) async {
    final stream = await connect.openRead(file);
    final bytes = BytesBuilder();
    await for (final chunk in stream) {
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes());
  }

  Future<void> _writeText(SmbConnect connect, String path, String text) async {
    var file = await connect.file(path);
    if (file.isExists) {
      await connect.delete(file);
    }
    file = await connect.createFile(path);
    final writer = await connect.openWrite(file);
    writer.add(utf8.encode(text));
    await writer.flush();
    await writer.close();
  }

  // One full sync. Returns how many records were received from other devices.
  Future<int> _syncOnce(SyncConfig config) async {
    final deviceId = await SyncConfigStore.deviceId();
    final ownName = '$deviceId.json';
    final connect = await _connect(config);

    try {
      final folderPath = _folderPath(config);
      final folder = await _ensureFolder(connect, folderPath);

      // 1. Read and merge every other device's file.
      int changed = 0;
      final files = await connect.listFiles(folder);
      for (final file in files) {
        final name = file.path.split('/').last;
        if (!name.endsWith('.json') || name == ownName) continue;
        try {
          final data = jsonDecode(await _readText(connect, file));
          if (data is! Map<String, dynamic>) continue;
          final format = data['format'];
          if (format is int && format > _fileFormat) continue; // newer app
          changed += await AppDatabase.mergeAll(data);
        } catch (e) {
          debugPrint('Skipping $name: $e');
        }
      }

      // 2. Write our own copy, which now includes everything merged.
      final export = await AppDatabase.exportAll();
      final text = jsonEncode({
        'format': _fileFormat,
        'device': deviceId,
        'saved_at': DateTime.now().toIso8601String(),
        ...export,
      });
      await _writeText(connect, '$folderPath/$ownName', text);

      return changed;
    } finally {
      await connect.close();
    }
  }
}

// One shared copy that every screen can use.
final SyncService syncService = SyncService();
