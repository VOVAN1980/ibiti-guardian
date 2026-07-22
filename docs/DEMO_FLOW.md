# Demo Walkthrough Flow (1-2 Min Video Script)

Use this step-by-step flow to record a high-impact 1-2 minute video demonstration of **IBITI Guardian** for hackathon submission.

---

## 🎬 Scene 1: Introduction (0:00 - 0:20)
* **Visual**: Show the phone screen with the premium dark theme, starting on the main dashboard. Open the Voice AI screen (the glowing orb).
* **Action**: Tap the voice orb and say:
  > *«Привет, Джарвис! Какая сейчас цена Solana на бирже MEXC?»* (Hi Jarvis! What is the price of Solana on MEXC right now?)
* **AI Voice Response**:
  > *«Цена Solana на бирже MEXC составляет 148 долларов и 50 центов. Наблюдается рост на три процента за сутки.»* (The price of Solana on MEXC is 148 dollars and 50 cents. Up 3% today.)

---

## 🎬 Scene 2: Policy Engine Block (0:20 - 0:45)
* **Visual**: Stay on the Voice AI screen.
* **Goal**: Show that the safety shield blocks orders that violate policy.
* **Action**: Tap the voice orb and say:
  > *«Купи Solana на два доллара на MEXC.»* (Buy Solana for two dollars on MEXC.)
* **AI Voice Response**:
  > *«Не могу выполнить ордер на два доллара. Минимальная сумма покупки — пять долларов.»* (Cannot execute order for two dollars. Minimum purchase amount is five dollars.)
* **Screen Card**: The screen displays a red error card indicating the min-notional rule violation ($2 is below the $5 limit).

---

## 🎬 Scene 3: Successful Guarded Trade (0:45 - 1:15)
* **Visual**: Still on the Voice AI screen.
* **Goal**: Show a valid trade passing through the Policy Engine and requiring user confirmation (Guarded Mode).
* **Action**: Tap the voice orb and say:
  > *«Купи Solana на пять долларов на MEXC.»* (Buy Solana for five dollars on MEXC.)
* **AI Voice Response**:
  > *«Ордер исполнен, удачных торгов.»* (Order executed, happy trading.)
* **Screen Action**: A confirmation popup/biometrics lock triggers, the user taps confirm, and the screen transitions to a clean, successful transaction card displaying:
  * Asset Symbol: `SOL`
  * Platform: `MEXC`
  * Purchase Amount: `$5.00`
  * Order ID: `C02__...` (hidden in voice response, but visible on screen for support).

---

## 🎬 Scene 4: Web3 Sandbox Simulation (1:15 - 1:40)
* **Visual**: Navigate to the Web3 Wallet tab.
* **Goal**: Show the SandboxGuard pre-flight simulation before signing a swap.
* **Action**: Initiate a token swap of `USDT` to `BNB`.
* **Screen Action**: Show the loading spinner labeled *«Симуляция транзакции...»* (Simulating transaction...).
* **Result**: The app shows the predicted balance changes (e.g. `-10 USDT`, `+0.016 BNB`) and highlights that the contract target is verified and safe. The user authenticates with FaceID/PIN to sign and complete the transaction.

---

## 🎬 Scene 5: Outro (1:40 - 2:00)
* **Visual**: Zoom out to show the logo or website.
* **Narrator Voiceover**:
  > *«IBITI Guardian — это первый голосовой ассистент, который защищает ваши средства от ошибок ИИ и сетевых угроз. Торгуйте голосом безопасно!»* (IBITI Guardian — the first voice assistant that protects your funds from AI mistakes and network threats. Trade by voice safely!)
