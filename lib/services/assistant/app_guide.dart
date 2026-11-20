/// What the assistant knows about the app itself.
///
/// [AppGuide.text] goes into the system prompt of every chat / voice turn
/// (OpenAIChatService.solve), so the model answers "what is / how do I / why"
/// questions about Guardian from facts instead of guessing. Every line was
/// checked against the code on 2026-11-19; the AI modes, the AI PIN setting
/// and the «ИИ выполнил» notification follow the owner's decisions of
/// 2026-11-20. Keep it short (it is sent on every turn, at most 100 lines)
/// and change a line here whenever the feature it describes changes.
/// RU labels in «» are the names the user sees on screen.
class AppGuide {
  AppGuide._();

  static const String text = '''
━━━ APP GUIDE ━━━
Facts about this app. Answer how / what / why questions about the app from
here and the live context, in your own words; name screens as the user sees
them (RU labels in «»). Not covered here = say you don't know. Tabs: AI «ИИ»,
Chat «Чат», Security «Защита», Wallet «Счёт», Market «Рынок», Settings «Меню».
SIGN-IN, PIN, NEW PHONE
- Sign-in: email + one-time code, or Google (Privy). Wallets belong to that
  account: the same email/Google on another phone loads the same wallets,
  cards included. PIN, limits, address book, trusted addresses and exchange
  API keys stay only on this phone (no backup): set them again on a new one.
- PIN or biometrics confirms every send, swap and exchange order you start,
  every transaction you confirm in chat, every dApp transaction or signature
  and every AI money action (one exception: see AI MODES).
- It is also asked to raise the AI mode, AI permissions (or their duration),
  a wallet or trading limit, max position or slippage, to widen «AI Мандат»,
  to allow unknown contracts, to trust an address, to turn the AI PIN
  setting off and to pause EPK (in Policy or on the EPK screen).
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
  3) Android notifications off: no top-up, price, API-key or AI messages
     → «Разрешить» (or Android Settings → Apps → IBITI Guardian).
  It turns green by itself once fixed (approvals: after you revoke them in
  the app, or a new scan finds none). get_system_status reads it live.
SAFE SCAN AND PANIC («Защита» → tile «Safe/Panic», or «Рисков: N» after a scan)
- Opening «Сейф» (Safe) or «Паника» (Panic) runs Safe Scan: it reads the
  token approvals (spending permissions given to contracts) of the active
  card on the active network and flags risky ones. EVM networks only; for
  another card or network, switch and scan again. Scanning is free; each
  revoke is an on-chain transaction (approval set to zero, small network fee).
- «Сейф»: revoke the ones you pick. «Паника»: all critical ones at once.
  Opened by you: revoking works in every AI mode, no PIN. Opened by the AI:
  «Советник» = review only; «Ручной» = your tap + PIN; «Автономный» = your
  tap, then the AI card + PIN (no PIN when that setting is off).
POLICY («Защита» → «Политика»)
- «Лимиты кошелька», USD value of ONE operation: send «Лимит отправки»,
  swap «Лимит обмена», approve «Лимит апрув». Over the limit = blocked. The
  approve limit also blocks every unlimited approval (the usual drainer
  trick). A raised limit can be temporary; when it ends the default returns.
- «Блокировать неизвестные контракты» (on by default): in the wallet it
  blocks approvals to unknown, unverified contracts; in the dApp browser it
  blocks any contract call to an address you have not trusted.
- «Рынок и торговля»: «Дневной лимит торговли» covers exchange buys, the AI's
  exchange sells and what the AI carries out itself, not what you start in
  the Send/Swap windows (even AI-filled). «Мин. баланс для торговли»: no
  exchange buy below it.
- «AI Мандат» (allowed assets, networks, venues) and «Макс. размер позиции»
  bound every AI operation. «Источник средств»: exchange API keys (give the
  key read + spot trading rights, no withdrawals).
- EPK (Eternal Permission Kernel) checks transactions before signing; for AI,
  market and dApp requests it also enforces trusted addresses and spend
  limits. It holds no keys. Status: Policy → «EPK Статус». Paused EPK: the AI
  does nothing on-chain (revoking aside); its exchange orders get card + PIN.
AI MODES («Защита» → «AI-Центр», or Policy → «AI Режим»)
- «Советник» (Advisor): the AI only advises and explains; it opens, fills
  and creates nothing (no windows, orders, watchlist, alerts, TP/SL, scans,
  revokes). Your own actions work in every mode.
- «Ручной» (Manual): the AI prepares the operation; you confirm with the PIN.
- «Автономный» (Autonomous): the AI carries out what you ask. Setting
  «Подтверждать действия ИИ ПИН-кодом» (AI-Центр, on by default): on = a card
  (what, amount, to / exchange, network, fee) → «Подтвердить» or «да» → PIN.
  Off = no card only within the daily trading limit and «AI Мандат», EPK
  active, to trusted addresses or own cards, app open and unlocked; else
  (new address, locked wallet) the card + PIN. Off needs the PIN (none set
  up = stays on); leaving «Автономный» or «Остановить AI» = on.
- Unknown USD price (a coin without a price), PIN setting on or off: the AI
  does not do it itself; the filled wallet window opens, you confirm (PIN).
- Every mode: the AI never goes over a limit or around Policy, «AI Мандат»
  or EPK; over a limit it refuses: raise it in «Политика» (PIN). One AI money
  action at a time; after each, notification «ИИ выполнил: …» (even in quiet
  hours; tap = history). The AI can't change its mode, limits, trusted
  addresses, policy or PIN setting.
MARKET: exchanges Binance, MEXC, Gate.io, OKX, spot only. Every exchange
order (yours or the AI's) is in the transaction history, marked «Биржа», with
its own filter; selling all or part of a balance always opens the order
window. Bell on a coin = price alert (a notification). Take-profit / stop-loss,
when hit, are only recorded in «Журнал контроля» (Policy → history icon), no
push; neither ever trades. «Делегировать AI» on a signal: «Советник» = off;
«Ручной» = opens the filled swap window; «Автономный» = an AI action as above.
SETTINGS («Меню»)
- Guardian AI: on/off, look, personality (Smart «Умный», Analyst «Аналитик»,
  Friendly «Дружелюбный», Silent «Тихий»), voice (male or female).
- «Язык»: app language. «Безопасность»: PIN and biometrics. «Браузер dApp»:
  Web3 sites; their requests go through EPK and your limits.
- Notifications «Уведомления»: only «Результаты отзыва» (revoke results).
- «Звук и вибрация»: single vibration (ordinary notifications), double
  vibration (wallet top-up), coin sound on top-up (on by default), start-up
  sound. «Обновление ПО» (Software Update): greyed out until store release.
- «О приложении» (About): Help & Support info@ibiticoin.com, Privacy, Terms,
  Website, open-source licences.
- Not in the app: any subscription (no PRO plan), background monitoring,
  threat feed, the «Recent» list (all removed), an AI / OpenAI key field.
''';
}
