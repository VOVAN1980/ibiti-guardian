import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/services/exchanges/okx_exchange_service.dart';
import 'package:ibiti_guardian/services/market/market_memory_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

class ExchangeOrderResult {
  final bool isSuccess;
  final String? orderId;
  final double executedQty;
  final double executedPrice;
  final String? errorMessage;

  ExchangeOrderResult({
    required this.isSuccess,
    this.orderId,
    this.executedQty = 0.0,
    this.executedPrice = 0.0,
    this.errorMessage,
  });
}

abstract class ExchangeExecutionAdapter {
  Future<ExchangeOrderResult> executeMarketOrder({
    required String symbol,
    required bool isBuy,
    required double amount,
    required double price,
  });

  Future<Map<String, dynamic>?> getSymbolRules(String symbol);
  Future<double> fetchAssetBalance(String asset);
}

class ExchangeOrderService {
  ExchangeOrderService._();
  static final ExchangeOrderService instance = ExchangeOrderService._();

  static const _log = GuardianLogger('ExchangeOrderService');

  final Map<String, ExchangeExecutionAdapter> _adapters = {
    'mexc': MexcSpotExecutionAdapter(),
    'okx': OkxSpotExecutionAdapter(),
    'binance': BinanceSpotExecutionAdapter(),
    'gateio': GateioSpotExecutionAdapter(),
  };

  ExchangeExecutionAdapter? adapterFor(String exchangeId) => _adapters[exchangeId.toLowerCase()];

  void setAdapterForTest(String exchangeId, ExchangeExecutionAdapter adapter) {
    _adapters[exchangeId.toLowerCase()] = adapter;
  }

  void resetAdaptersForTest() {
    _adapters['mexc'] = MexcSpotExecutionAdapter();
    _adapters['okx'] = OkxSpotExecutionAdapter();
    _adapters['binance'] = BinanceSpotExecutionAdapter();
    _adapters['gateio'] = GateioSpotExecutionAdapter();
  }

