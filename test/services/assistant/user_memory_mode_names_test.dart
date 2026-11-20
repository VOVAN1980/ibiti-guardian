// The built-in voice macro «эвакуация» shows the AI mode by the name the
// user sees: «Советник» (code name manual). It used to say "переключить на
// Manual", and "Manual" is now the name of «Ручной» (code name guarded), so
// a saved copy of the old text is replaced on load. Only the text changes:
// the macro still switches to AiMode.manual.
//
// Run: flutter test test/services/assistant/user_memory_mode_names_test.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/user_memory.dart';
import 'package:ibiti_guardian/services/assistant/user_memory_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _evacuationActions = [
  MacroAction(type: MacroActionType.openModal, target: 'panic'),
  MacroAction(type: MacroActionType.executeAction, target: 'revoke_all'),
  MacroAction(type: MacroActionType.switchMode, target: 'manual'),
];

VoiceMacro _evacuation(UserMemoryService memory) => memory.allMacros
    .firstWhere((m) => m.triggerPhrase == 'эвакуация');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final memory = UserMemoryService.instance;

  test('a fresh install names the mode «Советник»', () async {
    SharedPreferences.setMockInitialValues({});
    await memory.clearAll();

    final m = _evacuation(memory);
    expect(m.description, UserMemoryService.evacuationDescription);
    expect(m.description, contains('режим «Советник»'));
    expect(m.description, isNot(contains('Manual')));
    expect(m.actions.last.type, MacroActionType.switchMode);
    expect(m.actions.last.target, 'manual');
  });

  test('a saved macro with the old mode name is shown with the new one',
      () async {
    final saved = VoiceMacro(
      triggerPhrase: 'эвакуация',
      description: UserMemoryService.legacyEvacuationDescription,
      actions: _evacuationActions,
      requiresConfirmation: true,
      isRisky: true,
      createdAt: DateTime(2025, 1, 1),
    );
    SharedPreferences.setMockInitialValues({
      'user_memory_macros': jsonEncode([saved.toJson()]),
    });
    await memory.init();

    final m = _evacuation(memory);
    expect(m.description, UserMemoryService.evacuationDescription);
    expect(m.description, isNot(contains('Manual')));
    // Everything else is kept as saved.
    expect(m.actions.map((a) => a.target).toList(),
        ['panic', 'revoke_all', 'manual']);
    expect(m.requiresConfirmation, isTrue);
    expect(m.isRisky, isTrue);
    expect(m.createdAt, DateTime(2025, 1, 1));
    expect(m.allowedModes, saved.allowedModes);
  });

  test("the user's own macro text is never rewritten", () async {
    final own = VoiceMacro(
      triggerPhrase: 'мой выход',
      description: 'Panic → переключить на Manual (мой текст)',
      actions: _evacuationActions,
      createdAt: DateTime(2025, 6, 1),
    );
    SharedPreferences.setMockInitialValues({
      'user_memory_macros': jsonEncode([own.toJson()]),
    });
    await memory.init();

    final m =
        memory.allMacros.firstWhere((m) => m.triggerPhrase == 'мой выход');
    expect(m.description, own.description);
  });
}
