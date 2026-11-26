import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'reminder_notifier.dart';
import 'settings.dart';
import 'sync_config.dart';
import 'sync_service.dart';

const String _taskName = 'vehicleLogSync';
const String _uniqueName = 'vehicle-log-periodic-sync';

// Runs in the background (a separate isolate), possibly with the app closed.
// The pragma line stops Android's build tools from removing it.
@pragma('vm:entry-point')
void backgroundCallback() {
  Workmanager().executeTask((task, inputData) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
      await settings.load(); // this isolate starts with default settings
      await syncService.runSync();
      await ReminderNotifier.check();
    } catch (e) {
      debugPrint('Background task error: $e');
    }
    // Always report success, so Android doesn't retry early when we simply
    // couldn't reach the server. The next scheduled run will try again.
    return true;
  });
}

class BackgroundSync {
  static bool _initialised = false;

  // Schedules or cancels the background job to match the saved settings.
  // Does nothing on desktop.
  static Future<void> apply() async {
    if (!Platform.isAndroid) return;

    try {
      if (!_initialised) {
        await Workmanager().initialize(backgroundCallback);
        _initialised = true;
      }

      final config = await SyncConfigStore.load();
      final syncOn = config.enabled && config.isComplete;
      final notifyOn = settings.notifications;

      // Replace any existing schedule so changed settings take effect.
      await Workmanager().cancelByUniqueName(_uniqueName);

      if (syncOn || notifyOn) {
        await Workmanager().registerPeriodicTask(
          _uniqueName,
          _taskName,
          frequency: const Duration(minutes: 15),
          // Syncing needs Wi-Fi; checking reminders alone needs nothing.
          constraints: Constraints(
            networkType:
                syncOn ? NetworkType.unmetered : NetworkType.notRequired,
          ),
        );
      }
    } catch (e) {
      debugPrint('Could not set up background tasks: $e');
    }
  }
}