  /// Places a spot market order on a connected CEX
  Future<ExchangeOrderResult> placeMarketOrder({
    required String exchangeId,
    required String symbol,
    required bool isBuy,
    required double amount,
    required double price,
    String source = 'ui',
  }) async {
    final id = exchangeId.toLowerCase();
    final adapter = _adapters[id];

    final mode = AiControlService.instance.settings.mode;
    final modeStr = mode == AiMode.manual
        ? 'manual'
        : mode == AiMode.guarded
            ? 'guarded'
            : 'fullAutonomy';

    if (mode == AiMode.manual) {
      const msg = 'Blocked: JARVIS is in Manual Mode.';
      await MarketMemoryService.instance.record(
        action: isBuy ? 'buy' : 'sell',
        symbol: symbol,
        source: source,
        aiMode: modeStr,
        result: 'blocked',
        amount: amount,
        priceThen: price,
        reason: msg,
        rawInput: 'CEX spot order on $exchangeId',
      );
      return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
    }

    if (adapter == null) {
      final msg = 'Unsupported or unimplemented exchange: $exchangeId';
      _log.e(msg);
      return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
    }

    try {
      // 1. Check if connected
      final isConnected = await ExchangeAccountStore.instance.isConnected(id);
      if (!isConnected) {
        final msg = 'Exchange $exchangeId is not connected.';
        return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
      }

      // 1B. Check if active in Policy
      final settings = AiControlService.instance.settings;
      final displayName = id == 'gateio' ? 'Gate.io' : (id == 'mexc' ? 'MEXC' : (id == 'binance' ? 'Binance' : 'OKX'));
      if (!settings.activeSources.contains(id)) {
        final msg = '$displayName Spot выключен в Policy. Включите $displayName Spot как источник торговли.';
        return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
      }

      String quoteAsset = 'USDT';

      // 1BB. Check if OKX pair is available in the region
      if (id == 'okx') {
        final base = symbol.replaceAll('USDT', '').replaceAll('USDC', '').replaceAll('EUR', '').replaceAll('-', '').replaceAll('/', '').toUpperCase();
        final region = await ExchangeAccountStore.instance.getOkxRegion() ?? 'global';
        final bestPair = await OkxExchangeService.instance.findBestPair(base, region);
        if (bestPair == null) {
          final msg = '$displayName Spot: пара $symbol недоступна для торговли в вашем регионе.';
          return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
        }
        quoteAsset = bestPair.split('-')[1];
      }

      // 1C. Check if balance is at least minTradeBalance in quote asset (only for BUY)
      if (isBuy) {
        final balance = await adapter.fetchAssetBalance(quoteAsset);
        final minTradeBal = settings.minTradeBalance;
        if (balance < minTradeBal) {
          final msg = '$displayName Spot баланс меньше ${minTradeBal.toStringAsFixed(0)} $quoteAsset. Торговля недоступна.';
          return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
        }
      }

      // 2. Normalize Symbol (e.g., VIM/USDT -> VIMUSDT)
      final normSymbol = normalizeSpotSymbol(symbol, quote: quoteAsset);

      // 3. Policy Limit Gate Check (Kill Switch, Daily Limit, Per-Tx Limit)
      if (!settings.isActive) {
        const msg = 'Blocked by AI Policy: JARVIS trading is disabled (Kill Switch active or permissions expired).';
        await MarketMemoryService.instance.record(
          action: isBuy ? 'buy' : 'sell',
          symbol: symbol,
          source: source,
          aiMode: modeStr,
          result: 'blocked',
          amount: amount,
          priceThen: price,
          reason: msg,
          rawInput: 'CEX spot order on $exchangeId',
        );
        return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
      }

      final txValueUsdt = isBuy ? amount : amount * price;
      final delegation = DelegationController.instance;

      if (isBuy) {
        if (!delegation.canSpend(txValueUsdt)) {
          final msg = 'Blocked by AI Policy: Order value (\$${txValueUsdt.toStringAsFixed(2)}) exceeds remaining daily budget. ${delegation.usageSummary()}';
          await MarketMemoryService.instance.record(
            action: 'buy',
            symbol: symbol,
            source: source,
            aiMode: modeStr,
            result: 'blocked',
            amount: amount,
            priceThen: price,
            reason: msg,
            rawInput: 'CEX spot order on $exchangeId',
          );
          return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
        }

      }

      // 4. Check Symbol Rules & Existence
      final rules = await adapter.getSymbolRules(normSymbol);
      if (rules == null) {
        final msg = 'Symbol $normSymbol does not exist on $exchangeId Spot market.';
        await MarketMemoryService.instance.record(
          action: isBuy ? 'buy' : 'sell',
          symbol: symbol,
          source: source,
          aiMode: modeStr,
          result: 'failed',
          amount: amount,
          priceThen: price,
          reason: msg,
          rawInput: 'CEX spot order on $exchangeId',
        );
        return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
      }

      final double minQty = rules['minQty'] ?? 0.0;
      final double minNotional = rules['minNotional'] ?? 0.0;
      final String baseAsset = rules['baseAsset'] ?? '';
      quoteAsset = rules['quoteAsset'] ?? 'USDT';

      // 5. Pre-trade Validation (Balance & Limits)
      if (isBuy) {
        // Amount is USDT value we want to spend
        final balance = await adapter.fetchAssetBalance(quoteAsset);
        if (balance < amount) {
          final msg = 'Insufficient $quoteAsset balance. Available: $balance, Required: $amount';
          await MarketMemoryService.instance.record(
            action: 'buy',
            symbol: symbol,
            source: source,
            aiMode: modeStr,
            result: 'failed',
            amount: amount,
            priceThen: price,
            reason: msg,
            rawInput: 'CEX spot order on $exchangeId',
          );
          return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
        }

        if (amount < minNotional) {
          final msg = 'Order value (\$${amount.toStringAsFixed(2)}) is below the minimum required (\$${minNotional.toStringAsFixed(2)})';
          await MarketMemoryService.instance.record(
            action: 'buy',
            symbol: symbol,
            source: source,
            aiMode: modeStr,
            result: 'blocked',
            amount: amount,
            priceThen: price,
            reason: msg,
            rawInput: 'CEX spot order on $exchangeId',
          );
          return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
        }
      } else {
        // Amount is token quantity we want to sell
        final balance = await adapter.fetchAssetBalance(baseAsset);
        if (balance < amount) {
          final msg = 'Insufficient $baseAsset balance. Available: $balance, Required: $amount';
          await MarketMemoryService.instance.record(
            action: 'sell',
            symbol: symbol,
            source: source,
            aiMode: modeStr,
            result: 'failed',
            amount: amount,
            priceThen: price,
            reason: msg,
            rawInput: 'CEX spot order on $exchangeId',
          );
          return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
        }

        if (amount < minQty) {
          final msg = 'Order quantity ($amount) is below the minimum required ($minQty)';
          await MarketMemoryService.instance.record(
            action: 'sell',
            symbol: symbol,
            source: source,
            aiMode: modeStr,
            result: 'blocked',
            amount: amount,
            priceThen: price,
            reason: msg,
            rawInput: 'CEX spot order on $exchangeId',
          );
          return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
        }

        final notionalValue = amount * price;
        if (notionalValue < minNotional) {
          final msg = 'Order value (\$${notionalValue.toStringAsFixed(2)}) is below the minimum required (\$${minNotional.toStringAsFixed(2)})';
          await MarketMemoryService.instance.record(
            action: 'sell',
            symbol: symbol,
            source: source,
            aiMode: modeStr,
            result: 'blocked',
            amount: amount,
            priceThen: price,
            reason: msg,
            rawInput: 'CEX spot order on $exchangeId',
          );
          return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
        }
      }

      // 6. Execute Market Order
      final result = await adapter.executeMarketOrder(
        symbol: normSymbol,
        isBuy: isBuy,
        amount: amount,
        price: price,
      );

      // If successful, commit usage to delegation controller (only for BUY)
      if (result.isSuccess && isBuy) {
        delegation.commitUsage(txValueUsdt);
      }

      // 7. Record result in Market Memory
      await MarketMemoryService.instance.record(
        action: isBuy ? 'buy' : 'sell',
        symbol: symbol,
        source: source,
        aiMode: modeStr,
        result: result.isSuccess ? 'confirmed' : 'failed',
        amount: amount,
        priceThen: price,
        reason: result.isSuccess ? null : result.errorMessage,
        rawInput: 'CEX spot order on $exchangeId',
      );

      return result;
    } catch (e) {
      final msg = 'Execution error: $e';
      _log.e(msg);
      return ExchangeOrderResult(isSuccess: false, errorMessage: msg);
    }
  }
}

