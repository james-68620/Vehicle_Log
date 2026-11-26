import 'dart:io';
import 'sync_on_change.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';

class AppDatabase {
  static Database? _db;

  static Future<Database> get() async {
    if (_db != null) return _db!;

    // Desktop needs this extra setup; Android doesn't.
    if (Platform.isLinux || Platform.isWindows) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'fuel_log.db');

    _db = await openDatabase(
      path,
      version: 6,
      // Runs only when the database is first created.
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE vehicles (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            reg_number TEXT,
            make TEXT,
            model TEXT,
            year INTEGER,
            tank_capacity REAL,
            mileage INTEGER,
            mot_date TEXT,
            updated_at TEXT NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE fuel_entries (
            id TEXT PRIMARY KEY,
            vehicle_id TEXT,
            date TEXT NOT NULL,
            odometer INTEGER NOT NULL,
            litres REAL NOT NULL,
            cost REAL NOT NULL,
            full_tank INTEGER NOT NULL DEFAULT 1,
            updated_at TEXT NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await _createServiceTable(db);
        await _createReminderTable(db);
      },
      // Runs when an older database is opened by a newer version of the app.
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE fuel_entries ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE vehicles (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              deleted INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('ALTER TABLE fuel_entries ADD COLUMN vehicle_id TEXT');

          // Create a first vehicle and give all existing entries to it.
          final vehicleId = const Uuid().v4();
          await db.insert('vehicles', {
            'id': vehicleId,
            'name': 'My vehicle',
            'updated_at': DateTime.now().toIso8601String(),
            'deleted': 0,
          });
          await db.update('fuel_entries', {'vehicle_id': vehicleId});
        }
        if (oldVersion < 4) {
          await _createServiceTable(db);
        }
        if (oldVersion < 5) {
          // Existing fill-ups are assumed to be full tanks.
          await db.execute(
            'ALTER TABLE fuel_entries ADD COLUMN full_tank INTEGER NOT NULL DEFAULT 1',
          );
          await db.execute('ALTER TABLE vehicles ADD COLUMN reg_number TEXT');
          await db.execute('ALTER TABLE vehicles ADD COLUMN make TEXT');
          await db.execute('ALTER TABLE vehicles ADD COLUMN model TEXT');
          await db.execute('ALTER TABLE vehicles ADD COLUMN year INTEGER');
          await db.execute('ALTER TABLE vehicles ADD COLUMN tank_capacity REAL');
          await db.execute('ALTER TABLE vehicles ADD COLUMN mileage INTEGER');
          await db.execute('ALTER TABLE vehicles ADD COLUMN mot_date TEXT');
        }
        if (oldVersion < 6) {
          await _createReminderTable(db);
        }
      },
    );
    return _db!;
  }

  static Future<void> _createServiceTable(Database db) async {
    await db.execute('''
      CREATE TABLE service_entries (
        id TEXT PRIMARY KEY,
        vehicle_id TEXT NOT NULL,
        date TEXT NOT NULL,
        odometer INTEGER NOT NULL,
        service_type TEXT NOT NULL,
        cost REAL NOT NULL,
        notes TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  static Future<void> _createReminderTable(Database db) async {
    await db.execute('''
      CREATE TABLE service_reminders (
        id TEXT PRIMARY KEY,
        vehicle_id TEXT NOT NULL,
        service_type TEXT NOT NULL,
        interval_km INTEGER,
        interval_months INTEGER,
        updated_at TEXT NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  // ---- Vehicles ----

  static Future<List<Vehicle>> loadVehicles() async {
    final db = await get();
    final rows = await db.query(
      'vehicles',
      where: 'deleted = 0',
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows.map(Vehicle.fromMap).toList();
  }

  // Adds a new vehicle, or replaces an existing one with the same id.
  static Future<void> saveVehicle(Vehicle vehicle) async {
    final db = await get();
    await db.insert(
      'vehicles',
      vehicle.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
        SyncOnChange.request();
  }

  static Future<void> deleteVehicle(String id) async {
    final db = await get();
    await db.update(
      'vehicles',
      {'deleted': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
        SyncOnChange.request();
  }

  // The highest odometer reading logged for this vehicle (fuel or service).
  static Future<int?> latestOdometer(String vehicleId) async {
    final db = await get();
    final rows = await db.rawQuery('''
      SELECT MAX(odometer) AS latest FROM (
        SELECT odometer FROM fuel_entries
          WHERE vehicle_id = ? AND deleted = 0
        UNION ALL
        SELECT odometer FROM service_entries
          WHERE vehicle_id = ? AND deleted = 0
      )
    ''', [vehicleId, vehicleId]);
    return rows.first['latest'] as int?;
  }

  // ---- Fuel entries ----

  // Only this vehicle's entries that haven't been deleted.
  static Future<List<FuelEntry>> loadEntries(String vehicleId) async {
    final db = await get();
    final rows = await db.query(
      'fuel_entries',
      where: 'deleted = 0 AND vehicle_id = ?',
      whereArgs: [vehicleId],
      orderBy: 'odometer ASC',
    );
    return rows.map(FuelEntry.fromMap).toList();
  }

  // Adds a new entry, or replaces an existing one with the same id (an edit).
  static Future<void> insertEntry(FuelEntry entry) async {
    final db = await get();
    await db.insert(
      'fuel_entries',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
        SyncOnChange.request();
  }

  static Future<void> deleteEntry(String id) async {
    final db = await get();
    await db.update(
      'fuel_entries',
      {'deleted': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
        SyncOnChange.request();
  }

  // ---- Service entries ----

  // Newest first.
  static Future<List<ServiceEntry>> loadServices(String vehicleId) async {
    final db = await get();
    final rows = await db.query(
      'service_entries',
      where: 'deleted = 0 AND vehicle_id = ?',
      whereArgs: [vehicleId],
      orderBy: 'date DESC, odometer DESC',
    );
    return rows.map(ServiceEntry.fromMap).toList();
  }

  static Future<void> saveService(ServiceEntry entry) async {
    final db = await get();
    await db.insert(
      'service_entries',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
        SyncOnChange.request();
  }

  static Future<void> deleteService(String id) async {
    final db = await get();
    await db.update(
      'service_entries',
      {'deleted': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
        SyncOnChange.request();
  }

  // ---- Service reminders ----

  static Future<List<ServiceReminder>> loadReminders(String vehicleId) async {
    final db = await get();
    final rows = await db.query(
      'service_reminders',
      where: 'deleted = 0 AND vehicle_id = ?',
      whereArgs: [vehicleId],
      orderBy: 'service_type COLLATE NOCASE ASC',
    );
    return rows.map(ServiceReminder.fromMap).toList();
  }

  static Future<void> saveReminder(ServiceReminder reminder) async {
    final db = await get();
    await db.insert(
      'service_reminders',
      reminder.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
        SyncOnChange.request();
  }

  static Future<void> deleteReminder(String id) async {
    final db = await get();
    await db.update(
      'service_reminders',
      {'deleted': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
        SyncOnChange.request();
  }

  // ---- Sync ----

  static const _syncTables = [
    'vehicles',
    'fuel_entries',
    'service_entries',
    'service_reminders',
  ];

  // Everything in the database, including deleted rows, ready for sync.
  static Future<Map<String, List<Map<String, Object?>>>> exportAll() async {
    final db = await get();
    final result = <String, List<Map<String, Object?>>>{};
    for (final table in _syncTables) {
      result[table] = await db.query(table);
    }
    return result;
  }

  // Merges rows received from another device. A row is only taken if it is
  // new to this device or has a newer updated_at. Returns how many changed.
  static Future<int> mergeAll(Map<String, dynamic> remote) async {
    final db = await get();
    int changed = 0;

    await db.transaction((txn) async {
      for (final table in _syncTables) {
        final rows = remote[table];
        if (rows is! List) continue;

        // Only copy columns this version of the app knows about.
        final info = await txn.rawQuery('PRAGMA table_info($table)');
        final columns = info.map((c) => c['name'] as String).toSet();

        for (final raw in rows) {
          if (raw is! Map) continue;

          final row = <String, Object?>{};
          for (final entry in raw.entries) {
            final key = entry.key;
            if (key is String && columns.contains(key)) {
              row[key] = entry.value;
            }
          }

          final id = row['id'];
          final remoteTime = DateTime.tryParse('${row['updated_at']}');
          if (id is! String || remoteTime == null) continue;

          final local = await txn.query(
            table,
            columns: ['updated_at'],
            where: 'id = ?',
            whereArgs: [id],
          );
          if (local.isNotEmpty) {
            final localTime =
                DateTime.tryParse(local.first['updated_at'] as String);
            if (localTime != null && !remoteTime.isAfter(localTime)) continue;
          }

          try {
            await txn.insert(
              table,
              row,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            changed++;
          } catch (_) {
            // Skip a row that doesn't fit this version's table.
          }
        }
      }
    });
    return changed;
  }
}
