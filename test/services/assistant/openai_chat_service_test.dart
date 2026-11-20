// OpenAIChatService: the gpt-6-luna request shape, the 10-minute fallback to
// gpt-4o-mini, the read-only status tools, tool routing for the System
// status card, remembered canned turns, the app guide in the prompt, the AI
// mode and AI PIN setting in the prompt («Советник» / «Ручной» /
// «Автономный»), the voice's grammatical gender and the language of error
// replies.
//
// No real network: every request goes to a MockClient.
//
// Run: flutter test test/services/assistant/openai_chat_service_test.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ibiti_guardian/models/app_settings.dart';
import 'package:ibiti_guardian/models/approval.dart';
import 'package:ibiti_guardian/models/risk_assessment.dart';
import 'package:ibiti_guardian/services/assistant/app_guide.dart';
import 'package:ibiti_guardian/services/assistant/openai_chat_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/security/approval_scan_service.dart';
import 'package:ibiti_guardian/services/security/system_status_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = OpenAIChatService.instance;
  late List<Map<String, dynamic>> requests;

  const jsonHeaders = {'content-type': 'application/json'};

  http.Response chatResponse(Map<String, dynamic> message) => http.Response(
        jsonEncode({
          'choices': [
            {'message': message, 'finish_reason': 'stop'}
          ]
        }),
        200,
        headers: jsonHeaders,
      );

  Map<String, dynamic> answer(String text) => {
        'role': 'assistant',
        'content': jsonEncode({
          'displayMessage': text,
          'speechText': text,
          'uiCommands': <Object>[],
          'explicitIntent': null,
        }),
      };

  http.Response errorResponse(int status, String code, String message,
          {String? param}) =>
      http.Response(
        jsonEncode({
          'error': {
            'message': message,
            'type': 'invalid_request_error',
            'param': param,
            'code': code,
          }
        }),
        status,
        headers: jsonHeaders,
      );

  /// Records every request body and answers with [reply].
  void mockOpenAi(http.Response Function(Map<String, dynamic> body) reply) {
    service.httpClientForTest = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      requests.add(body);
      return reply(body);
    });
  }

  setUp(() {
    // Fresh storage per test: saved Safe Scan results must not leak.
    SharedPreferences.setMockInitialValues({});
    requests = [];
    SettingsService.instance.settingsForTest = AppSettings(
      openaiApiKey: 'test_key',
      isNeuralOperatorEnabled: true,
    );
    AiControlService.instance.setSettingsForTest(
      const AiControlSettings(
        mode: AiMode.guarded,
        allowedActions: [AiAction.openWindows],
      ),
    );
    service.clearHistory();
    service.resetModelFallbackForTest();
    SystemStatusService.instance.resetForTest();
    ApprovalScanService.lastScanTime = null;
    ApprovalScanService.lastScannedApprovals = [];
  });

  tearDown(() {
    service.httpClientForTest = null;
    service.resetModelFallbackForTest();
    service.clearHistory();
  });

  group('request shape', () {
    test('solve sends gpt-6-luna, reasoning_effort none, max_completion_tokens',
        () async {
      mockOpenAi((_) => chatResponse(answer('Привет! Чем помочь?')));

      final result = await service.solve('привет', 'ru', false);

      expect(result['displayMessage'], 'Привет! Чем помочь?');
      expect(requests, hasLength(1));
      final body = requests.single;
      expect(body['model'], 'gpt-6-luna');
      expect(body['reasoning_effort'], 'none');
      expect(body['max_completion_tokens'], 1200);
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body['temperature'], 0.3);
      expect(body['tool_choice'], 'auto');
    });

    test('the system prompt carries the app guide', () async {
      mockOpenAi((_) => chatResponse(answer('Готово.')));

      await service.solve('что такое Safe Scan?', 'ru', false);

      final messages = requests.single['messages'] as List;
      final system = messages.first['content'] as String;
      expect(system, contains('APP GUIDE'));
      expect(system, contains(AppGuide.text.trim().split('\n')[1].trim()));
      expect(system, contains('Safe Scan (token approval check)'));
      expect(system, isNot(contains('approval scan, revoke (Panic)')));
    });

    test('voice turns may read scan results and the status card', () async {
      mockOpenAi((_) => chatResponse(answer('Готово.')));

      await service.solve('что нашёл скан?', 'ru', false);

      final names = (requests.single['tools'] as List)
          .map((t) => t['function']['name'])
          .toList();
      expect(names, containsAll(['get_system_status', 'scan_security_risks']));
      // Action tools stay off in conversation-only turns.
      expect(names, isNot(contains('panic_revoke_all')));
      expect(names, isNot(contains('safe_revoke_review')));
    });

    test('solveTradeIntent keeps temperature 0 on gpt-6-luna', () async {
      mockOpenAi((_) => chatResponse({
            'role': 'assistant',
            'content': jsonEncode({
              'type': 'buyAsset',
              'tokenSymbol': 'SOL',
              'amount': 10,
              'isQuantity': false,
              'missingField': null,
              'confidence': 0.95,
            }),
          }));

      final result = await service.solveTradeIntent('купи SOL на 10');

      expect(result?['type'], 'buyAsset');
      final body = requests.single;
      expect(body['model'], 'gpt-6-luna');
      expect(body['reasoning_effort'], 'none');
      expect(body['temperature'], 0);
      expect(body['max_completion_tokens'], 150);
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body.containsKey('tools'), isFalse);
    });
  });

  group('model fallback', () {
    http.Response modelNotFound() => errorResponse(
        404,
        'model_not_found',
        'The model `gpt-6-luna` does not exist or you do not have '
            'access to it.');

    test('a missing model falls back to gpt-4o-mini, for 10 minutes only',
        () async {
      var now = DateTime(2026, 11, 19, 12);
      service.clock = () => now;
      var lunaRejected = true;
      mockOpenAi((body) =>
          body['model'] == OpenAIChatService.chatModel && lunaRejected
              ? modelNotFound()
              : chatResponse(answer('Привет!')));

      final first = await service.solve('привет', 'ru', false);

      expect(first['displayMessage'], 'Привет!');
      expect(requests.map((r) => r['model']), ['gpt-6-luna', 'gpt-4o-mini']);
      final retry = requests[1];
      expect(retry['max_tokens'], 1200);
      expect(retry.containsKey('max_completion_tokens'), isFalse);
      expect(retry.containsKey('reasoning_effort'), isFalse);
      expect(service.usingFallbackModel, isTrue);

      // Within 10 minutes the next turn goes straight to the fallback model.
      requests.clear();
      now = now.add(const Duration(minutes: 9));
      await service.solve('как дела?', 'ru', false);
      expect(requests.map((r) => r['model']), ['gpt-4o-mini']);

      // After 10 minutes gpt-6-luna is tried first again.
      requests.clear();
      lunaRejected = false;
      now = now.add(const Duration(minutes: 2));
      expect(service.usingFallbackModel, isFalse);
      await service.solve('а сейчас?', 'ru', false);
      expect(requests.map((r) => r['model']), ['gpt-6-luna']);
      expect(service.usingFallbackModel, isFalse);
    });

    test('a model still rejected after 10 minutes falls back again',
        () async {
      var now = DateTime(2026, 11, 19, 12);
      service.clock = () => now;
      mockOpenAi((body) => body['model'] == OpenAIChatService.chatModel
          ? modelNotFound()
          : chatResponse(answer('Привет!')));

      await service.solve('привет', 'ru', false);
      requests.clear();
      now = now.add(OpenAIChatService.fallbackRetryAfter);

      final result = await service.solve('ещё раз', 'ru', false);

      expect(result['displayMessage'], 'Привет!');
      expect(requests.map((r) => r['model']), ['gpt-6-luna', 'gpt-4o-mini']);
      expect(service.usingFallbackModel, isTrue);
    });

    test('an unsupported reasoning_effort falls back in solveTradeIntent',
        () async {
      mockOpenAi((body) => body['model'] == OpenAIChatService.chatModel
          ? errorResponse(400, 'unsupported_parameter',
              "Unsupported parameter: 'reasoning_effort'.",
              param: 'reasoning_effort')
          : chatResponse({
              'role': 'assistant',
              'content': jsonEncode({'type': 'unknown', 'confidence': 0.1}),
            }));

      final result = await service.solveTradeIntent('привет');

      expect(result?['type'], 'unknown');
      expect(requests.map((r) => r['model']), ['gpt-6-luna', 'gpt-4o-mini']);
      expect(requests.last['max_tokens'], 150);
      expect(requests.last['temperature'], 0);
      expect(service.usingFallbackModel, isTrue);
    });

    test('auth errors keep the model and never mention keys or Settings',
        () async {
      mockOpenAi((_) => errorResponse(
          401, 'invalid_api_key', 'Incorrect API key provided: sk-…'));

      final result = await service.solve('привет', 'ru', false);

      expect(requests, hasLength(1));
      expect(service.usingFallbackModel, isFalse);
      final text = '${result['displayMessage']} ${result['speechText']}';
      expect(text, contains('недоступен'));
      for (final word in ['API', 'ключ', 'key', 'Settings', 'OpenAI']) {
        expect(text, isNot(contains(word)), reason: word);
      }
    });

    test('a switched-off AI says where to switch it on, without a key',
        () async {
      SettingsService.instance.settingsForTest = AppSettings(
        openaiApiKey: null,
        isNeuralOperatorEnabled: false,
      );
      mockOpenAi((_) => chatResponse(answer('не должно быть вызвано')));

      final result = await service.solve('привет', 'ru', false);

      expect(requests, isEmpty);
      expect(result['displayMessage'], contains('выключен'));
      expect(result['displayMessage'], contains('Guardian AI'));
      expect(result['displayMessage'], isNot(contains('API')));
      expect(result['displayMessage'], isNot(contains('OpenAI')));
    });

    test('isModelRejection: only model / parameter errors', () {
      String err(String code, {String? param, String message = 'x'}) =>
          jsonEncode({
            'error': {'code': code, 'param': param, 'message': message}
          });

      expect(OpenAIChatService.isModelRejection(404, err('model_not_found')),
          isTrue);
      expect(
          OpenAIChatService.isModelRejection(
              400, err('unsupported_parameter', param: 'reasoning_effort')),
          isTrue);
      expect(
          OpenAIChatService.isModelRejection(
              400,
              err('invalid_request_error',
                  message: 'Invalid model name passed in model=gpt-6-luna',
                  param: 'model')),
          isTrue);
      expect(
          OpenAIChatService.isModelRejection(
              400, err('context_length_exceeded', param: 'messages')),
          isFalse);
      expect(OpenAIChatService.isModelRejection(401, err('invalid_api_key')),
          isFalse);
      expect(
          OpenAIChatService.isModelRejection(429, err('insufficient_quota')),
          isFalse);
      expect(OpenAIChatService.isModelRejection(500, 'oops'), isFalse);
    });
  });

  group('voice gender', () {
    void useVoice(String voiceId, {bool aiOn = true}) {
      SettingsService.instance.settingsForTest = AppSettings(
        openaiApiKey: aiOn ? 'test_key' : null,
        isNeuralOperatorEnabled: aiOn,
        preferredAiVoiceId: voiceId,
      );
    }

    Future<String> systemPrompt() async {
      mockOpenAi((_) => chatResponse(answer('Готово.')));
      await service.solve('что ты проверил?', 'ru', false);
      final messages = requests.single['messages'] as List;
      return messages.first['content'] as String;
    }

    test('the female voice speaks about itself in the feminine', () async {
      useVoice('marin');

      final system = await systemPrompt();

      expect(system, contains('Your voice is female'));
      expect(system, contains('я проверила'));
      expect(system, isNot(contains('Your voice is male')));
    });

    test('the male voice speaks about itself in the masculine', () async {
      useVoice('cedar');

      final system = await systemPrompt();

      expect(system, contains('Your voice is male'));
      expect(system, contains('я проверил,'));
      expect(system, isNot(contains('Your voice is female')));
    });

    test('canned Russian replies follow the voice', () async {
      mockOpenAi((_) => chatResponse(answer('не должно быть вызвано')));

      useVoice('marin', aiOn: false);
      final female = await service.solve('привет', 'ru', false);
      useVoice('cedar', aiOn: false);
      final male = await service.solve('привет', 'ru', false);

      expect(requests, isEmpty);
      expect(female['speechText'], startsWith('Я выключена.'));
      expect(male['speechText'], startsWith('Я выключен.'));
    });

    test('"unavailable" follows the voice too', () async {
      useVoice('marin');
      mockOpenAi((_) => errorResponse(500, 'server_error', 'oops'));

      final result = await service.solve('привет', 'ru', false);

      expect(result['speechText'], startsWith('Я сейчас недоступна.'));
    });
  });

  group('error reply language', () {
    http.Response truncated() => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': '{"displayMes'},
                'finish_reason': 'length',
              }
            ]
          }),
          200,
          headers: jsonHeaders,
        );

    test('a cut-off answer is explained in the language of the message',
        () async {
      mockOpenAi((_) => truncated());

      final ru = await service.solve('расскажи всё про рынок', 'en', false);
      final en = await service.solve('tell me everything', 'ru', false);

      expect(ru['displayMessage'], contains('слишком длинным'));
      expect(en['displayMessage'], contains('too long'));
    });
  });

  group('tool rounds', () {
    test('the last round forces an answer instead of "limit reached"',
        () async {
      var call = 0;
      mockOpenAi((body) {
        call++;
        if (body['tool_choice'] == 'none') {
          return chatResponse(answer('Всё в порядке, статус зелёный.'));
        }
        return chatResponse({
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'id': 'call_$call',
              'type': 'function',
              'function': {'name': 'get_system_status', 'arguments': '{}'},
            }
          ],
        });
      });

      final result =
          await service.solve('всё ли в порядке с системой?', 'ru', false);

      expect(result['displayMessage'], 'Всё в порядке, статус зелёный.');
      expect(requests.map((r) => r['tool_choice']), ['auto', 'auto', 'none']);
    });
  });

  group('get_system_status', () {
    test('lists the problems, their fixes and where the approvals are', () {
      final payload = buildSystemStatusPayload(
        problems: [SystemProblem.riskyApprovals, SystemProblem.notificationsOff],
        riskyScans: const [
          RiskyScan('0x1234567890abcdef1234567890abcdef12345678', 56, 2),
        ],
      );

      expect(payload['isSafe'], isFalse);
      final problems = payload['problems'] as List;
      expect(problems.map((p) => p['problem']),
          ['riskyApprovals', 'notificationsOff']);
      expect(problems.first['fix'], contains('Открыть'));
      // Revoking is off only in a window the AI opened in Manual.
      expect(problems.first['fix'], contains('every AI mode'));
      expect(problems.first['fix'], isNot(contains('Безопасность / Паника')));
      expect(problems.last['fix'], contains('Разрешить'));
      expect(payload['riskyScans'], [
        {'network': 'BNB Chain', 'wallet': '0x1234…5678', 'count': 2},
      ]);
    });

    test('green when nothing is wrong', () {
      final payload =
          buildSystemStatusPayload(problems: const [], riskyScans: const []);

      expect(payload['isSafe'], isTrue);
      expect(payload['problems'], isEmpty);
      expect(payload['riskyScans'], isEmpty);
    });

    test('the tool reads the live status service', () async {
      await SystemStatusService.instance
          .recordScan('0xAbCdEf0000000000000000000000000000001234', 137, 3);

      final result =
          jsonDecode(await service.executeToolForTest('get_system_status'));

      expect(result['isSafe'], isFalse);
      expect((result['problems'] as List).first['problem'], 'riskyApprovals');
      expect(result['riskyScans'], [
        {'network': 'Polygon', 'wallet': '0xabcd…1234', 'count': 3},
      ]);
    });
  });

  group('scan_security_risks', () {
    test('says "not scanned yet" instead of "0 risks"', () async {
      final result =
          jsonDecode(await service.executeToolForTest('scan_security_risks'));

      expect(result['scanned_this_session'], isFalse);
      expect(result['status'], 'not_scanned_yet');
      expect(result.containsKey('risks'), isFalse);
      expect(result['saved_risky_results'], isEmpty);
    });

    test('still reports saved results of earlier scans', () async {
      await SystemStatusService.instance
          .recordScan('0x1111111111111111111111111111111111112222', 1, 1);

      final result =
          jsonDecode(await service.executeToolForTest('scan_security_risks'));

      expect(result['status'], 'not_scanned_yet');
      expect(result['saved_risky_results'], [
        {'network': 'Ethereum', 'wallet': '0x1111…2222', 'count': 1},
      ]);
    });

    test('reports the latest scan of this session', () {
      final payload = buildSafeScanPayload(
        lastScanAt: DateTime(2026, 11, 19, 12),
        lastScanApprovals: const [],
        savedRiskyScans: const [],
      );

      expect(payload['scanned_this_session'], isTrue);
      expect(payload.containsKey('status'), isFalse);
      expect(payload['last_scan']['approvals_checked'], 0);
      expect(payload['last_scan']['risky_found_by_scan'], 0);
      expect(payload['last_scan']['risky_not_revoked'], 0);
    });

    const wallet = '0xAbCdEf0000000000000000000000000000005678';

    ApprovalData approval({required bool risky, int chainId = 137}) =>
        ApprovalData(
          chainId: chainId,
          token: '0x${'1' * 40}',
          spenderAddress: '0x${'2' * 40}',
          spender: 'Spender',
          allowance: BigInt.one,
          walletAddress: wallet,
          assessment: ApprovalRiskAssessment(
            score: risky ? 90 : 0,
            label: risky ? RiskLabel.critical : RiskLabel.safe,
            shouldRevoke: risky,
            reasons: const [],
          ),
        );

    test('approvals revoked in the app are not reported as still risky', () {
      final scan = [
        approval(risky: true),
        approval(risky: true),
        approval(risky: false),
      ];

      // Both revoked: the status service has no entry left for the pair; an
      // entry of another network must not count.
      final allRevoked = buildSafeScanPayload(
        lastScanAt: DateTime(2026, 11, 19, 12),
        lastScanApprovals: scan,
        savedRiskyScans: [RiskyScan(wallet.toLowerCase(), 56, 4)],
      );
      expect(allRevoked['last_scan']['risky_found_by_scan'], 2);
      expect(allRevoked['last_scan']['risky_not_revoked'], 0);

      // One of two revoked.
      final oneLeft = buildSafeScanPayload(
        lastScanAt: DateTime(2026, 11, 19, 12),
        lastScanApprovals: scan,
        savedRiskyScans: [RiskyScan(wallet.toLowerCase(), 137, 1)],
      );
      expect(oneLeft['last_scan']['risky_found_by_scan'], 2);
      expect(oneLeft['last_scan']['risky_not_revoked'], 1);
    });

    test('the tool counts revokes recorded by the status service', () async {
      ApprovalScanService.lastScanTime = DateTime(2026, 11, 19, 12);
      ApprovalScanService.lastScannedApprovals = [
        approval(risky: true),
        approval(risky: true),
      ];
      // What the scan and then the in-app revoke record.
      await SystemStatusService.instance.recordScan(wallet, 137, 2);
      await SystemStatusService.instance.recordScan(wallet, 137, 0);

      final result =
          jsonDecode(await service.executeToolForTest('scan_security_risks'));

      expect(result['last_scan']['network'], 'Polygon');
      expect(result['last_scan']['risky_found_by_scan'], 2);
      expect(result['last_scan']['risky_not_revoked'], 0);
      expect(result['saved_risky_results'], isEmpty);
    });

    test('the "how to scan" path uses the Security tab labels', () {
      final payload = buildSafeScanPayload(
        lastScanAt: null,
        lastScanApprovals: const [],
        savedRiskyScans: const [],
      );

      expect(payload['note'], contains('«Safe/Panic»'));
      expect(payload['note'], isNot(contains('«Безопасность / Паника»')));
    });
  });

  group('tool routing hint', () {
    test('the status card goes to get_system_status, not get_vault_info', () {
      for (final q in [
        'почему карточка статуса красная?',
        'Карточка статуса системы красная, что не так?',
        'почему карточка опасно показывает?',
        'что показывает статус системы',
        'why is the status card red?',
      ]) {
        final hint = OpenAIChatService.toolHintFor(q);
        expect(hint, contains('get_system_status'), reason: q);
        expect(hint, isNot(contains('You MUST call get_vault_info')),
            reason: q);
      }
    });

    test('wallet card questions still go to get_vault_info', () {
      for (final q in [
        'сколько у меня карточек?',
        'how many cards do I have',
        'прекрасно, а сколько карточек у меня?',
        'безопасно ли выпустить ещё одну карту?',
      ]) {
        expect(OpenAIChatService.toolHintFor(q), contains('get_vault_info'),
            reason: q);
      }
    });
  });

  group('rememberTurn', () {
    test('a canned answer is context for the next LLM turn', () async {
      service.rememberTurn(
        user: 'Что такое Safe Scan?',
        assistant: 'Safe Scan проверяет разрешения ваших токенов.',
      );
      mockOpenAi((_) => chatResponse(answer('Чтобы никто не списал токены.')));

      await service.solve('а зачем?', 'ru', false);

      final messages = (requests.single['messages'] as List).cast<Map>();
      expect(messages[1]['role'], 'user');
      expect(messages[1]['content'], 'Что такое Safe Scan?');
      expect(messages[2]['role'], 'assistant');
      final remembered = jsonDecode(messages[2]['content'] as String) as Map;
      expect(remembered['displayMessage'],
          'Safe Scan проверяет разрешения ваших токенов.');
      // Stored once: no speechText copy of the same text.
      expect(remembered.containsKey('speechText'), isFalse);
      expect(messages.last['content'], 'а зачем?');
    });

    test('a long canned answer is cut at 1500 characters', () {
      service.rememberTurn(user: 'список', assistant: 'x' * 2000);

      final stored =
          jsonDecode(service.historyForTest.last['content'] as String) as Map;
      expect(stored['displayMessage'], '${'x' * 1500}…');
      expect(stored.containsKey('speechText'), isFalse);
    });

    test('keeps the same cap and ignores empty turns', () {
      for (var i = 0; i < 10; i++) {
        service.rememberTurn(user: 'q$i', assistant: 'a$i');
      }
      service.rememberTurn(user: '', assistant: 'x');
      service.rememberTurn(user: 'y', assistant: '  ');

      final history = service.historyForTest;
      expect(history, hasLength(12));
      expect(history.first['content'], 'q4');
      expect(history.last['content'], contains('a9'));
    });
  });

  group('app guide', () {
    test('covers the features users ask about, briefly', () {
      const guide = AppGuide.text;
      for (final fact in [
        'Safe Scan',
        '«Статус системы»',
        '«Выпустить',
        '«Лимит апрув»',
        '«Блокировать неизвестные контракты»',
        'EPK',
        'info@ibiticoin.com',
        '«Результаты отзыва»',
        // AI mode names as AI-Центр shows them (RU, then EN).
        '«Советник»',
        '«Ручной»',
        '«Автономный»',
        'Advisor',
        'Manual',
        'Autonomous',
        // The AI PIN setting, its notification and exchange orders in history.
        '«Подтверждать действия ИИ ПИН-кодом»',
        '«ИИ выполнил: …»',
        '«Биржа»',
        '«Делегировать AI»',
        '«Остановить AI»',
        '«AI Мандат»',
        '«Безопасность»',
        '«Язык»',
        '«Браузер dApp»',
        '«Safe/Panic»',
        '«Журнал контроля»',
      ]) {
        expect(guide, contains(fact), reason: fact);
      }
      expect(guide.trim().split('\n').length, lessThanOrEqualTo(100));
    });

    test('states the AI mode rules the owner decided', () {
      final guide = AppGuide.text.replaceAll(RegExp(r'\s+'), ' ');
      for (final fact in [
        // «Советник» only advises; the user's own actions work in every mode.
        'the AI only advises and explains',
        'Your own actions work in every mode',
        // «Ручной»: the user confirms with the PIN.
        'you confirm with the PIN',
        // «Автономный» without the PIN: limits, mandate, EPK, trusted only.
        'only within the daily trading limit and «AI Мандат», EPK active, '
            'to trusted addresses or own cards',
        // A new address or a locked wallet still gets the card + PIN.
        '(new address, locked wallet) the card + PIN',
        // An unknown USD price: the AI never does it itself, in either PIN
        // setting; the user confirms it in the filled window (D17).
        'Unknown USD price (a coin without a price), PIN setting on or off: '
            'the AI does not do it itself; the filled wallet window opens, '
            'you confirm (PIN).',
        // A paused EPK: nothing on-chain; an AI exchange order asks first.
        'Paused EPK: the AI does nothing on-chain (revoking aside); its '
            'exchange orders get card + PIN.',
        // Limits hold in every mode; raising one needs the PIN.
        'the AI never goes over a limit',
        'raise it in «Политика» (PIN)',
        // AI-opened Safe/Panic.
        '«Ручной» = your tap + PIN',
        // Selling all always shows the order window.
        'selling all or part of a balance always opens the order window',
        // The EPK screen can pause EPK too (with the PIN).
        'pause EPK (in Policy or on the EPK screen)',
      ]) {
        expect(guide, contains(fact), reason: fact);
      }
    });

    test('drops the claims the code does not back', () {
      const guide = AppGuide.text;
      for (final wrong in [
        // The Safe/Panic screen is reached from the «Safe/Panic» tile.
        '«Безопасность / Паника»',
        // Nothing in the code gives the PRO tag a meaning.
        'card tiers',
        '«PRO»',
        // Revoking is off only in a window the AI opened in «Советник».
        'revoke button is off',
        // Not every loosening asks the PIN (e.g. max gas).
        'loosening',
        // The old mode names.
        'Guarded',
        'Full Autonomy',
        '«Руководство»',
        '«Охраняемый»',
        '«Полная автономия»',
        // «Советник» no longer blocks the user's own exchange orders.
        'your own too',
        // «Делегировать AI» now runs in «Автономный».
        'never signs',
        // Exchange orders no longer skip the PIN by default.
        'without it, inside the daily trading limit',
        // An unknown price never gets the card: the filled window opens.
        'unknown price) the card',
      ]) {
        expect(guide, isNot(contains(wrong)), reason: wrong);
      }
    });
  });

  group('AI mode and the AI PIN setting in the prompt', () {
    Future<String> systemPrompt({bool allowActionTools = false}) async {
      mockOpenAi((_) => chatResponse(answer('Готово.')));
      await service.solve('какой режим?', 'ru', allowActionTools);
      final messages = requests.last['messages'] as List;
      return messages.first['content'] as String;
    }

    List<String> toolNames() => (requests.last['tools'] as List)
        .map((t) => t['function']['name'] as String)
        .toList();

    test('«Ручной»: the mode as the user sees it, PIN confirmation ON',
        () async {
      final system = await systemPrompt();

      expect(system, contains('Current AI mode: «Ручной» (Manual).'));
      expect(system, contains('AI action PIN confirmation: ON'));
      expect(system, contains('- AI mode: «Ручной» (Manual): prepare'));
      expect(system, contains('AI MODES: WHAT YOU MAY DO'));
      expect(system, isNot(contains('Guarded')));
      expect(system, isNot(contains('Full Autonomy')));
      expect(system, isNot(contains('AI can open screens, open modals')));
    });

    test('«Автономный» with the PIN setting ON', () async {
      AiControlService.instance.setSettingsForTest(
          const AiControlSettings(mode: AiMode.fullAutonomy));

      final system = await systemPrompt();

      expect(system, contains('Current AI mode: «Автономный» (Autonomous).'));
      expect(
          system,
          contains('AI action PIN confirmation: ON (every AI action shows a '
              'card and asks the PIN first; one with an unknown USD value '
              'opens in the filled wallet window instead)'));
    });

    test('«Автономный» with the PIN setting OFF: the limits still hold',
        () async {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
          mode: AiMode.fullAutonomy, aiPinConfirm: false));

      final system = await systemPrompt();

      expect(system, contains('AI action PIN confirmation: OFF'));
      expect(system, contains('to trusted addresses or own cards'));
      expect(system, contains('«ИИ выполнил»'));
      expect(system, isNot(contains('AI action PIN confirmation: ON')));
      // D6 as the code runs it: a new address / a locked wallet / an
      // exchange order with EPK paused → card + PIN; an unknown USD value →
      // the filled wallet window for the user (never a card, never the AI).
      expect(
          system,
          contains('a new address, a locked wallet or an exchange order '
              'while EPK is paused = card + PIN'));
      expect(
          system,
          contains('an unknown USD value = the filled wallet window for the '
              'user, never you'));
      expect(system, isNot(contains('with a known USD value; otherwise')));
    });

    test('pinConfirmationLabel: the setting counts only in «Автономный»', () {
      for (final mode in [AiMode.manual, AiMode.guarded]) {
        final label = OpenAIChatService.pinConfirmationLabel(
            AiControlSettings(mode: mode, aiPinConfirm: false));
        expect(label, startsWith('ON'), reason: mode.name);
      }
      expect(
          OpenAIChatService.pinConfirmationLabel(const AiControlSettings(
              mode: AiMode.fullAutonomy, aiPinConfirm: false)),
          startsWith('OFF'));
    });

    test('the rules: refuse over a limit and say how to raise it', () {
      const rules = OpenAIChatService.aiModeRules;
      for (final rule in [
        '«Советник» (Advisor): ONLY advise and explain',
        'watchlist entries, price',
        '«Ручной» (Manual): prepare only',
        'never exceed a limit or go around Policy, «AI Мандат» or EPK',
        'refuse it, name the limit and its value',
        'raises it in «Политика» (Security → Policy) with',
        'Never suggest splitting an order',
        'Never say an operation is done',
        // D6 as the code runs it (no card, else the card + PIN).
        'with the app open and the wallet unlocked; a new address, a locked '
            'wallet, or an exchange order while EPK is paused gets the card '
            '+ PIN',
        'While EPK is paused nothing on-chain is carried out',
        // An unknown USD value: never the AI, never a card (D17).
        'Never carry out yourself an operation whose USD value is unknown',
        'PIN confirmation ON or OFF: the app opens the filled wallet window '
            'and the user confirms it there with the PIN',
        'Never promise a card for it',
      ]) {
        expect(rules.replaceAll(RegExp(r'\s+'), ' '), contains(rule),
            reason: rule);
      }
      // The old rule promised the card + PIN for an unknown value.
      expect(rules.replaceAll(RegExp(r'\s+'), ' '),
          isNot(contains('with a known USD value; otherwise the card + PIN')));
    });

    test('«Советник» offers no action tools, even in an action turn',
        () async {
      AiControlService.instance.setSettingsForTest(
          const AiControlSettings(mode: AiMode.manual, allowedActions: []));

      final system = await systemPrompt(allowActionTools: true);

      expect(system, contains('Current AI mode: «Советник» (Advisor).'));
      expect(system, contains('- AI mode: «Советник» (Advisor): advise only'));
      final names = toolNames();
      for (final action in [
        'panic_revoke_all',
        'safe_revoke_review',
        'manage_watchlist',
      ]) {
        expect(names, isNot(contains(action)), reason: action);
      }
      expect(names, containsAll(['get_wallet_balance', 'get_system_status']));
    });

    test('«Ручной» still offers the action tools in an action turn', () async {
      await systemPrompt(allowActionTools: true);

      expect(
          toolNames(),
          containsAll(
              ['panic_revoke_all', 'safe_revoke_review', 'manage_watchlist']));
    });

    test('«Советник»: a watchlist call is refused and a send never leaves',
        () async {
      AiControlService.instance.setSettingsForTest(
          const AiControlSettings(mode: AiMode.manual, allowedActions: []));
      var call = 0;
      mockOpenAi((body) {
        call++;
        if (call == 1) {
          return chatResponse({
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {
                  'name': 'manage_watchlist',
                  'arguments': jsonEncode({'action': 'add', 'symbol': 'SOL'}),
                },
              }
            ],
          });
        }
        return chatResponse({
          'role': 'assistant',
          'content': jsonEncode({
            'displayMessage': 'В режиме «Советник» я только советую.',
            'speechText': 'Я только советую.',
            'uiCommands': [
              {'type': 'openModal', 'target': 'wallet_send'}
            ],
            'explicitIntent': {'type': 'sendAsset'},
          }),
        });
      });

      final result = await service.solve('добавь SOL в отслеживание', 'ru');

      final toolMessage = (requests.last['messages'] as List)
          .cast<Map>()
          .firstWhere((m) => m['role'] == 'tool');
      final toolResult = jsonDecode(toolMessage['content'] as String) as Map;
      expect(toolResult['error'], contains('«Советник»'));
      expect(toolResult['error'], contains('only advises'));
      expect(result.containsKey('uiCommands'), isFalse);
      expect(result['explicitIntent']['type'], 'explainOnly');
      expect(result['explicitIntent']['reason'], contains('«Советник»'));
    });
  });
}