class MexcSpotExecutionAdapter implements ExchangeExecutionAdapter {
  static const _baseUrl = 'https://api.mexc.com';

  Future<Map<String, String>> _getAuthHeaders(String apiKey) async {
    return {
      'X-MEXC-APIKEY': apiKey,
      'Content-Type': 'application/json',
    };
  }

  String _hmacSha256(String secret, String input) {
    final keyBytes = utf8.encode(secret);
    final inputBytes = utf8.encode(input);
    final hmac = Hmac(sha256, keyBytes);
    return hmac.convert(inputBytes).toString();
  }

  @override
  Future<ExchangeOrderResult> executeMarketOrder({
    required String symbol,
    required bool isBuy,
    required double amount,
    required double price,
  }) async {
    try {
      final creds = await ExchangeAccountStore.instance.getCredentials('mexc');
      if (creds == null) {
        return ExchangeOrderResult(isSuccess: false, errorMessage: 'API keys not configured');
      }

      final apiKey = creds['apiKey']!;
      final secret = creds['apiSecret']!;

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      
      // Fetch symbol rules to get stepSize
      final normSymbol = normalizeSpotSymbol(symbol);
      final rules = await getSymbolRules(normSymbol);
      final double stepSize = rules?['stepSize'] ?? 0.0;

      final Map<String, String> params = {
        'symbol': normSymbol,
        'side': isBuy ? 'BUY' : 'SELL',
        'type': 'MARKET',
        'timestamp': timestamp.toString(),
      };

      if (isBuy) {
        // For market buy, we spend USDT (quoteOrderQty)
        params['quoteOrderQty'] = amount.toStringAsFixed(2);
      } else {
        // For market sell, we sell token quantity
        params['quantity'] = _formatQuantity(amount, stepSize);
      }

      // Generate query string and signature
      final queryString = Uri(queryParameters: params).query;
      final signature = _hmacSha256(secret, queryString);
      final url = '$_baseUrl/api/v3/order?$queryString&signature=$signature';

      final response = await http.post(
        Uri.parse(url),
        headers: await _getAuthHeaders(apiKey),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        final orderId = data['orderId']?.toString();
        final execQty = double.tryParse(data['executedQty']?.toString() ?? '') ?? 0.0;
        final cumQuote = double.tryParse(data['cummulativeQuoteQty']?.toString() ?? '') ?? 0.0;
        final execPrice = execQty > 0 ? cumQuote / execQty : price;

        return ExchangeOrderResult(
          isSuccess: true,
          orderId: orderId,
          executedQty: execQty,
          executedPrice: execPrice,
        );
      } else {
        final code = data['code'];
        final errorMsg = data['msg']?.toString() ?? 'API error: ${response.statusCode}';
        
        final errLower = errorMsg.toLowerCase();
        if (errLower.contains('pair not allowed') || 
            errLower.contains('permission') || 
            errLower.contains('api-key') || 
            errLower.contains('ip') ||
            code == -2015) {
          final customMsg = 'Эта торговая пара не разрешена в настройках MEXC API. Откройте MEXC → API Key → Trading Pairs → добавьте $normSymbol.';
          return ExchangeOrderResult(isSuccess: false, errorMessage: customMsg);
        }
        
        return ExchangeOrderResult(isSuccess: false, errorMessage: errorMsg);
      }
    } catch (e) {
      return ExchangeOrderResult(isSuccess: false, errorMessage: 'Network or parse error: $e');
    }
  }

