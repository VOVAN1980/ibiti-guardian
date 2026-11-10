# Privacy Policy

## 🔒 Non-Custodial & Privacy-First Architecture

IBITI Guardian is built with privacy as a core engineering specification. IBITI Guardian does not sell or monetize user data and runs no servers of its own that store user wallets or secrets. To work, the app sends some data directly from your device to the third-party services listed below.

---

## 1. Keys and Secrets
* **Wallet keys**: Your wallet is an embedded wallet provided by **Privy**. Signing happens through the Privy SDK on your device. IBITI Guardian never receives or stores your private key or seed phrase.
* **Exchange API keys**: Stored on your device in secure storage and sent only to the exchange they belong to. They are never sent to an AI provider.
* **PIN**: Stored on your device as a salted hash. It never leaves the device.

## 2. Personal Data
* **Sign-in**: To create or restore your wallet you sign in with Google or email through Privy, which processes that identifier under its own privacy policy.
* **No analytics**: There are no marketing trackers, analytics cookies or fingerprinting SDKs in the app.

## 3. Third-Party Services
* **OpenAI**: Speech recognition (Whisper), voice synthesis and the AI assistant. When you talk to the assistant, your message is sent together with wallet context:
  * shortened addresses (for example `0x7376…9015`) and the active network;
  * asset balances and their USD value, and the status of your latest transaction;
  * your AI settings and limits, and your saved assistant preferences and voice macros.

  When the assistant needs it, it can also request the full wallet address, your address book (contact names and addresses), your transaction history and the AI action log. Exchange API keys, your PIN and private keys are never sent.
* **Web search and page reading**: If the assistant searches the web, the query goes to DuckDuckGo. If it reads a web page, the page address goes to r.jina.ai.
* **Market analysis (IBITI/Jarvis)**: Market data and your market questions may be sent to the AI providers configured for analysis (Groq, DeepSeek, Anthropic, Mistral, Cerebras, OpenRouter, Google Gemini).
* **Privy**: Sign-in and embedded-wallet signing.
* **Moralis, Ankr and RPC nodes**: Balances, token metadata and transaction simulation for your wallet address.
* **Swap services (0x, Jupiter, SunSwap)**: Receive your wallet address and the swap parameters to build a quote.
* **Exchanges (MEXC, OKX, Gate.io, Binance)**: Queries and orders go directly from your device to the exchange's official endpoints.

## 4. Updates
This policy describes the current app version. It will be updated when the app starts sending data to new services.
