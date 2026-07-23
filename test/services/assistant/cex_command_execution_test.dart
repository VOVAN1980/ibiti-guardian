import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/assistant/guardian_assistant_service.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/services/assistant/market_voice_brain.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_order_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/services/exchanges/okx_exchange_service.dart';
import 'package:ibiti_guardian/services/market/market_live_engine.dart';
import 'package:ibiti_guardian/services/market/market_memory_service.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/services/assistant/openai_chat_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/models/app_settings.dart';

class MockExchangeExecutionAdapter implements ExchangeExecutionAdapter {
  final Map<String, double> balances = {};
  final List<Map<String, dynamic>> ordersPlaced = [];
  Map<String, dynamic>? symbolRules;

  @override
  Future<double> fetchAssetBalance(String asset) async {
    return balances[asset.toUpperCase()] ?? 0.0;
  }

  @override
  Future<Map<String, dynamic>?> getSymbolRules(String symbol) async {
    return symbolRules ?? {
      'symbol': symbol,
      'baseAsset': symbol.replaceAll('USDT', '').replaceAll('USDC', ''),
      'quoteAsset': symbol.endsWith('USDC') ? 'USDC' : 'USDT',
      'minQty': 0.01,
      'stepSize': 0.001,
      'minNotional': 5.0,
    };
  }

  @override
  Future<ExchangeOrderResult> executeMarketOrder({
    required String symbol,
    required bool isBuy,
    required double amount,
    required double price,
  }) async {
    ordersPlaced.add({
      'symbol': symbol,
      'isBuy': isBuy,
      'amount': amount,
      'price': price,
    });
    return ExchangeOrderResult(
      isSuccess: true,
      orderId: 'mock_order_123',
      executedQty: isBuy ? amount / price : amount,
      executedPrice: price,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CEX Command Execution Tests', () {
    late MockExchangeExecutionAdapter mockMexc;
    late MockExchangeExecutionAdapter mockOkx;
    late List<UICommand> dispatchedCommands;
    StreamSubscription<UICommand>? commandSubscription;

    late MockHttpOverrides mockHttp;

    setUp(() {
      dispatchedCommands = [];
      commandSubscription = UICommandBus.instance.commands.listen((cmd) {
        dispatchedCommands.add(cmd);
      });

    // Mock HTTP requests globally to prevent any outbound requests
    mockHttp = MockHttpOverrides();
    mockHttp.mockResponses['completions'] = '{}';
    mockHttp.mockStatusCodes['completions'] = 500;
    HttpOverrides.global = mockHttp;

    // Disable OpenAI by default for offline execution tests to fallback cleanly
    SettingsService.instance.settingsForTest = AppSettings(
      openaiApiKey: null,
      isNeuralOperatorEnabled: false,
    );

      // Mock AudioPlayers global channel
      const audioplayersGlobalChannel = MethodChannel('xyz.luan/audioplayers.global');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioplayersGlobalChannel, (MethodCall methodCall) async {
        return null;
      });

      const audioplayersChannel = MethodChannel('xyz.luan/audioplayers');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioplayersChannel, (MethodCall methodCall) async {
        return null;
      });

      // Clear Live Engine cache to isolate tests
      MarketLiveEngine.instance.clearForTest();
      MarketDataService.instance.clearForTest();

      // Register default mock SOL asset in MarketDataService
      final solAsset = MarketAsset(
        id: 'solana-mexc',
        symbol: 'SOL',
        name: 'Solana (MEXC)',
        imageUrl: '',
        price: 100.0,
        change24h: 1.0,
        marketCap: 1000000.0,
        volume: 50000.0,
        rank: 5,
        sparkline: const [],
        high24h: 105.0,
        low24h: 98.0,
        change7d: 2.0,
        change30d: 5.0,
        networkGroup: 'Solana',
        sourceId: 'mexc',
        sourcePair: 'SOLUSDT',
        sourceUpdatedAt: DateTime.now(),
      );
      MarketDataService.instance.mergeExchangeData({'mexc:SOLUSDT': solAsset});

      mockMexc = MockExchangeExecutionAdapter();
      mockOkx = MockExchangeExecutionAdapter();

      ExchangeOrderService.instance.setAdapterForTest('mexc', mockMexc);
      ExchangeOrderService.instance.setAdapterForTest('okx', mockOkx);

      // Setup connected exchanges in store overrides
      ExchangeAccountStore.instance.clearTestOverrides();
      ExchangeAccountStore.instance.setTestOverride('cex_mexc_api_key', 'mock_mexc_key');
      ExchangeAccountStore.instance.setTestOverride('cex_mexc_api_secret', 'mock_mexc_secret');
      ExchangeAccountStore.instance.setTestOverride('cex_okx_api_key', 'mock_okx_key');
      ExchangeAccountStore.instance.setTestOverride('cex_okx_api_secret', 'mock_okx_secret');

      // Set active sources in AI Control with high limits to avoid policy blocks in tests
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.fullAutonomy,
        activeSources: ['mexc', 'okx'],
        dailyLimit: 500000.0,
      ));

      // Reset OKX tickers
      OkxExchangeService.instance.clearTickersForTest();
      
      // Clear memory
      MarketMemoryService.instance.clearForTest();

