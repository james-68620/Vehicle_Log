import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'database.dart';
import 'models.dart';
import 'sync_service.dart';

// What happened during an import.
class ImportResult {
  int added = 0;
  int duplicates = 0;
  int vehiclesCreated = 0;
  final List<String> problems = [];

  String summary(String noun) {
    final lines = <String>[];
    lines.add('Imported $added $noun.');
    if (duplicates > 0) {
      lines.add('Skipped $duplicates that were already in the app.');
    }
    if (vehiclesCreated > 0) {
      lines.add('Created $vehiclesCreated new '
          '${vehiclesCreated == 1 ? 'vehicle' : 'vehicles'}.');
    }
    if (problems.isNotEmpty) {
      lines.add('');
      lines.add('Problems:');
      lines.addAll(problems.take(8));
      if (problems.length > 8) {
        lines.add('...and ${problems.length - 8} more.');
      }
    }
    return lines.join('\n');
  }
}

// Reading and writing CSV files of fuel and service history.
// Distances are always kilometres and fuel always litres in the files.
class CsvTools {
  CsvTools._();

  // ---------------------------------------------------------------- export

  static Future<String> exportFuelFile() async {
    final vehicles = await AppDatabase.loadVehicles();
    final lines = <String>[
      _line(['vehicle', 'date', 'odometer_km', 'litres', 'cost', 'full_tank']),
    ];
    var count = 0;
    for (final vehicle in vehicles) {
      final entries = await AppDatabase.loadEntries(vehicle.id);
      for (final e in entries) {
        lines.add(_line([
          vehicle.name,
          _formatDate(e.date),
          '${e.odometer}',
          '${e.litres}',
          e.cost.toStringAsFixed(2),
          e.fullTank ? 'yes' : 'no',
        ]));
        count++;
      }
    }
    if (count == 0) return 'There are no fuel entries to export.';

    final saved = await _saveCsv(
      'vehicle-log-fuel-${_formatDate(DateTime.now())}.csv',
      '${lines.join('\r\n')}\r\n',
    );
    return saved ? 'Exported $count fuel entries.' : 'Export cancelled.';
  }

  static Future<String> exportServiceFile() async {
    final vehicles = await AppDatabase.loadVehicles();
    final lines = <String>[
      _line(['vehicle', 'date', 'odometer_km', 'service_type', 'cost', 'notes']),
    ];
    var count = 0;
    for (final vehicle in vehicles) {
      final entries = await AppDatabase.loadServices(vehicle.id); // newest first
      for (final e in entries.reversed) {
        lines.add(_line([
          vehicle.name,
          _formatDate(e.date),
          e.odometer == null ? '' : '${e.odometer}',
          e.serviceType,
          e.cost.toStringAsFixed(2),
          e.notes,
        ]));
        count++;
      }
    }
    if (count == 0) return 'There are no service entries to export.';

    final saved = await _saveCsv(
      'vehicle-log-service-${_formatDate(DateTime.now())}.csv',
      '${lines.join('\r\n')}\r\n',
    );
    return saved ? 'Exported $count service entries.' : 'Export cancelled.';
  }

  // ---------------------------------------------------------------- import

  static Future<String> importFuelFile() async {
    final text = await _pickText();
    if (text == null) return 'Import cancelled.';
    final result = await importFuel(text);
    return result.summary('fuel entries');
  }

  static Future<String> importServiceFile() async {
    final text = await _pickText();
    if (text == null) return 'Import cancelled.';
    final result = await importService(text);
    return result.summary('service entries');
  }