  @override
  Future<double> fetchAssetBalance(String asset) async {
    try {
      final creds = await ExchangeAccountStore.instance.getCredentials('mexc');
      if (creds == null) return 0.0;

      final apiKey = creds['apiKey']!;
      final secret = creds['apiSecret']!;

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final queryString = 'timestamp=$timestamp';
      final signature = _hmacSha256(secret, queryString);

      final url = '$_baseUrl/api/v3/account?timestamp=$timestamp&signature=$signature';
      final response = await http.get(
        Uri.parse(url),
        headers: await _getAuthHeaders(apiKey),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final balances = data['balances'] as List?;
        if (balances != null) {
          final target = asset.toUpperCase();
          for (final bal in balances) {
            if (bal['asset'] == target) {
              return double.tryParse(bal['free'].toString()) ?? 0.0;
            }
          }
        }
      }
    } catch (_) {}
    return 0.0;
  }

  @override
  Future<Map<String, dynamic>?> getSymbolRules(String symbol) async {
    try {
      final normSymbol = normalizeSpotSymbol(symbol);
      final url = '$_baseUrl/api/v3/exchangeInfo?symbol=$normSymbol';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      final symbols = data['symbols'] as List?;
      if (symbols == null || symbols.isEmpty) return null;

      final symbolInfo = symbols[0];
      final status = symbolInfo['status']?.toString().toUpperCase();
      if (status != 'TRADING' && status != 'ENABLED') {
        // MEXC status could be TRADING
      }

      double minQty = 0.0;
      double stepSize = 0.0;
      double minNotional = 5.0; // Default fallback for CEX Spot

      final filters = symbolInfo['filters'] as List?;
      if (filters != null) {
        for (final f in filters) {
          final type = f['filterType']?.toString().toUpperCase();
          if (type == 'LOT_SIZE') {
            minQty = double.tryParse(f['minQty']?.toString() ?? '') ?? 0.0;
            stepSize = double.tryParse(f['stepSize']?.toString() ?? '') ?? 0.0;
          } else if (type == 'MIN_NOTIONAL') {
            minNotional = double.tryParse(f['minNotional']?.toString() ?? '') ?? 5.0;
          }
        }
      }

      return {
        'symbol': symbolInfo['symbol'],
        'baseAsset': symbolInfo['baseAsset'],
        'quoteAsset': symbolInfo['quoteAsset'],
        'minQty': minQty,
        'stepSize': stepSize,
        'minNotional': minNotional,
      };
    } catch (_) {
      return null;
    }
  }

  String _formatQuantity(double value, double stepSize) {
    if (stepSize <= 0) return value.toString();
    final double factor = 1 / stepSize;
    final rounded = (value * factor).floorToDouble() / factor;
    
    final stepStr = stepSize.toString();
    int decimals = 0;
    if (stepStr.contains('.')) {
      decimals = stepStr.split('.')[1].length;
    }
    return rounded.toStringAsFixed(decimals);
  }
}

String normalizeSpotSymbol(String symbol, {String quote = 'USDT'}) {
  final clean = symbol.replaceAll('/', '').toUpperCase();
  if (clean.endsWith(quote)) {
    return clean;
  }
  return '$clean$quote';
}

class OkxSpotExecutionAdapter implements ExchangeExecutionAdapter {
  static const _log = GuardianLogger('OkxExecutionAdapter');

  Future<String> _getBaseUrl() async {
    final region = await ExchangeAccountStore.instance.getOkxRegion();
    return region == 'eea' ? 'https://eea.okx.com' : 'https://www.okx.com';
  }

  String _hmacSha256Base64(String secret, String input) {
    final keyBytes = utf8.encode(secret);
    final inputBytes = utf8.encode(input);
    final hmac = Hmac(sha256, keyBytes);
    return base64.encode(hmac.convert(inputBytes).bytes);
  }

