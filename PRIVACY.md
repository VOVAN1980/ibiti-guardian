# Privacy Policy

## 🔒 Non-Custodial & Privacy-First Architecture

IBITI Guardian is built with privacy as a core engineering specification. IBITI Guardian does not intentionally collect, sell, or monetize user PII. Some third-party APIs may process transient technical metadata required to provide their service.

---

## 1. Zero-Knowledge of Private Keys
* **Local Security**: Your private keys, seed phrases, and exchange API keys are processed and stored locally on your device in an encrypted SQLite database and secure storage container (Vault).
* **No Server Storage**: We do not run servers that store user wallets or secrets. All cryptographic signatures occur locally on-device.

## 2. No PII Collection
* **Zero Tracking**: IBITI Guardian does not collect names, emails, phone numbers, or IP addresses.
* **No Analytics Cookies**: There are no marketing trackers or user fingerprinting SDKs integrated into the codebase.

## 3. Third-Party Integrations
For the app to function, it connects to specific secure endpoints. Please review their privacy models if needed:
* **OpenAI API**: Used for Whisper (STT) and GPT-4o voice responses. Audio snippets are sent only to process transient transcription and voice synthesis.
* **Moralis & RPC Nodes**: Used for fetching token metadata and simulating transaction state.
* **Exchange APIs**: Direct CEX queries and order placements (MEXC, OKX, Gate.io, Binance) are executed locally from your device to the exchanges' official endpoints.

## 4. Updates
This privacy policy applies to the local app distribution. Any future features that require network routing will maintain the same zero-PII standard.
