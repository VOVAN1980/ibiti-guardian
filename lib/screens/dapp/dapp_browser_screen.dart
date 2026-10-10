import 'dart:async';
import 'dapp_approval_dialog.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:ibiti_guardian/services/dapp/dapp_return_navigation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/screens/vault/vault_unlock_screen.dart';
import 'package:ibiti_guardian/services/dapp/dapp_permissions.dart';
import 'package:ibiti_guardian/services/dapp/dapp_protocol.dart';
import 'package:ibiti_guardian/services/dapp/dapp_session.dart';
import 'package:ibiti_guardian/services/dapp/dapp_wallet_backend.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';

/// Native browser chrome and consent live outside web content.
class DappBrowserScreen extends StatefulWidget {
  final Uri? initialUrl;
  const DappBrowserScreen({super.key, this.initialUrl});
  @override
  State<DappBrowserScreen> createState() => _DappBrowserScreenState();
}

class _DappBrowserScreenState extends State<DappBrowserScreen>
    with WidgetsBindingObserver {
  final _address = TextEditingController();
  final _permissions = SecureDappPermissions();
  final _wallet = GuardianDappWallet();
  late final DappSession _session;
  late final Future<String> _provider;
  InAppWebViewController? _web;
  Uri? _url;
  String? _error;
  int _progress = 0;
  BuildContext? _dialogContext;
  String _walletFingerprint = '';
  bool get _ru => Localizations.localeOf(context).languageCode == 'ru';
  String _l(String ru, String en) => _ru ? ru : en;

  @override
  void initState() {
    super.initState();
    _session = DappSession(
        wallet: _wallet,
        permissions: _permissions,
        approve: _approve,
        authenticate: () async {
          if (!mounted) return false;
          return VaultUnlockScreen.requireAuth(context, forceSetup: true);
        });
    _provider = rootBundle.loadString('assets/dapp/guardian_provider.js');
    _walletFingerprint =
        '${_wallet.account.toLowerCase()}|${_wallet.available}';
    WidgetsBinding.instance.addObserver(this);
    IBITIVaultService.instance.addListener(_walletChanged);
    // Plugin debug logs can include message/signature content.
    PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
  }

  void _walletChanged() {
    final next = '${_wallet.account.toLowerCase()}|${_wallet.available}';
    if (next == _walletFingerprint) return;
    _walletFingerprint = next;
    _session.invalidate();
    _dismissConsent();
    if (mounted) setState(() {});
    unawaited(_web?.reload() ?? Future<void>.value());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _session.invalidate();
      _dismissConsent();
    }
  }

  void _dismissConsent() {
    final dialog = _dialogContext;
    _dialogContext = null;
    if (dialog != null && dialog.mounted) Navigator.of(dialog).pop(false);
  }

  @override
  void dispose() {
    _session.close();
    IBITIVaultService.instance.removeListener(_walletChanged);
    WidgetsBinding.instance.removeObserver(this);
    _address.dispose();
    super.dispose();
  }

  Future<void> _open(String raw) async {
    try {
      final url = DappOrigin.httpsUrl(
          raw.contains('://') ? raw.trim() : 'https://${raw.trim()}');
      _session.navigate(null);
      _dismissConsent();
      await _web?.loadUrl(urlRequest: URLRequest(url: WebUri.uri(url)));
      if (mounted) {
        setState(() {
          _error = null;
        });
      }
    } on DappError {
      if (mounted) {
        setState(() {
          _error = _l('Введите корректный HTTPS-адрес.',
              'Enter a valid HTTPS address.');
        });
      }
    }
  }

  Future<void> _receive(WebMessage? message, WebUri? sourceOrigin,
      bool isMainFrame, PlatformJavaScriptReplyProxy reply) async {
    int? id;
    Map<String, dynamic> output;
    try {
      if (message?.data is! String || sourceOrigin == null) {
        throw const DappError(-32600, 'Invalid browser message.');
      }
      final request = DappRpcRequest.decode(message!.data as String);
      id = request.id;
      final current = await _web?.getUrl();
      if (current == null ||
          DappOrigin.canonical(current.toString()) !=
              DappOrigin.canonical(sourceOrigin.toString())) {
        throw const DappError(4100, 'Website origin changed.');
      }
      final result = await _session.handle(request,
          sourceOrigin: sourceOrigin.toString(), isMainFrame: isMainFrame);
      final authorized = _wallet.available &&
          await _permissions.has(sourceOrigin.toString(), _wallet.account);
      output = {
        'id': id,
        'result': result,
        'state': {
          'chainId': hexQuantity(BigInt.from(_session.chainId)),
          'accounts': authorized ? [_wallet.account] : <String>[],
        }
      };
      if (kDebugMode) debugPrint('[DappBridge] request=$id status=success');
    } on DappError catch (error) {
      if (kDebugMode) {
        debugPrint(
            '[DappBridge] request=$id status=rejected code=${error.code}');
      }
      output = {'id': id, 'error': error.toJson()};
      if (mounted && error.code != 4001) {
        setState(() {
          _error = switch (error.message) {
            'Your policy does not allow this contract or address.' => _l(
                'Этот контракт не разрешён вашей текущей политикой. Браузер не добавляет сайты в доверенные и не меняет правила автоматически.',
                error.message),
            'Contract code is not a reviewed receiver.' => _l(
                'Код контракта не совпал с проверенной версией получения выплаты. Подпись заблокирована.',
                error.message),
            'The simulated withdrawal does not match its payout.' => _l(
                'Симуляция не подтвердила точное поступление выплаты. Подпись заблокирована.',
                error.message),
            'Withdrawal token or deadline is invalid.' => _l(
                'Котировка вывода истекла либо токен не проверен. Создайте новую операцию на сайте.',
                error.message),
            'EPK cannot verify this contract call against your spending limits.' =>
              _l('EPK не может проверить расход токенов в этом вызове контракта. Подпись заблокирована; правила защиты не изменены.',
                  error.message),
            'Spending authorizations require a dedicated EPK permit validator.' =>
              _l('Разрешение на расход токенов через подпись пока не поддерживается безопасно. Запрос заблокирован.',
                  error.message),
            'Not enough native coin to pay value and network fees.' => _l(
                'Недостаточно монеты сети для суммы и комиссии.',
                error.message),
            'Unlock your Guardian EVM wallet first.' =>
              _l('Сначала разблокируйте EVM-кошелёк Guardian.', error.message),
            'Guardian protection is paused.' => _l(
                'Защита Guardian приостановлена. Подпись запрещена.',
                error.message),
            _ => _l('Запрос сайта отклонён кошельком (код ${error.code}).',
                error.message),
          };
        });
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
            '[DappBridge] request=$id status=error type=${error.runtimeType}');
      }
      output = {
        'id': id,
        'error':
            const DappError(-32603, 'Guardian could not complete the request.')
                .toJson()
      };
    }
    // ReplyProxy belongs to the originating document. Never evaluate a callback
    // in whatever page happens to be visible after an await.
    if (!mounted) return;
    try {
      await reply.postMessage(WebMessage(data: jsonEncode(output)));
    } catch (_) {}
  }

  String _title(DappApproval request) => request.warnings.contains('oneTimeReceive')
      ? _l('Получить выплату', 'Receive payout') : switch (request.method) {
        'connect' => _l('Подключить сайт', 'Connect website'),
        'switchChain' => _l('Сменить сеть сайта', 'Switch website network'),
        'personal_sign' => _l('Подписать сообщение', 'Sign message'),
        'eth_signTypedData_v4' =>
          _l('Подписать структурированные данные', 'Sign typed data'),
        _ => _l('Подтвердить транзакцию', 'Confirm transaction'),
      };

  String _warning(String key) => switch (key) {
        'messageAuthorization' => _l(
            'Подпись может дать сайту права доступа. Прочитайте сообщение целиком.',
            'A signature may authorize access. Read the complete message.'),
        'typedAuthorization' => _l(
            'Структурированная подпись может разрешить действия без дальнейшего подтверждения.',
            'Typed signatures may authorize actions without further confirmation.'),
        'tokenApproval' => _l(
            'Сайт запрашивает разрешение расходовать токены. Проверьте адрес получателя разрешения и сумму.',
            'The website requests token spending permission. Check the spender and amount.'),
        'unlimitedApproval' => _l('Безлимитное разрешение на расход токенов.',
            'Unlimited token spending permission.'),
        'verifiedReceive' => _l(
            'Получение выплаты: проверены код контракта, получатель и точное поступление токенов в симуляции. С вашего кошелька оплачивается только комиссия сети. До включения транзакции состояние сети может измениться.',
            'Receive payout: contract code, recipient and exact token credit were checked in simulation. Your wallet pays only the network fee. Network state can change before inclusion.'),
        'oneTimeReceive' => _l(
            'Вы разрешаете только эту выплату с указанной комиссией. Контракт не добавляется в доверенные. Следующая операция потребует нового подтверждения.',
            'You authorize only this payout with the displayed fee. The contract is not added to trusted contracts. Another transaction needs a new confirmation.'),
        'unverifiedTokenChanges' => _l(
            'Изменения токенов не расшифрованы. Это вызов контракта, а не простой перевод.',
            'Token changes have not been decoded. This is a contract call, not a simple transfer.'),
        _ => _l(
            'Сеть проверила выполнение и газ. Эта проверка не гарантирует безопасность контракта или все изменения токенов.',
            'The network checked execution and gas. This does not guarantee contract safety or all token changes.'),
      };

  Future<bool> _approve(DappApproval request) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialog) {
          _dialogContext = dialog;
          return DappApprovalDialog(
            title: Text(_title(request)),
            content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(request.origin,
                            style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.cyan)),
                        const SizedBox(height: 12),
                        Text(
                            '${_l('Сеть', 'Network')}: ${PrivyChainRegistry.getEvmChain(request.chainId)?.displayName ?? request.chainId}'),
                        SelectableText(
                            '${_l('Кошелёк', 'Wallet')}: ${request.account}'),
                        for (final entry in request.transactionDetails.entries)
                          Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: SelectableText('${switch (entry.key) {
                                'operation' => _l('Операция', 'Operation'),
                                'receiveAmount' =>
                                  _l('Вы получите', 'You receive'),
                                'receiveToken' =>
                                  _l('Контракт токена', 'Token contract'),
                                'recipient' =>
                                  _l('Получатель выплаты', 'Payout recipient'),
                                'outgoingAssets' => _l(
                                    'Расход активов без комиссии',
                                    'Asset spend excluding fee'),
                                'target' => _l('Контракт / получатель',
                                    'Contract / recipient'),
                                'nativeValue' => _l('Отправляемая монета',
                                    'Outgoing native coin'),
                                'tokenRecipient' =>
                                  request.warnings.contains('tokenApproval')
                                      ? _l('Кому разрешён расход',
                                          'Authorized spender')
                                      : _l('Получатель токенов',
                                          'Token recipient'),
                                _ => _l('Сумма токенов / разрешения',
                                    'Token / allowance amount'),
                              }}: ${entry.value == 'verifiedReceive' ? _l('Получение выплаты', 'Receive payout') : entry.value}')),
                        if (request.method == 'connect')
                          Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(_l(
                                  'Сайт увидит только ваш адрес. Каждая подпись потребует отдельного подтверждения. Доступ можно отозвать.',
                                  'The website can see your address. Each signature requires separate approval. You can revoke access.'))),
                        if (request.fee != null)
                          Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                  '${_l('Максимальная комиссия по оценке', 'Estimated maximum network fee')}: ${request.fee}')),
                        for (final warning in request.warnings)
                          Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(_warning(warning),
                                  style: const TextStyle(color: Colors.amber))),
                        if (request.method != 'connect' &&
                            request.method != 'switchChain') ...[
                          const SizedBox(height: 16),
                          SelectableText(request.content,
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 13)),
                        ],
                      ]),
                )),
            rejectLabel: _l('Отклонить', 'Reject'),
            approveLabel: request.method == 'connect'
                ? _l('Подключить', 'Connect')
                : request.warnings.contains('oneTimeReceive')
                    ? _l('Разрешить эту выплату', 'Authorize this payout')
                    : _l('Продолжить', 'Continue'),
          );
        });
    _dialogContext = null;
    return result ?? false;
  }

  Future<void> _sites() async {
    final origins = await _permissions.origins();
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: Text(_l('Подключённые сайты', 'Connected websites')),
              content: SizedBox(
                  width: double.maxFinite,
                  child: origins.isEmpty
                      ? Text(_l('Нет разрешений для сайтов.',
                          'No website permissions.'))
                      : ListView(
                          shrinkWrap: true,
                          children: origins
                              .map((origin) => ListTile(
                                    title: Text(origin),
                                    trailing: IconButton(
                                        icon: const Icon(Icons.link_off),
                                        onPressed: () async {
                                          _session.invalidate();
                                          await _permissions.revoke(origin);
                                          if (dialog.mounted) {
                                            Navigator.of(dialog).pop();
                                          }
                                          await _web?.reload();
                                        }),
                                  ))
                              .toList())),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(dialog).pop(),
                    child: Text(_l('Закрыть', 'Close')))
              ],
            ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_l('Браузер dApp', 'dApp Browser')), actions: [
        IconButton(
            onPressed: _sites,
            icon: const Icon(Icons.verified_user_outlined),
            tooltip: _l('Разрешения сайтов', 'Website permissions'))
      ]),
      body: Column(children: [
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              const Icon(Icons.lock_outline, size: 18),
              const SizedBox(width: 8),
              Expanded(
                  child: TextField(
                      controller: _address,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.go,
                      onSubmitted: _open,
                      decoration:
                          const InputDecoration(hintText: 'https://…'))),
              IconButton(
                  onPressed: () => _open(_address.text),
                  icon: const Icon(Icons.arrow_forward)),
            ])),
        if (_url != null)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                Expanded(
                    child: Text(_url!.authority,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 19),
                        overflow: TextOverflow.ellipsis)),
                Text(PrivyChainRegistry.getEvmChain(_session.chainId)
                        ?.displayName ??
                    '')
              ])),
        if (_progress > 0 && _progress < 100)
          LinearProgressIndicator(value: _progress / 100),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.all(12),
              child:
                  Text(_error!, style: const TextStyle(color: Colors.amber))),
        Expanded(
            child: FutureBuilder<String>(
                future: _provider,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                        child: Text(_l('Не удалось загрузить мост кошелька.',
                            'The wallet bridge could not be loaded.')));
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (defaultTargetPlatform != TargetPlatform.android &&
                      defaultTargetPlatform != TargetPlatform.iOS) {
                    return Center(
                        child: Text(_l(
                            'Браузер кошелька доступен на Android и iOS.',
                            'Wallet browser is available on Android and iOS.')));
                  }
                  return InAppWebView(
                    initialSettings: InAppWebViewSettings(
                        useShouldOverrideUrlLoading: true,
                        javaScriptEnabled: true,
                        javaScriptCanOpenWindowsAutomatically: false,
                        supportMultipleWindows: false,
                        allowFileAccess: false,
                        allowContentAccess: false,
                        allowFileAccessFromFileURLs: false,
                        allowUniversalAccessFromFileURLs: false,
                        mixedContentMode:
                            MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
                        safeBrowsingEnabled: true,
                        mediaPlaybackRequiresUserGesture: true,
                        useShouldInterceptRequest: true),
                    onWebViewCreated: (controller) async {
                      _web = controller;
                      if (defaultTargetPlatform == TargetPlatform.android &&
                          (!await WebViewFeature.isFeatureSupported(
                                  WebViewFeature.WEB_MESSAGE_LISTENER) ||
                              !await WebViewFeature.isFeatureSupported(
                                  WebViewFeature.DOCUMENT_START_SCRIPT))) {
                        if (mounted) {
                          setState(() {
                            _error = _l(
                                'Обновите Android System WebView для безопасного подключения кошелька.',
                                'Update Android System WebView for a secure wallet connection.');
                          });
                        }
                        return;
                      }
                      await controller.addWebMessageListener(WebMessageListener(
                          jsObjectName: 'guardianWallet',
                          allowedOriginRules: {'*'},
                          onPostMessage: _receive));
                      // On iOS the listener itself is a document-start script.
                      // Register it first so the provider can bind immediately,
                      // before any dApp script performs wallet discovery.
                      await controller.addUserScript(
                          userScript: UserScript(
                              source: snapshot.data!,
                              injectionTime:
                                  UserScriptInjectionTime.AT_DOCUMENT_START,
                              forMainFrameOnly: true));
                      if (widget.initialUrl != null) {
                        await _open(widget.initialUrl.toString());
                      }
                    },
                    shouldOverrideUrlLoading: (controller, action) async {
                      final url = action.request.url;
                      if (url?.toString() == DappReturnNavigation.lvsReturn) {
                        final source = await controller.getUrl();
                        if (DappReturnNavigation.allows(
                            source: source?.toString(),
                            target: url.toString(),
                            isMainFrame: action.isForMainFrame)) {
                          _session.invalidate();
                          _dismissConsent();
                          var opened = false;
                          try {
                            opened = await launchUrl(
                                Uri.parse(DappReturnNavigation.lvsReturn),
                                mode: LaunchMode.externalApplication);
                          } catch (_) {}
                          if (mounted) {
                            setState(() {
                              _error = opened
                                  ? null
                                  : _l(
                                      'Не удалось открыть LVS. Откройте приложение вручную: статус вывода сохранён.',
                                      'Could not open LVS. Open the app manually: your withdrawal status is preserved.');
                            });
                          }
                        }
                        return NavigationActionPolicy.CANCEL;
                      }
                      try {
                        if (url == null) return NavigationActionPolicy.CANCEL;
                        DappOrigin.httpsUrl(url.toString());
                        return NavigationActionPolicy.ALLOW;
                      } on DappError {
                        return NavigationActionPolicy.CANCEL;
                      }
                    },
                    shouldInterceptRequest: (_, request) async {
                      if (request.url.scheme == 'http' ||
                          request.url.scheme == 'file' ||
                          request.url.scheme == 'content') {
                        return WebResourceResponse(
                            statusCode: 403,
                            reasonPhrase: 'Blocked',
                            contentType: 'text/plain',
                            data: Uint8List(0));
                      }
                      return null;
                    },
                    onLoadStart: (_, url) {
                      _dismissConsent();
                      try {
                        _session.navigate(url?.toString());
                      } on DappError {
                        _session.navigate(null);
                      }
                      if (mounted) {
                        setState(() {
                          _url = url != null && url.scheme == 'https'
                              ? Uri.parse(url.toString())
                              : null;
                          _address.text = _url?.toString() ?? '';
                          _error = null;
                        });
                      }
                    },
                    onProgressChanged: (_, progress) {
                      if (mounted) {
                        setState(() {
                          _progress = progress;
                        });
                      }
                    },
                    onLoadStop: (_, __) {
                      if (mounted) setState(() {});
                    },
                    // Let the OS validate certificates. In particular, iOS
                    // sends this challenge even for valid certificates; CANCEL
                    // would block all HTTPS, PROCEED would bypass TLS checks.
                    onReceivedServerTrustAuthRequest: (_, __) async => null,
                    onPermissionRequest: (_, request) async =>
                        PermissionResponse(
                            resources: request.resources,
                            action: PermissionResponseAction.DENY),
                    onCreateWindow: (_, __) async => false,
                    onReceivedError: (_, request, __) {
                      if (request.isForMainFrame == true) {
                        _session.navigate(null);
                        if (mounted) {
                          setState(() {
                            _error = _l('Не удалось безопасно загрузить сайт.',
                                'The website could not be loaded securely.');
                          });
                        }
                      }
                    },
                  );
                })),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(
              onPressed: () async {
                if (await _web?.canGoBack() ?? false) await _web?.goBack();
              },
              icon: const Icon(Icons.arrow_back)),
          IconButton(
              onPressed: () => _web?.reload(), icon: const Icon(Icons.refresh)),
          IconButton(
              onPressed: () async {
                if (await _web?.canGoForward() ?? false) {
                  await _web?.goForward();
                }
              },
              icon: const Icon(Icons.arrow_forward)),
        ]),
      ]),
    );
  }
}