  @override
  Future<ExchangeOrderResult> executeMarketOrder({
    required String symbol,
    required bool isBuy,
    required double amount,
    required double price,
  }) async {
    try {
      final creds = await ExchangeAccountStore.instance.getCredentials('okx');
      if (creds == null) {
        return ExchangeOrderResult(isSuccess: false, errorMessage: 'API keys not configured');
      }

      final apiKey = creds['apiKey']!;
      final secret = creds['apiSecret']!;
      final passphrase = creds['passphrase'] ?? '';

      final normSymbol = await _toOkxSymbol(symbol); // e.g. BTC-USDT
      final baseUrl = await _getBaseUrl();

      final bodyMap = {
        'instId': normSymbol,
        'tdMode': 'cash',
        'side': isBuy ? 'buy' : 'sell',
        'ordType': 'market',
        'sz': isBuy ? amount.toStringAsFixed(2) : amount.toString(),
      };
      
      final bodyStr = jsonEncode(bodyMap);

      final timestamp = getOkxIsoTimestamp();
      const method = 'POST';
      const requestPath = '/api/v5/trade/order';

      final prehash = '$timestamp$method$requestPath$bodyStr';
      final signature = _hmacSha256Base64(secret, prehash);

      final response = await http.post(
        Uri.parse('$baseUrl$requestPath'),
        headers: {
          'OK-ACCESS-KEY': apiKey,
          'OK-ACCESS-SIGN': signature,
          'OK-ACCESS-TIMESTAMP': timestamp,
          'OK-ACCESS-PASSPHRASE': passphrase,
          'Content-Type': 'application/json',
          'accept': 'application/json',
        },
        body: bodyStr,
      );

      final data = jsonDecode(response.body);
      if (response.statusCode == 200) {
        final code = data['code']?.toString();
        if (code == '0') {
          final orderList = data['data'] as List?;
          if (orderList != null && orderList.isNotEmpty) {
            final ordId = orderList[0]['ordId']?.toString();
            return ExchangeOrderResult(
              isSuccess: true,
              orderId: ordId,
              executedQty: isBuy ? amount / price : amount,
              executedPrice: price,
            );
          }
        }
        final msg = data['msg']?.toString() ?? 'Error code $code';
        return ExchangeOrderResult(isSuccess: false, errorMessage: 'OKX error: $msg');
      } else {
        final err = data['msg']?.toString() ?? 'HTTP ${response.statusCode}';
        return ExchangeOrderResult(isSuccess: false, errorMessage: err);
      }
    } catch (e) {
      return ExchangeOrderResult(isSuccess: false, errorMessage: 'Execution error: $e');
    }
  }

  @override
  Future<double> fetchAssetBalance(String asset) async {
    try {
      final creds = await ExchangeAccountStore.instance.getCredentials('okx');
      if (creds == null) return 0.0;

      final apiKey = creds['apiKey']!;
      final secret = creds['apiSecret']!;
      final passphrase = creds['passphrase'] ?? '';
      
      final baseUrl = await _getBaseUrl();
      final targetAsset = asset.toUpperCase();

      final requestPath = '/api/v5/account/balance?ccy=$targetAsset';
      final timestamp = getOkxIsoTimestamp();
      const method = 'GET';
      const body = '';

      final prehash = '$timestamp$method$requestPath$body';
      final signature = _hmacSha256Base64(secret, prehash);

      final response = await http.get(
        Uri.parse('$baseUrl$requestPath'),
        headers: {
          'OK-ACCESS-KEY': apiKey,
          'OK-ACCESS-SIGN': signature,
          'OK-ACCESS-TIMESTAMP': timestamp,
          'OK-ACCESS-PASSPHRASE': passphrase,
          'accept': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['code'] == '0') {
          final dataList = data['data'] as List?;
          if (dataList != null && dataList.isNotEmpty) {
            final details = dataList[0]['details'] as List?;
            if (details != null) {
              for (final detail in details) {
                if (detail['ccy'] == targetAsset) {
                  return double.tryParse(detail['availBal']?.toString() ?? '') ?? 0.0;
                }
              }
            }
          }
        }
      }
    } catch (_) {}
    return 0.0;
  }

