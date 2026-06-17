import 'package:flutter/material.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

class ConnectExchangeModal extends StatefulWidget {
  final String exchangeId;
  final VoidCallback? onConnected;

  const ConnectExchangeModal({
    super.key,
    required this.exchangeId,
    this.onConnected,
  });

  static void show(
    BuildContext context, {
    required String exchangeId,
    VoidCallback? onConnected,
  }) {
    showDialog(
      context: context,
      useSafeArea: true,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: SingleChildScrollView(
          child: ConnectExchangeModal(
            exchangeId: exchangeId,
            onConnected: onConnected,
          ),
        ),
      ),
    );
  }

  @override
  State<ConnectExchangeModal> createState() => _ConnectExchangeModalState();
}

class _ConnectExchangeModalState extends State<ConnectExchangeModal> {
  final _keyController = TextEditingController();
  final _secretController = TextEditingController();
  final _passphraseController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = false;
  String? _errorMessage;
  String? _warningMessage;
  double? _verifiedBalance;
  String? _detectedRegion;
  bool _showSecret = false;

  String get _exchangeName {
    var id = widget.exchangeId.toLowerCase();
    if (id == 'gate.io') id = 'gateio';
    if (id == 'gateio') return 'Gate.io';
    if (id == 'mexc') return 'MEXC';
    if (id == 'binance') return 'Binance';
    if (id == 'okx') {
      if (_detectedRegion != null) {
        return 'OKX (${_detectedRegion!.toUpperCase()})';
      }
      return 'OKX';
    }
    return widget.exchangeId.toUpperCase();
  }

  @override
  void dispose() {
    _keyController.dispose();
    _secretController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  Future<void> _handleConnect() async {
    if (!_formKey.currentState!.validate()) return;
    
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _warningMessage = null;
      _verifiedBalance = null;
    });

    final apiKey = _keyController.text.trim();
    final secret = _secretController.text.trim();
    final passphrase = _passphraseController.text.trim();

    final result = await ExchangeAccountStore.instance.verifyAndConnect(
      widget.exchangeId,
      apiKey,
      secret,
      passphrase: passphrase.isNotEmpty ? passphrase : null,
    );

    if (!mounted) return;