      // Reset daily budget usage
      DelegationController.instance.resetUsageForTest();
    });

    tearDown(() {
      HttpOverrides.global = null;
      commandSubscription?.cancel();
      ExchangeOrderService.instance.resetAdaptersForTest();
      ExchangeAccountStore.instance.clearTestOverrides();
    });

    void setLivePrice(String exchange, String token, String quote, double price) {
      MarketLiveEngine.instance.pushTick(
        exchange,
        '$token$quote',
        LiveTicker(
          symbol: '$token$quote',
          baseAsset: token,
          quoteAsset: quote,
          lastPrice: price,
          priceChangePercent24h: 1.0,
          volume24h: 1000.0,
          quoteVolume24h: 100000.0,
        ),
      );
    }

    test('Full Autonomy Buy Execution parses and places order', () async {
      setLivePrice('mexc', 'SOL', 'USDT', 100.0);
      mockMexc.balances['USDT'] = 500.0; // sufficient balance

      final response = await GuardianAssistantService.instance.process(
        'купи SOL на 20',
        source: AssistantInputSource.voice,
      );

      expect(response.type, ResponseType.info);
      expect(response.message, contains('Ордер успешно выполнен'));
      expect(mockMexc.ordersPlaced.length, 1);
      expect(mockMexc.ordersPlaced[0]['isBuy'], true);
      expect(mockMexc.ordersPlaced[0]['amount'], 20.0); // buy SOL for 20 USDT
    });

    test('Full Autonomy Sell Execution (all / 50% / quantity / \$ value)', () async {
      setLivePrice('mexc', 'SOL', 'USDT', 100.0);
      mockMexc.balances['SOL'] = 10.0; // base balance
      mockMexc.balances['USDT'] = 0.0; // Sell must succeed with 0 USDT/quote balance

      // 1. sell all SOL
      var response = await GuardianAssistantService.instance.process(
        'sell all SOL',
        source: AssistantInputSource.voice,
      );
      expect(response.type, ResponseType.info);
      expect(mockMexc.ordersPlaced.last['amount'], 10.0); // 10.0 SOL

      // 2. sell 50% SOL
      response = await GuardianAssistantService.instance.process(
        'sell 50% SOL',
        source: AssistantInputSource.voice,
      );
      expect(response.type, ResponseType.info);
      expect(mockMexc.ordersPlaced.last['amount'], 5.0); // 5.0 SOL

      // 3. sell 2 SOL
      response = await GuardianAssistantService.instance.process(
        'sell 2 SOL',
        source: AssistantInputSource.voice,
      );
      expect(response.type, ResponseType.info);
      expect(mockMexc.ordersPlaced.last['amount'], 2.0); // 2.0 SOL

      // 4. sell SOL for 200 dollars
      response = await GuardianAssistantService.instance.process(
        'sell SOL for 200',
        source: AssistantInputSource.voice,
      );
      expect(response.type, ResponseType.info);
      expect(mockMexc.ordersPlaced.last['amount'], 2.0); // 200 / 100.0 = 2.0 SOL
    });

    test('Sell without amount blocks and prompts for amount', () async {
      setLivePrice('mexc', 'SOL', 'USDT', 100.0);
      mockMexc.balances['SOL'] = 10.0;

      final response = await GuardianAssistantService.instance.process(
        'sell SOL',
        source: AssistantInputSource.voice,
      );

      expect(response.type, ResponseType.info);
      expect(response.message, anyOf(contains('Укажите сумму.'), contains('Please specify the amount.')));
      expect(mockMexc.ordersPlaced.isEmpty, true);
    });

    test('Guarded Mode Preview opens modal, does not place direct order', () async {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        activeSources: ['mexc'],
      ));

      setLivePrice('mexc', 'SOL', 'USDT', 100.0);
      mockMexc.balances['USDT'] = 200.0;

      final response = await GuardianAssistantService.instance.process(
        'купи SOL на 50',
        source: AssistantInputSource.voice,
      );

      expect(response.type, ResponseType.info);
      expect(response.message, contains('Подготовила ордер'));
      expect(mockMexc.ordersPlaced.isEmpty, true);

      // Verify dispatched UICommand
      expect(dispatchedCommands.length, 1);
      expect(dispatchedCommands[0].type, UICommandType.openModal);
      expect(dispatchedCommands[0].target, 'cex_trade');
      
      final payload = dispatchedCommands[0].payload!;
      expect(payload['symbol'], 'SOL');
      expect(payload['isBuy'], true);
      expect(payload['exchangeId'], 'mexc');
      expect(payload['initialAmount'], 50.0);
      expect(payload['price'], 100.0);
      expect(payload['quoteAsset'], 'USDT');
    });

    test('Manual Mode strictly blocks CEX trades', () async {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.manual,
        activeSources: ['mexc'],
      ));

      setLivePrice('mexc', 'SOL', 'USDT', 100.0);
      mockMexc.balances['USDT'] = 200.0;

      final response = await GuardianAssistantService.instance.process(
        'купи SOL на 50',
        source: AssistantInputSource.voice,
      );

      expect(response.message, anyOf(contains('Manual'), contains('Manual mode')));
      expect(mockMexc.ordersPlaced.isEmpty, true);
      expect(dispatchedCommands.isEmpty, true);
    });

    test('Distinct balance checks block buy or sell on insufficient funds', () async {
      setLivePrice('mexc', 'SOL', 'USDT', 100.0);

      // 1. Buy fails when quote balance is below 10 (e.g. 5.0)
      mockMexc.balances['USDT'] = 5.0;
      var response = await GuardianAssistantService.instance.process(
        'купи SOL на 20',
        source: AssistantInputSource.voice,
      );
      expect(response.message, anyOf(contains('Недостаточный баланс'), contains('Insufficient')));
      expect(mockMexc.ordersPlaced.isEmpty, true);

      // 2. Buy fails when quote balance is >= 10 but below order amount (e.g. 15.0 for a $20 order)
      mockMexc.balances['USDT'] = 15.0;
      response = await GuardianAssistantService.instance.process(
        'купи SOL на 20',
        source: AssistantInputSource.voice,
      );
      expect(response.message, anyOf(contains('Недостаточный баланс'), contains('Insufficient')));
      expect(mockMexc.ordersPlaced.isEmpty, true);

      // 3. Sell fails when SOL balance is too low (even if USDT is 0)
      mockMexc.balances['USDT'] = 0.0;
      mockMexc.balances['SOL'] = 0.5; // too low for 1.0 SOL sell
      response = await GuardianAssistantService.instance.process(
        'sell 1.0 SOL',
        source: AssistantInputSource.voice,
      );
      expect(response.message, anyOf(contains('Недостаточный баланс'), contains('Insufficient')));
      expect(mockMexc.ordersPlaced.isEmpty, true);
    });

    test('No Fallback price blocks order if ticker price is zero/unavailable', () async {
      mockMexc.balances['USDT'] = 200.0;
      // Do not set price in LiveEngine

      final response = await GuardianAssistantService.instance.process(
        'купи SOL на 20',
        source: AssistantInputSource.voice,
      );

      expect(response.message, contains('Не удалось найти подходящую'));
      expect(mockMexc.ordersPlaced.isEmpty, true);
    });

    test('OKX EEA Quote routing prefers USDC dynamically', () async {
      // Deactivate MEXC to ensure OKX is selected
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.fullAutonomy,
        activeSources: ['okx'],
        dailyLimit: 500000.0,
      ));

      // 1. Setup OKX EEA
      ExchangeAccountStore.instance.setTestOverride('cex_okx_region', 'eea');
      
      // SOLUSDC exists
      OkxExchangeService.instance.setTickerForTest(
        'SOLUSDC',
        const LiveTicker(
          symbol: 'SOLUSDC',
          baseAsset: 'SOL',
          lastPrice: 150.0,
          priceChangePercent24h: 1.0,
          volume24h: 1000.0,
          quoteVolume24h: 150000.0,
        ),
      );

      // Live price available on OKX SOLUSDC
      setLivePrice('okx', 'SOL', 'USDC', 150.0);
      mockOkx.balances['USDC'] = 300.0;

      final response = await GuardianAssistantService.instance.process(
        'купи SOL на 50',
        source: AssistantInputSource.voice,
      );

      print('DEBUG OKX RESPONSE: ${response.type} | ${response.message}');
      expect(response.type, ResponseType.info);
      expect(response.message, contains('Ордер успешно выполнен на OKX'));
      expect(mockOkx.ordersPlaced.length, 1);
      // symbol passed to executeMarketOrder is resolved as SOLUSDC
      expect(mockOkx.ordersPlaced[0]['symbol'], 'SOLUSDC');
    });

    test('General Chat and Automated sources are strictly blocked from trading', () async {
      setLivePrice('mexc', 'SOL', 'USDT', 100.0);
      mockMexc.balances['USDT'] = 500.0;

      // 1. General Chat
      var response = await GuardianAssistantService.instance.process(
        'купи SOL на 20',
        source: AssistantInputSource.generalChat,
      );
      expect(response.message, contains('Торговля CEX поддерживается только'));
      expect(mockMexc.ordersPlaced.isEmpty, true);

      // 2. Automated
      response = await GuardianAssistantService.instance.process(
        'купи SOL на 20',
        source: AssistantInputSource.automated,
      );
      expect(response.message, contains('Торговля CEX поддерживается только'));
      expect(mockMexc.ordersPlaced.isEmpty, true);
    });

    test('BinanceSpotExecutionAdapter executes market BUY and SELL correctly', () async {
      final oldOverrides = HttpOverrides.current;
      final mockHttp = MockHttpOverrides();
      HttpOverrides.global = mockHttp;

      // Mock exchange info
      mockHttp.mockResponses['/api/v3/exchangeInfo'] = jsonEncode({
        'symbols': [
          {
            'symbol': 'SOLUSDT',
            'status': 'TRADING',
            'baseAsset': 'SOL',
            'quoteAsset': 'USDT',
            'filters': [
              {
                'filterType': 'LOT_SIZE',
                'minQty': '0.01',
                'stepSize': '0.001',
              },
              {
                'filterType': 'MIN_NOTIONAL',
                'minNotional': '5.0',
              }
            ]
          }
        ]
      });

      // Mock account balance
      mockHttp.mockResponses['/api/v3/account'] = jsonEncode({
        'balances': [
          {'asset': 'USDT', 'free': '150.0'},
          {'asset': 'SOL', 'free': '5.0'}
        ]
      });

      // Mock order placement
      mockHttp.mockResponses['/api/v3/order'] = jsonEncode({
        'orderId': 98765,
        'executedQty': '2.0',
        'cummulativeQuoteQty': '200.0',
      });

      ExchangeAccountStore.instance.setTestOverride('cex_binance_api_key', 'binance_key');
      ExchangeAccountStore.instance.setTestOverride('cex_binance_api_secret', 'binance_secret');

      final adapter = BinanceSpotExecutionAdapter();

      // 1. Symbol rules
      final rules = await adapter.getSymbolRules('SOLUSDT');
      expect(rules?['symbol'], 'SOLUSDT');
      expect(rules?['minQty'], 0.01);
      expect(rules?['stepSize'], 0.001);
      expect(rules?['minNotional'], 5.0);

      // 2. Fetch Balance
      final usdtBal = await adapter.fetchAssetBalance('USDT');
      expect(usdtBal, 150.0);
      final solBal = await adapter.fetchAssetBalance('SOL');
      expect(solBal, 5.0);

      // 3. Execute MARKET BUY
      final buyRes = await adapter.executeMarketOrder(
        symbol: 'SOL/USDT',
        isBuy: true,
        amount: 20.0,
        price: 100.0,
      );
      expect(buyRes.isSuccess, true);
      expect(buyRes.orderId, '98765');
      expect(buyRes.executedQty, 2.0);
      expect(buyRes.executedPrice, 100.0);

      // Check request URL parameters
      final buyUrl = mockHttp.requestedUrls.firstWhere((url) => url.contains('/api/v3/order'));
      expect(buyUrl, contains('symbol=SOLUSDT'));
      expect(buyUrl, contains('side=BUY'));
      expect(buyUrl, contains('type=MARKET'));
      expect(buyUrl, contains('quoteOrderQty=20.00'));
      expect(buyUrl, contains('signature='));

      // 4. Execute MARKET SELL
      final sellRes = await adapter.executeMarketOrder(
        symbol: 'SOL_USDT',
        isBuy: false,
        amount: 2.3456,
        price: 100.0,
      );
      expect(sellRes.isSuccess, true);
      expect(sellRes.orderId, '98765');

      final sellUrl = mockHttp.requestedUrls.lastWhere((url) => url.contains('/api/v3/order'));
      expect(sellUrl, contains('symbol=SOLUSDT'));
      expect(sellUrl, contains('side=SELL'));
      expect(sellUrl, contains('type=MARKET'));
      expect(sellUrl, contains('quantity=2.345')); // formatted to stepSize 0.001

      HttpOverrides.global = oldOverrides;
    });

    test('GateioSpotExecutionAdapter executes market BUY and SELL correctly', () async {
      final oldOverrides = HttpOverrides.current;
      final mockHttp = MockHttpOverrides();
      HttpOverrides.global = mockHttp;

      // Mock currency pairs rules
      mockHttp.mockResponses['/api/v4/spot/currency_pairs/SOL_USDT'] = jsonEncode({
        'id': 'SOL_USDT',
        'base': 'SOL',
        'quote': 'USDT',
        'min_quote_amount': '2.0',
        'amount_precision': 3,
        'precision': 2,
        'trade_status': 'tradable'
      });

      // Mock accounts
      mockHttp.mockResponses['/api/v4/spot/accounts'] = jsonEncode([
        {'currency': 'USDT', 'available': '300.0'},
        {'currency': 'SOL', 'available': '8.0'}
      ]);

      // Mock order placement
      mockHttp.mockResponses['/api/v4/spot/orders'] = jsonEncode({
        'id': 'gate_order_123',
        'filled_total': '1.5',
        'avg_deal_price': '100.0',
      });

      ExchangeAccountStore.instance.setTestOverride('cex_gateio_api_key', 'gateio_key');
      ExchangeAccountStore.instance.setTestOverride('cex_gateio_api_secret', 'gateio_secret');

      final adapter = GateioSpotExecutionAdapter();

      // 1. Get rules
      final rules = await adapter.getSymbolRules('SOLUSDT');
      expect(rules?['symbol'], 'SOL_USDT');
      expect(rules?['stepSize'], 0.001);
      expect(rules?['minNotional'], 2.0);

      // 2. Fetch Balance
      final usdtBal = await adapter.fetchAssetBalance('USDT');
      expect(usdtBal, 300.0);
      final solBal = await adapter.fetchAssetBalance('SOL');
      expect(solBal, 8.0);

      // 3. Execute BUY
      final buyRes = await adapter.executeMarketOrder(
        symbol: 'SOL/USDT',
        isBuy: true,
        amount: 50.0,
        price: 100.0,
      );
      expect(buyRes.isSuccess, true);
      expect(buyRes.orderId, 'gate_order_123');
      expect(buyRes.executedQty, 1.5);
      expect(buyRes.executedPrice, 100.0);

      // Check request body and headers
      final buyBodyStr = mockHttp.requestBodies.firstWhere((b) => b.contains('currency_pair'));
      final Map<String, dynamic> buyBody = jsonDecode(buyBodyStr);
      expect(buyBody['currency_pair'], 'SOL_USDT');
      expect(buyBody['type'], 'market');
      expect(buyBody['side'], 'buy');
      expect(buyBody['amount'], '50.00'); // quote amount directly
      expect(buyBody['time_in_force'], 'ioc');

      final buyHeaders = mockHttp.requestHeaders[mockHttp.requestBodies.indexOf(buyBodyStr)];
      expect(buyHeaders['key']?.first, 'gateio_key');
      expect(buyHeaders['sign']?.first, isNotNull);
      expect(buyHeaders['timestamp']?.first, isNotNull);

      // 4. Execute SELL
      final sellRes = await adapter.executeMarketOrder(
        symbol: 'SOL-USDT',
        isBuy: false,
        amount: 2.3456,
        price: 100.0,
      );
      expect(sellRes.isSuccess, true);
      expect(sellRes.orderId, 'gate_order_123');

      final sellBodyStr = mockHttp.requestBodies.lastWhere((b) => b.contains('currency_pair'));
      final Map<String, dynamic> sellBody = jsonDecode(sellBodyStr);
      expect(sellBody['currency_pair'], 'SOL_USDT');
      expect(sellBody['side'], 'sell');
      expect(sellBody['amount'], '2.345'); // formatted to stepSize 0.001 (amount_precision = 3)

      HttpOverrides.global = oldOverrides;
    });

    test('CEX SELL Hotfix Tests (Zero quote balance & budget bypass)', () async {
      // Setup: MEXC exchange connected, SOL price = 100.0
      setLivePrice('mexc', 'SOL', 'USDT', 100.0);
      mockMexc.balances['SOL'] = 5.0; // 5 SOL
      mockMexc.balances['USDT'] = 0.0; // 0 USDT
      mockMexc.ordersPlaced.clear();

      // Configure Min Trade Balance in Settings to 20.0
      await AiControlService.instance.updateMinTradeBalance(20.0);

      // 1. MEXC buy blocks if USDT < minTradeBalance (USDT = 0)
      final buyRes = await ExchangeOrderService.instance.placeMarketOrder(
        exchangeId: 'mexc',
        symbol: 'SOL/USDT',
        isBuy: true,
        amount: 20.0,
        price: 100.0,
      );
      expect(buyRes.isSuccess, false);
      expect(buyRes.errorMessage, contains('баланс меньше 20'));

      // 2. MEXC sell all succeeds with SOL balance and 0 USDT
      final sellAllRes = await ExchangeOrderService.instance.placeMarketOrder(
        exchangeId: 'mexc',
        symbol: 'SOL/USDT',
        isBuy: false,
        amount: 5.0, // Sell 5 SOL
        price: 100.0,
      );
      expect(sellAllRes.isSuccess, true);
      expect(mockMexc.ordersPlaced.length, 1);
      expect(mockMexc.ordersPlaced[0]['isBuy'], false);
      expect(mockMexc.ordersPlaced[0]['amount'], 5.0);

      // 3. MEXC sell 50% succeeds with SOL balance and 0 USDT
      mockMexc.ordersPlaced.clear();
      final sellHalfRes = await ExchangeOrderService.instance.placeMarketOrder(
        exchangeId: 'mexc',
        symbol: 'SOL/USDT',
        isBuy: false,
        amount: 2.5, // 50% of 5 SOL
        price: 100.0,
      );
      expect(sellHalfRes.isSuccess, true);
      expect(mockMexc.ordersPlaced.length, 1);
      expect(mockMexc.ordersPlaced[0]['amount'], 2.5);

      // 4. MEXC sell succeeds even when daily buy budget is exhausted
      // Set daily limit to 50.0 and spend 50.0 (simulate buy budget exhaustion)
      await AiControlService.instance.updateLimits(daily: 50.0);
      DelegationController.instance.commitUsage(50.0);
      expect(DelegationController.instance.canSpend(1.0), false); // Budget exhausted

      mockMexc.ordersPlaced.clear();
      final sellBudgetRes = await ExchangeOrderService.instance.placeMarketOrder(
        exchangeId: 'mexc',
        symbol: 'SOL/USDT',
        isBuy: false,
        amount: 1.0,
        price: 100.0,
      );
      expect(sellBudgetRes.isSuccess, true);
      expect(mockMexc.ordersPlaced.length, 1);

      // 5. MEXC sell does not call delegation.commitUsage()
      final usedBefore = DelegationController.instance.usedTodayUsd;
      final sellCommitRes = await ExchangeOrderService.instance.placeMarketOrder(
        exchangeId: 'mexc',
        symbol: 'SOL/USDT',
        isBuy: false,
        amount: 1.0,
        price: 100.0,
      );
      expect(sellCommitRes.isSuccess, true);
      expect(DelegationController.instance.usedTodayUsd, usedBefore); // No increase

      // 6. OKX sell succeeds with base asset balance and 0 USDC/USDT
      OkxExchangeService.instance.setTickerForTest(
        'SOLUSDT',
        const LiveTicker(
          symbol: 'SOLUSDT',
          baseAsset: 'SOL',
          lastPrice: 100.0,
          priceChangePercent24h: 1.0,
          volume24h: 1000.0,
          quoteVolume24h: 100000.0,
        ),
      );
      setLivePrice('okx', 'SOL', 'USDT', 100.0);
      mockOkx.balances['SOL'] = 10.0;
      mockOkx.balances['USDT'] = 0.0;
      mockOkx.ordersPlaced.clear();

      final okxSellRes = await ExchangeOrderService.instance.placeMarketOrder(
        exchangeId: 'okx',
        symbol: 'SOL/USDT',
        isBuy: false,
        amount: 2.0,
        price: 100.0,
      );
      expect(okxSellRes.isSuccess, true);
      expect(mockOkx.ordersPlaced.length, 1);
      expect(mockOkx.ordersPlaced[0]['isBuy'], false);

      // 7. Guarded sell opens CexSpotTradeModal even with 0 quote balance
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        activeSources: ['mexc'],
        minTradeBalance: 15.0,
      ));
      dispatchedCommands.clear();

      final guardedRes = await GuardianAssistantService.instance.process(
        'sell 2 SOL',
        source: AssistantInputSource.voice,
      );
      expect(guardedRes.message, anyOf(contains('Подготовила ордер'), contains('Prepared')));
      expect(dispatchedCommands.length, 1);
      expect(dispatchedCommands[0].type, UICommandType.openModal);
      expect(dispatchedCommands[0].target, 'cex_trade');

      // 8. FullAutonomy sell executes even with 0 quote balance if sell gates pass
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.fullAutonomy,
        activeSources: ['mexc'],
        minTradeBalance: 15.0,
      ));
      mockMexc.ordersPlaced.clear();

      final autoRes = await GuardianAssistantService.instance.process(
        'sell 2 SOL',
        source: AssistantInputSource.voice,
      );
      expect(autoRes.message, anyOf(contains('успешно выполнен'), contains('executed')));
      expect(mockMexc.ordersPlaced.length, 1);
      expect(mockMexc.ordersPlaced[0]['isBuy'], false);
    });

    test('Voice CEX trade (Guarded) dispatches cex_trade', () async {
      final solAsset = MarketAsset(
        id: 'solana-mexc',
        symbol: 'SOL',
        name: 'Solana (MEXC)',
        imageUrl: '',
        price: 100.0,
        change24h: 1.0,
        marketCap: 1000000.0,
        volume: 50000.0,
        rank: 5,
        sparkline: const [],
        high24h: 105.0,
        low24h: 98.0,
        change7d: 2.0,
        change30d: 5.0,
        networkGroup: 'Solana',
        sourceId: 'mexc',
        sourcePair: 'SOLUSDT',
        sourceUpdatedAt: DateTime.now(),
      );
      MarketDataService.instance.mergeExchangeData({'mexc:SOLUSDT': solAsset});
      setLivePrice('mexc', 'SOL', 'USDT', 100.0);
      mockMexc.balances['USDT'] = 200.0;

      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        activeSources: ['mexc'],
      ));
      dispatchedCommands.clear();

      final response = await GuardianAssistantService.instance.process(
        'купи SOL на 50 долларов',
        source: AssistantInputSource.voice,
      );

      expect(response.message, anyOf(contains('Подготовила ордер'), contains('Prepared')));
      expect(dispatchedCommands.length, 1);
      expect(dispatchedCommands[0].type, UICommandType.openModal);
      expect(dispatchedCommands[0].target, 'cex_trade');
    });

    test('Voice CEX trade (Full) calls ExchangeOrderService', () async {
      final solAsset = MarketAsset(
        id: 'solana-mexc',
        symbol: 'SOL',
        name: 'Solana (MEXC)',
        imageUrl: '',
        price: 100.0,
        change24h: 1.0,
        marketCap: 1000000.0,
        volume: 50000.0,
        rank: 5,
        sparkline: const [],
        high24h: 105.0,
        low24h: 98.0,
        change7d: 2.0,
        change30d: 5.0,
        networkGroup: 'Solana',
        sourceId: 'mexc',
        sourcePair: 'SOLUSDT',
        sourceUpdatedAt: DateTime.now(),
      );
      MarketDataService.instance.mergeExchangeData({'mexc:SOLUSDT': solAsset});
      setLivePrice('mexc', 'SOL', 'USDT', 100.0);
      mockMexc.balances['USDT'] = 200.0;
      mockMexc.ordersPlaced.clear();

      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.fullAutonomy,
        activeSources: ['mexc'],
        dailyLimit: 50000.0,
      ));

      final response = await GuardianAssistantService.instance.process(
        'купи SOL на 50 долларов',
        source: AssistantInputSource.voice,
      );

      expect(response.message, anyOf(contains('Ордер успешно выполнен'), contains('executed successfully')));
      expect(mockMexc.ordersPlaced.length, 1);
      expect(mockMexc.ordersPlaced[0]['isBuy'], true);
      expect(mockMexc.ordersPlaced[0]['amount'], 50.0);
    });

    test('Voice CEX trade (Manual) blocks CEX trade', () async {
      final solAsset = MarketAsset(
        id: 'solana-mexc',
        symbol: 'SOL',
        name: 'Solana (MEXC)',
        imageUrl: '',
        price: 100.0,
        change24h: 1.0,
        marketCap: 1000000.0,
        volume: 50000.0,
        rank: 5,
        sparkline: const [],
        high24h: 105.0,
        low24h: 98.0,
        change7d: 2.0,
        change30d: 5.0,
        networkGroup: 'Solana',
        sourceId: 'mexc',
        sourcePair: 'SOLUSDT',
        sourceUpdatedAt: DateTime.now(),
      );
      MarketDataService.instance.mergeExchangeData({'mexc:SOLUSDT': solAsset});
      setLivePrice('mexc', 'SOL', 'USDT', 100.0);
      mockMexc.balances['USDT'] = 200.0;
      mockMexc.ordersPlaced.clear();
      dispatchedCommands.clear();

      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.manual,
        activeSources: ['mexc'],
      ));

      final response = await GuardianAssistantService.instance.process(
        'купи SOL на 50 долларов',
        source: AssistantInputSource.voice,
      );

      expect(response.message, anyOf(contains('Manual'), contains('Manual mode')));
      expect(mockMexc.ordersPlaced.isEmpty, true);
      expect(dispatchedCommands.isEmpty, true);
    });

    test('Voice on-chain trade routes to wallet_buy target', () async {
      final coingeckoBnbAsset = MarketAsset(
        id: 'binancecoin',
        symbol: 'BNB',
        name: 'BNB',
        imageUrl: '',
        price: 300.0,
        change24h: 1.5,
        marketCap: 50000000.0,
        volume: 200000.0,
        rank: 4,
        sparkline: const [],
        high24h: 305.0,
        low24h: 298.0,
        change7d: 3.0,
        change30d: 6.0,
        networkGroup: 'BNB Chain',
        sourceId: 'coingecko',
        sourcePair: '',
        sourceUpdatedAt: DateTime.now(),
      );
      MarketDataService.instance.mergeExchangeData({'coingecko:BNB': coingeckoBnbAsset});

      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        activeSources: ['mexc'],
      ));
      dispatchedCommands.clear();

      await GuardianAssistantService.instance.process(
        'купи BNB на 50 долларов',
        source: AssistantInputSource.voice,
      );

      await Future.delayed(const Duration(milliseconds: 50));
      expect(dispatchedCommands.any((cmd) => cmd.type == UICommandType.openModal && cmd.target == 'wallet_buy'), true);
    });

    test('CEX assets never trigger wallet_buy even when MEXC is disconnected', () async {
      final mexcSolAsset = MarketAsset(
        id: 'solana-mexc',
        symbol: 'SOL',
        name: 'Solana (MEXC)',
        imageUrl: '',
        price: 100.0,
        change24h: 1.0,
        marketCap: 1000000.0,
        volume: 50000.0,
        rank: 5,
        sparkline: const [],
        high24h: 105.0,
        low24h: 98.0,
        change7d: 2.0,
        change30d: 5.0,
        networkGroup: 'Solana',
        sourceId: 'mexc',
        sourcePair: 'SOLUSDT',
        sourceUpdatedAt: DateTime.now(),
      );
      MarketDataService.instance.mergeExchangeData({'mexc:SOLUSDT': mexcSolAsset});

      ExchangeAccountStore.instance.clearTestOverrides();

      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        activeSources: ['mexc'],
      ));
      dispatchedCommands.clear();

      final response = await GuardianAssistantService.instance.process(
        'купи SOL на 50 долларов',
        source: AssistantInputSource.voice,
      );

      expect(dispatchedCommands.any((cmd) => cmd.target == 'wallet_buy' || cmd.target == 'wallet_sell' || cmd.target == 'wallet_swap'), false);
      expect(response.message, anyOf(contains('Подготовила ордер'), contains('Prepared trade modal')));
    });

    test('Voice CEX trade parses decimals with comma "купи SOL на 0,50"', () async {
      setLivePrice('mexc', 'SOL', 'USDT', 100.0);
      mockMexc.balances['USDT'] = 500.0;
      dispatchedCommands.clear();

      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        activeSources: ['mexc'],
      ));

      final response = await GuardianAssistantService.instance.process(
        'купи SOL на 0,50',
        source: AssistantInputSource.voice,
      );

      expect(response.type, ResponseType.info);
      expect(dispatchedCommands.length, 1);
      expect(dispatchedCommands[0].target, 'cex_trade');
      expect(dispatchedCommands[0].payload?['symbol'], 'SOL');
      expect(dispatchedCommands[0].payload?['initialAmount'], 0.50);
    });

    test('Voice CEX trade parses cents "купи SOL на 50 центов"', () async {
      setLivePrice('mexc', 'SOL', 'USDT', 100.0);
      mockMexc.balances['USDT'] = 500.0;
      dispatchedCommands.clear();

      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        activeSources: ['mexc'],
      ));

      final response = await GuardianAssistantService.instance.process(
        'купи SOL на 50 центов',
        source: AssistantInputSource.voice,
      );

      expect(response.type, ResponseType.info);
      expect(dispatchedCommands.length, 1);
      expect(dispatchedCommands[0].target, 'cex_trade');
      expect(dispatchedCommands[0].payload?['symbol'], 'SOL');
      expect(dispatchedCommands[0].payload?['initialAmount'], 0.50);
    });

    test('Voice CEX trade uses focused symbol "купи эту монету на 50 центов"', () async {
      final xtAsset = MarketAsset(
        id: 'xt-mexc',
        symbol: 'XT',
        name: 'XT Token',
        imageUrl: '',
        price: 2.0,
        change24h: 1.0,
        marketCap: 100000.0,
        volume: 5000.0,
        rank: 100,
        sparkline: const [],
        high24h: 2.1,
        low24h: 1.9,
        change7d: 2.0,
        change30d: 5.0,
        networkGroup: 'XT',
        sourceId: 'mexc',
        sourcePair: 'XTUSDT',
        sourceUpdatedAt: DateTime.now(),
      );
      MarketDataService.instance.mergeExchangeData({'mexc:XTUSDT': xtAsset});

      setLivePrice('mexc', 'XT', 'USDT', 2.0);
      mockMexc.balances['USDT'] = 500.0;
      dispatchedCommands.clear();

      ScreenContextService.instance.setFocusedToken('XT', price: 2.0);

      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        activeSources: ['mexc'],
      ));

      final response = await GuardianAssistantService.instance.process(
        'купи эту монету на 50 центов',
        source: AssistantInputSource.voice,
      );

      expect(response.type, ResponseType.info);
      expect(dispatchedCommands.length, 1);
      expect(dispatchedCommands[0].target, 'cex_trade');
      expect(dispatchedCommands[0].payload?['symbol'], 'XT');
      expect(dispatchedCommands[0].payload?['initialAmount'], 0.50);

      ScreenContextService.instance.clearFocusedToken();
    });

    test('Voice CEX trade fallback symbol "купи на 0,50"', () async {
      final xtAsset = MarketAsset(
        id: 'xt-mexc',
        symbol: 'XT',
        name: 'XT Token',
        imageUrl: '',
        price: 2.0,
        change24h: 1.0,
        marketCap: 100000.0,
        volume: 5000.0,
        rank: 100,
        sparkline: const [],
        high24h: 2.1,
        low24h: 1.9,
        change7d: 2.0,
        change30d: 5.0,
        networkGroup: 'XT',
        sourceId: 'mexc',
        sourcePair: 'XTUSDT',
        sourceUpdatedAt: DateTime.now(),
      );
      MarketDataService.instance.mergeExchangeData({'mexc:XTUSDT': xtAsset});

      setLivePrice('mexc', 'XT', 'USDT', 2.0);
      mockMexc.balances['USDT'] = 500.0;
      dispatchedCommands.clear();

      ScreenContextService.instance.setFocusedToken('XT', price: 2.0);

      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        activeSources: ['mexc'],
      ));

      final response = await GuardianAssistantService.instance.process(
        'купи на 0,50',
        source: AssistantInputSource.voice,
      );

      expect(response.type, ResponseType.info);
      expect(dispatchedCommands.length, 1);
      expect(dispatchedCommands[0].target, 'cex_trade');
      expect(dispatchedCommands[0].payload?['symbol'], 'XT');
      expect(dispatchedCommands[0].payload?['initialAmount'], 0.50);

      ScreenContextService.instance.clearFocusedToken();
    });

    test('Voice CEX trade missing amount speech response', () async {
      dispatchedCommands.clear();

      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        activeSources: ['mexc'],
      ));

      final response = await GuardianAssistantService.instance.process(
        'купи SOL',
        source: AssistantInputSource.voice,
      );

      expect(response.message, 'Укажите сумму.');
      expect(response.speechText, 'Сумма?');
      expect(dispatchedCommands.isEmpty, true);
    });

    test('MarketVoiceBrain resolves slang, context, and filler words', () async {
      dispatchedCommands.clear();
      ScreenContextService.instance.setFocusedToken('SOL', price: 100.0);

      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        activeSources: ['mexc'],
      ));

      // 1. Filler words, slang amount, context token
      final response1 = await GuardianAssistantService.instance.process(
        'давай купи её на пол бакса',
        source: AssistantInputSource.voice,
      );
      expect(response1.type, ResponseType.info);
      expect(dispatchedCommands.length, 1);
      expect(dispatchedCommands[0].payload?['symbol'], 'SOL');
      expect(dispatchedCommands[0].payload?['initialAmount'], 0.50);

      // 2. Filler words, quote value sell
      dispatchedCommands.clear();
      final response2 = await GuardianAssistantService.instance.process(
        'пожалуйста слей её на сотку',
        source: AssistantInputSource.voice,
      );
      expect(response2.type, ResponseType.info);
      expect(dispatchedCommands.length, 1);
      expect(dispatchedCommands[0].payload?['symbol'], 'SOL');
      expect(dispatchedCommands[0].payload?['initialAmount'], 1.0);

      // 3. Sell quantity mode
      dispatchedCommands.clear();
      await GuardianAssistantService.instance.process(
        'продай 2 SOL',
        source: AssistantInputSource.voice,
      );
      expect(dispatchedCommands[0].payload?['initialAmount'], 2.0);

      // 4. Strict token validation
      dispatchedCommands.clear();
      final response4 = await GuardianAssistantService.instance.process(
        'купи blabla на 50',
        source: AssistantInputSource.voice,
      );
      expect(response4.message, 'Укажите монету.');
      expect(response4.speechText, 'Монета?');

      // 5. Vague amount check ("чуть-чуть")
      dispatchedCommands.clear();
      final response5 = await GuardianAssistantService.instance.process(
        'купи SOL чуть-чуть',
        source: AssistantInputSource.voice,
      );
      expect(response5.message, 'Укажите сумму.');
      expect(response5.speechText, 'Сумма?');

      // 6. Sell all command ("слей всё SOL")
      final intent6 = MarketVoiceBrain.parseTradeIntent('слей всё SOL');
      expect(intent6?.amount, -1.0);
      expect(intent6?.isQuantity, true);

      dispatchedCommands.clear();
      await GuardianAssistantService.instance.process(
        'слей всё SOL',
        source: AssistantInputSource.voice,
      );
      expect(dispatchedCommands[0].payload?['initialAmount'], isNull);

      // 7. Sell half command ("продай половину SOL")
      final intent7 = MarketVoiceBrain.parseTradeIntent('продай половину SOL');
      expect(intent7?.amount, -0.5);
      expect(intent7?.isQuantity, true);

      dispatchedCommands.clear();
      await GuardianAssistantService.instance.process(
        'продай половину SOL',
        source: AssistantInputSource.voice,
      );
      expect(dispatchedCommands[0].payload?['initialAmount'], isNull);

      // 8. focused SOL + "buy bitcoin for 10" -> BTC, not SOL
      ScreenContextService.instance.setFocusedToken('SOL', price: 100.0);
      final intent8 = MarketVoiceBrain.parseTradeIntent('buy bitcoin for 10');
      expect(intent8?.tokenSymbol, 'BTC');
      expect(intent8?.amount, 10.0);

      // 9. focused XT + "купи на пол бакса" -> XT, amount 0.50
      ScreenContextService.instance.setFocusedToken('XT', price: 2.0);
      final intent9 = MarketVoiceBrain.parseTradeIntent('купи на пол бакса');
      expect(intent9?.tokenSymbol, 'XT');
      expect(intent9?.amount, 0.50);

      // 10. focused XT + "купи мне на 10" -> XT, amount 10
      final intent10 = MarketVoiceBrain.parseTradeIntent('купи мне на 10');
      expect(intent10?.tokenSymbol, 'XT');
      expect(intent10?.amount, 10.0);

      // 11. focused XT + "купи монету на один доллар" -> XT, amount 1.0
      final intent11 = MarketVoiceBrain.parseTradeIntent('купи монету на один доллар');
      expect(intent11?.tokenSymbol, 'XT');
      expect(intent11?.amount, 1.0);

      // 12. focused XT + "купи на 1 бакс монету" -> XT, amount 1.0
      final intent12 = MarketVoiceBrain.parseTradeIntent('купи на 1 бакс монету');
      expect(intent12?.tokenSymbol, 'XT');
      expect(intent12?.amount, 1.0);

      // 13. focused XT + "купи монету на 1 долар" -> XT, amount 1.0
      final intent13 = MarketVoiceBrain.parseTradeIntent('купи монету на 1 долар');
      expect(intent13?.tokenSymbol, 'XT');
      expect(intent13?.amount, 1.0);

      // 14. focused XT + "купи монету на один долар" -> XT, amount 1.0
      final intent14 = MarketVoiceBrain.parseTradeIntent('купи монету на один долар');
      expect(intent14?.tokenSymbol, 'XT');
      expect(intent14?.amount, 1.0);

      ScreenContextService.instance.clearFocusedToken();
    });

    test('solveTradeIntent intercepts capability questions correctly', () async {
      final overrides = MockHttpOverrides();
      await HttpOverrides.runWithHttpOverrides(() async {
        overrides.mockResponses['completions'] = jsonEncode({
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'type': 'capabilityQuestion',
                  'confidence': 1.0,
                })
              }
            }
          ]
        });

        OpenAIChatService.instance.clearHistory();
        SettingsService.instance.settingsForTest = AppSettings(
          openaiApiKey: 'mock_key',
          isNeuralOperatorEnabled: true,
        );
        await OpenAIChatService.instance.init();

        final response = await GuardianAssistantService.instance.process(
          'монеты покупать можешь?',
          source: AssistantInputSource.voice,
        );

        expect(response.type, ResponseType.info);
        expect(response.message, contains('В Guarded я открою окно покупки для подтверждения'));
      }, overrides);
    });
  });
}