  @override
  Future<Map<String, dynamic>?> getSymbolRules(String symbol) async {
    try {
      final normSymbol = await _toOkxSymbol(symbol);
      final baseUrl = await _getBaseUrl();
      
      final url = '$baseUrl/api/v5/public/instruments?instType=SPOT&instId=$normSymbol';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      if (data['code'] != '0') return null;

      final dataList = data['data'] as List?;
      if (dataList == null || dataList.isEmpty) return null;

      final info = dataList[0];
      final minSz = double.tryParse(info['minSz']?.toString() ?? '') ?? 0.0;
      final lotSz = double.tryParse(info['lotSz']?.toString() ?? '') ?? 0.0;

      return {
        'symbol': info['instId'],
        'baseAsset': info['baseCcy'],
        'quoteAsset': info['quoteCcy'],
        'minQty': minSz,
        'stepSize': lotSz,
        'minNotional': 1.0,
      };
    } catch (_) {
      return null;
    }
  }

  Future<String> _toOkxSymbol(String symbol) async {
    final clean = symbol.replaceAll('/', '').replaceAll('-', '').toUpperCase();
    String base = clean;
    if (clean.endsWith('USDT')) {
      base = clean.substring(0, clean.length - 4);
    } else if (clean.endsWith('USDC')) {
      base = clean.substring(0, clean.length - 4);
    }

    final region = await ExchangeAccountStore.instance.getOkxRegion() ?? 'global';
    final bestPair = await OkxExchangeService.instance.findBestPair(base, region);
    if (bestPair == null) {
      throw Exception('Exact OKX pair is not available for this account/region.');
    }
    return bestPair;
  }
}

class BinanceSpotExecutionAdapter implements ExchangeExecutionAdapter {
  static const _baseUrl = 'https://api.binance.com';

  Future<Map<String, String>> _getAuthHeaders(String apiKey) async {
    return {
      'X-MBX-APIKEY': apiKey,
      'Content-Type': 'application/json',
    };
  }

  String _hmacSha256(String secret, String input) {
    final keyBytes = utf8.encode(secret);
    final inputBytes = utf8.encode(input);
    final hmac = Hmac(sha256, keyBytes);
    return hmac.convert(inputBytes).toString();
  }

  @override
  Future<ExchangeOrderResult> executeMarketOrder({
    required String symbol,
    required bool isBuy,
    required double amount,
    required double price,
  }) async {
    try {
      final creds = await ExchangeAccountStore.instance.getCredentials('binance');
      if (creds == null) {
        return ExchangeOrderResult(isSuccess: false, errorMessage: 'API keys not configured');
      }

      final apiKey = creds['apiKey']!;
      final secret = creds['apiSecret']!;

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      
      // Fetch symbol rules to get stepSize
      final normSymbol = _toBinanceSymbol(symbol);
      final rules = await getSymbolRules(normSymbol);
      final double stepSize = rules?['stepSize'] ?? 0.0;

      final Map<String, String> params = {
        'symbol': normSymbol,
        'side': isBuy ? 'BUY' : 'SELL',
        'type': 'MARKET',
        'recvWindow': '60000',
        'timestamp': timestamp.toString(),
      };

      if (isBuy) {
        // Binance MARKET BUY uses quoteOrderQty
        params['quoteOrderQty'] = amount.toStringAsFixed(2);
      } else {
        // Binance MARKET SELL uses quantity
        params['quantity'] = _formatQuantity(amount, stepSize);
      }

      // Generate query string and signature
      final queryString = Uri(queryParameters: params).query;
      final signature = _hmacSha256(secret, queryString);
      final url = '$_baseUrl/api/v3/order?$queryString&signature=$signature';

      final response = await http.post(
        Uri.parse(url),
        headers: await _getAuthHeaders(apiKey),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        final orderId = data['orderId']?.toString();
        final execQty = double.tryParse(data['executedQty']?.toString() ?? '') ?? 0.0;
        final cumQuote = double.tryParse(data['cummulativeQuoteQty']?.toString() ?? '') ?? 0.0;
        final execPrice = execQty > 0 ? cumQuote / execQty : price;

        return ExchangeOrderResult(
          isSuccess: true,
          orderId: orderId,
          executedQty: execQty,
          executedPrice: execPrice,
        );
      } else {
        final errorMsg = data['msg']?.toString() ?? 'API error: ${response.statusCode}';
        return ExchangeOrderResult(isSuccess: false, errorMessage: errorMsg);
      }
    } catch (e) {
      return ExchangeOrderResult(isSuccess: false, errorMessage: 'Network or parse error: $e');
    }
  }