  static Future<ImportResult> importFuel(String text) async {
    final result = ImportResult();
    final sheet = _Sheet(text);

    final cVehicle = sheet.col(['vehicle']);
    final cDate = sheet.col(['date']);
    final cOdo = sheet.col(['odometer_km', 'odometer']);
    final cLitres = sheet.col(['litres', 'liters']);
    final cCost = sheet.col(['cost', 'total_cost']);
    final cFull = sheet.col(['full_tank', 'full']);

    final missing = <String>[
      if (cVehicle == null) 'vehicle',
      if (cDate == null) 'date',
      if (cOdo == null) 'odometer_km',
      if (cLitres == null) 'litres',
      if (cCost == null) 'cost',
    ];
    if (missing.isNotEmpty) {
      result.problems.add('The file is missing these columns: '
          '${missing.join(', ')}.');
      return result;
    }

    final vehicles = await _VehicleLookup.load();
    final seen = <String, Set<String>>{};

    Future<Set<String>> keysFor(String vehicleId) async {
      final existing = seen[vehicleId];
      if (existing != null) return existing;
      final entries = await AppDatabase.loadEntries(vehicleId);
      final keys =
          entries.map((e) => '${_formatDate(e.date)}|${e.odometer}').toSet();
      seen[vehicleId] = keys;
      return keys;
    }

    for (var i = 0; i < sheet.rows.length; i++) {
      final row = sheet.rows[i];
      final label = 'Row ${sheet.lineNumbers[i]}';

      final name = _cell(row, cVehicle);
      final date = _parseDate(_cell(row, cDate));
      final odometer = _parseNumber(_cell(row, cOdo))?.round();
      final litres = _parseNumber(_cell(row, cLitres));
      final cost = _parseNumber(_cell(row, cCost));

      if (name.isEmpty) {
        result.problems.add('$label: no vehicle name.');
        continue;
      }
      if (date == null) {
        result.problems.add('$label: date not understood '
            '("${_cell(row, cDate)}"). Use 2025-03-14 or 14/03/2025.');
        continue;
      }
      if (odometer == null || odometer < 0) {
        result.problems.add('$label: odometer is not a valid number.');
        continue;
      }
      if (litres == null || litres <= 0) {
        result.problems.add('$label: litres must be a number above 0.');
        continue;
      }
      if (cost == null || cost < 0) {
        result.problems.add('$label: cost is not a valid number.');
        continue;
      }
      final fullTank = _parseYesNo(_cell(row, cFull)) ?? true;

      final vehicleId = await vehicles.idFor(name, result);
      final keys = await keysFor(vehicleId);
      final key = '${_formatDate(date)}|$odometer';
      if (keys.contains(key)) {
        result.duplicates++;
        continue;
      }

      await AppDatabase.insertEntry(FuelEntry(
        vehicleId: vehicleId,
        date: date,
        odometer: odometer,
        litres: litres,
        cost: cost,
        fullTank: fullTank,
      ));
      keys.add(key);
      result.added++;
    }

    _tellAppAboutChanges(result);
    return result;
  }

