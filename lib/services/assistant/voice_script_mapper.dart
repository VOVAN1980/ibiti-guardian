import 'package:ibiti_guardian/models/tx_status.dart';
import 'package:ibiti_guardian/services/assistant/language_detector.dart';

/// Generates clean, human-readable TTS phrases for every execution event.
///
/// **Contract:**
/// - These phrases are the ONLY source of speech content.
/// - They are NEVER derived from display messages or technical strings.
/// - No markdown, no hex addresses, no "route", "tx", "calldata" jargon.
/// - Language is fixed per call — never mixed.
///
/// Usage:
/// ```dart
/// final voice = VoiceScriptMapper.forLang(lang);
/// response.speechText = voice.swapSent();
/// ```
class VoiceScriptMapper {
  final bool _ru;

  const VoiceScriptMapper._(this._ru);

  /// Pick a variant from a pool based on current time (cheap pseudo-random).
  static String _pick(List<String> pool) =>
      pool[DateTime.now().millisecond % pool.length];

  /// Select mapper for the detected user language code ('ru' → Russian, else English).
  factory VoiceScriptMapper.forLang(String? languageCode) =>
      VoiceScriptMapper._(languageCode == 'ru');

  // ── Send ──────────────────────────────────────────────────────────────────

  String sendSent() => _ru
      ? _pick(const [
          'Перевод ушёл. Жду подтверждение.',
          'Отправлено. Сеть обрабатывает.',
          'Перевод в пути.'
        ])
      : _pick(const [
          'Transfer sent. Awaiting confirmation.',
          'Sent. Network is processing.',
          'Transfer on its way.'
        ]);

  String sendConfirmed() => _ru
      ? _pick(const [
          'Перевод прошёл.',
          'Готово, перевод выполнен.',
          'Перевод доставлен.'
        ])
      : _pick(const [
          'Transfer confirmed.',
          'Done, transfer complete.',
          'Transfer delivered.'
        ]);

  String sendFailed() => _ru
      ? _pick(const [
          'Перевод не прошёл.',
          'К сожалению, перевод не выполнен.',
          'Не удалось выполнить перевод.'
        ])
      : _pick(const [
          'Transfer failed.',
          'Unfortunately, the transfer didn\'t go through.',
          'Transfer could not be completed.'
        ]);

  // ── Approve ───────────────────────────────────────────────────────────────

  String approveSent() => _ru ? 'Разрешение выдано.' : 'Approval sent.';

  String revokeSent() => _ru ? 'Разрешение отозвано.' : 'Approval revoked.';

  // ── Swap ──────────────────────────────────────────────────────────────────

  String swapSent() => _ru
      ? _pick(const [
          'Обмен запущен. Жду подтверждение.',
          'Обмен отправлен, сеть обрабатывает.',
          'Обмен в процессе.'
        ])
      : _pick(const [
          'Swap initiated. Awaiting confirmation.',
          'Swap sent, network processing.',
          'Swap in progress.'
        ]);

  String swapConfirmed({String? receivedAmount, String? tokenSymbol}) {
    if (_ru) {
      if (receivedAmount != null && tokenSymbol != null) {
        return 'Обмен выполнен. Вы получили $receivedAmount $tokenSymbol.';
      }
      return 'Обмен выполнен.';
    }
    if (receivedAmount != null && tokenSymbol != null) {
      return 'Swap complete. You received $receivedAmount $tokenSymbol.';
    }
    return 'Swap complete.';
  }

  String swapFailed() => _ru
      ? _pick(const [
          'Обмен не прошёл.',
          'К сожалению, обмен не выполнен.',
          'Не удалось завершить обмен.'
        ])
      : _pick(const [
          'Swap failed.',
          'Unfortunately, the swap didn\'t complete.',
          'Swap could not be executed.'
        ]);

  String swapNoRoute() => _ru
      ? 'Маршрут не найден. Попробуйте другую сумму.'
      : 'No route found. Try a different amount.';

  // ── Policy blocks ─────────────────────────────────────────────────────────

