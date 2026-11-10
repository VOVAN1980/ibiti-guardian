import 'package:flutter/material.dart';
import 'package:ibiti_guardian/screens/security/policy_limits_screen.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

/// A market trade on an exchange needs its API key connected and the
/// exchange switched on as a funding source in Policy. If either is
/// missing, Policy opens at Funding sources, where tapping the exchange
/// connects the key and switches it on. Returns true once both are in
/// place (after the user comes back), so the caller can go on to the trade.
Future<bool> ensureExchangeReady(BuildContext context, String exchangeId) async {
  final connected = await ExchangeAccountStore.instance.isConnected(exchangeId);
  if (connected && _isOn(exchangeId)) return true;
  if (!context.mounted) return false;

  final name = _displayName(exchangeId);
  final isRu = Localizations.localeOf(context).languageCode == 'ru';
  final hint = connected
      ? (isRu
          ? 'Включите $name в «Источнике средств», затем нажмите «Назад».'
          : 'Switch $name on under Funding sources, then go back.')
      : (isRu
          ? 'Нажмите $name в «Источнике средств», чтобы подключить API-ключ. '
              'После этого нажмите «Назад».'
          : 'Tap $name under Funding sources to connect the API key, '
              'then go back.');

  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => PolicyLimitsScreen(focusHint: hint),
  ));

  return await ExchangeAccountStore.instance.isConnected(exchangeId) &&
      _isOn(exchangeId);
}

bool _isOn(String exchangeId) =>
    AiControlService.instance.settings.activeSources.contains(exchangeId);

String _displayName(String exchangeId) => switch (exchangeId) {
      'gateio' => 'Gate.io Spot',
      'mexc' => 'MEXC Spot',
      'binance' => 'Binance Spot',
      'okx' => 'OKX Spot',
      _ => exchangeId,
    };
