import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One exchange (CEX) market order the app sent: by the AI or by the user.
@immutable
class ExchangeOrderRecord {
  const ExchangeOrderRecord({
    required this.id,
    required this.exchange,
    required this.symbol,
    required this.quote,
    required this.side,
    required this.amount,
    required this.price,
    required this.status,
    required this.time,
    required this.source,
    this.executedQty = 0,
    this.orderId,
    this.error,
  });

  /// Local id (the notification «ИИ выполнил» opens it).
  final String id;

  /// 'mexc' | 'binance' | 'gateio' | 'okx'.
  final String exchange;

  /// The coin bought or sold ('SOL').
  final String symbol;

  /// The quote asset ('USDT', 'USDC', 'EUR').
  final String quote;

  /// 'buy' | 'sell'.
  final String side;

  /// As placed: a buy spends [amount] of [quote]; a sell sells [amount]
  /// of [symbol].
  final double amount;

  /// Executed price, or the reference price when the exchange gave none.
  final double price;

  /// [statusFilled] | [statusPlaced] | [statusFailed].
  final String status;

  final DateTime time;

  /// [sourceAi] | [sourceUser].
  final String source;

  /// Coins filled (0 = unknown).
  final double executedQty;

  /// The exchange's own order id.
  final String? orderId;

  /// Why the exchange refused it ([statusFailed]).
  final String? error;

  static const String statusFilled = 'filled';
  static const String statusPlaced = 'placed';
  static const String statusFailed = 'failed';

  static const String sourceAi = 'ai';
  static const String sourceUser = 'user';

  bool get isBuy => side == 'buy';
  bool get isAi => source == sourceAi;
  bool get isFailed => status == statusFailed;

  /// Approximate value in the quote asset (≈ USD for stablecoins).
  double get valueQuote {
    if (isBuy) return amount;
    final qty = executedQty > 0 ? executedQty : amount;
    return qty * price;
  }

  /// Coins bought or sold (approximate when the exchange gave no fill).
  double get coinQty {
    if (executedQty > 0) return executedQty;
    if (!isBuy) return amount;
    return price > 0 ? amount / price : 0;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'exchange': exchange,
        'symbol': symbol,
        'quote': quote,
        'side': side,
        'amount': amount,
        'price': price,
        'status': status,
        'time': time.toIso8601String(),
        'source': source,
        if (executedQty > 0) 'executedQty': executedQty,
        if (orderId != null) 'orderId': orderId,
        if (error != null) 'error': error,
      };

  static ExchangeOrderRecord? fromJson(Map<String, dynamic> m) {
    final id = m['id']?.toString();
    final exchange = m['exchange']?.toString();
    final symbol = m['symbol']?.toString();
    final time = DateTime.tryParse(m['time']?.toString() ?? '');
    if (id == null || exchange == null || symbol == null || time == null) {
      return null;
    }
    double num0(Object? v) => (v is num) ? v.toDouble() : 0.0;
    final side = m['side']?.toString() == 'sell' ? 'sell' : 'buy';
    final source =
        m['source']?.toString() == sourceAi ? sourceAi : sourceUser;
    return ExchangeOrderRecord(
      id: id,
      exchange: exchange,
      symbol: symbol,
      quote: m['quote']?.toString() ?? 'USDT',
      side: side,
      amount: num0(m['amount']),
      price: num0(m['price']),
      status: m['status']?.toString() ?? statusPlaced,
      time: time,
      source: source,
      executedQty: num0(m['executedQty']),
      orderId: m['orderId']?.toString(),
      error: m['error']?.toString(),
    );
  }
}

/// Every exchange order the app sent (the AI's and the user's own), kept on
/// the device and shown in the common transaction history with the
/// «Биржа» / "Exchange" label. Newest first, at most [maxEntries].
class ExchangeOrderHistoryStore extends ChangeNotifier {
  ExchangeOrderHistoryStore._();
  static final ExchangeOrderHistoryStore instance =
      ExchangeOrderHistoryStore._();

