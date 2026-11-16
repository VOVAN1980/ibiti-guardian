import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/app_settings.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/screens/security/ai_trust_actions.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/services/assistant/guardian_assistant_service.dart';
import 'package:ibiti_guardian/services/assistant/openai_chat_service.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_resolver.dart';
import 'package:ibiti_guardian/services/intents/intent_parser.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/policy/trusted_address_directory.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/wallet/address_book_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The assistant knows the trusted addresses (AI whitelist) the way it knows
/// the address book: it lists them, opens their screen when asked, and never
/// changes them — only the owner can, with the PIN.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The address book keeps checksummed addresses; the whitelist lower case.
  const mexc = '0x195898373cC0c85F7fE7b325C3fE0e1FfF701383';
  const stranger = '0x2222222222222222222222222222222222222222';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService.instance.settingsForTest = AppSettings(
      openaiApiKey: null,
      isNeuralOperatorEnabled: false,
    );
    await AddressBookService.instance.add('MEXC', mexc);
  });

  setUp(() async {
    AiControlService.instance.setSettingsForTest(
      const AiControlSettings(
        mode: AiMode.guarded,
        allowedActions: [AiAction.openWindows],
      ),
    );
    await PolicyProfileStore.instance.addTrustedAddress(mexc);
  });

  tearDown(() async {
    for (final a in [...PolicyProfileStore.instance.current.trustedAddresses]) {
      await PolicyProfileStore.instance.removeTrustedAddress(a);
    }
  });

  Future<dynamic> ask(String text,
          {AssistantInputSource source = AssistantInputSource.voice}) =>
      GuardianAssistantService.instance
          .process(text, languageCode: 'ru', source: source);

  bool opensTrusted(List<UICommand> commands) => commands.any((c) =>
      c.type == UICommandType.openModal && c.target == 'trusted_addresses');

  test('a question lists them by address-book name and opens nothing',
      () async {
    final r = await ask('Какие у меня доверенные адреса?');
    expect(r.message, contains('MEXC'));
    expect(r.message, contains('(1)'));
    expect(r.uiCommands, isEmpty);
  });

  test('"open trusted addresses" opens their screen', () async {
    final r = await ask('открой доверенные адреса',
        source: AssistantInputSource.generalChat);
    expect(opensTrusted(r.uiCommands), true);
    expect(r.message, contains('MEXC'));
  });

  test('without the open-windows permission it still answers, no window',
      () async {
    AiControlService.instance.setSettingsForTest(
      const AiControlSettings(mode: AiMode.manual, allowedActions: []),
    );
    final r = await ask('открой доверенные адреса',
        source: AssistantInputSource.generalChat);
    expect(r.uiCommands, isEmpty);
    expect(r.message, contains('MEXC'));
  });

  test('asking to add an address is refused and changes nothing', () async {
    for (final text in [
      'добавь $stranger в белый список',
      'внеси этот адрес в доверенные адреса',
    ]) {
      final r = await ask(text, source: AssistantInputSource.generalChat);
      expect(r.message, contains('ПИН'));
      expect(PolicyProfileStore.instance.current.trustedAddresses,
          [mexc.toLowerCase()]);
    }
  });

  test('"how many" and "allowed addresses" are about the whitelist', () async {
    final count = await ask('сколько у меня доверенных адресов');
    expect(count.message, contains('Доверенные адреса (1)'));

    final allowed = await ask('какие адреса разрешены');
    expect(allowed.message, contains('MEXC'));
    expect(allowed.message, isNot(contains('Лимит одного перевода')));
  });

  test('plain questions about the list are answered, not refused', () async {
    for (final text in [
      'Что изменилось в доверенных адресах?',
      'Кто удалил адрес из белого списка?',
      'Ты переводишь исключительно на доверенные адреса?',
      'кому ты можешь переводить?',
    ]) {
      final r = await ask(text);
      expect(r.message, contains('MEXC'), reason: text);
      expect(r.message, isNot(contains('не могу')), reason: text);
    }
  });

  test('change requests show the list and say only the owner changes it',
      () async {
    for (final text in [
      'удали mexc из белого списка',
      'Guardian, add mexc to trusted addresses',
      'сделай этот адрес доверенным',
      'исключи адрес из белого списка',
    ]) {
      final r = await ask(text, source: AssistantInputSource.generalChat);
      expect(r.message, contains('ПИН'), reason: text);
      expect(r.message, contains('MEXC'), reason: text);
    }
    expect(PolicyProfileStore.instance.current.trustedAddresses,
        [mexc.toLowerCase()]);
  });

  test('"отзови все разрешения" is not taken for a limits question', () {
    final s = GuardianAssistantService.instance;
    // The limits answer used to catch it through "разрешен".
    expect(s.isLimitsStatusQuestionForTest('отзови все разрешения'), false);
    expect(s.isLimitsStatusQuestionForTest('revoke all approvals'), false);
    expect(s.isLimitsStatusQuestionForTest('какие у тебя лимиты'), true);
    expect(s.isLimitsStatusQuestionForTest('что тебе разрешено'), true);
  });

  test('a limits question keeps the full limits answer', () async {
    final r = await ask('Какие лимиты на переводы на доверенные адреса?');
    expect(r.message, contains('Лимит одного перевода'));
  });

  test('"хочу отправить 20 USDT на доверенный адрес" stays a transfer', () {
    // The trusted answer steps aside for anything the parser reads as a
    // money action, so the send flow still prepares the transfer.
    const text = 'хочу отправить 20 USDT на доверенный адрес MEXC';
    expect(IntentParser.parse(text).isExecutionIntent, true);
  });

  test('an address kept as a trusted contract by an older build is trusted',
      () async {
    const legacy = '0xC0ffEE0000000000000000000000000000000001';
    await PolicyProfileStore.instance.addTrustedContract(legacy);
    expect(AiTrustActions.isTrusted(legacy), true);
    await PolicyProfileStore.instance.removeTrustedContract(legacy);
    expect(AiTrustActions.isTrusted(legacy), false);
  });

  test('a live token detail underneath does not hide the trusted screen', () {
    final ctx = ScreenContextService.instance;
    ctx.setScreen('market');
    ctx.setFocusedToken('BTC', price: 1);
    ctx.setSubScreen('trusted_addresses');
    ctx.setFocusedToken('BTC', price: 2); // the ticker keeps updating
    final prompt = ctx.buildContextPrompt();
    expect(prompt, contains('Trusted addresses'));
    expect(prompt, isNot(contains('Focused token')));

    ctx.setSubScreen('address_book'); // address book opened on top
    expect(ctx.buildContextPrompt(), contains('Address book'));
    ctx.clearSubScreen('address_book');
    expect(ctx.activeSubScreen, 'trusted_addresses');
    ctx.clearSubScreen('trusted_addresses');
    expect(ctx.activeSubScreen, 'token_detail');
  });

  test('a transfer to a trusted address is not taken for a list question',
      () {
    // The trusted answer starts with this rule, so the transfer keeps its
    // normal send flow (the full flow needs audio plugins absent in tests).
    expect(
        UICommandResolver.mentionsTrustedList(
            'отправь 5 usdt на доверенный адрес mexc'),
        false);
  });

  test('the chat model gets names, short and full addresses, read-only', () {
    final payload = buildTrustedAddressesPayload(
      PolicyProfileStore.instance.current,
      TrustedAddressDirectory.current(),
    );
    final first = (payload['trusted'] as List).single as Map;
    expect(first['label'], 'MEXC');
    expect(first['full_address'], mexc.toLowerCase());
    expect(first['address'], '0x1958...1383');
    expect(payload['ai_can_modify'], false);
    expect(payload['strict'],
        PolicyProfileStore.instance.current.mode == PolicyMode.safe);
  });

  test('a trusted Solana address is shown and copied exactly as written',
      () {
    const sol = '7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2';
    final items = TrustedAddressDirectory.build(
      const PolicyProfile(
        mode: PolicyMode.safe,
        sendLimitUsd: 50,
        swapLimitUsd: 50,
        approveLimitUsd: 50,
        allowUnknownContracts: false,
        trustedAddresses: [sol],
      ),
      const [AddressEntry(label: 'Phantom', address: sol)],
    );
    expect(items.single.address, sol);
    expect(items.single.label, 'Phantom');
  });

  test('an address missing from the book is listed by its short form', () {
    final items = TrustedAddressDirectory.build(
      const PolicyProfile(
        mode: PolicyMode.safe,
        sendLimitUsd: 50,
        swapLimitUsd: 50,
        approveLimitUsd: 50,
        allowUnknownContracts: false,
        trustedAddresses: [stranger],
        trustedContracts: ['0xc0ffee0000000000000000000000000000000001'],
      ),
      const [],
    );
    expect(items.first.label, isNull);
    expect(items.first.displayName, '0x2222...2222');
    expect(items.last.isContract, true);
  });

  test('the assistant knows when the trusted screen is open', () {
    final ctx = ScreenContextService.instance;
    ctx.setScreen('security');
    ctx.setSubScreen('trusted_addresses');
    expect(ctx.buildContextPrompt(), contains('Trusted addresses'));

    ctx.clearSubScreen('token_detail'); // another screen closing: no effect
    expect(ctx.activeSubScreen, 'trusted_addresses');
    ctx.clearSubScreen('trusted_addresses');
    expect(ctx.activeSubScreen, isNull);
  });
}