  static Future<ImportResult> importService(String text) async {
    final result = ImportResult();
    final sheet = _Sheet(text);

    final cVehicle = sheet.col(['vehicle']);
    final cDate = sheet.col(['date']);
    final cOdo = sheet.col(['odometer_km', 'odometer']);
    final cType = sheet.col(['service_type', 'type']);
    final cCost = sheet.col(['cost', 'total_cost']);
    final cNotes = sheet.col(['notes']);

    final missing = <String>[
      if (cVehicle == null) 'vehicle',
      if (cDate == null) 'date',
      if (cOdo == null) 'odometer_km',
      if (cType == null) 'service_type',
      if (cCost == null) 'cost',
    ];
    if (missing.isNotEmpty) {
      result.problems.add('The file is missing these columns: '
          '${missing.join(', ')}.');
      return result;
    }

    final vehicles = await _VehicleLookup.load();
    final seen = <String, Set<String>>{};

    Future<Set<String>> keysFor(String vehicleId) async {
      final existing = seen[vehicleId];
      if (existing != null) return existing;
      final entries = await AppDatabase.loadServices(vehicleId);
      final keys = entries
          .map((e) => '${_formatDate(e.date)}|${e.odometer}|'
              '${e.serviceType.trim().toLowerCase()}')
          .toSet();
      seen[vehicleId] = keys;
      return keys;
    }

    for (var i = 0; i < sheet.rows.length; i++) {
      final row = sheet.rows[i];
      final label = 'Row ${sheet.lineNumbers[i]}';

      final name = _cell(row, cVehicle);
      final date = _parseDate(_cell(row, cDate));
      final odoText = _cell(row, cOdo);
      final noOdometer = odoText.isEmpty || odoText.toLowerCase() == 'null';
      final int? odometer =
          noOdometer ? null : _parseNumber(odoText)?.round();
      final type = _cell(row, cType);
      final cost = _parseNumber(_cell(row, cCost));

      if (name.isEmpty) {
        result.problems.add('$label: no vehicle name.');
        continue;
      }
      if (date == null) {
        result.problems.add('$label: date not understood '
            '("${_cell(row, cDate)}"). Use 2025-03-14 or 14/03/2025.');
        continue;
      }
            if (!noOdometer && (odometer == null || odometer < 0)) {
        result.problems.add('$label: odometer is not a valid number.');
        continue;
      }
      if (type.isEmpty) {
        result.problems.add('$label: no service type.');
        continue;
      }
      if (cost == null || cost < 0) {
        result.problems.add('$label: cost is not a valid number.');
        continue;
      }

      final vehicleId = await vehicles.idFor(name, result);
      final keys = await keysFor(vehicleId);
      final key = '${_formatDate(date)}|$odometer|${type.toLowerCase()}';
      if (keys.contains(key)) {
        result.duplicates++;
        continue;
      }

      await AppDatabase.saveService(ServiceEntry(
        vehicleId: vehicleId,
        date: date,
        odometer: odometer,
        serviceType: type,
        cost: cost,
        notes: _cell(row, cNotes),
      ));
      keys.add(key);
      result.added++;
    }

    _tellAppAboutChanges(result);
    return result;
  }

  // Makes the screens reload after an import.
  static void _tellAppAboutChanges(ImportResult result) {
    if (result.added > 0 || result.vehiclesCreated > 0) {
      syncService.notifyDataChanged();
    }
  }

  // ----------------------------------------------------------------- files

  static const XTypeGroup _csvType = XTypeGroup(
    label: 'CSV files',
    extensions: ['csv'],
  );

