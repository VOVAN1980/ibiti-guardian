import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/assistant/guardian_assistant_service.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_order_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/services/market/market_live_engine.dart';
import 'package:ibiti_guardian/services/market/market_memory_service.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/services/assistant/openai_chat_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/models/app_settings.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/assistant/market_voice_brain.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/wallet/address_book_service.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/models/portfolio_summary.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'dart:typed_data';
import 'package:ibiti_guardian/services/execution/guardian_execution_controller.dart';
import 'package:ibiti_guardian/services/execution/rpc_transaction_simulator.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/swap/swap_provider.dart';

class MockExchangeExecutionAdapter implements ExchangeExecutionAdapter {
  final Map<String, double> balances = {};
  final List<Map<String, dynamic>> ordersPlaced = [];

  @override
  Future<double> fetchAssetBalance(String asset) async {
    return balances[asset.toUpperCase()] ?? 0.0;
  }

  @override
  Future<Map<String, dynamic>?> getSymbolRules(String symbol) async {
    return {
      'symbol': symbol,
      'baseAsset': symbol.replaceAll('USDT', '').replaceAll('USDC', '').replaceAll('SOL', 'SOL'),
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

class MockRpcSimulator implements RpcSimulator {
  @override
  Future<RpcSimulationResult> simulate(TransactionRequest tx) async {
    return RpcSimulationResult.ok(gas: '0x5208');
  }
}

class MockSwapProvider implements SwapProvider {
  @override
  Future<QuoteResponse> getQuote(QuoteRequest request) async {
    return QuoteResponse(
      expectedOutputAmount: request.amount * BigInt.from(99) ~/ BigInt.from(100),
      minOutputAmount: request.amount * BigInt.from(95) ~/ BigInt.from(100),
      routerAddress: '0x3333333333333333333333333333333333333333',
      allowanceTarget: '0x4444444444444444444444444444444444444444',
      calldata: Uint8List(0),
      nativeValue: BigInt.zero,
      priceImpactPct: 0.1,
      gasEstimate: BigInt.from(100000),
      approvalNeeded: false,
      providerName: 'MockSwapProvider',
      quoteTimestamp: DateTime.now(),
      routeSummary: 'SOL -> USDT via MockSwapProvider',
      extraSummary: const {},
    );
  }
}

class MockHttpOverrides extends HttpOverrides {
  final Map<String, String> mockResponses = {};
  Map<String, dynamic>? currentTestCase;

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
    String responseBody = "{}";
    if (url.toString().contains('completions') && overrides.currentTestCase != null) {
      final tc = overrides.currentTestCase!;
      final bodyStr = utf8.decode(_bodyBytes);
      final isSolveTradeIntent = bodyStr.contains('primary trading intent resolver');

      final intentType = tc['expectedIntent'];
      final tokenSymbol = tc['expectedToken'];
      final amount = tc['expectedAmount'];
      final isQuantity = tc['expectedIsQuantity'] ?? false;

      if (isSolveTradeIntent) {
        final isCapability = intentType == 'capabilityQuestion';
        final isTrade = intentType == 'buyAsset' || intentType == 'sellAsset';

        Map<String, dynamic> resp;
        if (isCapability) {
          resp = {
            'type': 'capabilityQuestion',
            'confidence': 1.0,
          };
        } else if (isTrade) {
          resp = {
            'type': intentType,
            'tokenSymbol': tokenSymbol,
            'amount': amount,
            'isQuantity': isQuantity,
            'confidence': 1.0,
          };
        } else {
          resp = {
            'type': 'unknown',
            'confidence': 0.1,
          };
        }

        responseBody = jsonEncode({
          'choices': [
            {
              'message': {
                'content': jsonEncode(resp)
              }
            }
          ]
        });
      } else {
        // solve endpoint
        final Map<String, dynamic>? explicitIntent = (intentType != null && intentType != 'unknown' && intentType != 'capabilityQuestion')
            ? {
                'type': intentType,
                'params': {
                  'amount': amount,
                  'tokenSymbol': tokenSymbol,
                  'isQuantity': isQuantity,
                  'toAddress': tc['expectedAddress'],
                  'sourceTokenSymbol': tc['expectedSourceToken'],
                  'targetTokenSymbol': tc['expectedTargetToken'],
                }
              }
            : null;

        final mode = AiControlService.instance.settings.mode;
        final isExecutionIntent = intentType == 'buyAsset' || intentType == 'sellAsset' || intentType == 'sendAsset' || intentType == 'swapAsset';
        final displayMsg = (mode == AiMode.manual && isExecutionIntent)
            ? 'Blocked in Manual mode. Switch to Guarded or Full Autonomy in Security → AI Control.'
            : 'Processing ${intentType ?? "query"}';

        final resp = {
          'displayMessage': displayMsg,
          'speechText': displayMsg,
          'uiCommands': <dynamic>[],
          'explicitIntent': explicitIntent,
        };

        responseBody = jsonEncode({
          'choices': [
            {
              'message': {
                'content': jsonEncode(resp)
              }
            }
          ]
        });
      }
    } else {
      for (final pattern in overrides.mockResponses.keys) {
        if (url.toString().contains(pattern)) {
          responseBody = overrides.mockResponses[pattern]!;
          break;
        }
      }
    }
    return _MockHttpClientResponse(responseBody, 200);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Guardian AI Deterministic Arena Tests', () {
    late MockExchangeExecutionAdapter mockMexc;
    late List<UICommand> dispatchedCommands;
    StreamSubscription<UICommand>? commandSubscription;

    setUp(() {
      dispatchedCommands = [];
      commandSubscription = UICommandBus.instance.commands.listen((cmd) {
        dispatchedCommands.add(cmd);
      });

      // Mock Vault and Portfolio
      IBITIVaultService.instance.setVaultCreatedForTest(
        evmAddress: '0x9999999999999999999999999999999999999999',
        solanaAddress: 'solana_address',
        tronAddress: 'tron_address',
        evmCardAddresses: [
          '0x1111111111111111111111111111111111111111',
          '0x2222222222222222222222222222222222222222',
        ],
      );

      final mockPortfolio = PortfolioSummary(
        totalBalanceUsd: 10000.0,
        assetsCount: 3,
        allAssets: [
          WalletAsset.native(
            name: 'Ethereum',
            symbol: 'ETH',
            balance: 5.0,
            logoUrl: '',
            priceUsd: 2000.0,
            decimals: 18,
            chainId: 56,
            chainKey: 'bsc',
          ),
          WalletAsset(
            name: 'Solana',
            symbol: 'SOL',
            address: 'solana_token_address',
            balance: 50.0,
            logoUrl: '',
            priceUsd: 100.0,
            valueUsd: 5000.0,
            decimals: 9,
            chainId: 0,
            chainKey: 'solana',
          ),
          WalletAsset(
            name: 'Tether USD',
            symbol: 'USDT',
            address: 'usdt_address',
            balance: 1000.0,
            logoUrl: '',
            priceUsd: 1.0,
            valueUsd: 1000.0,
            decimals: 6,
            chainId: 56,
            chainKey: 'bsc',
          ),
        ],
        address: '0x9999999999999999999999999999999999999999',
        networkName: 'BSC',
        chainKey: 'bsc',
        isSupported: true,
      );
      VaultPortfolioListener.instance.setSummaryForTest(mockPortfolio);

      // Mock RPC Simulator and Swap Provider
      GuardianExecutionController.instance.overrideRpcSimulator(MockRpcSimulator());
      GuardianExecutionController.instance.overrideSwapProvider(MockSwapProvider());

      // Mock SharedPreferences
      const sharedPrefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sharedPrefsChannel, (MethodCall methodCall) async {
        if (methodCall.method == 'getAll') {
          return <String, dynamic>{
            'flutter.guardian_policy_profileV1': jsonEncode({
              'mode': 'guarded',
              'sendLimitUsd': 50000.0,
              'swapLimitUsd': 50000.0,
              'approveLimitUsd': 50000.0,
              'allowUnknownContracts': true,
              'allowUnlimitedApprove': true,
              'trustedAddresses': [],
              'trustedContracts': [],
              'actionExpiries': {},
            }),
          };
        }
        return true;
      });

      // Clear engine state
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
      ExchangeOrderService.instance.setAdapterForTest('mexc', mockMexc);

      // Setup exchange keys overrides to avoid secure storage exceptions during tests
      ExchangeAccountStore.instance.clearTestOverrides();
      for (final ex in ['mexc', 'binance', 'gateio', 'okx']) {
        ExchangeAccountStore.instance.setTestOverride('cex_${ex}_api_key', 'mock_${ex}_key');
        ExchangeAccountStore.instance.setTestOverride('cex_${ex}_api_secret', 'mock_${ex}_secret');
      }

      // Reset mock settings
      SettingsService.instance.settingsForTest = AppSettings(
        openaiApiKey: 'mock_key',
        isNeuralOperatorEnabled: true,
      );
      OpenAIChatService.instance.clearHistory();

      // Mock audio channels to prevent errors
      const audioplayersGlobalChannel = MethodChannel('xyz.luan/audioplayers.global');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioplayersGlobalChannel, (MethodCall methodCall) async => null);

      const audioplayersChannel = MethodChannel('xyz.luan/audioplayers');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioplayersChannel, (MethodCall methodCall) async => null);

      // Populate mock address book
      // Clear first to prevent cross-run issues
      final existingAddresses = List<AddressEntry>.from(AddressBookService.instance.entries);
      for (final entry in existingAddresses) {
        AddressBookService.instance.remove(entry.address);
      }
      AddressBookService.instance.add('Alice', '0x1111111111111111111111111111111111111111');
      AddressBookService.instance.add('Алиса', '0x1111111111111111111111111111111111111111');
      AddressBookService.instance.add('Алисе', '0x1111111111111111111111111111111111111111');
      AddressBookService.instance.add('Bob', '0x2222222222222222222222222222222222222222');
      AddressBookService.instance.add('bob', '0x2222222222222222222222222222222222222222');

      DelegationController.instance.resetUsageForTest();
    });

