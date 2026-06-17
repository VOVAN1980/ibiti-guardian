import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Simple SharedPreferences-backed address book.
/// Entries: [{label: "Alice", address: "0x..."}]
class AddressBookService extends ChangeNotifier {
  static final AddressBookService instance = AddressBookService._internal();
  AddressBookService._internal() {
    _load();
  }

  static const _log = GuardianLogger('AddressBook');

  static const _key = 'address_book_v1';
  List<AddressEntry> _entries = [];

  List<AddressEntry> get entries => List.unmodifiable(_entries);

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        _entries = list
            .map((e) => AddressEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (e) {
      _log.e('load error', e);
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _key, jsonEncode(_entries.map((e) => e.toJson()).toList()));
    } catch (e) {
      _log.e('save error', e);
    }
  }

  Future<void> add(String label, String address) async {
    _entries.insert(0, AddressEntry(label: label, address: address));
    notifyListeners();
    await _save();
  }

  Future<void> remove(String address) async {
    _entries
        .removeWhere((e) => e.address.toLowerCase() == address.toLowerCase());
    notifyListeners();
    await _save();
  }

  Future<void> update(String address, String newLabel) async {
    final idx = _entries
        .indexWhere((e) => e.address.toLowerCase() == address.toLowerCase());
    if (idx >= 0) {
      _entries[idx] = AddressEntry(label: newLabel, address: address);
      notifyListeners();
      await _save();
    }
  }
}

class AddressEntry {
  final String label;
  final String address;
  const AddressEntry({required this.label, required this.address});

  factory AddressEntry.fromJson(Map<String, dynamic> json) =>
      AddressEntry(label: json['label'], address: json['address']);

  Map<String, dynamic> toJson() => {'label': label, 'address': address};
}
