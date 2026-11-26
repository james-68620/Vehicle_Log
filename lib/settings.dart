import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const double _kmPerMile = 1.609344;
const double _litresPerImperialGallon = 4.54609;

// A currency the user can pick in Settings.
class CurrencyOption {
  final String name;
  final String symbol; // shown before amounts; empty means "no symbol"

  const CurrencyOption(this.name, this.symbol);
}

const List<CurrencyOption> currencyOptions = [
  CurrencyOption('Pound (£)', '£'),
  CurrencyOption('US dollar (\$)', '\$'),
  CurrencyOption('Euro (€)', '€'),
  CurrencyOption('Yen (¥)', '¥'),
  CurrencyOption('Rupee (₹)', '₹'),
  CurrencyOption('Krona / krone (kr)', 'kr'),
  CurrencyOption('Zloty (zł)', 'zł'),
  CurrencyOption('Swiss franc (CHF)', 'CHF'),
  CurrencyOption('No symbol', ''),
];

// Holds the user's settings. Anything that listens to it is told when it
// changes, so the screens can redraw themselves.
class AppSettings extends ChangeNotifier {
  bool _imperial = false;
  bool get imperial => _imperial;

  String _currency = '£';
  String get currency => _currency;

  bool _notifications = false;
  bool get notifications => _notifications;

  // Reads the saved settings from disk (called once when the app starts).
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _imperial = prefs.getBool('imperial') ?? false;
    _currency = prefs.getString('currency') ?? '£';
    _notifications = prefs.getBool('notifications') ?? false;
    notifyListeners();
  }

  Future<void> setImperial(bool value) async {
    _imperial = value;
    notifyListeners(); // redraw straight away
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('imperial', value);
  }

  Future<void> setNotifications(bool value) async {
    _notifications = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications', value);
  }

  Future<void> setCurrency(String symbol) async {
    _currency = symbol;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('currency', symbol);
  }

  // e.g. "£12.50", "kr 12.50" or "12.50" (letters get a space after them)
  String formatMoney(double amount, {int decimals = 2}) {
    final needsSpace = RegExp(r'[A-Za-z]').hasMatch(_currency);
    return '$_currency${needsSpace ? ' ' : ''}${amount.toStringAsFixed(decimals)}';
  }

  // For form labels, e.g. " (£)" or an empty string.
  String get currencyLabel => _currency.isEmpty ? '' : ' ($_currency)';

  String get distanceUnit => _imperial ? 'mi' : 'km';
  String get consumptionUnit => _imperial ? 'MPG' : 'L/100km';

  // Stored kilometres -> whole number in the chosen unit.
  int displayDistance(int km) =>
      _imperial ? (km / _kmPerMile).round() : km;

  // Whole number typed in the chosen unit -> kilometres for storage.
  int distanceFromDisplay(int value) =>
      _imperial ? (value * _kmPerMile).round() : value;

  // e.g. "12345 km" or "7670 mi"
  String formatDistance(int km) => '${displayDistance(km)} $distanceUnit';

  // Fuel consumption in the chosen unit, from litres used over km travelled.
  double consumption(double litres, int km) {
    if (_imperial) {
      final miles = km / _kmPerMile;
      final gallons = litres / _litresPerImperialGallon;
      return miles / gallons;
    }
    return litres / km * 100;
  }
}

// One shared copy that every screen can import and use.
final AppSettings settings = AppSettings();
