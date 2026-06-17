import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_order_service.dart';
import 'package:ibiti_guardian/services/exchanges/okx_exchange_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

class CexSpotTradeModal extends StatefulWidget {
  final MarketAsset asset;
  final bool isBuy;
  final double? initialAmount;
  final bool isSuccess;
  final String? orderId;
  final double? executedQty;
  final double? executedPrice;

  const CexSpotTradeModal({
    super.key,
    required this.asset,
    required this.isBuy,
    this.initialAmount,
    this.isSuccess = false,
    this.orderId,
    this.executedQty,
    this.executedPrice,
  });

  static void show(
    BuildContext context, {
    required MarketAsset asset,
    required bool isBuy,
    double? initialAmount,
    bool isSuccess = false,
    String? orderId,
    double? executedQty,
    double? executedPrice,
  }) {
    showDialog(
      context: context,
      useSafeArea: true,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: SingleChildScrollView(
          child: CexSpotTradeModal(
            asset: asset,
            isBuy: isBuy,
            initialAmount: initialAmount,
            isSuccess: isSuccess,
            orderId: orderId,
            executedQty: executedQty,
            executedPrice: executedPrice,
          ),
        ),
      ),
    );
  }

  @override
  State<CexSpotTradeModal> createState() => _CexSpotTradeModalState();
}

class _CexSpotTradeModalState extends State<CexSpotTradeModal> {
  late bool _isBuy;
  final _amountController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoadingBalance = true;
  double _usdtBalance = 0.0;
  bool _isConfirming = false;
  bool _isSuccess = false;
  bool _isExecuting = false;
  String? _errorMessage;
  String? _orderId;
  double _executedQty = 0.0;
  double _executedPrice = 0.0;

  String get _exchangeId {
    final id = widget.asset.sourceId.toLowerCase();
    return id == 'gate.io' ? 'gateio' : id;
  }

  String get _exchangeName {
    if (_exchangeId == 'gateio') return 'Gate.io';
    if (_exchangeId == 'mexc') return 'MEXC';
    if (_exchangeId == 'binance') return 'Binance';
    if (_exchangeId == 'okx') return 'OKX';
    return widget.asset.sourceId.toUpperCase();
  }

  double get _assetPrice => widget.asset.price > 0 ? widget.asset.price : 1.0;

  double get _inputAmount =>
      double.tryParse(_amountController.text.replaceAll(',', '.')) ?? 0.0;

  double get _totalUsdt => _isBuy ? _inputAmount : _inputAmount * _assetPrice;
  double get _totalToken => _isBuy ? _inputAmount / _assetPrice : _inputAmount;

  String _quoteAsset = 'USDT';

  @override
  void initState() {
    super.initState();
    _isBuy = widget.isBuy;
    if (widget.initialAmount != null) {
      _amountController.text = widget.initialAmount!.toString();
    }
    _isSuccess = widget.isSuccess;
    if (_isSuccess) {
      _orderId = widget.orderId;
      _executedQty = widget.executedQty ?? 0.0;
      _executedPrice = widget.executedPrice ?? 0.0;
    }
    _initQuoteAssetAndLoadBalance();
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _initQuoteAssetAndLoadBalance() async {
    if (_exchangeId == 'okx') {
      try {
        final region = await ExchangeAccountStore.instance.getOkxRegion() ?? 'global';
        final base = widget.asset.symbol.replaceAll('USDT', '').replaceAll('USDC', '').replaceAll('-', '').replaceAll('/', '').toUpperCase();
        final bestPair = await OkxExchangeService.instance.findBestPair(base, region);
        if (bestPair != null) {
          final parts = bestPair.split('-');
          if (parts.length == 2 && mounted) {
            setState(() {
              _quoteAsset = parts[1];
            });
          }
        }
      } catch (_) {}
    }
    await _loadBalance();
  }

  Future<void> _loadBalance() async {
    if (!mounted) return;
    setState(() {
      _isLoadingBalance = true;
    });
    try {
      double bal = 0.0;
      if (_exchangeId == 'okx') {
        final adapter = ExchangeOrderService.instance.adapterFor(_exchangeId);
        if (adapter != null) {
          bal = await adapter.fetchAssetBalance(_quoteAsset);
        }
      } else {
        final res = await ExchangeAccountStore.instance.fetchUsdtBalance(_exchangeId);
        bal = res ?? 0.0;
      }
      if (mounted) {
        setState(() {
          _usdtBalance = bal;
          _isLoadingBalance = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoadingBalance = false;
        });
      }
    }
  }

  Future<void> _executeOrder() async {
    setState(() {
      _isExecuting = true;
      _errorMessage = null;
    });

    try {
      final targetAmount = _isBuy ? _totalUsdt : _totalToken;
      final result = await ExchangeOrderService.instance.placeMarketOrder(
        exchangeId: _exchangeId,
        symbol: widget.asset.symbol,
        isBuy: _isBuy,
        amount: targetAmount,
        price: _assetPrice,
      );

      if (mounted) {
        setState(() {
          _isExecuting = false;
          if (result.isSuccess) {
            _isSuccess = true;
            _isConfirming = false;
            _orderId = result.orderId;
            _executedQty = result.executedQty > 0 ? result.executedQty : _totalToken;
            _executedPrice = result.executedPrice > 0 ? result.executedPrice : _assetPrice;
          } else {
            _errorMessage = result.errorMessage ?? 'Execution failed';
            _isConfirming = false;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isExecuting = false;
          _errorMessage = e.toString();
          _isConfirming = false;
        });
      }
    }
  }

  void _handleExecute() {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isConfirming = true;
    });
  }

