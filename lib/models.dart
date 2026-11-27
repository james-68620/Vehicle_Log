import 'package:uuid/uuid.dart';

class Vehicle {
  final String id;
  final String name;
  final String? regNumber;
  final String? make;
  final String? model;
  final int? year;
  final double? tankCapacity; // litres
  final int? mileage; // km
  final DateTime? motDate;
  final DateTime? taxDate; // when the vehicle tax is next due
  final DateTime updatedAt;
  final bool deleted;

  Vehicle({
    String? id,
    required this.name,
    this.regNumber,
    this.make,
    this.model,
    this.year,
    this.tankCapacity,
    this.mileage,
    this.motDate,
    this.taxDate,
    DateTime? updatedAt,
    this.deleted = false,
  })  : id = id ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'reg_number': regNumber,
        'make': make,
        'model': model,
        'year': year,
        'tank_capacity': tankCapacity,
        'mileage': mileage,
        'mot_date': motDate?.toIso8601String(),
        'tax_date': taxDate?.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'deleted': deleted ? 1 : 0,
      };

  factory Vehicle.fromMap(Map<String, Object?> map) => Vehicle(
        id: map['id'] as String,
        name: map['name'] as String,
        regNumber: map['reg_number'] as String?,
        make: map['make'] as String?,
        model: map['model'] as String?,
        year: map['year'] as int?,
        tankCapacity: (map['tank_capacity'] as num?)?.toDouble(),
        mileage: map['mileage'] as int?,
        motDate: map['mot_date'] == null
            ? null
            : DateTime.parse(map['mot_date'] as String),
        taxDate: map['tax_date'] == null
            ? null
            : DateTime.parse(map['tax_date'] as String),
        updatedAt: DateTime.parse(map['updated_at'] as String),
        deleted: (map['deleted'] as int) == 1,
      );
}

// One fill-up.
class FuelEntry {
  final String id;
  final String vehicleId;
  final DateTime date;
  final int odometer; // km
  final double litres;
  final double cost;
  final bool fullTank;
  final DateTime updatedAt;
  final bool deleted;

  FuelEntry({
    String? id,
    required this.vehicleId,
    required this.date,
    required this.odometer,
    required this.litres,
    required this.cost,
    this.fullTank = true,
    DateTime? updatedAt,
    this.deleted = false,
  })  : id = id ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, Object?> toMap() => {
        'id': id,
        'vehicle_id': vehicleId,
        'date': date.toIso8601String(),
        'odometer': odometer,
        'litres': litres,
        'cost': cost,
        'full_tank': fullTank ? 1 : 0,
        'updated_at': updatedAt.toIso8601String(),
        'deleted': deleted ? 1 : 0,
      };

  factory FuelEntry.fromMap(Map<String, Object?> map) => FuelEntry(
        id: map['id'] as String,
        vehicleId: map['vehicle_id'] as String,
        date: DateTime.parse(map['date'] as String),
        odometer: map['odometer'] as int,
        litres: (map['litres'] as num).toDouble(),
        cost: (map['cost'] as num).toDouble(),
        fullTank: (map['full_tank'] as int) == 1,
        updatedAt: DateTime.parse(map['updated_at'] as String),
        deleted: (map['deleted'] as int) == 1,
      );
}

// One piece of servicing or maintenance work.
class ServiceEntry {
  final String id;
  final String vehicleId;
  final DateTime date;
  final int? odometer; // km, may be missing
  final String serviceType; // e.g. "Oil change"
  final String category; // 'service', 'repair', 'parts' or 'other'
  final double cost;
  final String notes;
  final DateTime updatedAt;
  final bool deleted;