  @override
  Future<double> fetchAssetBalance(String asset) async {
    try {
      final creds = await ExchangeAccountStore.instance.getCredentials('binance');
      if (creds == null) return 0.0;

      final apiKey = creds['apiKey']!;
      final secret = creds['apiSecret']!;

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final queryString = 'recvWindow=60000&timestamp=$timestamp';
      final signature = _hmacSha256(secret, queryString);

      final url = '$_baseUrl/api/v3/account?recvWindow=60000&timestamp=$timestamp&signature=$signature';
      final response = await http.get(
        Uri.parse(url),
        headers: await _getAuthHeaders(apiKey),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final balances = data['balances'] as List?;
        if (balances != null) {
          final target = asset.toUpperCase();
          for (final bal in balances) {
            if (bal['asset'] == target) {
              return double.tryParse(bal['free'].toString()) ?? 0.0;
            }
          }
        }
      }
    } catch (_) {}
    return 0.0;
  }

  @override
  Future<Map<String, dynamic>?> getSymbolRules(String symbol) async {
    try {
      final normSymbol = _toBinanceSymbol(symbol);
      final url = '$_baseUrl/api/v3/exchangeInfo?symbol=$normSymbol';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      final symbols = data['symbols'] as List?;
      if (symbols == null || symbols.isEmpty) return null;

      final symbolInfo = symbols[0];

      double minQty = 0.0;
      double stepSize = 0.0;
      double minNotional = 5.0; // Default fallback for CEX Spot

      final filters = symbolInfo['filters'] as List?;
      if (filters != null) {
        for (final f in filters) {
          final type = f['filterType']?.toString().toUpperCase();
          if (type == 'LOT_SIZE') {
            minQty = double.tryParse(f['minQty']?.toString() ?? '') ?? 0.0;
            stepSize = double.tryParse(f['stepSize']?.toString() ?? '') ?? 0.0;
          } else if (type == 'MIN_NOTIONAL' || type == 'NOTIONAL') {
            minNotional = double.tryParse(f['minNotional']?.toString() ?? '') ?? 5.0;
          }
        }
      }

      return {
        'symbol': symbolInfo['symbol'],
        'baseAsset': symbolInfo['baseAsset'],
        'quoteAsset': symbolInfo['quoteAsset'],
        'minQty': minQty,
        'stepSize': stepSize,
        'minNotional': minNotional,
      };
    } catch (_) {
      return null;
    }
  }

  String _toBinanceSymbol(String symbol) {
    return symbol.replaceAll('/', '').replaceAll('-', '').replaceAll('_', '').toUpperCase();
  }

  String _formatQuantity(double value, double stepSize) {
    if (stepSize <= 0) return value.toString();
    final double factor = 1 / stepSize;
    final rounded = (value * factor).floorToDouble() / factor;
    
    final stepStr = stepSize.toString();
    int decimals = 0;
    if (stepStr.contains('.')) {
      decimals = stepStr.split('.')[1].length;
    }
    return rounded.toStringAsFixed(decimals);
  }
}

class GateioSpotExecutionAdapter implements ExchangeExecutionAdapter {
  static const _baseUrl = 'https://api.gateio.ws';

  String _sha512Hex(String input) {
    return sha512.convert(utf8.encode(input)).toString();
  }

  String _hmacSha512(String secret, String input) {
    final keyBytes = utf8.encode(secret);
    final inputBytes = utf8.encode(input);
    final hmac = Hmac(sha512, keyBytes);
    return hmac.convert(inputBytes).toString();
  }

