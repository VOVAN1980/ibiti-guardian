import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/wallet/address_book_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const friend = '0xA2BD166173925E5b8E640f091b0f3bEcBbBE15f8';
  const exchange = '0x195898373cc0c85f7fe7b325c3fe0e1fff701383';

  Future<List<dynamic>> saved() async {
    final raw =
        (await SharedPreferences.getInstance()).getString('address_book_v1');
    return jsonDecode(raw!) as List;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'address_book_v1': jsonEncode([
        {'label': 'Friend', 'address': friend},
      ]),
    });
  });

  test('a recipient saved before the book finished loading is kept', () async {
    // First touch of the book in this run is the save after a send.
    final book = AddressBookService.forTest();
    await book.addIfMissing('Recent 0x1958', exchange);

    expect(book.entries.map((e) => e.address), [exchange, friend]);
    expect((await saved()).length, 2);

    // The next app start sees both.
    final next = AddressBookService.forTest();
    await next.ready;
    expect(next.entries.map((e) => e.address), [exchange, friend]);
  });

  test('an auto-saved recipient never renames an entry the owner named',
      () async {
    final book = AddressBookService.forTest();
    final added = await book.addIfMissing('Recent 0xa2bd', friend.toLowerCase());

    expect(added, false);
    expect(book.entries.single.label, 'Friend');
  });

  test('adding an address that is already in the book renames it', () async {
    final book = AddressBookService.forTest();
    await book.add('Wallet 2', friend.toLowerCase());

    expect(book.entries.single.label, 'Wallet 2');
    expect(book.entries.single.address, friend);
    expect((await saved()).length, 1);
  });

  test('a copy of the same address saved by an older build is dropped',
      () async {
    SharedPreferences.setMockInitialValues({
      'address_book_v1': jsonEncode([
        {'label': 'MEXC', 'address': exchange},
        {'label': 'Recent 0x1958', 'address': exchange.toUpperCase()},
        {'label': 'Friend', 'address': friend},
      ]),
    });
    final book = AddressBookService.forTest();
    await book.ready;

    expect(book.entries.map((e) => e.label), ['MEXC', 'Friend']);
    await book.remove(friend);
    expect((await saved()).single['label'], 'MEXC');
  });

  test('rename and delete wait for the saved list too', () async {
    final book = AddressBookService.forTest();
    await book.update(friend, 'MetaMask');
    expect(book.entries.single.label, 'MetaMask');

    final other = AddressBookService.forTest();
    await other.remove(friend);
    expect(other.entries, isEmpty);
    expect(await saved(), isEmpty);
  });
}