  static const _log = GuardianLogger('ExchangeOrderHistory');
  static const _prefsKey = 'exchange_order_history_v1';
  static const int maxEntries = 300;

  final List<ExchangeOrderRecord> _orders = [];
  Future<void>? _loading;

  /// Saved entries were read: only then is it safe to write the list back
  /// (a failed read must never overwrite the saved history).
  bool _loadedOk = false;
  int _seq = 0;

  /// Newest first.
  List<ExchangeOrderRecord> get orders => List.unmodifiable(_orders);

  /// The entry with this local id or exchange order id.
  ExchangeOrderRecord? byId(String id) {
    final key = id.trim();
    if (key.isEmpty) return null;
    for (final o in _orders) {
      if (o.id == key) return o;
    }
    for (final o in _orders) {
      if (o.orderId != null && o.orderId == key) return o;
    }
    return null;
  }

  /// Reads the saved history once. A failed read is retried next time.
  Future<void> ensureLoaded() {
    if (_loadedOk) return Future<void>.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final saved = (jsonDecode(raw) as List)
            .whereType<Map>()
            .map((e) => ExchangeOrderRecord.fromJson(
                Map<String, dynamic>.from(e)))
            .whereType<ExchangeOrderRecord>()
            .where((e) => !_orders.any((o) => o.id == e.id))
            .toList();
        _orders.addAll(saved);
        _sortAndTrim();
      }
      _loadedOk = true;
      notifyListeners();
    } catch (e) {
      _log.w('could not read the exchange order history', e);
    }
  }

  /// Adds an order the app just sent. Never throws: a storage problem must
  /// not affect the order itself.
  Future<ExchangeOrderRecord> record({
    required String exchange,
    required String symbol,
    required String quote,
    required bool isBuy,
    required double amount,
    required double price,
    required String status,
    required bool byAi,
    double executedQty = 0,
    String? orderId,
    String? error,
    DateTime? time,
  }) async {
    final when = time ?? DateTime.now();
    final ex = exchange.trim().toLowerCase();
    final cleanOrderId =
        (orderId == null || orderId.trim().isEmpty) ? null : orderId.trim();
    final entry = ExchangeOrderRecord(
      id: _newId(ex, when),
      exchange: ex,
      symbol: symbol.trim().toUpperCase(),
      quote: quote.trim().isEmpty ? 'USDT' : quote.trim().toUpperCase(),
      side: isBuy ? 'buy' : 'sell',
      amount: amount,
      price: price,
      status: status,
      time: when,
      source: byAi
          ? ExchangeOrderRecord.sourceAi
          : ExchangeOrderRecord.sourceUser,
      executedQty: executedQty,
      orderId: cleanOrderId,
      error: error,
    );
    try {
      await ensureLoaded();
    } catch (_) {}
    _orders.add(entry);
    _sortAndTrim();
    notifyListeners();
    await _save();
    return entry;
  }

  /// Always unique, also when an exchange reuses or omits its order id
  /// ([byId] still finds an entry by the exchange order id).
  String _newId(String exchange, DateTime when) {
    _seq++;
    return 'cex:$exchange:${when.microsecondsSinceEpoch}-$_seq';
  }

  void _sortAndTrim() {
    _orders.sort((a, b) => b.time.compareTo(a.time));
    if (_orders.length > maxEntries) {
      _orders.removeRange(maxEntries, _orders.length);
    }
  }

  Future<void> _saving = Future<void>.value();

  /// Writes run one after another, each with the list as it is then.
  Future<void> _save() => _saving = _saving.then((_) => _write());

  Future<void> _write() async {
    if (!_loadedOk) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefsKey, jsonEncode(_orders.map((o) => o.toJson()).toList()));
    } catch (e) {
      _log.w('could not save the exchange order history', e);
    }
  }

  /// Forgets everything in memory (the saved copy is read again on the next
  /// [ensureLoaded]).
  @visibleForTesting
  void resetForTest() {
    _orders.clear();
    _loading = null;
    _loadedOk = false;
    _seq = 0;
    _saving = Future<void>.value();
  }
}