    tearDown(() {
      commandSubscription?.cancel();
      ExchangeOrderService.instance.resetAdaptersForTest();

      // Clean up mock address book entries
      final entriesToClean = List<AddressEntry>.from(AddressBookService.instance.entries);
      for (final entry in entriesToClean) {
        AddressBookService.instance.remove(entry.address);
      }
    });

    // Helper to load and merge case files
    List<Map<String, dynamic>> loadCases() {
      final cases = <Map<String, dynamic>>[];
      final paths = [
        'test/fixtures/guardian_ai_voice_cases.json',
        'test/fixtures/guardian_ai_market_cases.json',
        'test/fixtures/guardian_ai_adversarial_cases.json',
      ];
      for (final path in paths) {
        final file = File(path);
        if (file.existsSync()) {
          final List<dynamic> list = jsonDecode(file.readAsStringSync());
          cases.addAll(list.cast<Map<String, dynamic>>());
        }
      }
      return cases;
    }

    final testCases = loadCases();

    for (final tc in testCases) {
      test('Case ${tc['id']} [${tc['category']}]: "${tc['input']}"', () async {
        // 1. Setup mock environment states
        final mode = tc['mode'] == 'manual'
            ? AiMode.manual
            : tc['mode'] == 'guarded'
                ? AiMode.guarded
                : AiMode.fullAutonomy;

        AiControlService.instance.setSettingsForTest(AiControlSettings(
          mode: mode,
          activeSources: const ['mexc'],
          perTxLimit: 50000.0,
          dailyLimit: 500000.0,
          perContractLimit: 50000.0,
          perRecipientLimit: 50000.0,
        ));

        if (tc['focusedSymbol'] != null) {
          ScreenContextService.instance.setFocusedToken(tc['focusedSymbol'], price: 100.0);
        } else {
          ScreenContextService.instance.clearFocusedToken();
        }

        final balances = Map<String, dynamic>.from(tc['balances'] ?? {});
        balances.forEach((asset, value) {
          mockMexc.balances[asset.toUpperCase()] = (value as num).toDouble();
        });

        // Setup live engine ticks
        MarketLiveEngine.instance.pushTick('mexc', 'SOLUSDT', LiveTicker(
          symbol: 'SOLUSDT',
          baseAsset: 'SOL',
          quoteAsset: 'USDT',
          lastPrice: 100.0,
          priceChangePercent24h: 1.0,
          volume24h: 1000.0,
          quoteVolume24h: 100000.0,
        ));

        // 2. Prepare HTTP overrides for OpenAI mocked response
        final overrides = MockHttpOverrides();
        overrides.currentTestCase = tc;

        // 3. Process request within HTTP override sandbox
        await HttpOverrides.runWithHttpOverrides(() async {
          await OpenAIChatService.instance.init();

          final sourceStr = tc['source'];
          final source = sourceStr == 'voice'
              ? AssistantInputSource.voice
              : sourceStr == 'marketChat'
                  ? AssistantInputSource.marketChat
                  : sourceStr == 'generalChat'
                      ? AssistantInputSource.generalChat
                      : AssistantInputSource.automated;

          final response = await GuardianAssistantService.instance.process(
            tc['input'],
            source: source,
          );

          // Let asynchronous microtasks/events complete so command stream is dispatched
          await Future.delayed(Duration.zero);

          // 4. Assertions


          // Response Kind
          if (tc['expectedResponseKind'] == 'error') {
            expect(response.type, ResponseType.error, reason: 'Case ${tc['id']}: ${response.message}');
          } else {
            expect(response.type, anyOf(ResponseType.info, ResponseType.preview), reason: 'Case ${tc['id']}: ${response.message}');
          }

          // Execution checks
          final shouldExecute = tc['shouldExecute'] as bool;
          if (shouldExecute) {
            expect(mockMexc.ordersPlaced.isNotEmpty, true);
            expect(mockMexc.ordersPlaced[0]['isBuy'], tc['expectedIntent'] == 'buyAsset');
          } else {
            expect(mockMexc.ordersPlaced.isEmpty, true);
          }

          // Modal checks
          final shouldOpenModal = tc['shouldOpenModal'] as bool;
          if (shouldOpenModal) {
            expect(dispatchedCommands.isNotEmpty, true);
            final hasExpectedModal = dispatchedCommands.any((cmd) => cmd.type == UICommandType.openModal && cmd.target == tc['expectedModal']);
            expect(hasExpectedModal, true, reason: 'Expected modal ${tc['expectedModal']} to be opened.');
          } else {
            // If it should not open modal, verify that no cex_trade modal is opened.
            final hasCexTradeModal = dispatchedCommands.any((cmd) => cmd.target == 'cex_trade');
            expect(hasCexTradeModal, false);
          }

          // Safety block reason checks
          final blockReason = tc['expectedBlockReason'];
          if (blockReason == 'missing_amount') {
            expect(response.message, anyOf(contains('Укажите сумму.'), contains('specify the amount')));
          } else if (blockReason == 'missing_token') {
            expect(response.message, anyOf(contains('Укажите монету.'), contains('specify the token')));
          } else if (blockReason == 'manual_mode_blocked') {
            expect(response.message, anyOf(contains('режим Manual'), contains('Manual mode'), contains('Торговля отключена')));
          } else if (blockReason == 'insufficient_balance') {
            expect(response.message, contains('Недостаточный баланс'));
          } else if (blockReason == 'source_blocked') {
            // General chat or automated block
            expect(response.message, contains('Торговля CEX поддерживается только'));
          }

          // Safety "mustNotExecute" enforcement
          final mustNotExecute = tc['mustNotExecute'] as bool;
          if (mustNotExecute) {
            expect(mockMexc.ordersPlaced.isEmpty, true);
          }

        }, overrides);
      });
    }
  });
}
