/// What the assistant knows about the app itself.
///
/// [AppGuide.text] goes into the system prompt of every chat / voice turn
/// (OpenAIChatService.solve), so the model answers "what is / how do I / why"
/// questions about Guardian from facts instead of guessing. Every line was
/// checked against the code on 2026-11-19. Keep it short (it is sent on every
/// turn) and change a line here whenever the feature it describes changes.
/// RU labels in «» are the names the user sees on screen.
class AppGuide {
  AppGuide._();

  static const String text = '''
━━━ APP GUIDE ━━━
Facts about this app. Answer how / what / why questions about the app from
here and the live context, in your own words; name screens the way the user
sees them (RU labels in «»). Not covered here = say you don't know.
Tabs: AI «ИИ», Chat «Чат», Security «Защита», Wallet «Счёт», Market «Рынок»,
Settings «Меню».
SIGN-IN, PIN, NEW PHONE
- Sign-in: email + one-time code, or Google (Privy). Wallets belong to that
  account: the same email/Google on another phone loads the same wallets,
  cards included. PIN, limits, address book, trusted addresses and exchange
  API keys stay only on this phone (no backup): set them again on a new one.
- PIN or biometrics confirms every send, swap and exchange order you start,
  every transaction confirmed in chat and every dApp transaction or
  signature. Only in Full Autonomy the AI places the exchange orders you ask
  for without it, inside the daily trading limit and «AI Мандат» (selling
  all or part of a balance still opens the order window).
- It is also asked to raise the AI mode, AI permissions (or their duration),
  a wallet or trading limit, max position or slippage, to widen «AI Мандат»,
  to allow unknown contracts, to trust an address and to pause EPK in Policy.
- 5 wrong PINs: locked for 5 minutes. 10 wrong PINs: signed out.
WALLET TAB
- Cards: each card is its own EVM address with its own balance; max 4:
  Black (main), Silver, Gold, Platinum. Add one: tap a card → «Выпустить
  виртуальную карту» (Issue virtual card) → tap a colour. The new card gets
  the next colour in that order, whichever you tap. EVM networks only.
- «Статус системы» (System status) card: green «Безопасно» = all fine, red
  «Опасно» = a problem. Tap red → «Что не так» lists each problem + button:
  1) risky token approvals found by Safe Scan (per network + wallet)
     → «Открыть «Защиту»» → revoke them in «Сейф» or «Паника»;
  2) sign-in expired (Privy): transfers can't be signed → «Войти»;
  3) Android notifications off: no top-up, price or API-key messages
     → «Разрешить» (or Android Settings → Apps → IBITI Guardian).
  It turns green by itself once fixed (approvals: after you revoke them in
  the app, or a new scan finds none). get_system_status reads it live.
SAFE SCAN AND PANIC («Защита» → tile «Safe/Panic», or «Рисков: N» after a scan)
- Opening «Сейф» (Safe) or «Паника» (Panic) runs Safe Scan: it reads the
  token approvals (spending permissions given to contracts) of the active
  card on the active network and flags risky ones. EVM networks only; for
  another card or network, switch and scan again.
- Scanning is free. Each revoke is an on-chain transaction setting the
  approval to zero: it costs a small network fee.
- «Сейф»: review the list, revoke the ones you pick. «Паника»: revoke all
  critical ones at once after you confirm. Revoking works in every AI mode
  when you open them yourself; only a window the AI opened is review-only
  («Manual: только обзор») while the AI mode is Manual.
POLICY («Защита» → «Политика»)
- «Лимиты кошелька», USD value of ONE operation: send «Лимит отправки»,
  swap «Лимит обмена», approve «Лимит апрув». Over the limit = blocked. The
  approve limit also blocks every unlimited approval (the usual drainer
  trick). A raised limit can be temporary; when it ends the default returns.
- «Блокировать неизвестные контракты» (on by default): in the wallet it
  blocks approvals to unknown, unverified contracts; in the dApp browser it
  blocks any contract call to an address you have not trusted.
- «Рынок и торговля»: «Дневной лимит торговли» covers what is not started in
  the wallet's own Send/Swap windows (even if the AI filled them in):
  exchange buys, the AI's exchange sells, sends and swaps the AI carries out
  from chat or voice. «Мин. баланс для торговли»: no exchange buy below it.
- «AI Мандат» (allowed assets, networks, venues) and «Макс. размер позиции»
  bound every AI operation.
- «Источник средств»: connect exchange API keys (give the key read + spot
  trading rights, no withdrawals).
- EPK (Eternal Permission Kernel) checks transactions before signing; for AI,
  market and dApp requests it also enforces trusted addresses and spend
  limits. It holds no keys. Status and pause: Policy → «EPK Статус».
AI MODES («Защита» → «AI-Центр», or Policy → «AI Режим»)
- Manual «Руководство»: analysis, explanations, balances, risks; no
  execution; exchange orders are blocked, your own too. Guarded «Охраняемый»:
  the AI opens screens, fills forms, prepares previews; the user always
  confirms. Full Autonomy «Полная автономия»: the AI carries out what you ask
  within limits, «AI Мандат» and EPK.
- Raising the mode needs the PIN. The AI can't raise its own mode or change
  its limits, trusted addresses or policy.
MARKET: exchanges Binance, MEXC, Gate.io, OKX, spot only. The bell on a coin
= price alert: it sends a notification. Take-profit / stop-loss, when hit,
are only recorded in «Журнал контроля» (Policy → history icon), no push.
Neither ever trades. The AI trades only when you ask it. «Делегировать AI»
(Delegate to AI; Full Autonomy only) queues a Market signal: the AI checks
it against «AI Мандат» and policy and builds the swap, but stops at review;
it never signs that swap by itself.
SETTINGS («Меню»)
- Guardian AI: on/off, look, personality (Smart «Умный», Analyst «Аналитик»,
  Friendly «Дружелюбный», Silent «Тихий»), voice (male or female).
- «Язык»: app language. «Безопасность»: PIN and biometrics. «Браузер dApp»:
  Web3 sites; their requests go through EPK and your limits.
- Notifications «Уведомления»: only «Результаты отзыва» (revoke results).
- «Звук и вибрация»: single vibration (ordinary notifications), double
  vibration (wallet top-up), coin sound on top-up (on by default), start-up
  sound. «Обновление ПО» (Software Update): greyed out until the app is
  published in the store.
- «О приложении» (About): Help & Support info@ibiticoin.com, Privacy, Terms,
  Website, open-source licences.
- Not in the app: any subscription (no PRO plan), background monitoring,
  threat feed, the «Recent» list (all removed), an AI / OpenAI key field.
''';
}