class MockHttpOverrides extends HttpOverrides {
  final Map<String, String> mockResponses = {};
  final Map<String, int> mockStatusCodes = {};
  final List<String> requestedUrls = [];
  final List<String> requestBodies = [];
  final List<Map<String, List<String>>> requestHeaders = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _MockHttpClient(this);
  }
}

class _MockHttpClient implements HttpClient {
  final MockHttpOverrides overrides;
  _MockHttpClient(this.overrides);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    overrides.requestedUrls.add(url.toString());
    return _MockHttpClientRequest(overrides, method, url);
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('get', url);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('post', url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpClientRequest implements HttpClientRequest {
  final MockHttpOverrides overrides;
  @override
  final String method;
  final Uri url;

  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  int contentLength = -1;
  @override
  bool persistentConnection = true;
  @override
  bool bufferOutput = true;

  final _MockHttpHeaders _headers = _MockHttpHeaders();
  final List<int> _bodyBytes = [];

  _MockHttpClientRequest(this.overrides, this.method, this.url);

  @override
  HttpHeaders get headers => _headers;

  @override
  void write(Object? obj) {
    if (obj != null) {
      _bodyBytes.addAll(utf8.encode(obj.toString()));
    }
  }

  @override
  void add(List<int> data) {
    _bodyBytes.addAll(data);
  }

  @override
  Future addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _bodyBytes.addAll(chunk);
    }
  }

