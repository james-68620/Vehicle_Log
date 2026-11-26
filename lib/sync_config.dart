import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// The server details the user types into Settings.
class SyncConfig {
  final bool enabled;
  final String host; // e.g. 192.168.1.50
  final String share; // the Samba share name
  final String folder; // a folder inside the share
  final String domain; // usually blank
  final String username;
  final String password;

  const SyncConfig({
    this.enabled = false,
    this.host = '',
    this.share = '',
    this.folder = 'VehicleLog',
    this.domain = '',
    this.username = '',
    this.password = '',
  });

  bool get isComplete =>
      host.isNotEmpty &&
      share.isNotEmpty &&
      folder.isNotEmpty &&
      username.isNotEmpty;
}

// Saves and loads the sync settings. Everything except the password goes in
// shared_preferences; the password goes in the platform's secure storage.
class SyncConfigStore {
  static const _secure = FlutterSecureStorage();
  static const _passwordKey = 'sync_password';

  static Future<SyncConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    String password = '';
    try {
      password = await _secure.read(key: _passwordKey) ?? '';
    } catch (_) {
      // Secure storage unavailable; treat as no saved password.
    }

    return SyncConfig(
      enabled: prefs.getBool('sync_enabled') ?? false,
      host: prefs.getString('sync_host') ?? '',
      share: prefs.getString('sync_share') ?? '',
      folder: prefs.getString('sync_folder') ?? 'VehicleLog',
      domain: prefs.getString('sync_domain') ?? '',
      username: prefs.getString('sync_username') ?? '',
      password: password,
    );
  }

  static Future<void> save(SyncConfig c) async {
    // Password first: if secure storage fails, nothing else is half-saved.
    await _secure.write(key: _passwordKey, value: c.password);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sync_enabled', c.enabled);
    await prefs.setString('sync_host', c.host);
    await prefs.setString('sync_share', c.share);
    await prefs.setString('sync_folder', c.folder);
    await prefs.setString('sync_domain', c.domain);
    await prefs.setString('sync_username', c.username);
  }

  // A random id that identifies this device (created the first time).
  static Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('device_id');
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString('device_id', id);
    }
    return id;
  }

  static Future<DateTime?> lastSync() async {
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString('last_sync');
    return text == null ? null : DateTime.tryParse(text);
  }

  static Future<void> setLastSync(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_sync', time.toIso8601String());
  }
}