  Map<String, String> _getGateioHeaders({
    required String apiKey,
    required String secret,
    required String method,
    required String requestPath,
    required String queryString,
    required String body,
    required String timestamp,
  }) {
    final bodyHash = _sha512Hex(body);
    final signatureString = '$method\n$requestPath\n$queryString\n$bodyHash\n$timestamp';
    final sign = _hmacSha512(secret, signatureString);
    
    return {
      'KEY': apiKey,
      'SIGN': sign,
      'Timestamp': timestamp,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
  }

  @override
  Future<ExchangeOrderResult> executeMarketOrder({
    required String symbol,
    required bool isBuy,
    required double amount,
    required double price,
  }) async {
    try {
      final creds = await ExchangeAccountStore.instance.getCredentials('gateio');
      if (creds == null) {
        return ExchangeOrderResult(isSuccess: false, errorMessage: 'API keys not configured');
      }

      final apiKey = creds['apiKey']!;
      final secret = creds['apiSecret']!;

      final normSymbol = _toGateioSymbol(symbol);
      final rules = await getSymbolRules(normSymbol);
      final double stepSize = rules?['stepSize'] ?? 0.0;

      final timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
      const method = 'POST';
      const requestPath = '/api/v4/spot/orders';
      const queryString = '';

      final Map<String, dynamic> bodyMap = {
        'currency_pair': normSymbol,
        'type': 'market',
        'side': isBuy ? 'buy' : 'sell',
        'time_in_force': 'ioc',
      };

      if (isBuy) {
        // Gate.io BUY amount is quote amount directly
        bodyMap['amount'] = amount.toStringAsFixed(2);
      } else {
        // Gate.io SELL amount is base quantity
        bodyMap['amount'] = _formatQuantity(amount, stepSize);
      }

      final bodyStr = jsonEncode(bodyMap);
      final headers = _getGateioHeaders(
        apiKey: apiKey,
        secret: secret,
        method: method,
        requestPath: requestPath,
        queryString: queryString,
        body: bodyStr,
        timestamp: timestamp,
      );

      final response = await http.post(
        Uri.parse('$_baseUrl$requestPath'),
        headers: headers,
        body: bodyStr,
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final orderId = data['id']?.toString();
        final execQty = double.tryParse(data['filled_total']?.toString() ?? '') ?? 0.0;
        final execPrice = double.tryParse(data['avg_deal_price']?.toString() ?? '') ?? price;

        return ExchangeOrderResult(
          isSuccess: true,
          orderId: orderId,
          executedQty: execQty,
          executedPrice: execPrice,
        );
      } else {
        final errorMsg = data['message']?.toString() ?? 'API error: ${response.statusCode}';
        return ExchangeOrderResult(isSuccess: false, errorMessage: errorMsg);
      }
    } catch (e) {
      return ExchangeOrderResult(isSuccess: false, errorMessage: 'Network or parse error: $e');
    }
  }

  @override
  Future<double> fetchAssetBalance(String asset) async {
    try {
      final creds = await ExchangeAccountStore.instance.getCredentials('gateio');
      if (creds == null) return 0.0;

      final apiKey = creds['apiKey']!;
      final secret = creds['apiSecret']!;

      final timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
      const method = 'GET';
      const requestPath = '/api/v4/spot/accounts';
      const queryString = '';
      const body = '';

      final headers = _getGateioHeaders(
        apiKey: apiKey,
        secret: secret,
        method: method,
        requestPath: requestPath,
        queryString: queryString,
        body: body,
        timestamp: timestamp,
      );

      final response = await http.get(
        Uri.parse('$_baseUrl$requestPath'),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        final target = asset.toUpperCase();
        for (final item in data) {
          if (item['currency']?.toString().toUpperCase() == target) {
            return double.tryParse(item['available']?.toString() ?? '') ?? 0.0;
          }
        }
      }
    } catch (_) {}
    return 0.0;
  }

  @override
  Future<Map<String, dynamic>?> getSymbolRules(String symbol) async {
    try {
      final normSymbol = _toGateioSymbol(symbol);
      final url = '$_baseUrl/api/v4/spot/currency_pairs/$normSymbol';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      final int precision = int.tryParse(data['amount_precision']?.toString() ?? '') ?? 4;
      final double stepSize = 1 / pow(10, precision);
      final double minQuoteAmount = double.tryParse(data['min_quote_amount']?.toString() ?? '') ?? 1.0;

      return {
        'symbol': data['id'],
        'baseAsset': data['base'],
        'quoteAsset': data['quote'],
        'minQty': 0.0,
        'stepSize': stepSize,
        'minNotional': minQuoteAmount,
      };
    } catch (_) {
      return null;
    }
  }

  String _toGateioSymbol(String symbol) {
    final clean = symbol.replaceAll('/', '').replaceAll('-', '').replaceAll('_', '').toUpperCase();
    for (final quote in ['USDT', 'USDC', 'BTC', 'ETH', 'EUR']) {
      if (clean.endsWith(quote)) {
        final base = clean.substring(0, clean.length - quote.length);
        return '${base}_$quote';
      }
    }
    if (symbol.contains('_')) return symbol.toUpperCase();
    if (clean.length > 4) {
      final base = clean.substring(0, clean.length - 4);
      final quote = clean.substring(clean.length - 4);
      return '${base}_$quote';
    }
    return '${clean}_USDT';
  }

  String _formatQuantity(double value, double stepSize) {
    if (stepSize <= 0) return value.toString();
    final double factor = 1 / stepSize;
    final rounded = (value * factor).floorToDouble() / factor;
    
    final stepStr = stepSize.toString();
    int decimals = 0;
    if (stepStr.contains('.')) {
      decimals = stepStr.split('.')[1].length;
    }
    return rounded.toStringAsFixed(decimals);
  }
}
