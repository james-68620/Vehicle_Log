import 'dart:async';

import 'sync_service.dart';

// Asks for a sync shortly after the data changes. Several changes in quick
// succession only cause one sync.
class SyncOnChange {
  static Timer? _timer;

  static void request() {
    _timer?.cancel(); // restart the countdown if another change comes in
    _timer = Timer(const Duration(seconds: 3), _run);
  }

  static Future<void> _run() async {
    // If a sync is already running, try again shortly instead of overlapping.
    if (syncService.syncing) {
      _timer = Timer(const Duration(seconds: 5), _run);
      return;
    }
    await syncService.runSync();
  }
}