  // Returns true if saved or shared, false if the person cancelled.
  static Future<bool> _saveCsv(String fileName, String content) async {
    // The three bytes at the start make Excel show £ and accents correctly.
    final bytes =
        Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(content)]);

    // Android has no "save as" dialog, so the file goes to the share menu
    // (Files, Drive, email and so on) and the person picks where it lands.
    if (Platform.isAndroid) {
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, fileName));
      await file.writeAsBytes(bytes);
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv')],
          subject: fileName,
        ),
      );
      return result.status != ShareResultStatus.dismissed;
    }

    // On the PC the dialog picks the place and we write the file.
    final location = await getSaveLocation(
      suggestedName: fileName,
      acceptedTypeGroups: [_csvType],
    );
    if (location == null) return false;

    var target = location.path;
    if (!target.toLowerCase().endsWith('.csv')) target = '$target.csv';
    await File(target).writeAsBytes(bytes);
    return true;
  }

  // Lets the person choose a file and returns its text, or null if cancelled.
  static Future<String?> _pickText() async {
    // Android's picker can wrongly grey out .csv files, so don't filter there.
    final file = await openFile(
      acceptedTypeGroups: Platform.isAndroid ? <XTypeGroup>[] : [_csvType],
    );
    if (file == null) return null;

    final bytes = await file.readAsBytes();
    if (bytes.length > 10 * 1024 * 1024) {
      throw 'That file is over 10 MB, which is too large for a vehicle log.';
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
 }
  
// ------------------------------------------------------------ vehicle lookup

// Matches vehicle names in a file to vehicles in the app, creating any that
// don't exist yet.
class _VehicleLookup {
  final Map<String, String> _ids; // lower-case name -> id

  _VehicleLookup(this._ids);

  static Future<_VehicleLookup> load() async {
    final ids = <String, String>{};
    for (final v in await AppDatabase.loadVehicles()) {
      ids.putIfAbsent(v.name.trim().toLowerCase(), () => v.id);
    }
    return _VehicleLookup(ids);
  }

  Future<String> idFor(String name, ImportResult result) async {
    final key = name.trim().toLowerCase();
    final found = _ids[key];
    if (found != null) return found;

    final vehicle = Vehicle(name: name.trim());
    await AppDatabase.saveVehicle(vehicle);
    _ids[key] = vehicle.id;
    result.vehiclesCreated++;
    return vehicle.id;
  }
}

// --------------------------------------------------------------- CSV basics

// A parsed CSV file: a header row naming the columns, then the data rows.
class _Sheet {
  final Map<String, int> _index = {};
  final List<List<String>> rows = [];
  final List<int> lineNumbers = []; // row number in the file, header = 1

  _Sheet(String text) {
    final all = _parseCsv(text);
    final headerAt = all.indexWhere((r) => r.any((c) => c.trim().isNotEmpty));
    if (headerAt < 0) return;

    final header = all[headerAt];
    for (var i = 0; i < header.length; i++) {
      final name =
          header[i].trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
      if (name.isNotEmpty) _index.putIfAbsent(name, () => i);
    }

    for (var i = headerAt + 1; i < all.length; i++) {
      if (all[i].every((c) => c.trim().isEmpty)) continue; // blank line
      rows.add(all[i]);
      lineNumbers.add(i + 1);
    }
  }

  // The column number for the first of these names that exists.
  int? col(List<String> names) {
    for (final name in names) {
      final i = _index[name];
      if (i != null) return i;
    }
    return null;
  }
}

String _cell(List<String> row, int? col) {
  if (col == null || col >= row.length) return '';
  return row[col].trim();
}

// Splits CSV text into rows of cells. Handles quoted cells that contain
// commas, quotes ("") or line breaks, and files that use ; instead of ,
// (common when a spreadsheet is set to a European language).
List<List<String>> _parseCsv(String input) {
  var text = input;
  if (text.startsWith('\uFEFF')) text = text.substring(1);

  final firstLine = text.split(RegExp(r'[\r\n]')).first;
  final delimiter =
      (firstLine.contains(';') && !firstLine.contains(',')) ? ';' : ',';

  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"'); // a doubled quote means one quote character
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        cell.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == delimiter) {
      row.add(cell.toString());
      cell.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = <String>[];
    } else {
      cell.write(c);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows;
}

// Wraps a cell in quotes if it needs them.
String _escape(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

String _line(List<String> cells) => cells.map(_escape).join(',');

// ----------------------------------------------------------- value parsing

String _two(int n) => n.toString().padLeft(2, '0');

String _formatDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

// Understands 2025-03-14 and 14/03/2025 (day first, as used in the UK).
DateTime? _parseDate(String input) {
  final s = input.trim();

  final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(s);
  if (iso != null) {
    return _validDate(
      int.parse(iso.group(1)!),
      int.parse(iso.group(2)!),
      int.parse(iso.group(3)!),
    );
  }

  final uk = RegExp(r'^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$').firstMatch(s);
  if (uk != null) {
    return _validDate(
      int.parse(uk.group(3)!),
      int.parse(uk.group(2)!),
      int.parse(uk.group(1)!),
    );
  }
  return null;
}

DateTime? _validDate(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final date = DateTime(year, month, day);
  if (date.month != month) return null; // e.g. 31 February
  return date;
}

// Reads 12.5, 1,234.50, 12,5 and £12.50.
double? _parseNumber(String input) {
  var t = input.replaceAll(RegExp(r'[£$€\s]'), '');
  if (t.isEmpty) return null;
  if (t.contains('.')) {
    t = t.replaceAll(',', '');
  } else {
    t = t.replaceAll(',', '.');
  }
  return double.tryParse(t);
}

bool? _parseYesNo(String input) {
  switch (input.trim().toLowerCase()) {
    case 'yes':
    case 'y':
    case 'true':
    case '1':
    case 'full':
      return true;
    case 'no':
    case 'n':
    case 'false':
    case '0':
    case 'partial':
      return false;
  }
  return null; // empty or unknown
}
