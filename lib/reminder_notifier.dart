import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database.dart';
import 'models.dart';
import 'reminders.dart';
import 'settings.dart';

const int _motSoonDays = 30; // warn this many days before the MOT runs out
const int _repeatDays = 7; // remind again after this long if still unresolved

// Works out what is due and shows Android notifications for it.
class ReminderNotifier {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'reminders',
      'Reminders',
      channelDescription: 'MOT and service reminders',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    ),
  );

  static Future<void> _init() async {
    if (_ready) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: android));
    _ready = true;
  }

  // Asks Android for permission to show notifications. True if allowed.
  static Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return false;
    await _init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? false;
  }

  // Shows a notification straight away, so you can see it works.
  static Future<void> showTest() async {
    if (!Platform.isAndroid) return;
    await _init();
    await _plugin.show(
      0,
      'Test notification',
      'Reminders will appear like this.',
      _details,
    );
  }

  // Looks at every vehicle and notifies about anything due. Safe to call
  // often: each item is only announced once per status per week.
  static Future<void> check() async {
    if (!Platform.isAndroid || !settings.notifications) return;

    // Quiet hours: nothing overnight. It will be picked up the next morning.
    final now = DateTime.now();
    if (now.hour < 8 || now.hour >= 21) return;

    try {
      await _init();
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      final today = DateTime.utc(now.year, now.month, now.day);
      final vehicles = await AppDatabase.loadVehicles();
      for (final vehicle in vehicles) {
        await _checkMot(prefs, vehicle, today);
        await _checkServices(prefs, vehicle);
      }
    } catch (e) {
      debugPrint('Reminder check failed: $e');
    }
  }

  static Future<void> _checkMot(
    SharedPreferences prefs,
    Vehicle vehicle,
    DateTime today,
  ) async {
    final key = 'mot-${vehicle.id}';
    final mot = vehicle.motDate;
    if (mot == null) {
      await prefs.remove(_prefKey(key));
      return;
    }

    final due = DateTime.utc(mot.year, mot.month, mot.day);
    final days = due.difference(today).inDays;

    if (days < 0) {
      await _notifyIfNeeded(
        prefs,
        key,
        ReminderStatus.overdue,
        'MOT expired: ${vehicle.name}',
        'The MOT ran out ${-days} days ago.',
      );
    } else if (days == 0) {
      await _notifyIfNeeded(
        prefs,
        key,
        ReminderStatus.overdue,
        'MOT due today: ${vehicle.name}',
        'The MOT runs out today.',
      );
    } else if (days <= _motSoonDays) {
      await _notifyIfNeeded(
        prefs,
        key,
        ReminderStatus.soon,
        'MOT due soon: ${vehicle.name}',
        'The MOT runs out in $days days.',
      );
    } else {
      await prefs.remove(_prefKey(key)); // all fine again
    }
  }

  static Future<void> _checkServices(
    SharedPreferences prefs,
    Vehicle vehicle,
  ) async {
    final reminders = await AppDatabase.loadReminders(vehicle.id);
    if (reminders.isEmpty) return;

    final services = await AppDatabase.loadServices(vehicle.id); // newest first
    final latest = await AppDatabase.latestOdometer(vehicle.id);
    final stored = vehicle.mileage;
    int? currentKm = latest;
    if (stored != null && (latest == null || stored > latest)) {
      currentKm = stored;
    }

    for (final reminder in reminders) {
      final key = 'service-${reminder.id}';

      // The most recent service of this type (matching ignores capitals).
      ServiceEntry? last;
      final wanted = reminder.serviceType.trim().toLowerCase();
      for (final service in services) {
        if (service.serviceType.trim().toLowerCase() == wanted) {
          last = service;
          break;
        }
      }

      final info = evaluateReminder(reminder, last, currentKm);
      if (info.status == ReminderStatus.soon ||
          info.status == ReminderStatus.overdue) {
        final word =
            info.status == ReminderStatus.overdue ? 'overdue' : 'due soon';
        await _notifyIfNeeded(
          prefs,
          key,
          info.status,
          '${reminder.serviceType} $word: ${vehicle.name}',
          info.summary,
        );
      } else {
        await prefs.remove(_prefKey(key)); // all fine again
      }
    }
  }

  static String _prefKey(String key) => 'notified_$key';

  // A number that identifies the notification, so repeats replace each other.
  static int _idFor(String key) {
    int id = 0;
    for (final unit in key.codeUnits) {
      id = (id * 31 + unit) & 0x7fffffff;
    }
    return id;
  }

  // Shows the notification unless this item was already announced with the
  // same status within the last week.
  static Future<void> _notifyIfNeeded(
    SharedPreferences prefs,
    String key,
    ReminderStatus status,
    String title,
    String body,
  ) async {
    final now = DateTime.now();
    final stored = prefs.getString(_prefKey(key));
    if (stored != null) {
      final parts = stored.split('|');
      final lastTime = parts.length > 1 ? DateTime.tryParse(parts[1]) : null;
      final recent =
          lastTime != null && now.difference(lastTime).inDays < _repeatDays;
      if (parts.first == status.name && recent) return;
    }

    await _plugin.show(_idFor(key), title, body, _details);
    await prefs.setString(
      _prefKey(key),
      '${status.name}|${now.toIso8601String()}',
    );
  }
}
