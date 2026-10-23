# Changelog

All notable changes to this project will be documented in this file.

---

## [Unreleased] - 2026-10

### Added
- **dApp browser** for EVM sites with per-origin consent, Policy/EPK checks and native transaction preview.
- **Transaction history** with details for native and token transfers.
- **Safe Scan & Panic**: scan of active ERC-20 approvals with revoke and an honest error/retry state.
- Localized transaction preview with the network fee in the coin and in USD.
- Re-login prompt when the Privy session has expired.

### Changed
- Conversational voice routing and more Guardian assistant tools; more natural speech.

### Fixed
- Security: the AI assistant can no longer change security policy.
- Exact maximum transfer amounts; send modal offers only the active network's coins.
- Swaps: native-token sentinel and `slippageBps` for 0x v2.
- Android release build restored after the Privy upgrade.

---

## [1.0.0-hackathon] - 2026-06-17

### Added
- **Jarvis Voice AI**: Added full voice recognition (STT) and voice synthesis (TTS) supporting natural voice commands.
- **Crypto Speech Normalizer**: Added pronunciation guidelines in TTS prompts to correctly speak terms like "IBITI", "USDT", "ETH", "BNB", "ордер", and "доллар" without syllable swallowing or foreign accents.
- **Safety Autonomy Modes**: Introduced `Manual`, `Guarded`, and `Full Autonomy` modes to control AI execution permissions.
- **SandboxGuard**: Enabled pre-flight RPC simulation for Web3 transactions.
- **Heuristic Policy Engine**: Introduced per-transaction limits, daily budgets, price impact warning (>1% to 5%) and block (>5%) thresholds, and automatic risk downgrades for trusted contacts.
- **CEX Order Engine**: Seamless market order execution for MEXC, OKX, Gate.io, and Binance Spot.
- **Safe UX Localization**: Localized error message display. Cleaned voice feedback (e.g. "Ордер исполнен, удачных торгов.") instead of spelling out long alphanumeric order IDs or raw English errors.
- **Test Coverage**: Added 79 tests covering critical policy checks and sandbox validations.
