import 'package:flutter/material.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';

class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key});

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  String _firstPin = '';
  String _currentPin = '';
  bool _isConfirming = false;
  bool _isError = false;

  void _onDigit(String digit) {
    if (_currentPin.length < 6) {
      setState(() {
        _currentPin += digit;
        _isError = false;
      });

      if (_currentPin.length == 6) {
        // Задержка чисто визуальная, чтобы пользователь увидел последнюю точку
        Future.delayed(const Duration(milliseconds: 200), _processFullPin);
      }
    }
  }

  void _onBackspace() {
    if (_currentPin.isNotEmpty) {
      setState(() {
        _currentPin = _currentPin.substring(0, _currentPin.length - 1);
        _isError = false;
      });
    }
  }

  void _processFullPin() async {
    if (!_isConfirming) {
      // Переход к подтверждению
      setState(() {
        _firstPin = _currentPin;
        _currentPin = '';
        _isConfirming = true;
      });
    } else {
      // Проверка совпадения
      if (_firstPin == _currentPin) {
        // Успех, сохраняем PIN
        await IBITIVaultService.instance.savePin(_firstPin);
        if (mounted) {
          Navigator.pop(context); // Возвращаемся в настройки
        }
      } else {
        // Ошибка, сбрасываем и начинаем заново
        setState(() {
          _isError = true;
          _currentPin = '';
        });
        // Через секунду возвращаем на шаг 1
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) {
            setState(() {
              _firstPin = '';
              _isConfirming = false;
              _isError = false;
            });
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _isConfirming ? 'Повторите PIN' : 'Придумайте PIN';
    final subtitle = _isConfirming
        ? 'Введите 6 цифр для подтверждения'
        : 'Этот PIN будет использоваться для доступа к Vault';

    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        backgroundColor: GuardianColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: GuardianColors.textPrimary, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 20),
            Icon(
              _isConfirming ? Icons.check_circle_outline : Icons.lock_outline,
              size: 48,
              color: _isError ? Colors.redAccent : GuardianColors.accent,
            ),
            const SizedBox(height: 16),
            Text(
              _isError ? 'PIN-коды не совпадают' : title,
              style: GuardianTextStyles.headline.copyWith(
                  color:
                      _isError ? Colors.redAccent : GuardianColors.textPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: GuardianTextStyles.bodySecondary
                  .copyWith(color: GuardianColors.textTertiary),
            ),
            const SizedBox(height: 48),

            // PIN Dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(6, (index) {
                final isFilled = index < _currentPin.length;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isFilled
                        ? (_isError ? Colors.redAccent : GuardianColors.accent)
                        : GuardianColors.background,
                    border: Border.all(
                      color: isFilled
                          ? (_isError
                              ? Colors.redAccent
                              : GuardianColors.accent)
                          : GuardianColors.glassBorder,
                      width: 2,
                    ),
                  ),
                );
              }),
            ),

            const Spacer(),

            // Numpad
            _buildNumpad(),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildNumpad() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildKey('1'),
              _buildKey('2'),
              _buildKey('3'),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildKey('4'),
              _buildKey('5'),
              _buildKey('6'),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildKey('7'),
              _buildKey('8'),
              _buildKey('9'),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const SizedBox(width: 72, height: 72), // Empty space
              _buildKey('0'),
              _buildBackspaceKey(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildKey(String digit) {
    return GestureDetector(
      onTap: () => _onDigit(digit),
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: GuardianColors.surface,
          shape: BoxShape.circle,
          border: Border.all(color: GuardianColors.glassBorder),
        ),
        alignment: Alignment.center,
        child: Text(
          digit,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w500,
            color: GuardianColors.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _buildBackspaceKey() {
    return GestureDetector(
      onTap: _onBackspace,
      child: Container(
        width: 72,
        height: 72,
        decoration: const BoxDecoration(
          color: Colors.transparent,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: const Icon(
          Icons.backspace_outlined,
          color: GuardianColors.textPrimary,
          size: 28,
        ),
      ),
    );
  }
}