    if (result.isValid) {
      await ExchangeAccountStore.instance.saveCredentials(
        widget.exchangeId,
        apiKey,
        secret,
        passphrase: passphrase.isNotEmpty ? passphrase : null,
        region: result.detectedRegion,
      );
      
      setState(() {
        _isLoading = false;
        _verifiedBalance = result.usdtBalance;
        _warningMessage = result.warningMessage;
        _detectedRegion = result.detectedRegion;
      });

      // Show success animation/state briefly, then close
      final delay = result.warningMessage != null ? 3500 : 1200;
      await Future.delayed(Duration(milliseconds: delay));
      if (!mounted) return;
      
      Navigator.of(context).pop(); // Close dialog
      if (widget.onConnected != null) {
        widget.onConnected!();
      }
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = result.errorMessage ?? 'Verification failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    final isRu = locale == 'ru' || locale == 'uk';

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: BoxDecoration(
        color: const Color(0xFF0C0F17),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: GuardianColors.glassBorder,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: GuardianColors.accentGlow.withOpacity(0.06),
            blurRadius: 40,
            spreadRadius: 2,
          ),
          const BoxShadow(color: Colors.black54, blurRadius: 30),
        ],
      ),
      child: Form(
        key: _formKey,
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header ───────────────────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: Text(
                      isRu ? 'Подключение $_exchangeName Spot' : 'Connect $_exchangeName Spot',
                      style: GuardianTextStyles.headline.copyWith(fontSize: 20),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── Security Warning Card ─────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF9100).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFFFF9100).withOpacity(0.2),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.shield_outlined,
                      color: Color(0xFFFF9100),
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        isRu
                            ? 'Безопасное спотовое подключение:\n• Убедитесь, что вывод средств (Withdraw) отключен в настройках API ключа.\n• Принимается только спотовая торговля (без фьючерсов).'
                            : 'Secure Spot Connection:\n• Make sure withdrawal permission is disabled in your API key settings.\n• Spot trading only (no futures/margin allowed).',
                        style: GuardianTextStyles.caption.copyWith(
                          color: const Color(0xFFE0E0E0),
                          height: 1.4,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              if (_verifiedBalance != null) ...[
                // ── Success State ───────────────────────────────────────────
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                  decoration: BoxDecoration(
                    color: GuardianColors.success.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.check_circle_rounded,
                        color: GuardianColors.success,
                        size: 48,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        isRu ? 'Успешно подключено!' : 'Successfully Connected!',
                        style: GuardianTextStyles.bodyPrimary.copyWith(
                          fontWeight: FontWeight.bold,
                          color: GuardianColors.success,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        isRu
                            ? 'Баланс: ${_verifiedBalance!.toStringAsFixed(2)} USDT'
                            : 'Balance: ${_verifiedBalance!.toStringAsFixed(2)} USDT',
                        style: GuardianTextStyles.caption.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                      if (_warningMessage != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF9100).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(0xFFFF9100).withOpacity(0.3),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                color: Color(0xFFFF9100),
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  isRu
                                      ? 'Проверьте, что Withdraw отключён в настройках $_exchangeName API.'
                                      : 'Withdraw must be disabled in $_exchangeName API settings.',
                                  style: GuardianTextStyles.caption.copyWith(
                                    color: const Color(0xFFFFCC80),
                                    fontSize: 11,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ] else ...[
                // ── Fields ───────────────────────────────────────────────────
                Text(
                  'API KEY',
                  style: GuardianTextStyles.caption.copyWith(
                    color: GuardianColors.textSecondary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _keyController,
                  enabled: !_isLoading,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Enter API Key',
                    hintStyle: const TextStyle(color: Colors.white30, fontSize: 14),
                    filled: true,
                    fillColor: GuardianColors.surfaceElevated,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: GuardianColors.accent, width: 1),
                    ),
                  ),
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return isRu ? 'Введите API Key' : 'API Key is required';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                Text(
                  'API SECRET',
                  style: GuardianTextStyles.caption.copyWith(
                    color: GuardianColors.textSecondary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _secretController,
                  enabled: !_isLoading,
                  obscureText: !_showSecret,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Enter API Secret',
                    hintStyle: const TextStyle(color: Colors.white30, fontSize: 14),
                    filled: true,
                    fillColor: GuardianColors.surfaceElevated,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: GuardianColors.accent, width: 1),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _showSecret ? Icons.visibility_off : Icons.visibility,
                        color: Colors.white60,
                        size: 18,
                      ),
                      onPressed: () => setState(() => _showSecret = !_showSecret),
                    ),
                  ),
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return isRu ? 'Введите API Secret' : 'API Secret is required';
                    }
                    return null;
                  },
                ),
                
                if (widget.exchangeId.toLowerCase() == 'okx') ...[
                  const SizedBox(height: 16),
                  Text(
                    'API PASSPHRASE',
                    style: GuardianTextStyles.caption.copyWith(
                      color: GuardianColors.textSecondary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _passphraseController,
                    enabled: !_isLoading,
                    obscureText: !_showSecret,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Enter API Passphrase',
                      hintStyle: const TextStyle(color: Colors.white30, fontSize: 14),
                      filled: true,
                      fillColor: GuardianColors.surfaceElevated,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: GuardianColors.accent, width: 1),
                      ),
                    ),
                    validator: (val) {
                      if (val == null || val.trim().isEmpty) {
                        return isRu ? 'Введите Passphrase' : 'Passphrase is required';
                      }
                      return null;
                    },
                  ),
                ],

                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _errorMessage!,
                    style: const TextStyle(color: GuardianColors.danger, fontSize: 12, height: 1.3),
                  ),
                ],
                const SizedBox(height: 24),

                // ── Action Buttons ───────────────────────────────────────────
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side: const BorderSide(color: GuardianColors.glassBorder),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          isRu ? 'Отмена' : 'Cancel',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _handleConnect,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          backgroundColor: GuardianColors.accent,
                          foregroundColor: GuardianColors.background,
                          disabledBackgroundColor: GuardianColors.accent.withOpacity(0.3),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: GuardianColors.background,
                                ),
                              )
                            : Text(
                                isRu ? 'Подключить' : 'Connect',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
    );
  }
}
