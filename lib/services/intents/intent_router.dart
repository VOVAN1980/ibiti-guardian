import 'package:ibiti_guardian/models/intent_data.dart';

/// Routes a parsed [IntentData] to an [IntentAction].
///
/// ⚠️ CRITICAL RULE: IntentRouter does NOT call any adapters or services.
/// It ONLY decides what should happen and returns an [IntentAction].
/// Actual execution is delegated to [GuardianExecutionService].
class IntentRouter {
  IntentRouter._();

  /// Classify the intent and return an [IntentAction] describing what to do.
  static IntentAction route(IntentData intent) {
    switch (intent.type) {
      // ——— Informational: no execution, no confirmation needed ———————————
      case IntentType.showBalances:
        return IntentAction(
          intent: intent,
          requiresExecution: false,
          requiresConfirmation: false,
        );

      case IntentType.showAddress:
      case IntentType.receiveAsset:
      case IntentType.showHistory:
      case IntentType.showWalletCards:
      case IntentType.openAddressBook:
      case IntentType.openWalletSettings:
      case IntentType.openMarket:
      case IntentType.openSecurityCenter:
        return IntentAction(
          intent: intent,
          requiresExecution: false,
          requiresConfirmation: false,
        );

      case IntentType.showRisks:
        return IntentAction(
          intent: intent,
          requiresExecution: false,
          requiresConfirmation: false,
        );

      // ——— Scan: triggers security scan — execution required, no confirmation
      case IntentType.scanApprovals:
        return IntentAction(
          intent: intent,
          requiresExecution: true,
          requiresConfirmation: false,
        );

      // ——— Revoke: modifies state — execution + confirmation required ———
      case IntentType.revokeApproval:
        return IntentAction(
          intent: intent,
          requiresExecution: true,
          requiresConfirmation: true,
        );

      // ——— Send: moves funds — execution + confirmation always required ——
      case IntentType.sendAsset:
        return IntentAction(
          intent: intent,
          requiresExecution: true,
          requiresConfirmation: true,
        );

      // ——— Swap: swap asset — execution + confirmation always required ———
      case IntentType.swapAsset:
        return IntentAction(
          intent: intent,
          requiresExecution: true,
          requiresConfirmation: true,
        );

      case IntentType.buyAsset:
      case IntentType.sellAsset:
        return IntentAction(
          intent: intent,
          requiresExecution: true,
          requiresConfirmation: true,
        );

      // ——— Unknown: return a non-execution action ————————————————————————
      case IntentType.unknown:
        return IntentAction(
          intent: intent,
          requiresExecution: false,
          requiresConfirmation: false,
        );
    }
  }
}