  void _confirmExecution() {
    _executeOrder();
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    final isRu = locale == 'ru' || locale == 'uk';
    final mode = AiControlService.instance.settings.mode;

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
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _isSuccess
            ? _buildSuccessState(isRu)
            : _isConfirming
                ? _buildConfirmationState(isRu)
                : _buildMainState(isRu, mode),
      ),
    );
  }

  Widget _buildMainState(bool isRu, AiMode mode) {
    String modeName = 'Guarded';
    String modeDesc = isRu ? 'Требуется подтверждение' : 'Requires confirmation';
    Color modeColor = const Color(0xFFFF9100);

    if (mode == AiMode.manual) {
      modeName = 'Manual';
      modeDesc = isRu ? 'Торговля заблокирована' : 'Trading blocked';
      modeColor = GuardianColors.danger;
    } else if (mode == AiMode.fullAutonomy) {
      modeName = 'Full Autonomy';
      modeDesc = isRu ? 'Авто-выполнение по лимитам' : 'Auto execution within limits';
      modeColor = GuardianColors.success;
    }

    return Form(
      key: _formKey,
      child: Column(
          key: const ValueKey('main_state'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header ─────────────────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$_exchangeName Spot',
                        style: GuardianTextStyles.caption.copyWith(
                          color: GuardianColors.textSecondary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${widget.asset.symbol} / $_quoteAsset',
                        style: GuardianTextStyles.titleMedium,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Buy/Sell Tabs ──────────────────────────────────────────────────
            Container(
              height: 44,
              decoration: BoxDecoration(
                color: GuardianColors.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _isBuy = true;
                        _amountController.clear();
                      }),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _isBuy ? GuardianColors.success : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          isRu ? 'КУПИТЬ' : 'BUY',
                          style: GuardianTextStyles.button.copyWith(
                            color: _isBuy ? Colors.black : Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _isBuy = false;
                        _amountController.clear();
                      }),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: !_isBuy ? GuardianColors.danger : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          isRu ? 'ПРОДАТЬ' : 'SELL',
                          style: GuardianTextStyles.button.copyWith(
                            color: !_isBuy ? Colors.white : Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Price & Balance ────────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isRu
                      ? 'Цена: \$${_assetPrice.toStringAsFixed(4)}'
                      : 'Price: \$${_assetPrice.toStringAsFixed(4)}',
                  style: GuardianTextStyles.caption,
                ),
                _isLoadingBalance
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: Colors.white30,
                        ),
                      )
                    : Text(
                        isRu
                            ? 'Доступно: ${_usdtBalance.toStringAsFixed(2)} $_quoteAsset'
                            : 'Available: ${_usdtBalance.toStringAsFixed(2)} $_quoteAsset',
                        style: GuardianTextStyles.caption.copyWith(color: Colors.white70),
                      ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Amount Input ───────────────────────────────────────────────────
            Text(
              _isBuy
                  ? (isRu ? 'Сумма покупки ($_quoteAsset)' : 'Buy amount ($_quoteAsset)')
                  : (isRu ? 'Количество ${widget.asset.symbol}' : 'Amount (${widget.asset.symbol})'),
              style: GuardianTextStyles.caption.copyWith(
                color: GuardianColors.textSecondary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*[\.\,]?\d*$')),
              ],
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                hintText: '0.00',
                hintStyle: const TextStyle(color: Colors.white30),
                filled: true,
                fillColor: GuardianColors.surfaceElevated,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: GuardianColors.accent, width: 1),
                ),
                suffixText: _isBuy ? _quoteAsset : widget.asset.symbol,
                suffixStyle: const TextStyle(color: Colors.white54, fontWeight: FontWeight.bold),
              ),
              validator: (val) {
                if (val == null || val.trim().isEmpty) {
                  return _isBuy
                      ? (isRu ? 'Введите сумму покупки' : 'Enter buy amount')
                      : (isRu ? 'Введите количество' : 'Enter amount');
                }
                final amount = double.tryParse(val.replaceAll(',', '.')) ?? 0.0;
                if (amount <= 0) {
                  return isRu ? 'Сумма должна быть больше 0' : 'Amount must be greater than 0';
                }
                if (_isBuy && amount > _usdtBalance) {
                  // Warning only, do not strictly block in demo mode if balance is 0
                }
                return null;
              },
              onChanged: (val) => setState(() {}),
            ),
            const SizedBox(height: 8),

            // ── Preview/Total Value ────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _isBuy
                      ? (isRu ? 'Получите (примерно):' : 'Receive (approx):')
                      : (isRu ? 'Всего (примерно):' : 'Total (approx):'),
                  style: GuardianTextStyles.caption,
                ),
                Text(
                  _isBuy
                      ? '${_totalToken.toStringAsFixed(6)} ${widget.asset.symbol}'
                      : '\$${_totalUsdt.toStringAsFixed(2)} $_quoteAsset',
                  style: GuardianTextStyles.bodyPrimary.copyWith(
                    fontWeight: FontWeight.bold,
                    color: GuardianColors.accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ── AI Shield Status Card ──────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: modeColor.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: modeColor.withOpacity(0.2)),
              ),
              child: Row(
                children: [
                  Icon(
                    mode == AiMode.manual
                        ? Icons.block_flipped
                        : mode == AiMode.guarded
                            ? Icons.security_outlined
                            : Icons.bolt,
                    color: modeColor,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'JARVIS Mode: $modeName',
                          style: GuardianTextStyles.caption.copyWith(
                            color: modeColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          modeDesc,
                          style: GuardianTextStyles.caption.copyWith(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Real Execution Disclaimer ──────────────────────────────────────
            Text(
              isRu
                  ? 'Ордер будет исполнен на вашем реальном CEX-аккаунте.'
                  : 'Order will be executed on your real CEX account.',
              textAlign: TextAlign.center,
              style: GuardianTextStyles.caption.copyWith(
                color: Colors.white54,
                fontSize: 10,
              ),
            ),
            const SizedBox(height: 16),

            if (_errorMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: GuardianColors.danger.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: GuardianColors.danger.withOpacity(0.2)),
                ),
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(color: GuardianColors.danger, fontSize: 12),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // ── Action Buttons ─────────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isExecuting ? null : () => Navigator.of(context).pop(),
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
                    onPressed: (mode == AiMode.manual || _isExecuting) ? null : _handleExecute,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: mode == AiMode.manual
                          ? Colors.white10
                          : _isBuy
                              ? GuardianColors.success
                              : GuardianColors.danger,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.white10,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isExecuting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            mode == AiMode.manual
                                ? (isRu ? 'Заблокировано' : 'Blocked')
                                : _isBuy
                                    ? (isRu ? 'Купить' : 'Buy')
                                    : (isRu ? 'Продать' : 'Sell'),
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
    );
  }

  Widget _buildConfirmationState(bool isRu) {
    return Column(
      key: const ValueKey('confirm_state'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.security, color: Color(0xFFFF9100), size: 24),
            const SizedBox(width: 10),
            Text(
              isRu ? 'Подтверждение ордера' : 'Confirm Order',
              style: GuardianTextStyles.headline,
            ),
          ],
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: GuardianColors.surfaceElevated,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              _buildDetailRow(isRu ? 'Биржа' : 'Exchange', _exchangeName),
              const Divider(color: Colors.white12, height: 20),
              _buildDetailRow(
                isRu ? 'Тип ордера' : 'Order Type',
                _isBuy 
                    ? (isRu ? 'ПОКУПКА (Market)' : 'BUY (Market)') 
                    : (isRu ? 'ПРОДАЖА (Market)' : 'SELL (Market)')
              ),
              const Divider(color: Colors.white12, height: 20),
              if (_isBuy) ...[
                _buildDetailRow(
                  isRu ? 'Потратить' : 'Spend',
                  '${_totalUsdt.toStringAsFixed(2)} $_quoteAsset',
                ),
                const Divider(color: Colors.white12, height: 20),
                _buildDetailRow(
                  isRu ? 'Получить (прим.)' : 'Receive (approx)',
                  '${_totalToken.toStringAsFixed(6)} ${widget.asset.symbol}',
                ),
              ] else ...[
                _buildDetailRow(
                  isRu ? 'Продать' : 'Sell',
                  '${_totalToken.toStringAsFixed(6)} ${widget.asset.symbol}',
                ),
                const Divider(color: Colors.white12, height: 20),
                _buildDetailRow(
                  isRu ? 'Получить (прим.)' : 'Receive (approx)',
                  '${_totalUsdt.toStringAsFixed(2)} $_quoteAsset',
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _isExecuting ? null : () => setState(() => _isConfirming = false),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: GuardianColors.glassBorder),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  isRu ? 'Назад' : 'Back',
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: _isExecuting ? null : _confirmExecution,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: GuardianColors.accent,
                  foregroundColor: GuardianColors.background,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isExecuting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: GuardianColors.background,
                        ),
                      )
                    : Text(
                        isRu ? 'Подтвердить' : 'Confirm',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSuccessState(bool isRu) {
    final symbol = widget.asset.symbol;
    final priceStr = _executedPrice > 0 ? '\n\nЦена: \$${_executedPrice.toStringAsFixed(4)}' : '';
    final priceStrEn = _executedPrice > 0 ? '\n\nPrice: \$${_executedPrice.toStringAsFixed(4)}' : '';
    final idStr = '\nID ордера: ${_orderId ?? "N/A"}';
    final idStrEn = '\nOrder ID: ${_orderId ?? "N/A"}';

    String text;
    if (_executedQty > 1e-8) {
      String qtyStr;
      if (_executedQty >= 1.0) {
        qtyStr = _executedQty.toStringAsFixed(4);
      } else {
        qtyStr = _executedQty.toStringAsFixed(6);
        while (qtyStr.endsWith('0') && qtyStr.contains('.')) {
          qtyStr = qtyStr.substring(0, qtyStr.length - 1);
        }
        if (qtyStr.endsWith('.')) {
          qtyStr = qtyStr.substring(0, qtyStr.length - 1);
        }
      }
      text = isRu
          ? 'Рыночный ордер на ${_isBuy ? 'покупку' : 'продажу'} $qtyStr $symbol через $_exchangeName Spot успешно исполнен.$priceStr$idStr'
          : 'Market ${_isBuy ? 'BUY' : 'SELL'} order of $qtyStr $symbol via $_exchangeName Spot successfully executed.$priceStrEn$idStrEn';
    } else {
      if (_isBuy && widget.initialAmount != null && widget.initialAmount! > 0.0) {
        final amountStr = '\$${widget.initialAmount!.toStringAsFixed(2)}';
        text = isRu
            ? 'Рыночный ордер на покупку $symbol на $amountStr через $_exchangeName Spot успешно исполнен.$priceStr$idStr'
            : 'Market BUY order of $symbol for $amountStr via $_exchangeName Spot successfully executed.$priceStrEn$idStrEn';
      } else {
        text = isRu
            ? 'Рыночный ордер на ${_isBuy ? 'покупку' : 'продажу'} $symbol через $_exchangeName Spot успешно исполнен.$priceStr$idStr'
            : 'Market ${_isBuy ? 'BUY' : 'SELL'} order of $symbol via $_exchangeName Spot successfully executed.$priceStrEn$idStrEn';
      }
    }

    return Column(
      key: const ValueKey('success_state'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(
          Icons.check_circle_rounded,
          color: GuardianColors.success,
          size: 64,
        ),
        const SizedBox(height: 16),
        Text(
          isRu ? 'Ордер Исполнен' : 'Order Executed',
          textAlign: TextAlign.center,
          style: GuardianTextStyles.titleMedium.copyWith(color: GuardianColors.success),
        ),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: GuardianTextStyles.bodySecondary.copyWith(height: 1.4),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            backgroundColor: GuardianColors.surfaceElevated,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(
            isRu ? 'Готово' : 'Done',
            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: GuardianTextStyles.caption.copyWith(color: Colors.white54)),
        Text(value, style: GuardianTextStyles.bodySecondary.copyWith(fontWeight: FontWeight.bold)),
      ],
    );
  }
}
