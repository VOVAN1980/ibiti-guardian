import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/utils/address_key.dart';

/// Simple SharedPreferences-backed address book.
/// Entries: [{label: "Alice", address: "0x..."}]
///
/// The saved list loads in the background when the book is first touched.
/// Every change waits for that load first: a change made before it finished
/// used to be overwritten by the old saved list a moment later (a recipient
/// saved right after the first send of a session silently disappeared).
class AddressBookService extends ChangeNotifier {
  static final AddressBookService instance = AddressBookService._internal();
  AddressBookService._internal() {
    _ready = _load();
  }

  /// A fresh, unshared book for tests (the app always uses [instance]).
  @visibleForTesting
  AddressBookService.forTest() : this._internal();

  static const _log = GuardianLogger('AddressBook');

  static const _key = 'address_book_v1';
  List<AddressEntry> _entries = [];
  late final Future<void> _ready;

  List<AddressEntry> get entries => List.unmodifiable(_entries);

  /// Completes once the saved list has been loaded.
  Future<void> get ready => _ready;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        final loaded = list
            .map((e) => AddressEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        // Older builds could save one address twice (a rename added a copy
        // in front of the old "Recent" entry). Keep the first, the one the
        // owner named, so delete and rename act on a single entry.
        final seen = <String>{};
        _entries = [
          for (final e in loaded)
            if (seen.add(AddressKey.of(e.address))) e,
        ];
        notifyListeners();
        if (_entries.length != loaded.length) await _save();
      }
    } catch (e) {
      _log.e('load error', e);
    }
  }

  Future<void> _saving = Future<void>.value();

  /// Writes run one after another, each with the list as it is when it runs.
  Future<void> _save() => _saving = _saving.then((_) => _write());

  Future<void> _write() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _key, jsonEncode(_entries.map((e) => e.toJson()).toList()));
    } catch (e) {
      _log.e('save error', e);
    }
  }

  int _indexOf(String address) => _entries
      .indexWhere((e) => AddressKey.same(e.address, address));

  /// Adds [address] under [label]. If the address is already in the book,
  /// it gets the new name instead of a second copy.
  Future<void> add(String label, String address) async {
    await _ready;
    final idx = _indexOf(address);
    if (idx >= 0) {
      _entries[idx] = AddressEntry(label: label, address: _entries[idx].address);
    } else {
      _entries.insert(0, AddressEntry(label: label, address: address));
    }
    notifyListeners();
    await _save();
  }

  /// Adds [address] only if it is not in the book yet, so a name the owner
  /// gave it is never replaced. Returns true when it was added.
  Future<bool> addIfMissing(String label, String address) async {
    await _ready;
    if (_indexOf(address) >= 0) return false;
    _entries.insert(0, AddressEntry(label: label, address: address));
    notifyListeners();
    await _save();
    return true;
  }

  Future<void> remove(String address) async {
    await _ready;
    _entries
        .removeWhere((e) => AddressKey.same(e.address, address));
    notifyListeners();
    await _save();
  }

  Future<void> update(String address, String newLabel) async {
    await _ready;
    final idx = _indexOf(address);
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
