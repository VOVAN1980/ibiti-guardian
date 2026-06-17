import 'package:flutter/material.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/wallet/token_manager_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/services/localization_service.dart';

class WalletTokenManagementScreen extends StatefulWidget {
  const WalletTokenManagementScreen({super.key});

  @override
  State<WalletTokenManagementScreen> createState() =>
      _WalletTokenManagementScreenState();
}

class _WalletTokenManagementScreenState
    extends State<WalletTokenManagementScreen> {
  final _symbolCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _decimalsCtrl = TextEditingController(text: '18');
  String _chainKey = PrivyChainRegistry.supportedChains.first.chainKey;

  @override
  void dispose() {
    _symbolCtrl.dispose();
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    _decimalsCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveToken() async {
    final chain = PrivyChainRegistry.getChain(_chainKey);
    final symbol = _symbolCtrl.text.trim().toUpperCase();
    final name = _nameCtrl.text.trim();
    final address = _addressCtrl.text.trim();
    final decimals = int.tryParse(_decimalsCtrl.text.trim()) ?? 18;

    if (symbol.isEmpty ||
        name.isEmpty ||
        address.isEmpty ||
        chain.evmChainId == null) {
      return;
    }

    await TokenManagerService.instance.addCustomToken(
      CustomTokenEntry(
        name: name,
        symbol: symbol,
        address: address,
        decimals: decimals,
        chainId: chain.evmChainId!,
      ),
    );

    if (!mounted) return;
    _symbolCtrl.clear();
    _nameCtrl.clear();
    _addressCtrl.clear();
    _decimalsCtrl.text = '18';
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(LocalizationService.instance.t('toastImportSuccess'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        backgroundColor: GuardianColors.background,
        elevation: 0,
        title: Text(LocalizationService.instance.t('manageTokensTitle'),
            style: GuardianTextStyles.headline),
      ),
      body: ListenableBuilder(
        listenable: TokenManagerService.instance,
        builder: (context, _) {
          final manager = TokenManagerService.instance;
          final customTokens = manager.customTokens;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _Panel(
                title: LocalizationService.instance.t('importCustomTitle'),
                subtitle: LocalizationService.instance.t('importCustomSub'),
                child: Column(
                  children: [
                    _InputField(
                        controller: _symbolCtrl,
                        label: LocalizationService.instance.t('fieldSymbol')),
                    const SizedBox(height: 12),
                    _InputField(
                        controller: _nameCtrl,
                        label: LocalizationService.instance.t('fieldName')),
                    const SizedBox(height: 12),
                    _InputField(
                      controller: _addressCtrl,
                      label: LocalizationService.instance.t('fieldAddress'),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _DropdownField(
                            label:
                                LocalizationService.instance.t('fieldNetwork'),
                            value: _chainKey,
                            options: [
                              for (final chain
                                  in PrivyChainRegistry.supportedChains)
                                if (chain.evmChainId != null)
                                  DropdownMenuItem(
                                    value: chain.chainKey,
                                    child: Text(chain.displayName),
                                  ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setState(() => _chainKey = value);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _InputField(
                            controller: _decimalsCtrl,
                            label:
                                LocalizationService.instance.t('fieldDecimals'),
                            keyboardType: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _saveToken,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: GuardianColors.accent,
                          foregroundColor: GuardianColors.background,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: Text(
                            LocalizationService.instance.t('btnImportToken')),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _Panel(
                title: LocalizationService.instance.t('importedTokensTitle'),
                subtitle: customTokens.isEmpty
                    ? LocalizationService.instance.t('importedTokensEmpty')
                    : LocalizationService.instance
                        .t('importedTokensCount', {'c': customTokens.length}),
                child: customTokens.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          LocalizationService.instance
                              .t('importedTokensFooter'),
                          style: GuardianTextStyles.bodySecondary,
                        ),
                      )
                    : Column(
                        children: customTokens.map((token) {
                          final chain =
                              PrivyChainRegistry.getEvmChain(token.chainId);
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: GuardianColors.surfaceElevated,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Center(
                                child: Text(
                                  token.symbol.length > 3
                                      ? token.symbol.substring(0, 3)
                                      : token.symbol,
                                  style: GuardianTextStyles.caption.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                            title: Text(
                              token.symbol,
                              style: GuardianTextStyles.bodyPrimary,
                            ),
                            subtitle: Text(
                              '${chain?.displayName ?? 'Chain ${token.chainId}'} • ${token.address.substring(0, 8)}...${token.address.substring(token.address.length - 4)}',
                              style: GuardianTextStyles.caption,
                            ),
                            trailing: IconButton(
                              onPressed: () => manager.removeCustomToken(
                                token.address,
                                token.chainId,
                              ),
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                color: GuardianColors.danger,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const _Panel({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: GuardianColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: GuardianColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: GuardianTextStyles.titleMedium),
          const SizedBox(height: 6),
          Text(subtitle, style: GuardianTextStyles.bodySecondary),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

class _InputField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final TextInputType? keyboardType;

  const _InputField({
    required this.controller,
    required this.label,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: GuardianTextStyles.bodyPrimary,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: GuardianColors.surfaceElevated,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: GuardianColors.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: GuardianColors.glassBorder),
        ),
      ),
    );
  }
}

class _DropdownField extends StatelessWidget {
  final String label;
  final String value;
  final List<DropdownMenuItem<String>> options;
  final ValueChanged<String?> onChanged;

  const _DropdownField({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      items: options,
      onChanged: onChanged,
      dropdownColor: GuardianColors.surface,
      style: GuardianTextStyles.bodyPrimary,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: GuardianColors.surfaceElevated,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: GuardianColors.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: GuardianColors.glassBorder),
        ),
      ),
    );
  }
}