  @override
  Future<HttpClientResponse> close() async {
    final urlStr = url.toString();
    final bodyStr = utf8.decode(_bodyBytes);
    overrides.requestBodies.add(bodyStr);

    final Map<String, List<String>> headerMap = {};
    _headers.forEach((name, values) {
      headerMap[name] = values;
    });
    overrides.requestHeaders.add(headerMap);

    String responseBody = "{}";
    int statusCode = 200;

    for (final pattern in overrides.mockResponses.keys) {
      if (urlStr.contains(pattern)) {
        responseBody = overrides.mockResponses[pattern]!;
        statusCode = overrides.mockStatusCodes[pattern] ?? 200;
        break;
      }
    }

    return _MockHttpClientResponse(responseBody, statusCode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _headers = {};

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _headers.putIfAbsent(name.toLowerCase(), () => []).add(value.toString());
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _headers[name.toLowerCase()] = [value.toString()];
  }

  @override
  List<String>? operator [](String name) => _headers[name.toLowerCase()];

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _headers.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpClientResponse implements HttpClientResponse {
  final String body;
  @override
  final int statusCode;

  _MockHttpClientResponse(this.body, this.statusCode);

  @override
  HttpHeaders get headers => _MockHttpHeaders();

  @override
  String get reasonPhrase => 'OK';
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => true;
  @override
  int get contentLength => utf8.encode(body).length;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<List<int>>();
    controller.add(utf8.encode(body));
    controller.close();
    return controller.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
