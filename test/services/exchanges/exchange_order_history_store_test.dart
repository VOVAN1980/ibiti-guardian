import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_order_history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Exchange orders (the AI's and the user's own) are kept on the device and
/// shown in the common transaction history («Биржа»).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = ExchangeOrderHistoryStore.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store.resetForTest();
  });

  Future<ExchangeOrderRecord> buy({
    String orderId = 'o-1',
    bool byAi = true,
    DateTime? time,
    String status = ExchangeOrderRecord.statusFilled,
  }) =>
      store.record(
        exchange: 'MEXC',
        symbol: 'sol',
        quote: 'usdt',
        isBuy: true,
        amount: 20,
        price: 100,
        executedQty: 0.2,
        status: status,
        byAi: byAi,
        orderId: orderId,
        time: time,
      );

  test('records an order with every field', () async {
    final r = await buy();
    expect(r.exchange, 'mexc');
    expect(r.symbol, 'SOL');
    expect(r.quote, 'USDT');
    expect(r.side, 'buy');
    expect(r.isBuy, true);
    expect(r.amount, 20);
    expect(r.price, 100);
    expect(r.status, ExchangeOrderRecord.statusFilled);
    expect(r.source, ExchangeOrderRecord.sourceAi);
    expect(r.isAi, true);
    expect(r.orderId, 'o-1');
    expect(r.id, startsWith('cex:mexc:'));
    expect(r.coinQty, closeTo(0.2, 1e-9));
    expect(r.valueQuote, closeTo(20, 1e-9));
    expect(store.orders.single.id, r.id);
  });

  test('the user\'s own order is marked as the user\'s', () async {
    final r = await buy(byAi: false);
    expect(r.source, ExchangeOrderRecord.sourceUser);
    expect(r.isAi, false);
  });

  test('newest first; found by local id or by the exchange order id',
      () async {
    final older = await buy(
        orderId: 'a', time: DateTime.now().subtract(const Duration(hours: 2)));
    final newer = await buy(orderId: 'b');
    expect(store.orders.map((o) => o.id), [newer.id, older.id]);
    expect(store.byId(older.id)?.orderId, 'a');
    expect(store.byId('b')?.id, newer.id);
    expect(store.byId('missing'), isNull);
    expect(store.byId(''), isNull);
  });

  test('every order gets its own id, even with a repeated exchange id',
      () async {
    final a = await buy(orderId: 'same');
    final b = await buy(orderId: 'same');
    expect(a.id, isNot(b.id));
    expect(store.orders, hasLength(2));
  });

  test('an order without an exchange id still gets a unique id', () async {
    final a = await store.record(
      exchange: 'okx',
      symbol: 'SOL',
      quote: 'USDC',
      isBuy: false,
      amount: 2,
      price: 150,
      status: ExchangeOrderRecord.statusFailed,
      byAi: false,
      error: 'pair not allowed',
    );
    final b = await store.record(
      exchange: 'okx',
      symbol: 'SOL',
      quote: 'USDC',
      isBuy: false,
      amount: 2,
      price: 150,
      status: ExchangeOrderRecord.statusFailed,
      byAi: false,
    );
    expect(a.id, isNot(b.id));
    expect(a.isFailed, true);
    expect(a.error, 'pair not allowed');
    // A sell is sold coins: the value comes from the price.
    expect(a.coinQty, 2);
    expect(a.valueQuote, closeTo(300, 1e-9));
  });

  test('survives a restart (saved and read back)', () async {
    await buy(orderId: 'keep');
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('exchange_order_history_v1');
    expect(raw, isNotNull);
    expect((jsonDecode(raw!) as List).single['orderId'], 'keep');

    store.resetForTest(); // a new app run: memory is empty
    expect(store.orders, isEmpty);
    await store.ensureLoaded();
    expect(store.orders.single.orderId, 'keep');
    expect(store.orders.single.source, ExchangeOrderRecord.sourceAi);
  });

  test('a saved list is not overwritten by a new order', () async {
    SharedPreferences.setMockInitialValues({
      'exchange_order_history_v1': jsonEncode([
        {
          'id': 'cex:mexc:1-1',
          'exchange': 'mexc',
          'symbol': 'BTC',
          'quote': 'USDT',
          'side': 'sell',
          'amount': 0.001,
          'price': 60000,
          'status': 'filled',
          'time': DateTime.now()
              .subtract(const Duration(days: 1))
              .toIso8601String(),
          'source': 'user',
          'orderId': 'old',
        }
      ]),
    });
    store.resetForTest();
    await buy(orderId: 'new');
    expect(store.orders.map((o) => o.orderId), ['new', 'old']);
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('exchange_order_history_v1')!)
        as List;
    expect(saved.map((e) => e['orderId']), ['new', 'old']);
  });

  test('keeps at most maxEntries, dropping the oldest', () async {
    final start = DateTime(2026, 1, 1);
    for (var i = 0; i < ExchangeOrderHistoryStore.maxEntries + 5; i++) {
      await buy(orderId: 'o$i', time: start.add(Duration(minutes: i)));
    }
    expect(store.orders, hasLength(ExchangeOrderHistoryStore.maxEntries));
    expect(store.byId('o0'), isNull);
    expect(store.orders.first.orderId,
        'o${ExchangeOrderHistoryStore.maxEntries + 4}');
  });

  test('a broken saved entry is skipped, not fatal', () async {
    SharedPreferences.setMockInitialValues({
      'exchange_order_history_v1': jsonEncode([
        {'id': 'x'},
        {
          'id': 'cex:gateio:ok',
          'exchange': 'gateio',
          'symbol': 'SOL',
          'side': 'buy',
          'amount': 5,
          'price': 100,
          'status': 'placed',
          'time': DateTime.now().toIso8601String(),
          'source': 'ai',
        },
      ]),
    });
    store.resetForTest();
    await store.ensureLoaded();
    expect(store.orders.single.id, 'cex:gateio:ok');
    expect(store.orders.single.quote, 'USDT');
  });

  test('notifies listeners when an order is added', () async {
    var calls = 0;
    void listener() => calls++;
    store.addListener(listener);
    addTearDown(() => store.removeListener(listener));
    await buy();
    expect(calls, greaterThan(0));
  });
}