  String policyBlocked() =>
      _ru ? 'Операция заблокирована.' : 'Operation blocked.';

  String policyLimitExceeded() => _ru
      ? 'Операция заблокирована. Превышен лимит.'
      : 'Operation blocked. Limit exceeded.';

  String policySlippageTooHigh() => _ru
      ? 'Операция заблокирована. Слишком высокое проскальзывание.'
      : 'Operation blocked. Slippage too high.';

  String policyAddressBlocked() => _ru
      ? 'Операция заблокирована. Адрес в списке ограничений.'
      : 'Operation blocked. Address is restricted.';

  // ── Tx lifecycle (for TxStatusPoller callbacks) ───────────────────────────

  String txSubmitted() => _ru
      ? _pick(const [
          'Транзакция отправлена.',
          'Отправлено в сеть.',
          'Транзакция ушла.'
        ])
      : _pick(const [
          'Transaction sent.',
          'Submitted to network.',
          'Transaction dispatched.'
        ]);

  String txConfirmed({String? assetLabel}) {
    if (_ru) {
      return assetLabel != null
          ? 'Готово. Вы получили $assetLabel.'
          : 'Транзакция подтверждена.';
    }
    return assetLabel != null
        ? 'Done. You received $assetLabel.'
        : 'Transaction confirmed.';
  }

  String txFailed() => _ru ? 'Транзакция не прошла.' : 'Transaction failed.';

  String txTimeout() => _ru
      ? 'Подтверждение не получено. Проверьте обозреватель блоков.'
      : 'Confirmation timeout. Check the explorer.';

  // ── Informational ─────────────────────────────────────────────────────────

  String balanceFetched(String totalUsd) => _ru
      ? 'Ваш портфель: $totalUsd долларов.'
      : 'Your portfolio: $totalUsd dollars.';

  String noBalance() => _ru ? 'Активы не найдены.' : 'No assets found.';

  String scanClean() => _ru
      ? 'Угроз не обнаружено. Активы под защитой.'
      : 'No threats found. Assets are protected.';

  String scanThreats(int count) =>
      _ru ? 'Обнаружено $count угроз.' : '$count threats found.';

  String rejected() => _ru ? 'Операция отменена.' : 'Operation cancelled.';

  // ── TxRegistry integration ────────────────────────────────────────────────

  /// Generate a voice phrase directly from a [TxStatusEvent].
  ///
  /// This is the canonical bridge between [TxRegistry] and the TTS engine.
  /// Call this instead of [txConfirmed]/[txFailed] to automatically include
  /// operation context (e.g. "Swap USDT → ETH completed.").
  String fromTxEvent(TxStatusEvent event, {String? assetLabel}) {
    final op = event.operationLabel;
    switch (event.status) {
      case TxStatus.submitted:
        return op != null
            ? (_ru
                ? '$op. Жду подтверждения.'
                : '$op. Waiting for confirmation.')
            : txSubmitted();
      case TxStatus.pending:
        return _ru ? 'Жду подтверждения.' : 'Waiting for confirmation.';
      case TxStatus.confirmed:
        if (op != null && assetLabel != null) {
          return _ru
              ? '$op завершено. Вы получили $assetLabel.'
              : '$op completed. You received $assetLabel.';
        }
        if (op != null) {
          return _ru ? '$op завершено.' : '$op completed.';
        }
        return txConfirmed(assetLabel: assetLabel);
      case TxStatus.failed:
        if (op != null) {
          return _ru ? '$op не выполнено.' : '$op failed.';
        }
        return txFailed();
      case TxStatus.timeout:
        return txTimeout();
    }
  }
}

/// Detects language from raw input. Delegates to [LanguageDetector.detect].
/// Kept as a top-level function for backward compatibility with callers.
String detectLangFromText(String? rawInput) {
  if (rawInput == null || rawInput.isEmpty) return 'en';
  return LanguageDetector.detect(rawInput);
}

// ── TxStatusEvent import helper ──────────────────────────────────────────────
// (TxStatusEvent is in models/tx_status.dart — import it in callers)