  ServiceEntry({
    String? id,
    required this.vehicleId,
    required this.date,
    this.odometer,
    required this.serviceType,
    this.category = 'service',
    required this.cost,
    this.notes = '',
    DateTime? updatedAt,
    this.deleted = false,
  })  : id = id ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, Object?> toMap() => {
        'id': id,
        'vehicle_id': vehicleId,
        'date': date.toIso8601String(),
        'odometer': odometer,
        'service_type': serviceType,
        'category': category,
        'cost': cost,
        'notes': notes,
        'updated_at': updatedAt.toIso8601String(),
        'deleted': deleted ? 1 : 0,
      };

  factory ServiceEntry.fromMap(Map<String, Object?> map) => ServiceEntry(
        id: map['id'] as String,
        vehicleId: map['vehicle_id'] as String,
        date: DateTime.parse(map['date'] as String),
        odometer: map['odometer'] as int?,
        serviceType: map['service_type'] as String,
        category: (map['category'] as String?) ?? 'service',
        cost: (map['cost'] as num).toDouble(),
        notes: map['notes'] as String,
        updatedAt: DateTime.parse(map['updated_at'] as String),
        deleted: (map['deleted'] as int) == 1,
      );
}

// The kinds of maintenance work, as stored. Order = order in menus.
const List<String> serviceCategories = ['service', 'repair', 'parts', 'other'];

String categoryLabel(String category) {
  switch (category) {
    case 'repair':
      return 'Repair';
    case 'parts':
      return 'Parts & upgrades';
    case 'other':
      return 'Other';
    default:
      return 'Service';
  }
}

// A repeating service job, e.g. "Oil change every 10,000 km or 12 months".
class ServiceReminder {
  final String id;
  final String vehicleId;
  final String serviceType;
  final int? intervalKm;
  final int? intervalMonths;
  final DateTime updatedAt;
  final bool deleted;

  ServiceReminder({
    String? id,
    required this.vehicleId,
    required this.serviceType,
    this.intervalKm,
    this.intervalMonths,
    DateTime? updatedAt,
    this.deleted = false,
  })  : id = id ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, Object?> toMap() => {
        'id': id,
        'vehicle_id': vehicleId,
        'service_type': serviceType,
        'interval_km': intervalKm,
        'interval_months': intervalMonths,
        'updated_at': updatedAt.toIso8601String(),
        'deleted': deleted ? 1 : 0,
      };

  factory ServiceReminder.fromMap(Map<String, Object?> map) => ServiceReminder(
        id: map['id'] as String,
        vehicleId: map['vehicle_id'] as String,
        serviceType: map['service_type'] as String,
        intervalKm: map['interval_km'] as int?,
        intervalMonths: map['interval_months'] as int?,
        updatedAt: DateTime.parse(map['updated_at'] as String),
        deleted: (map['deleted'] as int) == 1,
      );
}

// A receipt or invoice (a photo or PDF) attached to a fuel or service entry.
class Attachment {
  final String id;
  final String parentType; // 'fuel' or 'service'
  final String parentId; // id of the fuel or service entry
  final String fileName; // the original file name
  final String kind; // 'image' or 'pdf'
  final int originalSize; // bytes of the original file
  final DateTime updatedAt;
  final bool deleted;

  Attachment({
    String? id,
    required this.parentType,
    required this.parentId,
    required this.fileName,
    required this.kind,
    required this.originalSize,
    DateTime? updatedAt,
    this.deleted = false,
  })  : id = id ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, Object?> toMap() => {
        'id': id,
        'parent_type': parentType,
        'parent_id': parentId,
        'file_name': fileName,
        'kind': kind,
        'original_size': originalSize,
        'updated_at': updatedAt.toIso8601String(),
        'deleted': deleted ? 1 : 0,
      };

  factory Attachment.fromMap(Map<String, Object?> map) => Attachment(
        id: map['id'] as String,
        parentType: map['parent_type'] as String,
        parentId: map['parent_id'] as String,
        fileName: map['file_name'] as String,
        kind: map['kind'] as String,
        originalSize: (map['original_size'] as num).toInt(),
        updatedAt: DateTime.parse(map['updated_at'] as String),
        deleted: (map['deleted'] as int) == 1,
      );
}
